# P1 — cosmic stdlib sweeps and reshapes

Part of the [pre-stable API review](README.md). Items 22–31.

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
