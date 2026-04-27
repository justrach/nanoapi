-- Body matches bench/http_server.zig BodyModel { user_id, active, name }.
wrk.method = "POST"
wrk.body   = '{"user_id":42,"active":true,"name":"alice"}'
wrk.headers["Content-Type"] = "application/json"
