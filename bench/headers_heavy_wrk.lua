-- wrk script: send 8 X-Custom-N request headers per request so the
-- adapter's HTTP_KEY_CACHE misses exactly 8 times per request, exercising
-- the upcase_underscore C path on the hot side.

wrk.headers["X-Forwarded-Region"] = "us-east-1"
wrk.headers["X-Forwarded-Cluster"] = "edge-04"
wrk.headers["X-Forwarded-Origin"] = "external"
wrk.headers["X-Forwarded-Trace"]  = "abc123"
wrk.headers["X-Custom-Account"]   = "42"
wrk.headers["X-Custom-Tenant"]    = "blue"
wrk.headers["X-Custom-Feature"]   = "on"
wrk.headers["X-Custom-Build"]     = "1.5.0"
