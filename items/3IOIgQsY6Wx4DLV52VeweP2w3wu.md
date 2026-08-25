fetch's default retry policy backs off blind while servers say when
to come back: a 429 or 503 commonly carries Retry-After (seconds or
an HTTP date), and the wrapper's full-jitter exponential backoff
(cosmic/fetch/init.tl backoff(), default base 500ms cap 30s) ignores
it — grep for Retry-After in cosmic/fetch and tool/net/lfetch.c
finds nothing (2026-08-25, main a0c4ebd). The improvement: when the
response that triggered a retry carries Retry-After, the default
policy waits max(parsed value, jittered backoff) capped by
max_delay_ms, so a client under rate limiting stops hammering
half-open windows; a custom should_retry keeps full control (the
delay honor lives beside the policy call, not inside it). Parse both
forms (delta-seconds and HTTP-date via cosmic.time); an unparseable
value falls back to the jittered delay. Tests: loopback server
sending 429 with each form, asserting the observed inter-attempt
gap respects the header.
