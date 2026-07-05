# P1 — C-boundary and cross-layer contracts

Part of the [pre-stable API review](README.md). Items 14–21.

### 14. One error convention at the C boundary: `nil, err_string, errno?`

**Repo:** whilp/cosmopolitan (epic; land module-by-module) · **Layer:** cosmo-C

Today's inventory (all confirmed in source or probes): `nil, unix.Errno`
userdata (lunix.c:219-235, Slurp/Barf); a *different* `re.Errno` userdata
with a different method set (lre.c:168-204); `nil, string` (zip, fetch, json,
argon2, Inflate); **throws on data-dependent errors** ([verified]
`Uncompress` on corrupt input, `DecodeHex` on odd length,
`GetRandomBytes(257)`); sentinel returns ([verified] `ParseIp` → `-1`,
`ParseHttpDateTime` → `0`); and the argon2 `verify` tri-state
(`true | false | nil, err`). cosmic pays the tax everywhere: `errno.tl`
exists to stringify userdata, `compress.tl` must pcall, `ip.tl` propagates
-1, `hash.tl` needs 3-way disambiguation.

**Change.** One rule for all modules: success = `value...` (or `true`);
failure = `nil, err: string, errno: integer?` with err formatted
`"open /etc/passwd: ENOENT: No such file or directory"` (include the path —
cosmic adds it manually at every call site today); `error()` reserved for
programmer errors (bad argument types/ranges). Kill both Errno userdata
flavors, all data-error throws, all sentinels, the tri-state
(`verify → ok: boolean, err: string?`). In the same wave, standardize
definitions.lua on ONE fallibility dialect —
`---@return T|nil value, unix.Errno? error` — and ban the
`@overload fun(...): nil, Errno` idiom via a new ratchet check (the two
dialects are why #8 happened).

**Plan.** Start with `LuaUnixSysretErrno` (lunix.c:219): push nil + formatted
string (reuse the existing `__tostring`) + integer; delete the unix.Errno
metatable. Then lre, then the lfuncs throwers. Red per module: e.g.
`type(select(2, unix.open("/nonexistent"))) == "string"` and
`select(3, ...) == unix.ENOENT`. Knock-ons are large but mechanical: 200+
definitions.lua sites, cosmos release, regen; cosmic's `errno.tl` shrinks to
a lookup table and every wrapper drops its stringify call. Land as its own
release wave — this is exactly what the stable cut exists for.

### 15. re: captures are unusable, no-match is a truthy "error", subject isn't binary-safe

**Repo:** both · **Layer:** cosmo-C + cosmic

`LuaReSearchImpl` (lre.c:59-75) returns match + each capture group as
separate values and `nil, re.Errno("No match")` on no-match. **[verified]** —
captures ARE returned at runtime, but Teal can't type variadic returns, so
cosmic's `Regex:search` (re.tl:10-17) declares a single `string`: capture
groups are unusable through the entire cosmic stack. And idiomatic
`local m, err = rx:search(t); if err then ...` treats every non-match as an
error (the Errno is truthy). Subject uses `luaL_checkstring` — not
binary-safe. Also cosmic `re.match` returning boolean collides conceptually
with Lua's `string.match`.

**Change.** C: `rx:search(text, flags?) -> match: string, captures: {string}`
on match; bare `nil` on no-match; `nil, err: string` only for real regexec
errors (REG_ESPACE); use `luaL_checklstring` + `REG_STARTEND`. cosmic:

```teal
search: function(self: Regex, text: string, flags?: integer): string | nil, {string}
test:   function(self: Regex, text: string): boolean   -- rename of match
```

**Plan.** Red (cosmopolitan re test): `m, caps = rx:search("12-34")` with
pattern `(%d+)-(%d+)` ERE-equivalent asserts caps table; no-match returns
exactly one value. Green: build the captures table in C. definitions.lua,
pin bump, regen; cosmic wrapper gains the feature it currently cannot offer.
Fix the wrong "O(2^n) complexity" doc in re.tl:5 while there.

### 16. sqlite: blob binding, default busy timeout, raw-surface leaks

**Repo:** whilp/cosmic (blob is exposable without C changes) · **Layer:** cosmic

- **Blob:** `dbvm_bind_index` (lsqlite3.c:467-486) binds every Lua string as
  TEXT; the high-level API never calls the existing `bind_blob`
  (lsqlite3.c:516). [verified by agent] — a value inserted into a BLOB
  column round-trips but `typeof()` is `text`: wrong affinity, wrong
  comparisons/indexes. Add `sqlite.blob(s)` returning a marked wrapper that
  every bind loop recognizes (`getmetatable(v) == BlobMeta →
  raw:bind_blob(i, v.data)`).
- **Busy timeout:** `open()` never sets one; SQLite's default is 0, so two
  cosmic processes on one file DB fail instantly with BUSY. Default 5000ms
  via the existing `db_busy_timeout` (lsqlite3.c:1495), overridable:
  `open(filename, opts?: {busy_timeout_ms: integer, read_only: boolean})`.
- **Prepare tri-shape** `(stmt, rc, errmsg)` should be wrapped away before
  the surface freezes.

**Plan.** Red: `test_blob_bind_affinity` (insert `sqlite.blob("\0\1\2")`,
assert `typeof == "blob"` + byte round-trip); `test_busy_timeout_applied`
(IMMEDIATE tx on handle 1, timed write on handle 2). Green: blob marker +
`bind_blob` declared on the RawStatement record; `busy_timeout` call in
`open`. Pure cosmic.

### 17. zip: safe extraction (zip-slip), typed constructors, O(N) reads

**Repo:** both · **Layer:** cosmic API + cosmo-C internals

- **zip-slip (cosmic):** the writer validates entry names
  (`ValidateEntryName`, lzip.c:597-627, verified) but the reader returns raw
  central-directory names, and cosmic offers no extract helper — so the
  natural loop `for _, name in ipairs(r:list()) do io.barf(name, r:read(name))`
  writes through `../../` from attacker-controlled archives. Add
  `zip.extract(r, destdir, opts?)` that rejects absolute paths / `..`
  components / escapes of destdir, enforces `max_file_size`, applies
  sane-masked modes from `stat()`.
- **Typed constructors (cosmic):** `zip.open(...): any, string` (zip.tl:104)
  erases Reader/Writer/Appender. Replace with `zip.reader/writer/appender
  (path, opts?): T | nil, string`; delete `open`.
- **C contract:** `reader:stat(missing)` returns bare nil while
  `read(missing)` returns `nil, "entry not found"` and bad options throw —
  three conventions on one object; unify on `nil, err`. `FindEntry`
  (lzip.c:125-150) linearly scans the central directory per call → bulk
  extraction is O(N²); build a name index at open.

**Plan.** Red (cosmic): craft an archive with a `../escape` entry via the raw
writer bypass or hand-built bytes; `zip.extract` must refuse and write
nothing outside destdir. Type-level red: `--check-types` fixture using
`zip.writer(...):add(...)` uncast. Red (C): `select("#", r:stat("nope")) == 2`;
perf via cosmic's zip scenario in `perf-compare`. Green: extract helper
sharing an `is_unsafe_name` rule with the writer's semantics; three
constructors; C index + stat fix; definitions.lua + regen.

### 18. json: expose encoder options; define null/NaN policy; document round-trip loss

**Repo:** both · **Layer:** cosmic (options) + cosmo-C (NaN/null policy)

- **[verified by agent]** `json.encode(v, {pretty=true})` silently ignores
  the option — `json.tl:20-23` never forwards the second argument the C
  encoder fully supports. Add
  `EncodeOptions {pretty, sorted, indent, maxdepth}` and pass through.
- JSON `null` decodes to Lua `nil`: `{"a":null,"b":1}` re-encodes as
  `{"b":1}` and `[1,null,2]` truncates to `[1]` [verified by agent]. NaN/Inf
  encode silently as `null` [verified by agent]. Decide and document: at
  minimum a loud doc block; ideally a `json.null` sentinel recognized by the
  C encoder (pairs naturally with #9's metatable work) and
  `EncodeJson` returning `nil, "cannot encode NaN"` unless
  `opts.nan = "null"`.

**Plan.** Red: `test_encode_pretty` asserts a newline (fails today);
`test_null_roundtrip` locks whichever policy is chosen. Green: options
passthrough is a two-line cosmic fix; sentinel/NaN policy is a small C
change riding the #9 release.

### 19. fetch: options/result restructure — no opts mutation, full contract exposure, error taxonomy, working retries

**Repo:** both · **Layer:** cosmo-C + cosmic

Four related contract problems, one breaking wave:

- **Opts mutation (C):** on redirect the C writes `body`, `method`,
  `numredirects` into the caller's table and deletes `Authorization`/`Cookie`
  from the caller's headers (fetch.inc:804-853); `keepalive=true` is
  replaced by a table (fetch.inc:134-138). cosmic's retry loop then reuses
  the poisoned table: a 303-redirected POST silently retries as GET. Fix in
  C (copy opts internally); until then cosmic shallow-copies per attempt.
- **Hidden contract (cosmic):** `Opts` omits `followredirect`/`maxredirects`
  entirely — disabling redirects requires an `as` cast. Add
  `follow_redirects: boolean`, `max_redirects: integer`. Add `Result.url`
  (final URL after redirects) — needs the C to return the effective URL.
- **Retry semantics (cosmic):** transport errors are *never* retried — the
  loop only consults `should_retry` when `result.ok` is true
  (fetch.tl:146-150), inverted from retry's purpose; `max_attempts` without
  `should_retry` is a no-op; backoff is `2^attempt` with no jitter and 2s
  minimum. Default policy: retry transport errors + 429/502/503/504 for
  idempotent methods; full jitter; `base_delay`/`max_delay` options.
- **Error taxonomy (both):** every failure (DNS, connect, TLS-verify,
  timeout — which surfaces as the misleading `"read error: Resource
  temporarily unavailable"`, SSRF, proxy) is one opaque string. Add
  `Result.error_kind: enum ("validation" "dns" "connect" "tls" "timeout"
  "proxy" "protocol" "too_large")` — classifiable today from stable C string
  prefixes in cosmic; the right C contract (third return) before freeze.
  Also fix the `timeout` doc: it is a per-socket-op timeout defaulting to
  60s, not a whole-request deadline and not "no timeout if nil"
  (lfetch.c:92, fetch.inc:107-123).

**Plan.** Red tests all become writable once #7 lands (loopback servers):
mutation test (snapshot opts before/after a 302), `follow_redirects = false`
asserting 302 + location, retry test (first connect fails, second serves
200, `max_attempts=2` must succeed — fails today), `error_kind == "connect"`
for a refused port. Green in the order: cosmic copy + record fields +
classifier + retry rework; C mutation fix + final-URL return + error-kind
third return with definitions/regen.

### 20. Streaming: `Reader:lines()` and SSE convert mid-stream errors into clean EOF; SSE spec deviations

**Repo:** whilp/cosmic · **Layer:** cosmic

`fetch.tl:235-238` discards `read()`'s error return and sets `done = true`
— a TLS failure or reset mid-body is indistinguishable from end-of-stream.
`sse.tl:44` declares an error return that is structurally unreachable, so a
truncated event stream looks like a graceful close (silent data loss for
AI-streaming / event-feed consumers; the C layer *does* distinguish chunked
truncation). SSE parser also deviates from WHATWG: dispatches unterminated
events at EOF instead of discarding (sse.tl:62-73), doesn't reset the
event-type buffer on empty-data dispatch, updates `last_id` at dispatch
rather than on sight of `id:`, and accepts non-digit `retry` values. Also
expose `last_event_id` for reconnect support.

**Plan.** Red: `sse_test.tl` already has a mock-reader harness — add a mock
whose `read()` errors after one chunk; assert the events iterator yields
`nil, "connection reset"` (today: clean nil). Same-shape test for `lines()`.
Spec deviations each get a one-case red. Green: thread errors through
`make_reader.lines` and `sse.events`; four contained parser fixes.

### 21. url + ip: parse the right things, validate, kill sentinels

**Repo:** whilp/cosmic · **Layer:** cosmic

**[verified]** — `url.parse("http://example.com/path?a=1")` returns
`{["http://example.com/path?a"] = "1"}` (it parses *query strings*; URLs are
`parse_url`); `parse_host("::1")` mangles bare IPv6 to `":", 1`; port 99999
accepted; `%2F`-vs-`/` distinction destroyed with no `url.format` inverse
(cosmo.EncodeUrl exists, unwrapped). **[verified]** — `ip.parse("127.1")` →
`32513` (neither error nor inet_aton semantics), `1.2.3.4.5` accepted,
errors are `-1`, and `ip.format(-1)` = `"255.255.255.255"` — the sentinel
aliases broadcast. `ip.resolve` duplicates `lookup` with sentinel returns;
`net.parseip/formatip` duplicate `ip.*` with a *different* error contract.

**Change.**

```teal
url.parse:       function(url: string): Url | nil, string   -- was parse_url
url.format:      function(u: Url): string                   -- wraps cosmo.EncodeUrl
url.parse_query: function(q: string): {string: {string}}    -- multi-value honest
url.parse_host:  function(hp: string): string, integer | nil, string  -- port 1..65535, brackets
ip.parse:        function(s: string): integer | nil, string -- strict dotted quad, octets 0-255
-- delete: url.parse (old meaning), ip.resolve, net.parseip, net.formatip
```

`ip.categorize` return becomes a Teal enum.

**Plan.** Red (`url_test.tl` / `ip_test.tl`): the verified behaviors above as
assertions of the new contract (each fails today). Green: renames, strict
pre-validation before `cosmo.ParseIp`, wrap `EncodeUrl`/`ParseHost`.
Breaking renames are the point of pre-stable.
