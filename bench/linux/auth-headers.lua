-- Sends both Authorization and Cookie session=... so /auth takes the authorized branch.
wrk.headers["Authorization"] = "Bearer test-token-abc-123"
wrk.headers["Cookie"]         = "session=opaque-id-xyz"
wrk.headers["X-Request-Id"]   = "req-0001"
