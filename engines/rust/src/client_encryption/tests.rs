use super::*;
use sha2::{Digest, Sha256};

pub(crate) fn vectors() -> Vec<Value> {
    serde_json::from_str::<Value>(include_str!(
        "../../../../contracts/vectors/age-stream.json"
    ))
    .unwrap()["cases"]
        .as_array()
        .unwrap()
        .clone()
}
pub(crate) fn plaintext(case: &Value) -> Vec<u8> {
    (0..case["plaintextLength"].as_u64().unwrap())
        .map(|i| ((i * 31 + (i >> 8) * 7 + 3) & 255) as u8)
        .collect()
}
pub(crate) fn config(case: &Value) -> ClientEncryption {
    ClientEncryption::parse(
        &json!({"format":"age-v1", "header":case["header"],
        "payloadNonce":case["payloadNonce"], "fileKey":case["fileKey"]}),
        true,
        1,
    )
    .unwrap()
    .unwrap()
}
pub(crate) fn object(case: &Value) -> Vec<u8> {
    let config = config(case);
    let cipher = config.cipher(&config.nonce);
    let plain = plaintext(case);
    let mut object = config.header.clone();
    object.extend_from_slice(&config.nonce);
    for i in 0..chunk_count(plain.len() as u64) {
        let start = (i * CHUNK) as usize;
        let end = (start + CHUNK as usize).min(plain.len());
        object.extend(ClientEncryption::seal(
            &cipher,
            i,
            end == plain.len(),
            plain[start..end].to_vec(),
        ));
    }
    object
}
fn decrypt(config: &ClientEncryption, object: &[u8]) -> Result<Vec<u8>, SidecarError> {
    let plain = config.plaintext_length(object.len() as u64)?;
    let prefix = config.header_length as usize + 16;
    let cipher = config.cipher(object[prefix - 16..prefix].try_into().unwrap());
    let mut output = Vec::new();
    for (index, chunk) in object[prefix..].chunks(SEALED as usize).enumerate() {
        let mut bytes = chunk.to_vec();
        output.extend_from_slice(ClientEncryption::open(
            &cipher,
            index as u64,
            index as u64 + 1 == chunk_count(plain),
            &mut bytes,
        )?);
    }
    Ok(output)
}
#[test]
fn every_age_vector_rebuilds_object_and_authenticates_plaintext() {
    for case in vectors() {
        let config = config(&case);
        let object = object(&case);
        assert_eq!(object.len() as u64, case["objectLength"].as_u64().unwrap());
        assert_eq!(
            config
                .object_length(case["plaintextLength"].as_u64().unwrap())
                .unwrap(),
            object.len() as u64
        );
        assert_eq!(
            format!("{:x}", Sha256::digest(&object)),
            case["objectSha256"]
        );
        let plain = decrypt(&config, &object).unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(&plain)),
            case["plaintextSha256"]
        );
    }
}
#[test]
fn corruption_truncation_missing_final_extra_and_swapped_chunks_fail_authentication() {
    for case in vectors() {
        let config = config(&case);
        let original = object(&case);
        let prefix = config.header_length as usize + 16;
        for index in 0..chunk_count(case["plaintextLength"].as_u64().unwrap()) {
            let mut corrupted = original.clone();
            corrupted[prefix + index as usize * SEALED as usize] ^= 1;
            let error = decrypt(&config, &corrupted).unwrap_err();
            assert_eq!(error.code, "decryption_failed");
            assert_eq!(error.details["chunk"], index);
        }
        let mut bad = vec![
            original[..original.len() - 1].to_vec(),
            original[..prefix].to_vec(),
        ];
        if original.len() > prefix + SEALED as usize {
            // Cut immediately after a full non-final chunk: the remaining tag
            // must not authenticate as final. Also cut the next chunk mid-body.
            bad.push(original[..prefix + SEALED as usize].to_vec());
            bad.push(original[..prefix + SEALED as usize + 1].to_vec());
            let mut swapped = original.clone();
            // Swap two full chunks where available, otherwise the final short one.
            let chunks: Vec<_> = original[prefix..].chunks(SEALED as usize).collect();
            swapped.truncate(prefix);
            swapped.extend_from_slice(chunks[1]);
            swapped.extend_from_slice(chunks[0]);
            for chunk in &chunks[2..] {
                swapped.extend_from_slice(chunk);
            }
            bad.push(swapped);
        }
        let mut extra = original.clone();
        extra.extend_from_slice(&original[prefix..(prefix + SEALED as usize).min(original.len())]);
        bad.push(extra);
        for bytes in bad {
            assert_eq!(
                decrypt(&config, &bytes).unwrap_err().code,
                "decryption_failed"
            );
        }
    }
}
#[test]
fn length_arithmetic_rejects_impossible_lengths_and_checks_boundaries() {
    let config = config(&vectors()[0]);
    let prefix = config.header_length + 16;
    for payload in 0..16 {
        assert!(config.plaintext_length(prefix + payload).is_err());
    }
    for multiple in 1..5 {
        for remainder in 1..=16 {
            assert!(config
                .plaintext_length(prefix + multiple * SEALED + remainder)
                .is_err());
        }
    }
    for plain in [
        0,
        1,
        CHUNK - 1,
        CHUNK,
        CHUNK + 1,
        CHUNK * 2,
        50000 * 1024_u64.pow(3),
    ] {
        assert_eq!(
            config
                .plaintext_length(config.object_length(plain).unwrap())
                .unwrap(),
            plain
        );
    }
    assert!(config.object_length(u64::MAX).is_err());
    assert!(config.plaintext_length(0).is_err());
}
#[test]
fn invalid_client_configuration_and_multiple_items_are_rejected() {
    let case = &vectors()[0];
    let upload = json!({"format":"age-v1","header":case["header"],"payloadNonce":case["payloadNonce"],"fileKey":case["fileKey"]});
    for count in [0, 2] {
        assert_eq!(
            ClientEncryption::parse(&upload, true, count)
                .err()
                .unwrap()
                .code,
            "invalid_config"
        );
    }
    for (name, value) in [
        ("format", json!("unknown")),
        ("fileKey", json!("AA==")),
        ("payloadNonce", json!("AA==")),
        ("header", json!("")),
        ("header", json!(base64::encode(vec![0; 65537]))),
        ("unknown", json!(true)),
    ] {
        let mut bad = upload.clone();
        bad[name] = value;
        assert_eq!(
            ClientEncryption::parse(&bad, true, 1).err().unwrap().code,
            "invalid_config"
        );
    }
    for length in [json!(0), json!(65537), json!(-1), json!(1.5)] {
        let bad = json!({"format":"age-v1","headerLength":length,"fileKey":case["fileKey"]});
        assert!(ClientEncryption::parse(&bad, false, 1).is_err());
    }
    assert!(ClientEncryption::parse(&Value::Null, true, 2)
        .unwrap()
        .is_none());
}
#[tokio::test]
async fn ciphertext_range_bodies_are_bounded_retryable_and_source_checked() {
    let case = &vectors().last().unwrap().clone();
    let config = config(case);
    let path = std::env::temp_dir().join(format!("age-range-{}", Uuid::new_v4()));
    fs::write(&path, plaintext(case)).unwrap();
    let snapshot = SourceSnapshot::capture(&path).unwrap();
    let expected = object(case);
    // Deliberately split through header, nonce, tags and plaintext chunks.
    for (start, length) in [
        (0, 7),
        (160, 30),
        (180, 8),
        (65535, 500),
        (5 * 1024 * 1024, 65555),
        (expected.len() as u64 - 16, 16),
    ] {
        let body = config
            .body(
                &path,
                &snapshot,
                case["plaintextLength"].as_u64().unwrap(),
                start,
                length,
            )
            .into_inner();
        let retry = ByteStream::new(body.try_clone().expect("retryable"));
        for mut stream in [ByteStream::new(body), retry] {
            let mut actual = Vec::new();
            while let Some(frame) = stream.try_next().await.unwrap() {
                assert!(frame.len() as u64 <= SEALED);
                actual.extend_from_slice(&frame);
            }
            assert_eq!(actual, expected[start as usize..(start + length) as usize]);
        }
    }
    fs::write(&path, b"changed").unwrap();
    let error = config
        .body(
            &path,
            &snapshot,
            case["plaintextLength"].as_u64().unwrap(),
            0,
            10,
        )
        .collect()
        .await;
    assert!(error.is_err());
    fs::remove_file(path).unwrap();
}

#[test]
fn ciphertext_sizing_enforces_threshold_part_count_and_object_limits() {
    let config = config(&vectors()[0]);
    let mib = 1024 * 1024;
    // A source below the threshold must use multipart when its ciphertext
    // crosses it. The same applies to the 10,000-part and object limits.
    let ciphertext = config.object_length(mib - 1).unwrap();
    assert!(ciphertext >= mib);
    assert_eq!(ciphertext.div_ceil(5 * mib), 1);
    let part_limit = 10000 * 5 * mib;
    let mut object_limit = 50000 * 1024_u64.pow(3);
    while config.plaintext_length(object_limit).is_err() {
        object_limit -= 1;
    }
    for (limit, threshold, part) in [
        (part_limit, mib, 5 * mib),
        (object_limit, u64::MAX, 5 * mib),
    ] {
        let plain = config.plaintext_length(limit).unwrap();
        validate_upload_size(config.object_length(plain).unwrap(), threshold, part).unwrap();
        assert_eq!(
            validate_upload_size(config.object_length(plain + 1).unwrap(), threshold, part)
                .unwrap_err()
                .code,
            "invalid_config"
        );
    }
}

#[test]
fn download_file_name_validation() {
    let case = &vectors()[0];
    let mut config = json!({"format":"age-v1","fileKey":case["fileKey"],"headerLength":case["headerLength"]});
    for name in [Value::Null, json!(1), json!(false), json!([]), json!({}), json!(""), json!("."), json!(".."), json!("a/b"), json!("a\\b"), json!("a\0b")] {
        config["fileName"] = name;
        assert_eq!(ClientEncryption::parse(&config, false, 1).err().unwrap().code, "invalid_config");
    }
    config["fileName"] = json!("report.pdf");
    assert_eq!(ClientEncryption::parse(&config, false, 1).unwrap().unwrap().file_name.as_deref(), Some("report.pdf"));
}
