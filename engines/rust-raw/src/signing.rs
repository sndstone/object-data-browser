use crate::SidecarError;
use chrono::{DateTime, Utc};
use http::{header, HeaderMap, HeaderValue, Method};
use ring::{digest, hmac};
use std::collections::BTreeMap;
use std::sync::Mutex;

pub const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const ALGORITHM: &str = "AWS4-HMAC-SHA256";

pub fn encode(value: &str, keep_slashes: bool) -> String {
    const HEX: &[u8] = b"0123456789ABCDEF";
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || b"-_.~".contains(&byte) || (keep_slashes && byte == b'/')
        {
            encoded.push(char::from(byte));
        } else {
            encoded.push('%');
            encoded.push(char::from(HEX[(byte >> 4) as usize]));
            encoded.push(char::from(HEX[(byte & 15) as usize]));
        }
    }
    encoded
}

pub fn canonical_query(query: &[(&str, &str)]) -> String {
    let mut pairs: Vec<_> = query
        .iter()
        .map(|(key, value)| (encode(key, false), encode(value, false)))
        .collect();
    pairs.sort_unstable();
    pairs
        .into_iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join("&")
}

pub struct Signer {
    access: String,
    secret: String,
    token: Option<String>,
    region: String,
    key: Mutex<Option<(String, hmac::Key)>>,
}

impl Signer {
    pub fn new(access: String, secret: String, token: Option<String>, region: String) -> Self {
        Self {
            access,
            secret,
            token,
            region,
            key: Mutex::new(None),
        }
    }

    fn signing_key(&self, day: &str) -> hmac::Key {
        let mut cached = self.key.lock().unwrap();
        if let Some((key_day, key)) = cached.as_ref() {
            if key_day == day {
                return key.clone();
            }
        }
        let first = hmac::Key::new(hmac::HMAC_SHA256, format!("AWS4{}", self.secret).as_bytes());
        let date = derive(&first, day);
        let region = derive(&date, &self.region);
        let service = derive(&region, "s3");
        let key = derive(&service, "aws4_request");
        *cached = Some((day.to_owned(), key.clone()));
        key
    }

    fn scope(&self, day: &str) -> String {
        format!("{day}/{}/s3/aws4_request", self.region)
    }

    fn signature(&self, canonical: &str, timestamp: &str, day: &str, scope: &str) -> String {
        let canonical_hash = hex::encode(digest::digest(&digest::SHA256, canonical.as_bytes()));
        let to_sign = format!("{ALGORITHM}\n{timestamp}\n{scope}\n{canonical_hash}");
        hex::encode(hmac::sign(&self.signing_key(day), to_sign.as_bytes()))
    }

    pub fn sign(
        &self,
        method: &Method,
        path: &str,
        query: &str,
        headers: &mut HeaderMap,
        payload_hash: &str,
        now: DateTime<Utc>,
    ) -> Result<(), SidecarError> {
        let timestamp = now.format("%Y%m%dT%H%M%SZ").to_string();
        let day = &timestamp[..8];
        let scope = self.scope(day);
        headers.insert("x-amz-date", header_value(&timestamp)?);
        headers.insert("x-amz-content-sha256", header_value(payload_hash)?);
        if let Some(token) = &self.token {
            let mut value = header_value(token)?;
            value.set_sensitive(true);
            headers.insert("x-amz-security-token", value);
        }

        let mut ordered: BTreeMap<_, Vec<_>> = BTreeMap::new();
        for (name, value) in headers.iter() {
            if matches!(
                name.as_str(),
                "authorization"
                    | "connection"
                    | "content-length"
                    | "expect"
                    | "transfer-encoding"
                    | "user-agent"
            ) {
                continue;
            }
            let value = value
                .to_str()
                .map_err(|_| SidecarError::new("invalid_config", "Invalid HTTP header value."))?;
            let normalized = value.split_ascii_whitespace().collect::<Vec<_>>().join(" ");
            ordered.entry(name.as_str()).or_default().push(normalized);
        }
        let signed = ordered.keys().copied().collect::<Vec<_>>().join(";");
        let canonical_headers: String = ordered
            .into_iter()
            .map(|(key, values)| format!("{key}:{}\n", values.join(",")))
            .collect();
        let canonical =
            format!("{method}\n{path}\n{query}\n{canonical_headers}\n{signed}\n{payload_hash}");
        let signature = self.signature(&canonical, &timestamp, day, &scope);
        let mut auth = header_value(&format!(
            "{ALGORITHM} Credential={}/{scope},SignedHeaders={signed},Signature={signature}",
            self.access
        ))?;
        auth.set_sensitive(true);
        headers.insert(header::AUTHORIZATION, auth);
        Ok(())
    }

    pub fn presign(
        &self,
        host: &str,
        path: &str,
        query: &[(&str, &str)],
        expiration: u64,
        now: DateTime<Utc>,
    ) -> String {
        let timestamp = now.format("%Y%m%dT%H%M%SZ").to_string();
        let day = &timestamp[..8];
        let scope = self.scope(day);
        let credential = format!("{}/{scope}", self.access);
        let expiration = expiration.to_string();
        let mut query = query.to_vec();
        query.extend([
            ("X-Amz-Algorithm", ALGORITHM),
            ("X-Amz-Credential", credential.as_str()),
            ("X-Amz-Date", timestamp.as_str()),
            ("X-Amz-Expires", expiration.as_str()),
            ("X-Amz-SignedHeaders", "host"),
        ]);
        if let Some(token) = &self.token {
            query.push(("X-Amz-Security-Token", token));
        }
        let query = canonical_query(&query);
        let canonical = format!("GET\n{path}\n{query}\nhost:{host}\n\nhost\nUNSIGNED-PAYLOAD");
        format!(
            "{query}&X-Amz-Signature={}",
            self.signature(&canonical, &timestamp, day, &scope)
        )
    }
}

pub fn header_value(value: &str) -> Result<HeaderValue, SidecarError> {
    HeaderValue::from_str(value)
        .map_err(|_| SidecarError::new("invalid_config", "Invalid HTTP header value."))
}

fn derive(key: &hmac::Key, value: &str) -> hmac::Key {
    hmac::Key::new(
        hmac::HMAC_SHA256,
        hmac::sign(key, value.as_bytes()).as_ref(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn official_example() -> (Signer, DateTime<Utc>) {
        // Public AWS documentation credentials, exclusively for fixed vectors.
        let signer = Signer::new(
            "AKIAIOSFODNN7EXAMPLE".into(),
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY".into(),
            None,
            "us-east-1".into(),
        );
        (signer, "2013-05-24T00:00:00Z".parse().unwrap())
    }

    #[test]
    fn official_s3_header_signing_examples() {
        // AWS S3 Developer Guide, "Signature Calculations for the Authorization Header".
        let (signer, now) = official_example();
        for (method, path, query, extra, hash, expected) in [
            (
                Method::GET,
                "/test.txt",
                "",
                Some(("range", "bytes=0-9")),
                EMPTY_SHA256,
                "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
            ),
            (
                Method::GET,
                "/",
                "lifecycle=",
                None,
                EMPTY_SHA256,
                "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543",
            ),
            (
                Method::GET,
                "/",
                "max-keys=2&prefix=J",
                None,
                EMPTY_SHA256,
                "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7",
            ),
        ] {
            let mut headers = HeaderMap::new();
            headers.insert(
                header::HOST,
                HeaderValue::from_static("examplebucket.s3.amazonaws.com"),
            );
            if let Some((key, value)) = extra {
                headers.insert(key, HeaderValue::from_static(value));
            }
            signer
                .sign(&method, path, query, &mut headers, hash, now)
                .unwrap();
            assert!(
                headers[header::AUTHORIZATION]
                    .to_str()
                    .unwrap()
                    .ends_with(expected),
                "{query}: {:?}",
                headers[header::AUTHORIZATION].to_str().unwrap()
            );
        }
    }

    #[test]
    fn official_s3_signed_put_payload() {
        let (signer, now) = official_example();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::HOST,
            HeaderValue::from_static("examplebucket.s3.amazonaws.com"),
        );
        headers.insert(
            header::DATE,
            HeaderValue::from_static("Fri, 24 May 2013 00:00:00 GMT"),
        );
        headers.insert(
            "x-amz-storage-class",
            HeaderValue::from_static("REDUCED_REDUNDANCY"),
        );
        let hash = hex::encode(digest::digest(&digest::SHA256, b"Welcome to Amazon S3."));
        signer
            .sign(
                &Method::PUT,
                "/test%24file.text",
                "",
                &mut headers,
                &hash,
                now,
            )
            .unwrap();
        assert!(headers[header::AUTHORIZATION]
            .to_str()
            .unwrap()
            .ends_with("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"));
    }

    #[test]
    fn official_s3_presigning_example() {
        let (signer, now) = official_example();
        let query = signer.presign(
            "examplebucket.s3.amazonaws.com",
            "/test.txt",
            &[],
            86400,
            now,
        );
        assert!(query.ends_with(
            "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        ));
    }

    #[test]
    fn rfc3986_and_sorting_are_byte_exact() {
        assert_eq!(
            encode(" /a//../+%雪 ?#%2F", true),
            "%20/a//../%2B%25%E9%9B%AA%20%3F%23%252F"
        );
        assert_eq!(
            canonical_query(&[("z", ""), ("x", "+"), ("x", " "), ("+", "/")]),
            "%2B=%2F&x=%20&x=%2B&z="
        );
    }

    #[test]
    fn temporary_credentials_are_signed_and_encoded() {
        let (_, now) = official_example();
        let signer = Signer::new(
            "public".into(),
            "private".into(),
            Some("a+/= b".into()),
            "us-east-1".into(),
        );
        let mut headers = HeaderMap::new();
        headers.insert(header::HOST, HeaderValue::from_static("test.example:9000"));
        signer
            .sign(&Method::GET, "/", "", &mut headers, EMPTY_SHA256, now)
            .unwrap();
        assert!(headers[header::AUTHORIZATION]
            .to_str()
            .unwrap()
            .contains(";x-amz-security-token,Signature="));
        assert!(headers["x-amz-security-token"].is_sensitive());
        let signed = signer.presign("test.example:9000", "/", &[("versionId", "null")], 60, now);
        assert!(signed.contains("X-Amz-Security-Token=a%2B%2F%3D%20b&"));
        assert!(signed.contains("versionId=null&"));
    }
}
