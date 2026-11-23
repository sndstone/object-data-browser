//! Namespace-safe XML reading and writing for S3 control documents.
//!
//! Elements are matched by local name, so `<s3:Key>` and `<Key>` are the same
//! element. Leaf text is kept exactly as the provider sent it (no trimming), and
//! elements the mapping does not know about are carried through to JSON and back
//! so provider extensions survive a read-modify-write cycle.

use crate::SidecarError;
use quick_xml::events::Event;
use quick_xml::Reader;
use serde_json::{Map, Value};

pub const S3_NAMESPACE: &str = "http://s3.amazonaws.com/doc/2006-03-01/";
const MAX_DEPTH: usize = 64;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Node {
    pub name: String,
    pub text: String,
    pub children: Vec<Node>,
}

impl Node {
    pub fn child(&self, name: &str) -> Option<&Node> {
        self.children.iter().find(|node| node.name == name)
    }

    pub fn children_named<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a Node> + 'a {
        self.children.iter().filter(move |node| node.name == name)
    }

    /// Text of a direct child, exactly as sent.
    pub fn text_of(&self, name: &str) -> Option<&str> {
        self.child(name).map(|node| node.text.as_str())
    }
}

fn invalid_response(message: impl Into<String>) -> SidecarError {
    SidecarError::new("invalid_response", message)
}

/// Parses one XML document into its root element.
pub fn parse(bytes: &[u8]) -> Result<Node, SidecarError> {
    let mut reader = Reader::from_reader(bytes);
    let config = reader.config_mut();
    config.trim_text(false);
    config.check_end_names = true;
    config.expand_empty_elements = false;
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<Node> = None;
    loop {
        let event = reader.read_event().map_err(|error| {
            invalid_response(format!("The provider returned malformed XML: {error}"))
        })?;
        match event {
            Event::Start(start) => {
                if root.is_some() {
                    return Err(invalid_response(
                        "The provider returned XML with more than one root element.",
                    ));
                }
                if stack.len() >= MAX_DEPTH {
                    return Err(invalid_response(
                        "The provider returned XML nested too deeply.",
                    ));
                }
                stack.push(Node {
                    name: local_name(start.local_name().as_ref())?,
                    ..Node::default()
                });
            }
            Event::Empty(start) => {
                let node = Node {
                    name: local_name(start.local_name().as_ref())?,
                    ..Node::default()
                };
                attach(&mut stack, &mut root, node)?;
            }
            Event::End(_) => {
                let node = stack
                    .pop()
                    .ok_or_else(|| invalid_response("The provider returned unbalanced XML."))?;
                attach(&mut stack, &mut root, node)?;
            }
            Event::Text(text) => {
                let value = text.xml10_content().map_err(|_| {
                    invalid_response("The provider returned XML text that is not UTF-8.")
                })?;
                push_text(&mut stack, &value)?;
            }
            Event::CData(data) => {
                let value = data.decode().map_err(|_| {
                    invalid_response("The provider returned XML text that is not UTF-8.")
                })?;
                push_text(&mut stack, &value)?;
            }
            Event::GeneralRef(reference) => {
                let resolved = if reference.is_char_ref() {
                    reference.resolve_char_ref().map_err(|_| {
                        invalid_response(
                            "The provider returned an invalid XML character reference.",
                        )
                    })?
                } else {
                    let name = reference.decode().map_err(|_| {
                        invalid_response("The provider returned an invalid XML entity.")
                    })?;
                    match name.as_ref() {
                        "lt" => Some('<'),
                        "gt" => Some('>'),
                        "amp" => Some('&'),
                        "apos" => Some('\''),
                        "quot" => Some('"'),
                        _ => None,
                    }
                };
                let character = resolved.ok_or_else(|| {
                    invalid_response("The provider returned an unknown XML entity.")
                })?;
                push_text(&mut stack, character.encode_utf8(&mut [0; 4]))?;
            }
            Event::Eof => break,
            // Declarations, comments, processing instructions and DOCTYPE carry
            // no data for S3 documents. Custom entities are never expanded.
            _ => {}
        }
    }
    if !stack.is_empty() {
        return Err(invalid_response("The provider returned truncated XML."));
    }
    root.ok_or_else(|| invalid_response("The provider returned an empty XML document."))
}

fn local_name(raw: &[u8]) -> Result<String, SidecarError> {
    std::str::from_utf8(raw).map(str::to_owned).map_err(|_| {
        invalid_response("The provider returned an XML element name that is not UTF-8.")
    })
}

fn attach(stack: &mut [Node], root: &mut Option<Node>, node: Node) -> Result<(), SidecarError> {
    if let Some(parent) = stack.last_mut() {
        parent.children.push(node);
    } else if root.is_none() {
        *root = Some(node);
    } else {
        return Err(invalid_response(
            "The provider returned XML with more than one root element.",
        ));
    }
    Ok(())
}

fn push_text(stack: &mut [Node], value: &str) -> Result<(), SidecarError> {
    match stack.last_mut() {
        Some(node) => node.text.push_str(value),
        None if value.chars().all(char::is_whitespace) => {}
        None => {
            return Err(invalid_response(
                "The provider returned text outside the XML root element.",
            ))
        }
    }
    Ok(())
}

/// True for characters XML 1.0 can carry (escaped where needed).
pub fn is_xml_char(character: char) -> bool {
    matches!(character, '\t' | '\n' | '\r' | '\u{20}'..='\u{D7FF}' | '\u{E000}'..='\u{FFFD}' | '\u{10000}'..='\u{10FFFF}')
}

pub fn is_xml_text(value: &str) -> bool {
    value.chars().all(is_xml_char)
}

/// Escapes element text. Carriage returns become character references so an
/// XML parser cannot normalise them away; characters XML 1.0 cannot carry are
/// refused rather than altered.
pub fn escape_text(value: &str) -> Result<String, SidecarError> {
    let mut output = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => output.push_str("&amp;"),
            '<' => output.push_str("&lt;"),
            '>' => output.push_str("&gt;"),
            '"' => output.push_str("&quot;"),
            '\'' => output.push_str("&apos;"),
            '\r' => output.push_str("&#13;"),
            other if is_xml_char(other) => output.push(other),
            _ => {
                return Err(SidecarError::new(
                    "invalid_config",
                    "The value contains a character that cannot be sent in an XML request.",
                ))
            }
        }
    }
    Ok(output)
}

fn valid_element_name(name: &str) -> bool {
    let mut characters = name.chars();
    matches!(characters.next(), Some(first) if first.is_ascii_alphabetic() || first == '_')
        && characters.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.'))
}

/// The configuration document a JSON value belongs to. It decides which
/// repeated XML elements are presented as named JSON arrays (boto3 shapes).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Doc {
    Lifecycle,
    Cors,
    Encryption,
    Tagging,
    ObjectLock,
    Retention,
    LegalHold,
    Versioning,
}

/// (document, parent element, repeated child element, JSON key)
const FLATTENED_LISTS: &[(Doc, &str, &str, &str)] = &[
    (Doc::Lifecycle, "LifecycleConfiguration", "Rule", "Rules"),
    (Doc::Lifecycle, "Rule", "Transition", "Transitions"),
    (
        Doc::Lifecycle,
        "Rule",
        "NoncurrentVersionTransition",
        "NoncurrentVersionTransitions",
    ),
    (Doc::Lifecycle, "And", "Tag", "Tags"),
    (Doc::Cors, "CORSConfiguration", "CORSRule", "CORSRules"),
    (Doc::Cors, "CORSRule", "AllowedOrigin", "AllowedOrigins"),
    (Doc::Cors, "CORSRule", "AllowedMethod", "AllowedMethods"),
    (Doc::Cors, "CORSRule", "AllowedHeader", "AllowedHeaders"),
    (Doc::Cors, "CORSRule", "ExposeHeader", "ExposeHeaders"),
    (
        Doc::Encryption,
        "ServerSideEncryptionConfiguration",
        "Rule",
        "Rules",
    ),
    (
        Doc::Encryption,
        "BlockedEncryptionTypes",
        "EncryptionType",
        "EncryptionType",
    ),
];

/// Wrapped lists: `<TagSet><Tag/>...</TagSet>` is `"TagSet": [...]`.
fn wrapped_child(name: &str) -> Option<&'static str> {
    match name {
        "TagSet" => Some("Tag"),
        _ => None,
    }
}

fn flattened_key(doc: Doc, parent: &str, child: &str) -> Option<&'static str> {
    FLATTENED_LISTS
        .iter()
        .find(|(d, p, c, _)| *d == doc && *p == parent && *c == child)
        .map(|(_, _, _, key)| *key)
}

fn flattened_element(doc: Doc, parent: &str, key: &str) -> Option<&'static str> {
    FLATTENED_LISTS
        .iter()
        .find(|(d, p, _, k)| *d == doc && *p == parent && *k == key)
        .map(|(_, _, child, _)| *child)
}

const INTEGER_FIELDS: &[&str] = &[
    "Days",
    "Years",
    "NoncurrentDays",
    "NewerNoncurrentVersions",
    "DaysAfterInitiation",
    "ObjectSizeGreaterThan",
    "ObjectSizeLessThan",
    "MaxAgeSeconds",
];
const BOOLEAN_FIELDS: &[&str] = &["ExpiredObjectDeleteMarker", "BucketKeyEnabled"];
const CONTAINER_FIELDS: &[&str] = &[
    "Filter",
    "And",
    "Tag",
    "Expiration",
    "Transition",
    "NoncurrentVersionTransition",
    "NoncurrentVersionExpiration",
    "AbortIncompleteMultipartUpload",
    "ApplyServerSideEncryptionByDefault",
    "BlockedEncryptionTypes",
    "Rule",
    "DefaultRetention",
    "CORSRule",
];

fn leaf_value(name: &str, text: &str) -> Value {
    if INTEGER_FIELDS.contains(&name) {
        if let Ok(number) = text.parse::<i64>() {
            return Value::from(number);
        }
    }
    if BOOLEAN_FIELDS.contains(&name) {
        match text {
            "true" => return Value::Bool(true),
            "false" => return Value::Bool(false),
            _ => {}
        }
    }
    if text.is_empty() && CONTAINER_FIELDS.contains(&name) {
        return Value::Object(Map::new());
    }
    if text.is_empty() && wrapped_child(name).is_some() {
        return Value::Array(Vec::new());
    }
    Value::String(text.to_string())
}

/// Converts an element's content to boto3-shaped JSON. Unknown elements are
/// kept: a single one as a value, repeated ones as an array under their name.
pub fn to_json(doc: Doc, node: &Node) -> Value {
    if node.children.is_empty() {
        return leaf_value(&node.name, &node.text);
    }
    let mut map = Map::new();
    for child in &node.children {
        if let Some(item) = wrapped_child(&child.name) {
            let values = child
                .children_named(item)
                .map(|inner| to_json(doc, inner))
                .collect();
            map.insert(child.name.clone(), Value::Array(values));
            continue;
        }
        let value = to_json(doc, child);
        if let Some(key) = flattened_key(doc, &node.name, &child.name) {
            match map
                .entry(key.to_string())
                .or_insert_with(|| Value::Array(Vec::new()))
            {
                Value::Array(items) => items.push(value),
                other => *other = Value::Array(vec![other.take(), value]),
            }
            continue;
        }
        match map.get_mut(&child.name) {
            None => {
                map.insert(child.name.clone(), value);
            }
            Some(Value::Array(items)) => items.push(value),
            Some(existing) => *existing = Value::Array(vec![existing.take(), value]),
        }
    }
    Value::Object(map)
}

/// Serialises a JSON object as a complete S3 XML document.
pub fn document(doc: Doc, root: &str, value: &Value) -> Result<Vec<u8>, SidecarError> {
    let map = value.as_object().ok_or_else(|| {
        SidecarError::new("invalid_config", format!("{root} must be a JSON object."))
    })?;
    let mut output = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    output.push('<');
    output.push_str(root);
    output.push_str(" xmlns=\"");
    output.push_str(S3_NAMESPACE);
    output.push_str("\">");
    write_members(doc, root, map, &mut output, 0)?;
    output.push_str("</");
    output.push_str(root);
    output.push('>');
    Ok(output.into_bytes())
}

fn write_members(
    doc: Doc,
    parent: &str,
    map: &Map<String, Value>,
    output: &mut String,
    depth: usize,
) -> Result<(), SidecarError> {
    if depth > MAX_DEPTH {
        return Err(SidecarError::new(
            "invalid_config",
            "The configuration is nested too deeply.",
        ));
    }
    for (key, value) in map {
        match value {
            Value::Null => {}
            Value::Array(items) => {
                if let Some(item) = wrapped_child(key) {
                    open(key, output)?;
                    for entry in items {
                        write_element(doc, item, entry, output, depth + 1)?;
                    }
                    close(key, output);
                } else {
                    let element = flattened_element(doc, parent, key).unwrap_or(key.as_str());
                    for entry in items {
                        write_element(doc, element, entry, output, depth + 1)?;
                    }
                }
            }
            other => write_element(doc, key, other, output, depth + 1)?,
        }
    }
    Ok(())
}

fn open(name: &str, output: &mut String) -> Result<(), SidecarError> {
    if !valid_element_name(name) {
        return Err(SidecarError::new(
            "invalid_config",
            format!("Configuration field {name:?} is not a valid XML element name."),
        ));
    }
    output.push('<');
    output.push_str(name);
    output.push('>');
    Ok(())
}

fn close(name: &str, output: &mut String) {
    output.push_str("</");
    output.push_str(name);
    output.push('>');
}

fn write_element(
    doc: Doc,
    name: &str,
    value: &Value,
    output: &mut String,
    depth: usize,
) -> Result<(), SidecarError> {
    match value {
        Value::Null => Ok(()),
        Value::Array(_) => Err(SidecarError::new(
            "invalid_config",
            format!("Configuration field {name:?} contains a nested array."),
        )),
        Value::Object(map) => {
            open(name, output)?;
            write_members(doc, name, map, output, depth)?;
            close(name, output);
            Ok(())
        }
        Value::String(text) => {
            open(name, output)?;
            output.push_str(&escape_text(text)?);
            close(name, output);
            Ok(())
        }
        Value::Bool(flag) => {
            open(name, output)?;
            output.push_str(if *flag { "true" } else { "false" });
            close(name, output);
            Ok(())
        }
        Value::Number(number) => {
            open(name, output)?;
            output.push_str(&number.to_string());
            close(name, output);
            Ok(())
        }
    }
}

/// Writes `<name>escaped</name>` for request documents assembled by hand.
pub fn text_element(name: &str, value: &str, output: &mut String) -> Result<(), SidecarError> {
    open(name, output)?;
    output.push_str(&escape_text(value)?);
    close(name, output);
    Ok(())
}
