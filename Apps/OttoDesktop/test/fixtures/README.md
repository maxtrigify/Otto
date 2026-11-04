# Test fixtures

`localhost-test-cert.pem` and `localhost-test-key.pem` are a self-signed certificate for
`127.0.0.1`, used only by the desktop smoke test's local HTTPS site (website accounts are
HTTPS-only). They are not trusted anywhere; Otto Desktop accepts them only when the test sets
`OTTO_DESKTOP_TEST_TLS=1`, and only for 127.0.0.1.
