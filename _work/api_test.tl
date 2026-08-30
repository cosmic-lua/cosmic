#!/usr/bin/env cosmic
-- The quota-frugal half of `_work.api`: the pure fold behind a 304
-- reuse, rate-limit header parsing, the ETag and rate-limit caches
-- round-tripping through a real checkout root, and the reset time a
-- 403/429 refusal names. `reconcile` takes a fabricated response —
-- status, headers, body, exactly the three fields a live fetch would
-- hand it — so every branch, the 304 reuse included, is proven with
-- no network and no token. `api.call` itself (the live fetch, the
-- token check) is exercised only through the board's own flow against
-- a real GitHub token, same as `_work.gh`'s reads.

local hash = require("cosmic.hash")

local api = require("_work.api")
local fixture = require("_work.fixture")

-- A 304 means "unchanged": the cached status and body are what the
-- caller sees, and nothing new is written back — GitHub sent no body
-- of its own to cache.
local function test_reconcile_reuses_the_cached_body_on_304()
  local cached: api.CacheEntry = {status = 200, etag = "\"abc\"",
    body = "{\"ok\":true}", body_sha256 = hash.sha256_hex("{\"ok\":true}")}
  local status, body, fresh = api.reconcile(cached, 304, {}, "")
  assert(status == 200, "got: " .. tostring(status))
  assert(body == "{\"ok\":true}", "got: " .. body)
  assert(fresh == nil, "a 304 reuse writes nothing new")
end
test_reconcile_reuses_the_cached_body_on_304()

-- A fresh 200 carrying an ETag is cached, so the next call can
-- revalidate instead of paying for a full read.
local function test_reconcile_caches_a_fresh_200_with_an_etag()
  local status, body, fresh = api.reconcile(nil, 200, {etag = "\"xyz\""}, "{}")
  assert(status == 200)
  assert(body == "{}")
  assert(fresh ~= nil, "a 200 with an ETag is worth caching")
  assert(fresh.etag == "\"xyz\"" and fresh.status == 200 and fresh.body == "{}")
  assert(fresh.body_sha256 == hash.sha256_hex("{}"),
    "reconcile stamps the fresh entry's own integrity digest")
end
test_reconcile_caches_a_fresh_200_with_an_etag()

-- No ETag means no way to revalidate later, so there is nothing worth
-- writing — a cache entry with no ETag could never be reused.
local function test_reconcile_does_not_cache_without_an_etag()
  local _, _, fresh = api.reconcile(nil, 200, {}, "{}")
  assert(fresh == nil)
end
test_reconcile_does_not_cache_without_an_etag()

-- A non-2xx response is never cached, ETag or not: an error page is
-- not a value the next call should reuse.
local function test_reconcile_does_not_cache_a_non_2xx()
  local status, body, fresh = api.reconcile(nil, 404, {etag = "\"x\""}, "not found")
  assert(status == 404)
  assert(body == "not found")
  assert(fresh == nil)
end
test_reconcile_does_not_cache_a_non_2xx()

-- A 304 with nothing cached for it (the entry expired between the
-- request going out and the response coming back, say) passes the
-- live status and body through rather than reading into a nil cache.
local function test_reconcile_304_with_no_cached_entry_passes_through()
  local status, body, fresh = api.reconcile(nil, 304, {}, "")
  assert(status == 304)
  assert(body == "")
  assert(fresh == nil)
end
test_reconcile_304_with_no_cached_entry_passes_through()

-- rate_of reads both headers when GitHub sends them...
local function test_rate_of_reads_present_headers()
  local remaining, reset = api.rate_of({["x-ratelimit-remaining"] = "42",
      ["x-ratelimit-reset"] = "1700000000"})
  assert(remaining == 42, "got: " .. tostring(remaining))
  assert(reset == 1700000000, "got: " .. tostring(reset))
end
test_rate_of_reads_present_headers()

-- ...and neither is fabricated as 0 when a response carries none.
local function test_rate_of_is_nil_when_headers_are_absent()
  local remaining, reset = api.rate_of({})
  assert(remaining == nil)
  assert(reset == nil)
end
test_rate_of_is_nil_when_headers_are_absent()

-- The ETag cache round-trips through a real checkout's `o/`: a fresh
-- root has nothing, a write is read back exactly, and it lives under
-- `o/` rather than anywhere `git status` would ever see.
local function test_cache_round_trips_through_the_store_root()
  local s = fixture.init_state_repo("api-cache")
  assert(api.read_cache(s.root, "GET", "/repos/x/y") == nil,
    "a fresh checkout has no cache yet")
  api.write_cache(s.root, "GET", "/repos/x/y",
    {status = 200, etag = "\"abc\"", body = "{\"a\":1}",
      body_sha256 = hash.sha256_hex("{\"a\":1}")})
  local cached = api.read_cache(s.root, "GET", "/repos/x/y")
  assert(cached ~= nil, "the write is read back")
  assert(cached.status == 200 and cached.etag == "\"abc\""
    and cached.body == "{\"a\":1}", "got a mismatched entry back")
end
test_cache_round_trips_through_the_store_root()

-- A different request path caches under a different key: two GETs
-- never collide on one file.
local function test_cache_keys_by_method_and_path()
  local s = fixture.init_state_repo("api-cache-keys")
  api.write_cache(s.root, "GET", "/repos/x/y", {status = 200, etag = "\"one\"",
      body = "one", body_sha256 = hash.sha256_hex("one")})
  api.write_cache(s.root, "GET", "/repos/x/z", {status = 200, etag = "\"two\"",
      body = "two", body_sha256 = hash.sha256_hex("two")})
  local a = api.read_cache(s.root, "GET", "/repos/x/y")
  local b = api.read_cache(s.root, "GET", "/repos/x/z")
  assert(a ~= nil and a.body == "one")
  assert(b ~= nil and b.body == "two")
end
test_cache_keys_by_method_and_path()

-- A syntactically-valid entry (every field parses, all the right
-- types) whose body disagrees with its own digest is corruption, not
-- a value to replay on a 304 — read_cache treats it as a plain miss,
-- same as a half-written file.
local function test_read_cache_rejects_a_body_that_disagrees_with_its_digest()
  local s = fixture.init_state_repo("api-cache-corrupt")
  api.write_cache(s.root, "GET", "/repos/x/y", {status = 200, etag = "\"abc\"",
      body = "{\"a\":1}", body_sha256 = hash.sha256_hex("{\"a\":9}")})
  local cached = api.read_cache(s.root, "GET", "/repos/x/y")
  assert(cached == nil, "a body/digest mismatch must read as a miss")
end
test_read_cache_rejects_a_body_that_disagrees_with_its_digest()

-- The rate-limit fact persists the same way, one file per root, so
-- an optional caller can check the quota with no request of its own.
local function test_rate_round_trips_through_the_store_root()
  local s = fixture.init_state_repo("api-rate")
  local remaining, reset = api.read_rate(s.root)
  assert(remaining == nil and reset == nil, "a fresh checkout has no fact yet")
  api.write_rate(s.root, 4321, 1700000000)
  remaining, reset = api.read_rate(s.root)
  assert(remaining == 4321, "got: " .. tostring(remaining))
  assert(reset == 1700000000, "got: " .. tostring(reset))
end
test_rate_round_trips_through_the_store_root()

-- A nil remaining (no header on the response that produced it) writes
-- nothing, so a real prior fact is never overwritten with "unknown."
local function test_write_rate_skips_a_nil_remaining()
  local s = fixture.init_state_repo("api-rate-nil")
  api.write_rate(s.root, 999, 1700000000)
  api.write_rate(s.root, nil, nil)
  local remaining = api.read_rate(s.root)
  assert(remaining == 999, "the real fact survives a nil write: "
    .. tostring(remaining))
end
test_write_rate_skips_a_nil_remaining()

-- A 403 or 429 that carried a reset time names it, so a refusal says
-- when the quota comes back rather than only that it is gone.
local function test_error_of_names_the_reset_time_on_403()
  local res: api.ApiResult = {status = 403,
    value = {message = "API rate limit exceeded"}, headers = {},
    remaining = 0, reset = 1735689600}
  local msg = api.error_of("GET", "/repos/x/y", res)
  assert(msg:find("API rate limit exceeded", 1, true) ~= nil, "got: " .. msg)
  assert(msg:find("rate limit resets", 1, true) ~= nil, "got: " .. msg)
end
test_error_of_names_the_reset_time_on_403()

-- Any other status never names a reset time, even one the response
-- happened to carry — it is only ever the quota refusal's business.
local function test_error_of_omits_reset_time_off_403_429()
  local res: api.ApiResult = {status = 500, value = {}, headers = {},
    remaining = nil, reset = 1700000000}
  local msg = api.error_of("GET", "/x", res)
  assert(msg:find("resets", 1, true) == nil, "got: " .. msg)
end
test_error_of_omits_reset_time_off_403_429()
