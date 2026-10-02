//! Lossless supported S3 lifecycle JSON. Reject future fields rather than erase them.
use super::{json, SidecarError, Value};
use aws_sdk_s3::{
    primitives::{DateTime, DateTimeFormat},
    types::*,
};

fn fields(value: &Value, allowed: &[&str]) -> Result<(), SidecarError> {
    if let Some(object) = value.as_object() {
        for key in object.keys() {
            if !allowed.contains(&key.as_str()) {
                return Err(SidecarError::new(
                    "unsupported_feature",
                    format!(
                        "Lifecycle field {key} is not supported; configuration was not changed."
                    ),
                ));
            }
        }
    }
    Ok(())
}
fn date(value: &Value) -> Result<Option<DateTime>, SidecarError> {
    value
        .as_str()
        .map(|v| {
            DateTime::from_str(v, DateTimeFormat::DateTime)
                .map_err(|e| SidecarError::new("invalid_config", e.to_string()))
        })
        .transpose()
}
fn tag(value: &Value) -> Result<Tag, SidecarError> {
    fields(value, &["Key", "Value"])?;
    Tag::builder()
        .set_key(value["Key"].as_str().map(str::to_owned))
        .set_value(value["Value"].as_str().map(str::to_owned))
        .build()
        .map_err(|e| SidecarError::new("invalid_config", e.to_string()))
}
fn filter(value: &Value) -> Result<LifecycleRuleFilter, SidecarError> {
    fields(
        value,
        &[
            "Prefix",
            "Tag",
            "And",
            "ObjectSizeGreaterThan",
            "ObjectSizeLessThan",
        ],
    )?;
    let mut f = LifecycleRuleFilter::builder()
        .set_prefix(value["Prefix"].as_str().map(str::to_owned))
        .set_object_size_greater_than(value["ObjectSizeGreaterThan"].as_i64())
        .set_object_size_less_than(value["ObjectSizeLessThan"].as_i64());
    if value["Tag"].is_object() {
        f = f.tag(tag(&value["Tag"])?);
    }
    if value["And"].is_object() {
        let a = &value["And"];
        fields(
            a,
            &[
                "Prefix",
                "Tags",
                "ObjectSizeGreaterThan",
                "ObjectSizeLessThan",
            ],
        )?;
        let tags = a["Tags"]
            .as_array()
            .map(|v| v.iter().map(tag).collect::<Result<Vec<_>, _>>())
            .transpose()?;
        f = f.and(
            LifecycleRuleAndOperator::builder()
                .set_prefix(a["Prefix"].as_str().map(str::to_owned))
                .set_tags(tags)
                .set_object_size_greater_than(a["ObjectSizeGreaterThan"].as_i64())
                .set_object_size_less_than(a["ObjectSizeLessThan"].as_i64())
                .build(),
        );
    }
    Ok(f.build())
}
pub(super) fn parse_lifecycle_rules(value: &Value) -> Result<Vec<LifecycleRule>, SidecarError> {
    let items = value
        .as_array()
        .ok_or_else(|| SidecarError::new("invalid_config", "Lifecycle Rules must be an array."))?;
    items
        .iter()
        .map(|v| {
            fields(
                v,
                &[
                    "ID",
                    "Status",
                    "Prefix",
                    "Filter",
                    "Expiration",
                    "Transitions",
                    "NoncurrentVersionExpiration",
                    "NoncurrentVersionTransitions",
                    "AbortIncompleteMultipartUpload",
                ],
            )?;
            let status = v["Status"]
                .as_str()
                .filter(|s| matches!(*s, "Enabled" | "Disabled"))
                .ok_or_else(|| {
                    SidecarError::new(
                        "invalid_config",
                        "Lifecycle status must be Enabled or Disabled.",
                    )
                })?;
            let mut b = LifecycleRule::builder()
                .status(ExpirationStatus::from(status))
                .set_id(v["ID"].as_str().map(str::to_owned))
                .set_prefix(v["Prefix"].as_str().map(str::to_owned));
            if v["Filter"].is_object() {
                b = b.filter(filter(&v["Filter"])?);
            }
            let e = &v["Expiration"];
            if e.is_object() {
                fields(e, &["Days", "Date", "ExpiredObjectDeleteMarker"])?;
                b = b.expiration(
                    LifecycleExpiration::builder()
                        .set_days(e["Days"].as_i64().map(|i| i as i32))
                        .set_date(date(&e["Date"])?)
                        .set_expired_object_delete_marker(e["ExpiredObjectDeleteMarker"].as_bool())
                        .build(),
                );
            }
            if let Some(items) = v["Transitions"].as_array() {
                let mut transitions = vec![];
                for t in items {
                    fields(t, &["Days", "Date", "StorageClass"])?;
                    transitions.push(
                        Transition::builder()
                            .set_days(t["Days"].as_i64().map(|i| i as i32))
                            .set_date(date(&t["Date"])?)
                            .set_storage_class(
                                t["StorageClass"].as_str().map(TransitionStorageClass::from),
                            )
                            .build(),
                    );
                }
                b = b.set_transitions(Some(transitions));
            }
            let e = &v["NoncurrentVersionExpiration"];
            if e.is_object() {
                fields(e, &["NoncurrentDays", "NewerNoncurrentVersions"])?;
                b = b.noncurrent_version_expiration(
                    NoncurrentVersionExpiration::builder()
                        .set_noncurrent_days(e["NoncurrentDays"].as_i64().map(|i| i as i32))
                        .set_newer_noncurrent_versions(
                            e["NewerNoncurrentVersions"].as_i64().map(|i| i as i32),
                        )
                        .build(),
                );
            }
            if let Some(items) = v["NoncurrentVersionTransitions"].as_array() {
                let mut transitions = vec![];
                for t in items {
                    fields(
                        t,
                        &["NoncurrentDays", "NewerNoncurrentVersions", "StorageClass"],
                    )?;
                    transitions.push(
                        NoncurrentVersionTransition::builder()
                            .set_noncurrent_days(t["NoncurrentDays"].as_i64().map(|i| i as i32))
                            .set_newer_noncurrent_versions(
                                t["NewerNoncurrentVersions"].as_i64().map(|i| i as i32),
                            )
                            .set_storage_class(
                                t["StorageClass"].as_str().map(TransitionStorageClass::from),
                            )
                            .build(),
                    );
                }
                b = b.set_noncurrent_version_transitions(Some(transitions));
            }
            let a = &v["AbortIncompleteMultipartUpload"];
            if a.is_object() {
                fields(a, &["DaysAfterInitiation"])?;
                b = b.abort_incomplete_multipart_upload(
                    AbortIncompleteMultipartUpload::builder()
                        .set_days_after_initiation(
                            a["DaysAfterInitiation"].as_i64().map(|i| i as i32),
                        )
                        .build(),
                );
            }
            b.build()
                .map_err(|e| SidecarError::new("invalid_config", e.to_string()))
        })
        .collect()
}
pub(super) fn without_nulls(mut value: Value) -> Value {
    match &mut value {
        Value::Object(m) => {
            m.retain(|_, v| !v.is_null());
            for v in m.values_mut() {
                *v = without_nulls(v.take());
            }
        }
        Value::Array(a) => {
            for v in a {
                *v = without_nulls(v.take());
            }
        }
        _ => (),
    }
    value
}
fn date_raw(value: Option<&DateTime>) -> Option<String> {
    value.and_then(|d| d.fmt(DateTimeFormat::DateTime).ok())
}
pub(super) fn lifecycle_rule_raw(r: &LifecycleRule) -> Value {
    let filter = r.filter().map(|f| json!({"Prefix":f.prefix(),"Tag":f.tag().map(|t|json!({"Key":t.key(),"Value":t.value()})),"ObjectSizeGreaterThan":f.object_size_greater_than(),"ObjectSizeLessThan":f.object_size_less_than(),"And":f.and().map(|a|json!({"Prefix":a.prefix(),"Tags":a.tags().iter().map(|t|json!({"Key":t.key(),"Value":t.value()})).collect::<Vec<_>>(),"ObjectSizeGreaterThan":a.object_size_greater_than(),"ObjectSizeLessThan":a.object_size_less_than()}))}));
    without_nulls(json!({
        "ID":r.id(),"Status":r.status().as_str(),"Prefix":r.prefix(),"Filter":filter,
        "Expiration":r.expiration().map(|e|json!({"Days":e.days(),"Date":date_raw(e.date()),"ExpiredObjectDeleteMarker":e.expired_object_delete_marker()})),
        "Transitions": if r.transitions().is_empty() { None } else {Some(r.transitions().iter().map(|t|json!({"Days":t.days(),"Date":date_raw(t.date()),"StorageClass":t.storage_class().map(|c|c.as_str())})).collect::<Vec<_>>())},
        "NoncurrentVersionExpiration":r.noncurrent_version_expiration().map(|e|json!({"NoncurrentDays":e.noncurrent_days(),"NewerNoncurrentVersions":e.newer_noncurrent_versions()})),
        "NoncurrentVersionTransitions":if r.noncurrent_version_transitions().is_empty() {None} else {Some(r.noncurrent_version_transitions().iter().map(|t|json!({"NoncurrentDays":t.noncurrent_days(),"NewerNoncurrentVersions":t.newer_noncurrent_versions(),"StorageClass":t.storage_class().map(|c|c.as_str())})).collect::<Vec<_>>())},
        "AbortIncompleteMultipartUpload":r.abort_incomplete_multipart_upload().map(|a|json!({"DaysAfterInitiation":a.days_after_initiation()}))
    }))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn complex_roundtrip() {
        let v = json!({"ID":"complex","Status":"Enabled","Filter":{"And":{"Prefix":" spaced /","Tags":[{"Key":"tier","Value":"archive"}],"ObjectSizeGreaterThan":128,"ObjectSizeLessThan":900000}},"Transitions":[{"Date":"2030-01-01T00:00:00Z","StorageClass":"GLACIER"}],"Expiration":{"Date":"2035-01-01T00:00:00Z"},"NoncurrentVersionTransitions":[{"NoncurrentDays":60,"NewerNoncurrentVersions":3,"StorageClass":"STANDARD_IA"}],"NoncurrentVersionExpiration":{"NoncurrentDays":365,"NewerNoncurrentVersions":5}});
        let rules = parse_lifecycle_rules(&json!([v.clone()])).unwrap();
        assert_eq!(lifecycle_rule_raw(&rules[0]), v);
    }
    #[test]
    fn empty_filter_and_legacy_prefix_survive() {
        for predicate in [
            json!({"Filter":{}}),
            json!({"Prefix":""}),
            json!({"Filter":{"Tag":{"Key":"a","Value":"b"}}}),
            json!({"Filter":{"ObjectSizeGreaterThan":0}}),
        ] {
            let mut v = json!({"Status":"Enabled","Expiration":{"Days":30}});
            v.as_object_mut()
                .unwrap()
                .extend(predicate.as_object().unwrap().clone());
            assert_eq!(
                lifecycle_rule_raw(&parse_lifecycle_rules(&json!([v.clone()])).unwrap()[0]),
                v
            );
        }
    }
    #[test]
    fn unknown_fields_fail_closed() {
        assert!(parse_lifecycle_rules(&json!([{"Status":"Enabled","FutureField":true}])).is_err());
    }
}
