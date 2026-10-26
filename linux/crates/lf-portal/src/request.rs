//! `org.freedesktop.portal.Request` helpers, shared with the daemon's
//! GlobalShortcuts client: where the portal answers a request, and strings
//! in its results.
//!
//! Waiting for the `Response` stays with each client: what else ends that
//! wait differs between them.

use std::collections::HashMap;

use zbus::zvariant::{OwnedValue, Value};

use crate::portal::PATH;

/// The sender part of request paths: the unique name without `:`, with
/// `.` as `_`.
pub fn sender_path_element(unique_name: &str) -> String {
    unique_name.trim_start_matches(':').replace('.', "_")
}

/// `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`: the object path
/// the portal uses for a request made with `token` by `unique_name`.
pub fn request_path(unique_name: &str, token: &str) -> String {
    format!(
        "{PATH}/request/{}/{token}",
        sender_path_element(unique_name)
    )
}

/// A string or object path, as a string.
pub fn string_value(value: &Value<'_>) -> Option<String> {
    match value {
        Value::Str(s) => Some(s.as_str().to_owned()),
        Value::ObjectPath(p) => Some(p.as_str().to_owned()),
        _ => None,
    }
}

/// The string or object path under `key` in a response's results.
pub fn string_result(results: &HashMap<String, OwnedValue>, key: &str) -> Option<String> {
    string_value(results.get(key)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zbus::zvariant::ObjectPath;

    #[test]
    fn request_paths_follow_the_portal_spec() {
        assert_eq!(sender_path_element(":1.42"), "1_42");
        assert_eq!(
            request_path(":1.42", "localflow_7_0"),
            "/org/freedesktop/portal/desktop/request/1_42/localflow_7_0"
        );
        // No unique name (a peer-to-peer connection): an empty sender.
        assert_eq!(
            request_path("", "t"),
            "/org/freedesktop/portal/desktop/request//t"
        );
    }

    #[test]
    fn strings_and_object_paths_are_read_as_strings() {
        let path = ObjectPath::try_from("/org/freedesktop/portal/desktop/session/1_42/s").unwrap();
        let results: HashMap<String, OwnedValue> = [
            ("text", Value::from("synthetic")),
            ("path", Value::from(path)),
            ("number", Value::from(7u32)),
            ("wrapped", Value::Value(Box::new(Value::from("inner")))),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_owned(), v.try_into().unwrap()))
        .collect();
        assert_eq!(
            string_result(&results, "text").as_deref(),
            Some("synthetic")
        );
        assert_eq!(
            string_result(&results, "path").as_deref(),
            Some("/org/freedesktop/portal/desktop/session/1_42/s")
        );
        assert_eq!(string_result(&results, "number"), None);
        assert_eq!(string_result(&results, "missing"), None);
        // A variant inside the variant is not unwrapped.
        assert_eq!(string_result(&results, "wrapped"), None);
    }
}
