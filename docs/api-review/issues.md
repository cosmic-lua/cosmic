# Issue plan: 39 findings → 13 GitHub issues

Grouping rule: one issue = one coherent work stream a single implementer can
land as a short PR series in one repo. Detail lives in the chapter files;
each issue body should link its items. Bracketed numbers refer to review
items in [p0.md](p0.md), [p1-contracts.md](p1-contracts.md),
[p1-stdlib.md](p1-stdlib.md), [p2.md](p2.md).

## whilp/cosmopolitan (5 issues)

### C1. Binding safety batch
Independent memory/crypto/signal-safety fixes; no contract debate; land
first. — getopt single-shot `parse` redesign (optstring use-after-free,
global state, missing-arg protocol) [1]; UUIDv4/v7 on arc4random +
pushlstring [6]; shm C fixes: full-region read off-by-one, 32-bit futex
guard, no Lua push while holding the shared mutex [25]; signal handlers
deferred via lua_sethook + handler table into the registry [24].

### C2. Surface & definitions purge + annotation ratchet
Shrinks every later diff. — delete redbean fiction from definitions.lua and
its ratchet whitelist; remove dead C files (lmaxmind, lfinger, launch,
libresolv_query) and unreachable functions; delete ~40 unused top-level
functions incl. Rdrand/Rdseed/Lemur64, Curve25519, GetTime/Sleep,
bin/hex/oct; harden GetRandomBytes (raise cap, loop short reads, no abort);
drop lsqlite3 alias registrations + session/changeset surface [27]. Extend
the coverage ratchet with quality checks (every param annotated, every
function has @return, no inline table types, `any` allowlist) and reference
options classes in @param (EncoderOptions; new FetchOptions) [29].

### C3. One error convention at the C boundary
The big break; module-by-module. — success = values, failure =
`nil, err_string, errno?`; delete unix.Errno and re.Errno userdata; stop
throwing on data errors (Uncompress, DecodeHex, GetRandomBytes, base32);
kill sentinels (ParseIp −1, ParseHttpDateTime 0, Strftime nil-ambiguity)
[14]; re: captures as a table, bare nil on no-match, binary-safe subject
[15]; argon2: verify → boolean, err; drop config mutators + lightuserdata
variants, accept string variant [34]; Slurp/Barf path-in-error + options
table [16-nits]; unify definitions.lua on a single fallibility dialect and
ban the failure-@overload idiom [14].

### C4. Fetch C contract
— `allowprivate` SSRF opt-out [7]; stop mutating the caller's opts/headers
tables on redirect/keepalive [19]; return the final URL; add an error-kind
channel [19]; correct the headers annotation to the true multimap shape
[13]; 204/304 completed-not-closed reader state; don't return "" chunks
[37]; replace the resettls teardown-per-request with a getpid check and
drop the option [37].

### C5. Data format contracts
— JSON: array metatable marker replacing the `[0]=false` kludge, exposed as
a user-visible array marker [9]; NaN/Inf encode policy (error unless opted
into null) and null-sentinel recognition [18]; compression: Deflate/Inflate
with {format, maxsize}, streaming output buffer, delete deprecated
Compress/Uncompress [28]; zip: stat → nil,err like read, open-time name
index for O(N) bulk reads [17].

## whilp/cosmic (8 issues)

### T1. Honest types
No upstream dependency; highest leverage. — gentype renderer adds `| nil`
to fallible first returns; regen; stdlib-wide signature sweep to
`T | nil, string`; negative type-check tests in check_test.tl; generated-
Teal validity test in gentype; convention text update [8, 29].

### T2. Verified P0 quick fixes
Five small, unrelated, all reproduced; one batch to ship immediately. —
Socket:send MSG_NOSIGNAL (SIGPIPE kill) [2]; db:transaction rollback on
falsy body return [3]; host_os XNU→macos mapping + enum [12];
quicksand.capabilities non-destructive unveil probe [5]; child.spawn argv
copy + CLOEXEC pipes [10].

### T3. child Handle/Result redesign
— kill/try_wait/wait(timeout_ms), idempotent wait, __close/__gc reaping,
structured Result {code, signal, ok, stdout, stderr}, exec-failure error
pipe surfacing at spawn, one-shot child.run; move raw wait/fork/kill
syscall passthroughs to proc [11].

### T4. Fail-closed sandboxing
— pledge/unveil fail-closed wrappers + available() probes + best_effort
escape hatch; unveil.allow/commit split [4]; quicksand: real capability
probes (scratch unshare child), Box:run error pipe separating setup failure
from workload exit, un-skip run tests [5, 26]; landlock file-rule FILE_BITS
masking + TRUNCATE-gap docs [26]; stretch: cosmic.sandbox facade + typed
promise/permission enums [38].

### T5. errno-fidelity and convention sweep
Mechanical, one module per commit. — io (slurp/barf/open errno + path),
net_socket static strings → errstr, proc (setsid/daemon/nice/etc.),
time.sleep honest contract, signal (raise/setitimer/sigaction wrappers),
tty (errors, cc deep-copy, real raw mode [35]), shm wrapper with
value,err + size() [25]; poll error surfacing; codec.encode_lua error
channel; envd LoadResult.errors; dedupe shadow records (UnixIO/UnixTty/
Rusage/Errno); doc-comment nits [22, 39].

### T6. Networking reshape
Partially unblocked by C4 (hermetic loopback tests need allowprivate). —
headers lowercase + raw_headers normalization [13]; Opts exposes
follow_redirects/max_redirects, per-attempt opts copy, retry rework
(transport errors, jitter, idempotency), timeout docs, error_kind
classifier [19]; Reader:lines/SSE error propagation + WHATWG conformance +
last_event_id [20]; url.parse/format/parse_query/parse_host redesign,
strict ip.parse, delete sentinel duplicates [21]; net address ergonomics
(accept string/Addr, drop net.parseip/formatip/poll, fix or drop
nb_connect), is_success helper, delete has_stream [37, 39]; rewrite fetch
tests against loopback (drop httpbin) [7].

### T7. Data modules
— sqlite.blob marker + bind_blob, default busy_timeout, prepare tri-shape
wrapped [16]; json encoder options passthrough, null round-trip policy +
docs, adopt the C array marker [18]; zip.extract (zip-slip safe) + typed
reader/writer/appender replacing open():any [17]; compress: cap the
size-prefix allocation now, thin passthrough after C5 [28]; hash
hmac_sha256 + constant_time_equal; rand.int (unbiased) + drop
rdrand/rdseed fictions after C2 [33, 27].

### T8. Namespace, naming, and core reshape
Last wave; pure churn, batched to avoid rebasing everything else. —
cosmic.io → cosmic.fd + fd.wrap; whole-file ops to fs [30]; fs semantics:
stat-following isfile/isdir, stat/lstat split, walk error propagation,
copy/move/write_atomic/touch, mkstemp contract [23]; naming sweep
(fetch.fetch, re.test, drop string.upper/lower, <Verb>Options, Stat
methods) [31]; directory modules + PUBLIC manifest + CLI internals under
cosmic/cli + build-injected _VERSION [32]; time now_ms/monotonic_ms +
O(1) timegm + isdst:boolean [36]; IPv4-only documentation [39].

## Dependencies and sequencing

- **No upstream dependency:** T1, T2, T3, T4, T5, T8 — can start today.
- **Pin-bump choreography:** C1–C5 each end with definitions.lua updates →
  cosmos release → version.lua bump → regen-types → wrapper fixes in cosmic.
  C2 before C3 (purge shrinks the convention diff). C3 is the largest and
  should be its own release.
- **Cross-repo pairs:** T6 wants C4 first (loopback tests); T7's json/
  compress halves want C5; T7's rand cleanup wants C2. Each T-issue notes
  which parts are independent so work can start before the pin lands.
- Suggested order: T2 → C1 → T1 → C2 → (C3, T3, T4, T5 in parallel) →
  C4/C5 → T6/T7 → T8.
