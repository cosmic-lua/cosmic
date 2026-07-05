# Pre-stable API review: cosmo.* C bindings and cosmic.* stdlib

Date: 2026-07-05. Scope: the Lua C API in whilp/cosmopolitan as consumed by
whilp/cosmic, and the cosmic Teal API + generated types. Breaking changes are
in scope; no backwards compatibility. Each numbered item below is intended to
become one GitHub issue (repo noted per item). Items marked **[verified]**
were reproduced hands-on against a locally built cosmic binary during the
review; everything else is backed by cited source.

Priorities:

- **P0** — must land before stable: memory safety, security, silent data
  corruption, process-killing bugs, and type/shape contracts that are wrong
  in ways that freeze badly.
- **P1** — should land before stable: contract redesigns and convention
  sweeps that are breaking (so now is the time) or that make the API honest.
- **P2** — nice to have; additive or contained enough to land after stable
  without breaking anything.

Cross-repo mechanics for every cosmopolitan-side change: update
`tool/net/definitions.lua` in the same commit (annotation ratchet enforces
this), cut a cosmos release, bump `3p/cosmos/version.lua` in cosmic, run
`bin/make regen-types && bin/make test only=gentype`, fix wrappers, and run
`bin/make ci` + `bin/make perf-compare`.

---

## P0 — must fix before stable

### 1. getopt binding: use-after-free of the optstring; redesign as single-shot parse

**Repo:** whilp/cosmopolitan (+ cosmic wrapper rework) · **Layer:** cosmo-C

`tool/net/lgetopt.c:39,131` stores the raw `const char *` from
`luaL_checkstring(L, 2)` for the parser's lifetime without rooting the Lua
string (the argv strings *are* rooted in a registry refs table at
lgetopt.c:160-171; the optstring is not). **[verified]** — a dynamically
built optstring, GC pressure, then `parser:next()` returns `"?", "x"` where
the control case returns `"x", "val"`. Additionally the parser uses global
`optind`/`opterr` (lgetopt.c:205-207,294), so two parsers corrupt each other,
and getopt's `'?'` return conflates "unknown option" with "missing required
argument" (no leading-`:` protocol), so CLIs cannot produce the right error
message. `LongOpt.has_arg` is a stringly field where a typo silently changes
behavior.

**Change.** Delete the stateful Parser userdata. One C call, locally scoped
state, plain tables out:

```
getopt.parse(args: {string}, optstring: string,
             longopts?: {{name: string, has_arg: "none"|"required"|"optional", short: string}})
  -> {opts: {{opt: string, arg: string|nil}}, args: {string},
      unknown: {string},   -- always includes dashes
      missing: {string}}   -- options that lacked a required argument
  |  nil, err: string
```

cosmic's `getopt.tl` keeps its `Parser`/iterator ergonomics as pure Lua over
the parsed result, with `has_arg` as a Teal `enum`.

**Plan.** Red (cosmopolitan): add to `tool/lua` tests (a) the GC repro above
asserting `"x","val"`; (b) two interleaved parsers asserting independence;
(c) `parse({"-o"}, "o:")` puts `"o"` in `missing`, not `unknown`. Green:
implement `parse` with a private re-entrant loop (the bundled getopt is
small; a local reimplementation avoids globals entirely), delete the Parser
metatable and `__gc`. Then: definitions.lua getopt section rewrite, cosmos
pin bump, regen, rewrite `lib/cosmic/getopt.tl` on top (red first in
`getopt_test.tl`: missing-arg vs unknown distinction).

### 2. `Socket:send()` to a closed peer kills the process with SIGPIPE

**Repo:** whilp/cosmic · **Layer:** cosmic

**[verified]** — socketpair, close one end, `send()` on the other: the
interpreter dies with exit 141. `net_socket.tl:80-87` passes `flags or 0` to
`unix.send` and nothing sets `MSG_NOSIGNAL` or ignores SIGPIPE. Any server
whose client disconnects mid-response dies. `sendto` has the same hole.
(`child_io.tl:15` already neutralizes SIGPIPE for its own pump — the pattern
exists in-repo.)

**Change.** `send`/`sendto` always OR in `unix.MSG_NOSIGNAL`. On platforms
where cosmopolitan maps it to 0 (macOS), set `SO_NOSIGPIPE` in
`make_socket`.

**Plan.** Red (`net_test.tl`): socketpair, close peer, assert
`a:send("data")` returns `nil, err` — today the test process exits 141,
an unambiguous red. Green: one-line flag change in `send`/`sendto` plus the
`SO_NOSIGPIPE` setsockopt. No type or definitions change.

### 3. `db:transaction` silently COMMITS when the body returns `false, err`

**Repo:** whilp/cosmic · **Layer:** cosmic

**[verified]** — a body doing `d:exec("INSERT ...") return false, "boom"`
yields `transaction() -> true, nil` and the row is committed.
`sqlite.tl:430-441` only rolls back when the body *throws*; the body's return
value — the library's own documented error convention — is discarded. Users
writing idiomatic failure returns get silent partial commits.

**Change.**

```teal
transaction: function(self: Database, fn: function(Database): boolean, string): boolean, string
```

Rollback when fn throws, OR when its first return is literally `false`, OR
when the first return is `nil` and a second (error) value is present. A body
that returns nothing still commits. Propagate fn's error string.

**Plan.** Red (`sqlite_test.tl`): `test_transaction_rollback_on_false` —
insert + `return false, "boom"`, assert `false, "boom"` returned and
`count(*) == 0` (fails today with count 1). Companion green-lock test:
`test_transaction_commits_on_no_return`. Green: capture pcall results as
`success, ret1, ret2` and apply the rule above. Update doc comment and
examples. Pure cosmic.

### 4. `pledge`/`unveil` silently succeed with zero enforcement (fail-open)

**Repo:** whilp/cosmic (doc paragraph upstream) · **Layer:** both, fixable in cosmic

Cosmopolitan's libc deliberately fails open: `libc/calls/pledge.c:307-314`
returns success on hosts without enforcement (macOS, Windows, FreeBSD,
NetBSD); `libc/calls/unveil.c:461-464` swallows ENOSYS on Linux without
landlock. **[verified on a landlock-less Linux host]** — `unveil.apply("/tmp",
"r")` then commit both return `true`, and `/etc/hostname` remains readable.
A user who writes `assert(unveil.apply(dir, "r"))` believes they have a
sandbox; they have nothing. The C layer provides fail-closed feature probes
(`pledge(0,0)`, `unveil("",nil)` → ENOSYS, verified) that the wrappers never
call. `unveil_test.tl:51-62` knows about the leak and downgrades it to a
skip.

**Change.** Fail-closed by default with an explicit escape hatch:

```teal
-- pledge
apply: function(promises: string, opts?: {exec: string, best_effort: boolean}): boolean, string
available: function(): boolean
-- unveil
allow: function(path: string, permissions: string): boolean, string
commit: function(): boolean, string   -- replaces apply(nil, nil)
available: function(): boolean
```

`allow`/`commit`/`apply` return `false, "unveil unsupported on this host"`
when the startup probe fails, unless `best_effort = true`. Splitting
`commit()` out also fixes the current type lie (`apply(path: string, ...)`
called with nils).

**Plan.** Red (`unveil_test.tl`): on a host where `landlock.available()` is
false and OS ≠ OpenBSD, assert `unveil.allow(dir, "r")` returns
`false, err:match("unsupported")` — passes-as-enforcement today.
Red (`pledge_test.tl`): `pledge.available()` is boolean, true on Linux.
Green: cache one startup probe per module; gate. Then delete the
"leak-without-backing is a skip" hedge in the tests — it becomes a hard
failure, which is the point. Upstream: document fail-open + probe idioms in
`definitions.lua` for `unix.pledge`/`unix.unveil`.

### 5. `quicksand.capabilities()` unveil probe is destructive: it commits a deny-all sandbox

**Repo:** whilp/cosmic · **Layer:** cosmic

`quicksand/init.tl:63-70,100` probes bindings with `call(nil, nil)`. For
unveil, `unix.unveil(nil, nil)` **is the commit operation**
(`unveil.c:209-214`): on any landlock-enabled kernel (every mainstream
distro ≥ 5.13), merely calling `capabilities()` locks the calling process
into a deny-all filesystem sandbox plus seccomp filters. Since
`Box:run → preflight → caps()` (box/init.tl:142-143,188), every Box user
self-bricks before the fork; the resulting failure surfaces as exit 126,
which `run_test.tl:36-40` tolerates as a skip — so the whole suite is green
while enforcement never actually happens on hardened hosts. On landlock-less
Linux the same call silently succeeds (see #4), so the probe reports
`unveil=true` next to `landlock=false` **[verified]**.

**Change.** Probe unveil with the documented non-destructive feature check
`unix.unveil("", nil)`, or better: derive it (`unveil = landlock available on
Linux; true on OpenBSD`). Keep the generic probe only for pledge, where
`(nil, nil)` is a safe no-op.

**Plan.** Red (`init_test.tl`): (a) after `quicksand.capabilities()`, assert
`io.open("/etc/hostname", "r")` still works — fails today on landlock hosts;
(b) assert `c.unveil == c.landlock` on Linux — fails on landlock-less hosts
today. Green: replace `probe(unix.unveil)` at init.tl:100. Follow-up: remove
the exit-126-is-a-skip tolerance in `run_test.tl` (pairs with #26).

### 6. UUIDv4/v7 are generated from a non-cryptographic, poorly-seeded PRNG

**Repo:** whilp/cosmopolitan · **Layer:** cosmo-C

`LuaUuidV4`/`LuaUuidV7` (tool/net/lfuncs.c:914,946) draw from `_rand64()`,
whose whole 128-bit pool is seeded from `rdtsc()` + pid
(`libc/intrin/rand64.c:51-54`) — small, partially guessable entropy. UUIDv4
is routinely used as an unguessable token; these are predictable. Both also
push the result via `lua_pushfstring(L, uuid_str)` — generated data used as
a format string (harmless today, wrong on principle).

**Change.** Same signatures; random bits from `arc4random`
(`arc4random64()` helper already exists at lfuncs.c:161-165);
`lua_pushlstring(L, uuid_str, 36)`.

**Plan.** Mechanical C change; add a fork-uniqueness test (1000 UUIDs across
parent/child, all distinct) to `tool/lua` tests as a tripwire. No contract or
definitions.lua change; no cosmic knock-on.

### 7. Fetch SSRF guard has no opt-out — loopback/private networks are unreachable

**Repo:** both · **Layer:** cosmo-C contract + cosmic Opts

`tool/net/fetch.inc:429-437` and `lfetch.c:899-902` unconditionally reject
any non-public destination IP. **[verified by two independent probes]** —
`Fetch("http://127.0.0.1:<port>/")` against a live local server returns
`"request to private network blocked (SSRF protection)"`. Consequences:
talking to a local dev server or sidecar is impossible; every fetch
success-path test depends on external hosts and self-skips offline; and
cosmic's own `lib/perf/bench/http_bench.tl:68-72` works around it by
pretending the target is an HTTP proxy — which also proves the guard costs
legitimate users everything and attackers nothing (proxied requests skip the
check). Default-deny is right; no escape hatch is not.

**Change.** C: read an `allowprivate` boolean in `LuaFetch` and
`LuaFetchStream` next to `followredirect`; skip the `IsPublicIp` check when
set; the flag governs the whole redirect chain (document that). cosmic:
`Opts.allow_private: boolean` (default false), doc comment saying it exists
for addresses you control.

**Plan.** Red (cosmopolitan `tool/lua` test): loopback server; plain Fetch
fails with the SSRF message; `{allowprivate=true}` returns 200. Red (cosmic,
post-pin-bump): same via `fetch_test.tl` with `allow_private = true`. Green:
~10 lines in fetch.inc + lfetch.c, definitions.lua option lists, regen,
`Opts` field. Follow-up with high leverage: rewrite `fetch_test.tl` /
`fetch_example.tl` success paths against forked loopback servers (pattern
proven in `http_bench.tl` and `net_test.tl`) and drop httpbin + the skip
scaffolding; `http_bench.tl` drops the proxy lie.

### 8. Honest nil: generated types and cosmic signatures erase `nil` from every fallible function

**Repo:** whilp/cosmic (gentype renderer + stdlib sweep) · **Layer:** cosmic

The single highest-leverage typing fix. Upstream annotates fallibility as a
`@overload fun(...): nil, unix.Errno`; `gentype_parse.tl:228-238` detects it
and `gentype_render.tl:190-195` folds it into a trailing `, Errno` — but
never adds `| nil` to the success return. Result: 108 generated signatures
like `Slurp: function(...): string, unix.Errno`; the whole 3099-line
`cosmo/unix.d.tl` contains zero `| nil`. **[verified]** —
`local s = cosmo.Slurp("/nonexistent"); print(#s)` passes `--check-types`
and crashes at runtime, while the one honestly-annotated function
(`Strptime`, `table | nil`) is correctly *rejected* by the checker until
narrowed — proving Teal enforces this when declared. cosmic's own modules
repeat the lie library-wide: `fs.stat(): Stat, string`,
`io.slurp(): string, string`, `sqlite.open(): Database, string`,
`re.compile(): Regex, string`, `child.spawn(): Handle, string`, etc. — all
return nil at runtime on failure; only `embed.tl:70` is honest.

**Change.** (a) Renderer: when `fallible`, render the first return as
`T | nil`. (b) Stdlib sweep: every fallible value-returning function becomes
`T | nil, string`; fallible effects stay `boolean, string` returning
`false, msg`. Convention text for CLAUDE.md: "Fallible value: `T | nil,
string` — the checker forces callers to narrow. Fallible effect: `boolean,
string`. Infallible: bare value. Errors are strings from `errno.str`;
`unix.Errno` never crosses the cosmic boundary."

**Plan.** Red (a): edit `gentype_test.tl:116` to expect
`mkdir: function(path: string): boolean | nil, Errno`; run
`bin/make test only=gentype`. Green: `gentype_render.tl` `render_returns`
(line 178) appends `" | nil"` to the first return when fallible (parenthesize
existing unions). `bin/make regen-types`, commit. Red (b): add cases to
`check_test.tl` asserting `local st = fs.stat(p); print(st.size)` FAILS
`--check-types`. Green: mechanical sweep of module records + `@return` doc
tags; fix intra-repo callers `bin/make teal` flags (most already narrow).
Land (a)+(b) in one breaking wave so `cosmo.*` and `cosmic.*` flip together.

### 9. JSON: `DecodeJson("[]")` leaks a `[0]=false` sentinel into user tables

**Repo:** whilp/cosmopolitan · **Layer:** cosmo-C

**[verified]** — `DecodeJson("[]")[0] == false`. `ljson.c:260-264` stores a
data key so `[]` round-trips (EncodeJson special-cases it back). Any consumer
iterating with `pairs()`, counting keys, or re-serializing with another
encoder sees a phantom key. cosmic passes decoded values through untouched,
so this leaks to every user.

**Change.** Mark arrays with a shared metatable instead of a data key:
`luaL_setmetatable(L, "json.array")` on `[` in the decoder; encoder treats
an empty table with that metatable as `[]`. Expose the marker
(`cosmo.jsonarray(t)` or `json.array(t)` in cosmic) so users can force
array encoding for empty tables they build — fixing the inverse ambiguity
too.

**Plan.** Red (cosmopolitan test): `next(DecodeJson("[]")) == nil` AND
`EncodeJson(DecodeJson("[]")) == "[]"` — mutually unsatisfiable today.
Green: registry metatable created in `luaopen_cosmo`; decoder sets it;
encoder checks `lua_getmetatable` + registry compare before the `{}`/`[]`
decision; delete the kludge. definitions.lua note, pin bump, cosmic doc
update + `json.array` re-export.

### 10. `child.spawn` hygiene: mutates caller's argv; pipes are not CLOEXEC (cross-child deadlock)

**Repo:** whilp/cosmic · **Layer:** cosmic

Two independent correctness bugs in spawn, small fixes, big consequences:

- `child.tl:165-170` writes the PATH-resolved absolute path back into the
  *caller's* argv table. **[verified]** — after `spawn({"echo","hi"})`, the
  caller's `argv[1]` is `/usr/bin/echo`. Reused argv templates silently
  mutate.
- `new_pipe()` (child.tl:182-190) creates pipes without `O_CLOEXEC`. Spawn
  child B while holding a live handle to child A and B's fork inherits A's
  pipe ends: A never sees stdin EOF until B also exits, and `communicate()`
  hangs whenever two children overlap — the classic pipe-leak deadlock, fatal
  to the pump model which relies on EOF.

**Change.** Resolve the program into a local (`local prog = ...`) and pass it
as `execve`'s first arg. Create all spawn pipes with
`unix.pipe(unix.O_CLOEXEC)` — the child's `dup2` onto 0/1/2 clears CLOEXEC on
the duplicated fd, so children still get their ends; all other inherited
copies close on exec.

**Plan.** Red 1 (`child_test.tl`): `local a = {"echo","x"}; spawn(a):wait();
assert.eq(a[1], "echo")`. Red 2: spawn `cat` with stdin pending, spawn
`sleep 5`, assert the `cat` handle's wait completes promptly (with #11's
timeout, or a WNOHANG poll loop). Green: the two changes above; verify the
`stdin_r ~= 0` dup2 special-casing still holds.

### 11. `child.Handle` redesign: kill/timeout, idempotent wait, no zombies, structured Result, visible exec failures

**Repo:** whilp/cosmic · **Layer:** cosmic

The flagship process API cannot manage a running child, and its result shape
is wrong in ways that freeze badly:

- No `kill`, no timeout anywhere; `pump` blocks on `p:poll(-1)` forever
  (child_io.tl:147). Abandoned handles leak zombies **[verified — `ps` shows
  `Z`]**. `wait()` is not idempotent (second call: `nil, "wait failed:
  wait() failed: No child process"`).
- `handle:read(size?)` returns `boolean | string, string, number` — the
  meaning of the first value depends on arity, and stderr is silently
  discarded on the no-arg path.
- Signal death is a string to parse (`nil, "killed by signal 15"`); exec
  failure is invisible: `spawn({"/no/such/bin"})` succeeds and `wait()`
  returns `127, nil`, indistinguishable from a real exit 127.

**Change.**

```teal
local record Result
  code: integer      -- nil if signaled
  signal: integer    -- nil if exited
  ok: boolean        -- code == 0
  stdout: string
  stderr: string
end
local record Handle
  pid: integer
  kill: function(self, sig?: integer): boolean, string   -- default SIGTERM
  try_wait: function(self): Result | nil, string          -- WNOHANG
  wait: function(self, timeout_ms?: integer): Result | nil, string  -- nil,"timeout"
  read: function(self, size: integer): string | nil, string -- size REQUIRED; streaming only
end
child.spawn: function(argv: {string}, opts?: Opts): Handle | nil, string
child.run:  function(argv: {string}, opts?: Opts): Result | nil, string  -- one-shot
```

Cache the reaped Result so `wait()` is idempotent; `__close`/`__gc` kill+reap
un-waited handles so `local h <close> = spawn{...}` is leak-free. Exec
failures: one extra `O_CLOEXEC` pipe; child writes the errno name on exec
failure; parent's non-empty read makes `spawn` itself return
`nil, "exec failed: ENOENT: ..."` (the pipe EOFs instantly on success).

**Plan.** Red (`child_test.tl`): (a) kill sleep-10, wait, `r.signal == 15`;
(b) two waits return the same Result; (c) `wait(100)` on sleep-10 →
`nil, "timeout"`; (d) `spawn({"/no/such/bin"})` → `nil, err:match("ENOENT")`;
(e) `run({"sh","-c","echo o; echo e >&2; exit 3"})` → stdout `"o\n"`,
stderr `"e\n"`, code 3. Green: thread a deadline through `child_io.pump`
(compute remaining before each poll); rework `finish()` to build Result;
add the exec-status pipe; `kill` via `unix.kill` + `errno.str`. Knock-ons:
every spawn call site in-repo, `child_example.tl`, CLAUDE.md examples. The
single biggest breaking change — do it before stable or never.

### 12. `sys.host_os()` returns `"xnu"` where the docs promise `"macos"`

**Repo:** whilp/cosmic · **Layer:** cosmic

`sys.tl:24-28` documents `"linux"|"macos"|"windows"|"freebsd"|"openbsd"|
"netbsd"` but implements `cosmo.GetHostOs():lower()`, and the C returns
`"XNU"` on macOS (and `"METAL"`, undocumented) — verified in
`lfuncs.c:207-222` and definitions.lua:4371. Every `== "macos"` check
silently fails on one of the six OSes the fat binary exists to support;
`platform()` produces `"xnu-aarch64"`.

**Change.** Translate in the wrapper and type it:

```teal
local enum HostOs "linux" "macos" "windows" "freebsd" "openbsd" "netbsd" "metal" end
host_os: function(): HostOs
```

**Plan.** Red (`sys_test.tl`): assert membership in the enum set + a
table-driven test on the exported mapping (`XNU → macos`). Green: map + enum.
Grep call sites branching on `host_os`.

### 13. fetch: `Result.headers: {string: string}` is dishonest — repeatable headers are tables, keys are mixed-case

**Repo:** both · **Layer:** cosmic normalization + definitions.lua correction

`LuaPushHeaders` (lfetch.c:147-209) returns repeatable headers (Vary,
Cache-Control, …, per `net/http/khttprepeatable.c`) as nested array tables.
**[verified]** — two `Vary:` lines yield `headers.Vary` of Lua type `table`,
while every layer (fetch.tl:11, cosmo.d.tl:426, definitions.lua:4307)
declares `{string: string}`; `result.headers["Vary"]:lower()` type-checks
then crashes. Keys are canonical mixed case, so `headers["content-type"]` is
nil — there's no case-insensitive access.

**Change.** Normalize in cosmic:

```teal
headers: {string: string}        -- lowercase keys; repeats joined ", " (RFC 9110 §5.3; Set-Cookie is not repeatable here)
raw_headers: {string: {string}}  -- lowercase keys, all values in order
```

Correct definitions.lua to the true C contract
(`table<string, string|string[]>`) regardless.

**Plan.** Red: `fetch_multiheader_test.tl` against a forked loopback server
(after #7) sending two `Vary:` lines: `type(result.headers.vary) == "string"`
and `#result.raw_headers.vary == 2` — fails today. Green: one-pass
normalization helper (new `fetch_headers` chunk, 500-line cap) used by
`do_fetch` and `stream`; regen types for the definitions fix.

---

## P1 — should fix before stable

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

### 22. Error-convention sweep: stop discarding errno across io/net/proc/time/signal/tty

**Repo:** whilp/cosmic · **Layer:** cosmic

`errno.tl` is the right kernel and fs/env use it; the rest of the stdlib
doesn't:

- `io.tl` has ZERO `errno.str` uses: `slurp`/`barf` drop the C's Errno
  entirely (`"failed to read file: <path>"` — was it ENOENT? EACCES?
  EISDIR?); other ops `tostring(err)` without path or errno name; the local
  `UnixIO` shadow record types every error slot `any`.
- `net_socket.tl` returns static strings (`"send failed"`, `"recv failed"`,
  `"bind failed"`, …) while `connect` alone does it right [verified —
  `"connect: ECONNREFUSED: ..."`]; EAGAIN vs fatal is indistinguishable,
  which nonblocking code semantically needs.
- `proc.tl`: `setsid`/`setpgid`/`daemon`/`nice`/`getpriority`/`getsid`
  truncate errors with `return (unix.X(...))` — while `setrlimit` in the
  same file does it correctly; `exec*` return raw Errno objects;
  `getrlimit`'s type lies.
- `time.sleep` is typed `(number, number)` but returns
  `nil, "nanosleep() failed: ..."` [verified by agent] — honest signature is
  `(number, number, string)` (0,0 on success; remainder on EINTR; nil,nil,err
  on EINVAL).
- `signal.tl`: `raise` fabricates `"raise failed"`, `setitimer` discards
  failure entirely, `sigaction/sigprocmask/sigsuspend` are raw casts erasing
  the error slot; constants are 60 hand-copied `as number` lines.
- `tty.tl`: `getattr/setattr` use `err:doc()` (no errno name), `winsize`
  fabricates `"not a terminal"`; also `original.cc` aliases the live termios
  cc table (mutation corrupts `restore()`), and `raw()` isn't actually raw
  (doesn't clear IXON/ICRNL/OPOST or set VMIN/VTIME).

**Change.** Every fallible wrapper returns `value|nil, string` (or
`boolean, string`) built with `errstr(err, "<op>: <path-or-target>")`; delete
the `UnixIO`/`UnixTty` shadow records in favor of the generated
declarations; duplicate `Rusage` records (proc.tl:18-35 = child.tl:7-24)
move to one shared types module. `errno.name_of(msg): string | nil` gives
programmatic access to the leading `"ENAME:"` token.

**Plan.** One module per commit, red-first in each `*_test.tl`:
`slurp("/no/such")` error matches `"ENOENT"`; send-to-closed error matches
`"EPIPE"` (pairs with #2); `setpgid(1,1)` → `false, err:match("EPERM")`;
`time.sleep(-1)` third return matches `"EINVAL"`; `signal.setitimer` bad args
→ `nil, err`; tty `make_raw` extracted as a pure function unit-testable
without a tty. Green is mechanical (`proc.setrlimit` is the in-file
template).

### 23. fs semantics: symlink-following predicates, stat/lstat split, walk error propagation, table-stakes ops

**Repo:** whilp/cosmic · **Layer:** cosmic

- **[verified by agent]** `fs.isfile(symlink-to-file)` is `false` while
  `exists(same)` is `true` — the lstat-based predicates invert the universal
  convention (POSIX `test -f`, Python, Node all follow symlinks). Make
  `isfile`/`isdir` stat-based (implement over `unix.stat` in cosmic; leave
  `cosmo.path.*` alone), keep `islink` lstat-based; replace the
  `stat(path, follow_symlinks?)` boolean trap with `stat`/`lstat`.
  (`fs_walk` calls `unix.stat(p, AT_SYMLINK_NOFOLLOW)` directly and is
  unaffected — verify its test.)
- **Walk swallows errors:** `fs.walk("/no/such/dir")` visits 0 entries with
  no error; `collect` returns `{}` [verified by agent]; mid-walk EACCES and
  stat failures dropped (fs_walk.tl:43,53). "No tests found" when the
  directory was mistyped. Root opendir failure → `nil, err`; subtree
  failures → first error returned alongside results. Bind the visitor's ctx
  to the generic `T`. Fix the `files()` iterator's leaked directory handles
  on early abandonment.
- **Missing ops** every CLI hand-rolls: `fs.copy` (preserve mode),
  `fs.move` (rename, EXDEV → copy+unlink), `fs.touch`, `fs.write_atomic`
  (mkstemp + fsync + rename), `env.get(name, default?)`. Also fix
  `fs.mkstemp`'s contract — the only function whose second return changes
  meaning between success (path) and failure (error).

**Plan.** Red per group in `fs_path_test.tl` / `fs_walk_test.tl` /
`fs_test.tl`: symlink fixtures asserting the new predicate semantics;
`collect("/no/such")` returning an ENOENT error; copy preserving mode 0755;
`write_atomic` leaving no residue and keeping the original on failure.
Green as sketched. Knock-ons: internal `collect`/`walk` call sites (embed,
testrun, docs) must handle the new second return; CLAUDE.md mapping table.

### 24. Signal safety: defer Lua handler dispatch via lua_sethook; define the EINTR story

**Repo:** whilp/cosmopolitan (+ cosmic docs/defaults) · **Layer:** cosmo-C

`LuaUnixOnSignal` (third_party/lua/lunix.c:2369-2385) calls `lua_pcall` from
real signal context — the VM interrupted mid-malloc/mid-GC can corrupt the
heap; the in-code comment even acknowledges Lua isn't async-signal-safe but
only masks *other* Lua handlers. Standard fix: the C handler sets a
`volatile sig_atomic_t pending[sig]` flag and calls `lua_sethook` (the one
documented signal-safe API); the hook dispatches pending handlers at the
next VM boundary and restores the previous hook. Semantics change: handlers
run between VM instructions (blocking syscalls still EINTR first, preserving
wakeups). Related: `sa_flags` defaults to 0 (no SA_RESTART), so installing
any handler makes unrelated `cosmic.io`/`net` calls randomly fail with EINTR
[verified — 50ms ITIMER + blocking `unix.read` → `nil, EINTR`]; only
`poll.tl` retries. With deferred dispatch, cosmic's new `signal.on(sig,
handler, {restart: boolean})` can safely default `restart = true`, and
io/net read/write loops should retry EINTR. Also move the user-visible,
user-corruptible global `__signal_handlers` table into the Lua registry
(lunix.c:2414-2422).

**Plan.** Red (cosmopolitan): stress test — tight table-allocation loop with
a 1ms ITIMER handler for ~2s crashes intermittently today, never after.
Green: pending-flags + hook dispatch, registry-held handler table.
definitions.lua sigaction paragraph; cosmic `signal.on` rework rides #22's
signal commit.

### 25. shm: bounds off-by-one, 32-bit futex trap, wrapper with real error handling

**Repo:** both · **Layer:** cosmo-C + cosmic

- **C, off-by-one:** `lunix.c:3523`'s `n >= m->size` wrongly rejects reading
  the full region — [verified by agent] `mem:read(0, 64)` on a 64-byte map
  throws "out of range". Fix to `n > m->size`.
- **C, futex width:** atomics are 64-bit but `wait`/`wake` cast the word to
  `atomic_int` (lunix.c:3681,3693) — [verified by agent] a counter at
  `2^32+1` blocks/misbehaves silently. Cheapest honest fix: `wait` errors if
  the word's high bits are nonzero + a documentation paragraph in
  definitions.lua.
- **C, lock safety:** `LuaUnixMemoryRead` pushes a Lua string while holding
  the process-shared mutex — an OOM longjmp leaves it locked forever across
  processes (lunix.c:3528-3530). Push after unlock.
- **cosmic:** `shm.tl` is a one-line cast; every failure is a C throw despite
  the never-throw rule, signatures show no error slots, there's no `size()`
  or deterministic `close()`. Make it a real wrapper: validate size/bounds in
  Lua (size known at mapshared time), pcall-translate residual throws to
  `nil, err`, add `size()`; optionally add `Memory:size()`/`close()` in C.

**Plan.** Red (cosmopolitan tests): full-region read; high-bits wait
contract. Red (cosmic `shm_test.tl`): `mapshared(100)` → `nil,
err:find("multiple")`; `mem:read(9999, 8)` → `nil, err`. Green as sketched;
one cosmopolitan PR for the C fixes + definitions, then pin bump.

### 26. quicksand: separate sandbox-setup failure from workload exit; probe capabilities for real; fix landlock file rules

**Repo:** whilp/cosmic · **Layer:** cosmic

- **Box:run error channel:** setup failures (unshare, uid_map, landlock,
  pledge, exec) exit 126/127 and the parent returns that as if the workload
  exited (run.tl:151-154,222-225,264-270) — [verified] a userns failure
  surfaces as `126, nil` with the reason only on stderr. For a security API,
  "sandbox failed to assemble" must never look like "your command failed".
  Reuse the CLOEXEC error-pipe pattern already proven in `proxy.start`:
  non-empty pipe → `run` returns `nil, "quicksand: uid_map write failed:
  EPERM"`. Then delete the exit-126-is-a-skip tolerances in `run_test.tl`.
- **capabilities() honesty:** `user_ns = CLONE_NEWUSER ~= nil` is a
  compile-time constant — true on every Linux build including hosts where
  unprivileged userns is disabled [verified: `user_ns=true` immediately
  followed by `setup_userns_maps: EPERM`]. Probe once for real: scratch
  child attempts `unshare(CLONE_NEWUSER|CLONE_NEWNET|CLONE_NEWNS)`, reports
  over a pipe.
- **landlock.restrict:** attaching directory-only bits to a file rule
  EINVALs (the C unveil path masks with FILE_BITS after fstat,
  unveil.c:296-301; landlock.tl:149-163 doesn't) — so the natural
  `{path="/etc/passwd", access=ll.READ}` fails opaquely. fstat the O_PATH fd
  and mask for regular files. Document the pre-ABI-3 TRUNCATE gap the C
  path plugs with seccomp and cosmic silently strips (landlock.tl:103-110).

**Plan.** Red: `run_test.tl` — box with `pledge = "bogus_promise"` must
return `nil, err:find("pledge")` (today `126, nil`); `landlock_test.tl` —
single-file READ rule must succeed (today EINVAL); capabilities test —
`capabilities()` agrees with a scratch unshare probe. Green as sketched.

### 27. cosmopolitan surface purge: redbean fiction, dead files, unused and dangerous functions

**Repo:** whilp/cosmopolitan · **Layer:** cosmo-C

- definitions.lua carries ~200 references to redbean server mode
  (`OnHttpRequest`, `Route`, `maxmind`, …) that don't exist in the shipped
  binary [verified: `require("maxmind")` fails], kept alive by an explicit
  ratchet whitelist (test_definitions_coverage.lua:394-418). Delete both;
  make the ratchet fail if they reappear.
- Four C files are built but never registered: `lmaxmind.c`, `lfinger.c`,
  `launch.c`, `libresolv_query.c` (tool/net/BUILD.mk:100-103); four
  functions compiled but unreachable (`LuaRdtsc`, `LuaBenchmark`,
  `LuaGet/SetLogLevel`). Remove from the build (binary size + attack
  surface).
- ~40 registered top-level functions have no cosmic consumer and no strong
  standalone story (`Bsf/Bsr/Popcnt`, `bin/hex/oct`, `GetTime`/`Sleep` (worse
  duplicates of unix equivalents), `Decimate`, `MeasureEntropy`,
  `HighwayHash64`, redundant digests, `Underlong`, HTTP-token predicates,
  …). Delete before they freeze. Special cases: `Curve25519` silently
  zero-pads/truncates keys [verified by agent] — a crypto footgun that must
  not ship half-used; `Rdrand`/`Rdseed` are `arc4random64` aliases that
  never touch RDRAND [verified] — delete, and `Lemur64` (deterministic
  per-run) with them; keep exactly `GetRandomBytes` (cap raised, short-read
  loop, `nil,err` instead of process-abort CHECK) and `Rand64`. cosmic's
  `rand.tl` then drops the rdrand/rdseed/has_hwrng fictions and gains
  `rand.int(min, max)` (rejection-sampled over `bytes()`, unbiased).
- lsqlite3: delete dual alias registrations (`exec/execute`, …) and the
  session/changeset/rebaser surface cosmic never touches (binary-size win).

**Plan.** Mostly deletions; the ratchet enforces definitions.lua sync. Red
where behavior changes: `#GetRandomBytes(4096) == 4096`;
`cosmo.Rdrand == nil`; `assert(db.execute == nil)`. Verify with
`GENTYPE_DEFS=... bin/make regen-types && bin/make test only=gentype` that
cosmic regen is a no-op except intended removals, then `bin/make ci`.

### 28. Compression: modern contract, kill the deprecated path and the size-prefix DoS

**Repo:** both · **Layer:** cosmo-C + cosmic

cosmic's primary API wraps `Compress`/`Uncompress`, which the C marks "VERY
DEPRECATED - PLEASE DO NOT USE" (lfuncs.c:1171,1200), throws on corrupt
input [verified], and uses a bespoke non-interoperable framing. Meanwhile
`Inflate(data, exact_outsize)` forced cosmic to invent a 4-byte-LE length
prefix — and `compress.tl:58-73` trusts that attacker-controlled prefix as
an allocation size (a 5-byte blob claiming 4GB forces the allocation before
any validation); the C side also accepts negative `outsize` wrapping to a
huge size_t.

**Change.**

```
cosmo.Deflate(data, opts?: {level: integer, format: "raw"|"zlib"|"gzip"}) -> string
cosmo.Inflate(data, opts?: {maxsize: integer = 64MiB, format: "raw"|"zlib"|"gzip"|"auto"}) -> string | nil, err
```

Inflate streams into a growing luaL_Buffer under a `maxsize` *cap* (not an
exact size) — kills the prefix hack and the DoS. Delete
`Compress`/`Uncompress`; `compress.tl` becomes a thin typed passthrough.

**Plan.** Red (cosmopolitan): round-trip without size; zlib/gzip interop;
corrupt input → `nil, err`; maxsize exceeded → `nil, err`; negative/huge
sizes rejected. Green: `inflateInit2` wbits by format, 16KB chunk loop.
definitions.lua, pin bump, cosmic rewrite (stored-data format changes —
acceptable break), red in `compress_test.tl` for the bomb case.

### 29. gentype hardening: options classes, quality ratchet, validity check

**Repo:** both (definitions.lua + cosmic generator) · **Layer:** types pipeline

- **Options classes (definitions.lua):** `cosmo.EncoderOptions` exists and
  renders beautifully but nothing references it — `EncodeJson`,
  `EncodeLua`, `Fetch`, `FetchStream` use inline table types the generator
  must degrade to `any` [verified — `EncodeJson({1,2}, {bogus_option=42})`
  passes `--check-types`]. Reference classes in `@param`
  (`---@param options cosmo.EncoderOptions?`), add `cosmo.FetchOptions`;
  the generator already resolves dotted class refs.
- **Quality ratchet (cosmopolitan):** extend
  `tool/lua/test_definitions_coverage.lua` with shrink-only allowlisted
  checks: every declared param has `@param`; every function has `@return`
  or is on a returns-nothing list; no inline table types; no bare
  `any`/`table` without an allowlist entry. Seed allowlists at today's
  counts; burn down.
- **Validity check (cosmic):** nothing asserts generated output is valid
  Teal at generation time. Add a gentype test that runs `teal.check` over
  each generated file — a permanent tripwire for renderer bugs.

**Plan.** Each is independently red/green as described; A-item sequencing:
options classes first (immediate typing win, zero generator work), ratchet
checks second, validity test any time.

### 30. io/fs reorganization: rename `cosmic.io` → `cosmic.fd`; one home for whole-file ops

**Repo:** whilp/cosmic · **Layer:** cosmic

`io.tl`'s documented first fact is a warning not to bind it to its own name
(it shadows Lua's `io`); every consumer writes `local cio`. Whole-file
path-based ops (`slurp`/`barf`) live in `io` while everything else
path-based lives in `fs`; `truncate` exists in both; `fs.mkstemp`/`tmpfd`
return raw fds that cannot enter the Handle world (no `fdopen`/`wrap`).
CLAUDE.md even advertises a function that doesn't exist ("slurp/spit").

**Change.** Rename module to `cosmic.fd` (it is exactly the fd layer); add
`fd.wrap(rawfd): Handle`. Move whole-file ops to fs as `fs.read(path)` /
`fs.write(path, data, mode?)` (keep slurp/barf as aliases or drop — pick
one). Path-based `truncate` lives in fs only.

**Plan.** Red: `fs_test.tl` round-trip via `fs.read`/`fs.write`;
`fd_test.tl` wraps `fs.tmpfd()` output. Green: mechanical move; repo-wide
`grep -rln 'cosmic.io'` sweep in one commit; update CLAUDE.md mapping table
and the skills docs.

### 31. Naming and convention sweep (one pass, one issue)

**Repo:** whilp/cosmic · **Layer:** cosmic

Collected renames, each trivially mechanical, all breaking, so batch them:
`fetch.Fetch` → `fetch.fetch` (CLAUDE.md already documents the lowercase
name that doesn't exist); `re.match` → `re.test` (boolean; avoids
`string.match` confusion); delete `string.upper`/`lower` (verbatim stdlib
duplicates); `url.parse`/`parse_query` per #21; options records standardize
on `<Verb>Options`; `fs.is_dir(mode)`-style mode predicates move onto the
`Stat` record (`st:is_dir()`) to end the `isdir(path)` vs `is_dir(mode)`
confusion; `args.tl` (the CLI's own option table squatting on a
utility-sounding name) folds into CLI internals; document the rule
"PascalCase = record constructor" for `signal.Sigset`. The type checker +
`bin/make ci` are the red/green.

---

## P2 — nice to have

### 32. Namespace hygiene: directory modules, public-API manifest, versioned init

**Repo:** whilp/cosmic.** 74 requireable top-level modules, ~45 documented,
nothing marks internals: `fs_ops`/`fs_path`/`fs_walk`, `net_socket`,
`child_io`, `sqlite_row_iter`/`sqlite_stmt_cache`, the seven-file doc
family, and CLI internals (`main*`, `help`, `style`, `welcome`, `run`,
`script_cache`, `instrument`) all live in the user namespace; shard
re-exports create duplicate public surfaces (`cosmic.fs.join` ==
`cosmic.fs_path.join`). quicksand already demonstrates the fix: directory
modules with `init.tl`. Convert family-by-family (fs first as template);
add a PUBLIC manifest that docs and lint check; move CLI internals under
`cosmic/cli/`. Also `init.tl`: inject `_VERSION` from the release tag at
build time (hardcoded "0.1.0" today), fix `_DESCRIPTION`, fix the
mis-indented block at lines 16-41, and route `main()` through
`proc.is_main()` per its own layering advice.

### 33. hash/rand additions

**Repo:** whilp/cosmic.** `hmac_sha256(key, data)` (wraps the existing
`cosmo.GetCryptoHash("SHA256", data, key)` — no C change);
`constant_time_equal(a, b)` (XOR-accumulate in Teal) so digest/MAC
comparisons stop being timing-leaky `==`; `rand.int(min, max)` unbiased via
rejection sampling over `bytes()` (pairs with the #27 rand cleanup);
document/loop the 256-byte `bytes` cap. Streaming SHA-256 needs a new C
incremental binding — post-stable. Argon2 defaults verified OWASP-correct;
no change.

### 34. argon2 API cleanup

**Repo:** whilp/cosmopolitan.** Drop the module-level config mutators
(`argon2.t_cost(10)` mutates shared state for the whole process,
largon2.c:188-246) and the lightuserdata `variants` (untypeable); accept
`variant = "argon2id"` strings in the options table; `verify` → `boolean,
string?` per #14; optional `salt = nil` = generate 16 random bytes. cosmic
`hash.tl` deletes its variant map and casts.

### 35. tty raw mode

**Repo:** whilp/cosmic.** `tty.raw()` only clears lflag bits — `\r`
translation and Ctrl-S freezing remain (the two bugs every TUI hits); clear
IXON/ICRNL/BRKINT/OPOST, set VMIN=1/VTIME=0, offer `{keep_signals:
boolean}`; deep-copy `termios.cc` so `restore()` can't be corrupted by cc
mutation. Extract a pure `make_raw(Termios): Termios` so the flag math is
unit-testable without a tty. (Error-handling part covered in #22.)

### 36. time ergonomics

**Repo:** whilp/cosmic.** Two-integer `(secs, nanos)` returns force manual
arithmetic on every timeout/benchmark; add `now_ms()`/`monotonic_ms()`
(exact within 2^53). Replace `timegm`'s O(years) year-loop with the O(1)
civil-days algorithm (it sits under `parse_http`/`parse_iso8601` — hot when
parsing headers/logs). `DateTime.isdst: number` → `boolean`. `#11`'s
`wait(timeout_ms)` builds on `monotonic_ms`.

### 37. fetch/stream small warts

**Repo:** both.** 204/304 responses build the reader pre-closed so the first
`read()` returns `nil, "reader closed"` — a successful response that looks
like an error (lfetch.c:1340-1347); add a completed-not-closed state →
clean EOF. `read()` can return `""` on empty chunk frames — loop internally
or document loudly. `resettls=true` default tears down and re-inits TLS
config + DRBG on every HTTPS request to protect forked children
(fetch.inc:232-235) — remember getpid() at init and reset only on change;
delete the user-visible option. Add `Result:is_success()` (2xx helper) to
defuse the `ok`-means-transport trap. Delete `has_stream()` — a capability
probe for a pinned binary is dead weight.

### 38. quicksand facade, enums, typing

**Repo:** whilp/cosmic.** One `cosmic.sandbox.apply{fs = {ro, rw, exec},
sys = {promises}, best_effort = false}` facade over
unveil/landlock/pledge with per-OS mechanism choice and enforced ordering
(fs before sys), honest per #4; Box consumes the same schema (deleting the
third vocabulary; remove the decoy `fs.deny` knob). Teal enums for pledge
promises, unveil perms, NetRule types, log levels. Move shared records
(`BoxOpts`, `FsOpts`, `NetRule`, `Capabilities`) into
`quicksand/types.tl`; export `Box` typed instead of `Box: any`
(init.tl:47) and delete the ~20 re-casts in run.tl.

### 39. Grab-bag (small, independent)

- `codec.encode_lua` truncating parens drop the C error channel → return
  `string | nil, string` (codec.tl:40-42).
- `envd.load` gains an `errors: {string}` field in LoadResult instead of
  debug-only prints; `env.set` failures collected.
- `proc.exit` skips `__gc`/`<close>` finalizers [verified by agent] —
  document loudly or `collectgarbage("collect")` before `unix.exit`.
- `poll.wait()` on hard error should return an error, not an empty
  iterator; `poll.add(nil)` should error, not no-op.
- `html`: add `unescape` or document one-way-ness; `syslog`: document fixed
  ident/facility (no openlog binding exists).
- IPv4-only reality (fetch resolves AF_INET, ip can't parse `::1`): state
  "IPv4 only" in fetch/net/ip docs and make IPv6 literals produce a crisp
  `"IPv6 not supported"` — engineering is post-stable.
- C nits: `unix.fstatfs` doc says Stat (lunix.c:1785); setitimer silently
  truncates ns → µs (document); `path.join()` all-nil returns nil.
- `assert.tl` `@param err` / parameter `e` doc mismatch; `envd.parse` ctx
  optionality mismatch; dangling "gotchas #7" reference in child.tl:150.

---

## Suggested sequencing (release waves)

1. **Safety wave (no contract debate):** #1 getopt UAF, #6 UUID randomness,
   #2 SIGPIPE, #3 transaction, #5 destructive probe, #10 spawn hygiene,
   #25 shm C fixes.
2. **Purge wave:** #27 surface purge + definitions.lua cleanup — shrinks
   every later diff.
3. **Honest-types wave:** #8 (renderer + stdlib nil sweep) + #29 options
   classes + #12 host_os — one breaking release where the type checker
   starts enforcing error handling.
4. **C-contract wave:** #14 error convention with #15 re, #17 zip C, #18
   json C, #28 compression, #34 argon2, #24 signals folded in; one cosmos
   release, one pin bump, one regen.
5. **cosmic-shape wave:** #11 child redesign, #19 fetch restructure, #13
   headers, #20 streaming, #21 url/ip, #22 errno sweep, #23 fs, #26
   quicksand, #4 fail-closed sandboxing.
6. **Rename/namespace wave:** #30 io→fd, #31 naming sweep, #32 directory
   modules — last, so churn doesn't rebase everything else.

Every wave: `bin/make ci` + `bin/make perf-compare` in cosmic; C changes
also `make -j o//tool/lua/test` upstream.

## Coverage note

Reviewed and found sound (no issues filed): lunix.c's internal consistency
(the Errno *representation* is the issue, not the discipline); ljson.c's
decoder security posture (UTF-8 validation, depth + C-stack guards, junk
detection); fetch's TLS story (verification required, no disable path,
downgrade refusal, cross-origin credential stripping); lzip writer
validation and crash-safety; cosmic's errno.tl, child_io pump correctness,
fs_path.normalize fast path, fs_walk d_type optimization, glob escaping,
envd parsing/precedence, tty.getpass, codec validators, fuzzy, uuid (API),
argon2 parameter defaults (OWASP-compliant, verified from a live hash),
quicksand's proxy stack / netns / proc / caps ordering, landlock.tl's core
design, poll's core design, url escaping family, fetch header-injection
defense, and the gentype drift-test mechanism itself.
