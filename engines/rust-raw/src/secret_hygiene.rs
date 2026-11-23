use serde_json::Value;

tokio::task_local! {
    pub(super) static SECRETS: Vec<String>;
}

#[cfg(test)]
tokio::task_local! {
    pub(super) static CAPTURE: Option<std::sync::Arc<std::sync::Mutex<Vec<String>>>>;
}

fn sensitive(key: &str) -> bool {
    matches!(
        key.to_ascii_lowercase().as_str(),
        "accesskey"
            | "secretkey"
            | "sessiontoken"
            | "externalid"
            | "customerkey"
            | "filekey"
            | "filename"
            | "passphrase"
            | "encryptionkey"
            | "azurecredentials"
            | "azuresastoken"
            | "authorization"
            | "x-amz-security-token"
            | "x-amz-signature"
            | "x-amz-credential"
            | "x-amz-server-side-encryption-customer-key"
            | "x-amz-copy-source-server-side-encryption-customer-key"
            | "x-ms-encryption-key"
    )
}

pub(super) fn collect(value: &Value) -> Vec<String> {
    fn collect_values(value: &Value, secrets: &mut Vec<String>) {
        match value {
            Value::Object(map) => {
                for (key, value) in map {
                    if sensitive(key) {
                        // File names are redacted by field. Their values can be
                        // ordinary words and must not be substituted in job text.
                        if !key.eq_ignore_ascii_case("filename") {
                            if let Some(text) = value.as_str().filter(|s| !s.is_empty()) {
                                secrets.push(text.to_owned());
                                secrets.push(crate::signing::encode(text, false));
                            }
                        }
                    } else {
                        collect_values(value, secrets);
                    }
                }
            }
            Value::Array(values) => values
                .iter()
                .for_each(|value| collect_values(value, secrets)),
            _ => {}
        }
    }

    let mut secrets = Vec::new();
    collect_values(value, &mut secrets);
    secrets.sort_unstable_by(|left, right| right.len().cmp(&left.len()).then(left.cmp(right)));
    secrets.dedup();
    secrets
}

pub(super) fn text(value: &str) -> String {
    SECRETS
        .try_with(|secrets| {
            secrets.iter().fold(value.to_owned(), |text, key| {
                text.split("[redacted]")
                    .map(|part| part.replace(key, "[redacted]"))
                    .collect::<Vec<_>>()
                    .join("[redacted]")
            })
        })
        .unwrap_or_else(|_| value.to_owned())
}

/// Strip sensitive fields and sanitize diagnostics without altering structured
/// values such as object keys, run IDs, status codes and output paths.
pub(super) fn value(mut value: Value) -> Value {
    fn sanitize(value: &mut Value, diagnostic: bool) {
        match value {
            Value::Object(map) => {
                map.retain(|key, field| {
                    if sensitive(key) {
                        return false;
                    }
                    let diagnostic = matches!(
                        key.as_str(),
                        "message"
                            | "reason"
                            | "logLine"
                            | "liveLog"
                            | "outputLines"
                            | "debugLogExcerpt"
                            | "lastStatus"
                            | "currentItemLabel"
                    );
                    sanitize(field, diagnostic);
                    true
                });
            }
            Value::Array(items) => items.iter_mut().for_each(|item| sanitize(item, diagnostic)),
            Value::String(item) if diagnostic => *item = text(item),
            _ => {}
        }
    }
    sanitize(&mut value, false);
    value
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[tokio::test]
    async fn credential_matches_do_not_mutate_structured_protocol_data() {
        let profile = json!({"accessKey":"fixture","secretKey":"running","sessionToken":"id"});
        SECRETS.scope(collect(&profile), async {
            let wire = value(json!({
                "status":"running","id":"run-id","profile":{"accessKey":"fixture"},
                "config":{"bucketName":"fixture","prefix":"fixture/running/id","csvOutputPath":"id/running.csv"},
                "outputLines":["fixture running id"],
            }));
            assert_eq!(wire["status"], "running");
            assert_eq!(wire["id"], "run-id");
            assert_eq!(wire["config"]["bucketName"], "fixture");
            assert_eq!(wire["config"]["prefix"], "fixture/running/id");
            assert_eq!(wire["config"]["csvOutputPath"], "id/running.csv");
            assert!(wire["profile"].as_object().unwrap().is_empty());
            assert_eq!(wire["outputLines"][0], "[redacted] [redacted] [redacted]");
            assert_eq!(wire, value(wire.clone()));
        }).await;
    }
}
