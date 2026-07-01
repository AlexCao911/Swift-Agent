pub fn assert_error_debug_contains<T: core::fmt::Debug>(error: &T, expected: &str) {
    let actual = format!("{error:?}");
    assert!(
        actual.contains(expected),
        "expected error debug output to contain {expected:?}, got {actual}"
    );
}

pub fn assert_redacted_debug_output(value: &str) {
    for forbidden in ["sk-", "api_key", "secret", "token", "password"] {
        assert!(
            !value.to_lowercase().contains(forbidden),
            "debug output leaked forbidden marker {forbidden}: {value}"
        );
    }
}
