use super::*;

tokio::task_local! {
    pub(super) static SECRETS: Vec<String>;
}

pub(super) fn sensitive(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    name == "filename"
        || name == "filekey"
        || name == "customerkey"
        || name == "x-amz-server-side-encryption-customer-key"
        || name == "x-amz-copy-source-server-side-encryption-customer-key"
        || name == "x-ms-encryption-key"
}

pub(super) fn collect(value: &Value) -> Vec<String> {
    let mut result = Vec::new();
    match value {
        Value::Object(map) => {
            for (name, value) in map {
                if sensitive(name) {
                    // fileName is hidden as a field only. Its value is an
                    // ordinary word and the published path contains it.
                    if name.eq_ignore_ascii_case("filename") {
                        continue;
                    }
                    if let Some(key) = value.as_str().filter(|key| !key.is_empty()) {
                        result.push(key.to_owned());
                    }
                } else {
                    result.extend(collect(value));
                }
            }
        }
        Value::Array(items) => {
            for item in items {
                result.extend(collect(item));
            }
        }
        _ => {}
    }
    result
}

pub(super) fn collect_conformance(params: &Value) -> Vec<String> {
    let mut keys = collect(params);
    let profile = &params["profile"];
    // Static profile parsing trims secretKey but preserves sessionToken.
    for key in [
        profile["secretKey"].as_str().map(str::trim),
        profile["sessionToken"].as_str(),
    ] {
        if let Some(key) = key.filter(|key| !key.is_empty()) {
            keys.push(key.to_owned());
        }
    }
    keys
}

pub(super) fn text(value: &str) -> String {
    SECRETS
        .try_with(|keys| {
            keys.iter().fold(value.to_owned(), |text, key| {
                text.replace(key, "[redacted]")
            })
        })
        .unwrap_or_else(|_| value.to_owned())
}

pub(super) fn value(mut value: Value) -> Value {
    match &mut value {
        Value::Object(map) => {
            for (key, item) in std::mem::take(map) {
                let item = if sensitive(&key) {
                    json!("[redacted]")
                } else {
                    self::value(item)
                };
                map.insert(text(&key), item);
            }
        }
        Value::Array(items) => {
            for item in items {
                *item = self::value(item.take());
            }
        }
        Value::String(item) => *item = text(item),
        _ => {}
    }
    value
}

#[cfg(test)]
tokio::task_local! {
    pub(super) static CAPTURE: Option<Arc<Mutex<Vec<String>>>>;
}

#[cfg(test)]
pub(super) fn capture(line: &str) {
    let _ = CAPTURE.try_with(|sink| {
        if let Some(sink) = sink {
            sink.lock().unwrap().push(line.to_owned());
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn client_file_key_is_redacted_from_captured_output_and_worker_errors() {
        const KEY: &str = "1VhQv1Wmb7PsDDk3j2hNDw==";
        let params = json!({"clientEncryption":{"format":"age-v1","fileKey":KEY,"fileName":"hidden-name-sentinel.pdf"}});
        assert!(collect(&params).contains(&KEY.to_owned()));
        assert!(!value(params.clone()).to_string().contains("hidden-name-sentinel.pdf"));
        assert!(!value(params.clone()).to_string().contains(KEY));
        assert_eq!(sanitize_header_value("fileKey", KEY), "[redacted]");
        assert!(!summarize_body("application/json", params.to_string().as_bytes()).contains(KEY));
        let captured = Arc::new(Mutex::new(Vec::new()));
        CAPTURE
            .scope(
                Some(captured.clone()),
                SECRETS.scope(collect(&params), async {
                    emit_structured_log(
                        "debug",
                        "api",
                        format!("request: {params}; {KEY}"),
                        "test",
                    );
                    emit_transfer_event(
                        &json!({"outputLines":[KEY],"clientEncryption":{"fileKey":KEY}}),
                    );
                    let error = run_bounded(
                        1,
                        1,
                        |_| async {
                            emit_structured_log("debug", "api", KEY.into(), "worker");
                            Err::<(), _>(SidecarError::with_details(
                                "decryption_failed",
                                KEY,
                                json!({"chunk":0,"diagnostic":KEY}),
                            ))
                        },
                        |_| {},
                    )
                    .await
                    .unwrap_err();
                    write_response("file-key-test".into(), Err(error));
                    let result = handle_request(Request {
                        request_id: "file-key-test".into(),
                        method: KEY.into(),
                        params,
                    })
                    .await;
                    write_response("file-key-test".into(), result);
                }),
            )
            .await;
        let lines = captured.lock().unwrap().join("\n");
        assert!(lines.contains("[redacted]"));
        assert!(!lines.contains(KEY), "file key leaked in captured output");
    }
}
