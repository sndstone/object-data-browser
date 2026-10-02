use super::*;
pub(super) async fn run(params: Value) -> SidecarResult {
    let profile = parse_profile(&params["profile"])?;
    let source_bucket = required_text(&params, "sourceBucketName", "Source bucket is required.")?;
    let source_key = required_text(&params, "sourceKey", "Source key is required.")?;
    let bucket = required_text(
        &params,
        "destinationBucketName",
        "Destination bucket is required.",
    )?;
    let key = required_text(&params, "destinationKey", "Destination key is required.")?;
    let selected = params["sourceVersionId"]
        .as_str()
        .or_else(|| params["versionId"].as_str())
        .map(str::to_owned);
    if source_bucket == bucket && source_key == key && selected.is_none() {
        return Err(SidecarError::new(
            "invalid_config",
            "Source and destination must differ unless restoring a selected version.",
        ));
    }
    let client = build_client(&profile).await?;
    let head = client
        .head_object()
        .bucket(&source_bucket)
        .key(&source_key)
        .set_version_id(selected.clone())
        .send()
        .await
        .map_err(map_sdk_error)?;
    let size = head.content_length().unwrap_or(0).max(0) as u64;
    let version = selected.or_else(|| head.version_id().map(str::to_owned));
    let mut source = urlencoding::encode(&format!("{source_bucket}/{source_key}")).to_string();
    if let Some(v) = &version {
        source.push_str(&format!("?versionId={}", urlencoding::encode(v)));
    }
    let (dest_version, etag) = if size <= 5 * 1024 * 1024 * 1024 {
        let out = client
            .copy_object()
            .bucket(&bucket)
            .key(&key)
            .copy_source(&source)
            .set_copy_source_if_match(head.e_tag().map(str::to_owned))
            .send()
            .await
            .map_err(map_sdk_error)?;
        (
            out.version_id().map(str::to_owned),
            out.copy_object_result()
                .and_then(|v| v.e_tag())
                .map(str::to_owned),
        )
    } else {
        let tags = client
            .get_object_tagging()
            .bucket(&source_bucket)
            .key(&source_key)
            .set_version_id(version.clone())
            .send()
            .await
            .map_err(map_sdk_error)?;
        let tagging = tags
            .tag_set()
            .iter()
            .map(|t| {
                format!(
                    "{}={}",
                    urlencoding::encode(t.key()),
                    urlencoding::encode(t.value())
                )
            })
            .collect::<Vec<_>>()
            .join("&");
        let created = client
            .create_multipart_upload()
            .bucket(&bucket)
            .key(&key)
            .set_content_type(head.content_type().map(str::to_owned))
            .set_content_encoding(head.content_encoding().map(str::to_owned))
            .set_content_disposition(head.content_disposition().map(str::to_owned))
            .set_content_language(head.content_language().map(str::to_owned))
            .set_cache_control(head.cache_control().map(str::to_owned))
            .set_expires(head.expires().cloned())
            .set_metadata(head.metadata().cloned())
            .set_storage_class(head.storage_class().cloned())
            .set_server_side_encryption(head.server_side_encryption().cloned())
            .set_ssekms_key_id(head.ssekms_key_id().map(str::to_owned))
            .set_bucket_key_enabled(head.bucket_key_enabled())
            .set_tagging(if tagging.is_empty() {
                None
            } else {
                Some(tagging)
            })
            .send()
            .await
            .map_err(map_sdk_error)?;
        let upload = created
            .upload_id()
            .ok_or_else(|| {
                SidecarError::new(
                    "unknown_outcome",
                    "Multipart copy did not return an upload ID.",
                )
            })?
            .to_string();
        let result: Result<(Option<String>, Option<String>), SidecarError> = async {
            let part_size = (128_u64 * 1024 * 1024).max(size.div_ceil(10_000));
            let semaphore = Arc::new(Semaphore::new(transfer_concurrency(&profile)));
            let mut tasks = JoinSet::new();
            for index in 0..size.div_ceil(part_size) {
                let c = client.clone();
                let b = bucket.clone();
                let k = key.clone();
                let u = upload.clone();
                let s = source.clone();
                let etag = head.e_tag().map(str::to_owned);
                let sem = semaphore.clone();
                tasks.spawn(async move {
                    let _permit = sem.acquire_owned().await.unwrap();
                    let start = index * part_size;
                    let end = (start + part_size - 1).min(size - 1);
                    let out = c
                        .upload_part_copy()
                        .bucket(b)
                        .key(k)
                        .upload_id(u)
                        .part_number(index as i32 + 1)
                        .copy_source(s)
                        .copy_source_range(format!("bytes={start}-{end}"))
                        .set_copy_source_if_match(etag)
                        .send()
                        .await
                        .map_err(map_sdk_error)?;
                    let etag = out
                        .copy_part_result()
                        .and_then(|v| v.e_tag())
                        .ok_or_else(|| {
                            SidecarError::new("unknown_outcome", "Copy part returned no ETag.")
                        })?;
                    Ok::<CompletedPart, SidecarError>(
                        CompletedPart::builder()
                            .part_number(index as i32 + 1)
                            .e_tag(etag)
                            .build(),
                    )
                });
            }
            let mut parts = vec![];
            let mut failure = None;
            while let Some(next) = tasks.join_next().await {
                match next {
                    Ok(Ok(p)) => parts.push(p),
                    Ok(Err(e)) => {
                        failure = Some(e);
                        tasks.abort_all();
                    }
                    Err(e) => {
                        if failure.is_none() {
                            failure = Some(SidecarError::new("engine_unavailable", e.to_string()));
                        }
                    }
                }
            }
            if let Some(e) = failure {
                return Err(e);
            }
            parts.sort_by_key(|p| p.part_number());
            let out = client
                .complete_multipart_upload()
                .bucket(&bucket)
                .key(&key)
                .upload_id(&upload)
                .multipart_upload(
                    CompletedMultipartUpload::builder()
                        .set_parts(Some(parts))
                        .build(),
                )
                .send()
                .await
                .map_err(map_sdk_error)?;
            Ok((
                out.version_id().map(str::to_owned),
                out.e_tag().map(str::to_owned),
            ))
        }
        .await;
        if result.is_err() {
            let _ = client
                .abort_multipart_upload()
                .bucket(&bucket)
                .key(&key)
                .upload_id(&upload)
                .send()
                .await;
        }
        result?
    };
    if etag.is_none() {
        return Err(SidecarError::new("unknown_outcome", "Copy completion returned no ETag; source retained and destination requires reconciliation."));
    }
    Ok(
        json!({"successCount":1,"failureCount":0,"failures":[],"sourceVersionId":version,"sourceETag":head.e_tag(),"destinationVersionId":dest_version,"etag":etag,"bytesCopied":size,"strategy":if size>5*1024*1024*1024{"multipart server-side copy"}else{"server-side copy"}}),
    )
}
