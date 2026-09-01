## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s metadata readers, directory streams and temp-fd constructors. A research slice: its deliverable is recorded evidence and the
follow-up captures, not code.

## Evidence

Measured 2026-08-26 against whilp/cosmopolitan master `1e165815` (the
commit carrying both settled sibling contracts, #276 and #277).

The universe is one walk of `tool/net/definitions.lua`: for each
`^function` declaration, classify the FIRST `@return` line of the
contiguous `---` doc run directly above it — **NIL** when that line
contains `|nil` or its type token ends in `?`, **EXACT** otherwise,
**NONE** when the run declares no `@return` at all. Save this as
`census.awk` and run it from the cosmopolitan repo root:

```awk
/^---/ { run[n++] = $0; next }
/^function / {
  name = $2; sub(/\(.*/, "", name)
  cls = "NONE"
  for (i = 0; i < n; i++) {
    if (run[i] ~ /^---@return /) {
      split(run[i], f, " ")
      cls = (index(run[i], "|nil") > 0 || f[2] ~ /\?$/) ? "NIL" : "EXACT"
      break
    }
  }
  print cls "\t" name
  n = 0; next
}
{ n = 0 }
```

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    209 EXACT
    192 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
439
```

209 + 192 + 38 = 439, so the walk classifies every declaration and
nothing is silently dropped. By module, the 192 NIL rows
(`awk -F'\t' '$1=="NIL"{print $2}' … | sed 's/[:.].*//' | sort | uniq -c`):

| module | nil-admitting |
|---|---|
| `unix` | 127 |
| `lsqlite3` | 22 |
| `cosmo` | 22 |
| `zip` | 14 |
| `re` | 5 |
| `getopt` | 1 |
| `argon2` | 1 |
| `path`, `cov`, `repl` | 0 |

`path` is exact in all 7 of its bindings — sibling 3IQtfuCx (#276)
closed the last one — and `cov` and `repl` contribute no rows, so
neither module gets a census slice.

**This measurement supersedes the per-module figures in the parent's
bounce note**, which reported `unix` 128 (its walk predates #277's
`clock_gettime`), `lsqlite3` 30 and "`cov` and `repl` declare 2
bindings between them". Re-derived here at `1e165815`, `lsqlite3`
carries 22 NIL rows of 108 declarations, and `cov`/`repl` declare 7
between them, all EXACT. The command above is the one to re-run; the
parent's is not reproducible from its note.

Re-measured 2026-09-01 at HEAD `4fb77b7a` (thirty-odd commits ahead of
`1e165815`, none touching `third_party/lua/cosmo/lunix.c`,
`libc/stdio/dirstream.c`, `libc/calls/tmpfd.c`, or this slice's lines
of `tool/net/definitions.lua` — confirmed by `git log --oneline
1e165815..HEAD -- third_party/lua/cosmo/lunix.c tool/net/definitions.lua
libc/stdio/dirstream.c libc/calls/tmpfd.c`, which returns commits only
for `#276`/`#277`-adjacent unix families outside this scope, e.g. #320–324):
totals are now 216 EXACT / 186 NIL / 38 NONE = 440 (`unix` dropped from
127 to 122 NIL, `getopt` from 1 to 0, via #315–#324, none in this
slice's family). Re-running the scope filter below at HEAD still
yields exactly this slice's 11 bindings, all still NIL. Not a bounce.

**This slice's scope: the 11 nil-admitting bindings below.**

```text
unix.stat unix.fstat unix.statfs unix.fstatfs unix.opendir 
unix.fdopendir unix.Dir:close unix.Dir:read unix.Dir:fd 
unix.Dir:tell unix.tmpfd
```

## Change

Classify every binding in this slice's scope into exactly one class,
with evidence:

1. **degenerate-input-only** — nil reachable only for an argument shape
   no correct caller passes (the `path.join(nil)` class, closed by
   #276). Each is a raise-candidate: file one capture per binding,
   unparented, then `attach` it under this item's parent container
   with `--repo whilp/cosmopolitan`.
2. **environmental or data-dependent** — a correct caller can meet the
   failure (ENOENT, EINTR, bad input data). The union stays; verify the
   tuple is exactly `T|nil, err string, errno?` with nothing else
   sharing a slot. Each deviation gets its own capture — `unix.nanosleep`
   is the archetype, its slot 2 declared `integer|string remnanos` so
   the success remainder shares a slot with the error string.
3. **exact already** — no action; one summary row.

The evidence standard, per row:

- the C source cite, as `file:line`
- the `tool/net/definitions.lua` line
- one probe transcript against the built binary
  (`o//tool/lua/lua -e '...'`) demonstrating the reachability class
- the cosmic-side spend: `grep -rn '<binding>' cosmic/` in a cosmic
  checkout, listing the wrapper sites that guard or assert it today

Record the summary table (binding, class, probe command, capture id or
"exact") back onto THIS item with `gitboard spec`, then finish per
review.md's research-slice clause — the deliverable is board state, and
there is no product PR.

## Non-goals

- No code change in either repo — captures and evidence only.
- No bindings outside this slice's scope list above. A binding that
  turns out to belong to a sibling slice's family stays that slice's
  row; say so in this item's summary rather than adopting it.
- No re-litigating `path.join` (#276) or `unix.clock_gettime` (#277).
- No captures for class-3 rows.
- No promotion of the filed captures — ordering them is the goal
  owner's `compare`, after this slice reports.

## Acceptance

- This item's spec carries the summary table, with exactly one row per
  binding in the scope list above and no others. State the row count
  beside the scope count so a reader can see they match.
- Every class-1 row and every class-2 tuple-deviation row names a filed
  capture id, and `gitboard tree` under the parent container lists it.
- Every row's probe command is literally runnable from the
  cosmopolitan repo root against `o//tool/lua/lua`, built by
  `make -j$(nproc) o//tool/lua/lua`.
- The scope list is re-derived, not trusted: re-running the `census.awk`
  command above at the commit the slice is worked at yields this
  slice's binding set. A binding that has moved class since
  `1e165815` is a re-measured row, not a bounce.

## Enablement

none needed. The classes, the evidence standard and the capture rule
are stated in full above, so this slice is workable without reading the
parent. It writes no repo files, so it is parallel-safe with every
sibling census slice and with any contract slice they seed.

## Summary Table

Scope count: 11. Row count: 11 — match.

Read of the spec's three classes as applied here: none of this slice's
11 bindings is class-1 (nil reachable ONLY via a degenerate argument
shape). `stat`/`fstat`/`statfs`/`fstatfs`/`opendir`/`fdopendir` all
check their `path`/`fd`/`flags`/`dirfd` arguments with
`luaL_checkstring`/`luaL_checkinteger`/`luaL_optinteger`, which RAISE
on a wrong Lua type before any nil-tuple is reachable — that shape
error is already handled the `path.join` way, not part of the
declared NIL path. `tmpfd` takes no arguments at all. The four
`Dir:*` methods likewise already raise via `GetDirOrDie`'s
`luaL_argerror(L, 1, "unix.UnixDir is closed")` when called on an
already-closed handle — a second already-settled degenerate case, also
outside the declared NIL path. Every one of the 11 has a genuine (or,
for two rows, a now-dormant but contract-shaped) environmental/
data-dependent failure path instead. All 11 are therefore class-2;
within class-2 the disposition is either "tuple exact" (capture column
reads `exact`) or "tuple deviation" (needs its own capture). One
binding, `unix.Dir:read`, has a deviation — its declared shape carries
no error slot at all, so a genuine `readdir()` failure is
indistinguishable from legitimate end-of-directory.

| # | Binding | Class | C source | definitions.lua | Probe (from cosmopolitan repo root, against `o//tool/lua/lua`) | Cosmic-side spend | Capture |
|---|---|---|---|---|---|---|---|
| 1 | `unix.stat` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1929-1939` (`LuaUnixStat`, wraps `fstatat`) | `7222` | `o//tool/lua/lua -e 'local u=require("unix");print(u.stat("/nonexistent-xyz-path"))'` → `nil  stat: ENOENT: No such file or directory  2` (data-dependent: any correct caller checking a path's existence hits this) | `cosmic/fs/dir.tl:74,87`; `cosmic/fs/walk.tl:80`; `cosmic/fs/path.tl:48,59`; `cosmic/fs/find.tl:223`; `cosmic/fs/tree.tl:30,75` — all narrow the `Stat\|nil` result | exact |
| 2 | `unix.fstat` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1944-1953` | `7281` | `o//tool/lua/lua -e 'local u=require("unix");print(u.fstat(9999))'` → `nil  fstat: EBADF: Bad file descriptor  9` (data-dependent: a stale/closed fd is a routine runtime condition) | `cosmic/sandbox/landlock.tl:387`; `cosmic/fs/dir.tl:99`; `cosmic/fs/ops.tl:74` | exact |
| 3 | `unix.statfs` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1958-1967` | `8294` | `o//tool/lua/lua -e 'local u=require("unix");print(u.statfs("/nonexistent-xyz-path"))'` → `nil  statfs: ENOENT: No such file or directory  2` | `cosmic/fs/ops.tl:406` | exact |
| 4 | `unix.fstatfs` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1972-1981` | `8302` | `o//tool/lua/lua -e 'local u=require("unix");print(u.fstatfs(9999))'` → `nil  fstatfs: EBADF: Bad file descriptor  9` | `cosmic/fs/ops.tl:420` | exact |
| 5 | `unix.opendir` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:4269-4277` | `7300` | `o//tool/lua/lua -e 'local u=require("unix");print(u.opendir("/nonexistent-xyz-dir"))'` → `nil  opendir: ENOENT: No such file or directory  2` | `cosmic/fs/dir.tl:183`; `cosmic/fs/walk.tl:159,206`; `cosmic/fs/find.tl:159,184,313`; `cosmic/fs/tree.tl:19`; `cosmic/env.tl:306`; `cosmic/embed/init.tl:103` — all narrow via `raw is unix.Dir` or an `err` check | exact |
| 6 | `unix.fdopendir` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:4282-4290` | `7312` | `o//tool/lua/lua -e 'local u=require("unix");print(u.fdopendir(9999))'` → `nil  fdopendir: EBADF: Bad file descriptor  9` | `cosmic/fs/dir.tl:196` | exact |
| 7 | `unix.Dir:close` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:4196-4209` (`closedir()`; re-close after the handle is already closed returns `true` unconditionally by design, per the doc's "may be called multiple times") | `7888` | `o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir(".");print(d:close());print(d:close())'` → `true` then `true` (baseline: the documented multi-close is not the nil path); the nil path is `closedir()` itself failing (ENOSPC/EIO-class delayed-write errors on close, environmental) | `cosmic/fs/dir.tl:18-63` (`wrap_dir`'s `close`), the single guard/wrap site for all four `Dir:*` methods; consumed at `cosmic/fs/walk.tl:137,143,150`; `cosmic/fs/find.tl:167,202,325`; `cosmic/fs/tree.tl:32,39,47,52,58,64,70`; `cosmic/env.tl:325`; `cosmic/embed/init.tl:117` | exact |
| 8 | `unix.Dir:read` | 2, tuple DEVIATION | `third_party/lua/cosmo/lunix.c:4214-4228` (`LuaUnixDirRead`, wraps `readdir()`; comment at line 4223-4224: "end of directory stream condition / we make the assumption getdents() won't fail") | `7909` (declared `@return string\|nil name, integer kind, integer ino, integer off` — a single `@return` line with **no error-string or errno slot at all**) | `o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir(".");local fd=d:fd();u.close(fd);print(d:read())'` → `nil` — identical to the legitimate-EOF transcript `o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir("/tmp");while d:read() do end;print(d:read())'` → `nil`. `libc/stdio/dirstream.c:602-613`'s own doc for `readdir()` states the failure/EOF ambiguity is meant to be resolved by the caller zeroing `errno` before the call and checking it after; `LuaUnixDirRead` does not do this, so a genuine `readdir()` failure (fd invalidated, EIO, EOVERFLOW) is indistinguishable from ordinary end-of-directory — worse than sharing a slot, it declares none | `cosmic/fs/dir.tl:25-29` (`wrap_dir`'s `read`) propagates the same ambiguity one layer up: `if is_closed then return nil end; local name, kind = raw:read(); return name, kind` — no error surfaced either way; consumed at `cosmic/fs/walk.tl:107`; `cosmic/fs/find.tl:200,319`; `cosmic/fs/tree.tl:25`; `cosmic/env.tl:319`; `cosmic/embed/init.tl:111` | `3IjlqRGWbkQaAILUmmdixMqu8Ff` |
| 9 | `unix.Dir:fd` | 2, tuple exact (declared failure currently unreachable — see note) | `third_party/lua/cosmo/lunix.c:4233-4242` (checks `dirfd() != -1`); `libc/stdio/dirstream.c:693-695` (`int dirfd(DIR *dir) { return dir->fd; }`, unconditional) | `7918` (doc comment: "Returns `EOPNOTSUPP` if using a `/zip/...` path or if using Windows NT") | `o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir("/zip/");print(d:fd())'` → `3` (a valid fd, NOT nil/EOPNOTSUPP as documented) | `cosmic/fs/dir.tl:36-40` (`wrap_dir`'s `fd`) — already codes around the documented claim: `return raw:fd() or -1` with a comment citing the same EOPNOTSUPP-on-zip/Windows rationale; consumed at `cosmic/fs/find.tl` iterator internals via the wrapped `Dir` type | exact (see note below) |
| 10 | `unix.Dir:tell` | 2, tuple exact (declared failure currently unreachable — see note) | `third_party/lua/cosmo/lunix.c:4247-4250` (`SysretInteger` on `telldir()`); `libc/stdio/dirstream.c:682-688` (`long telldir(DIR *dir) { ...; rc = dir->index; ...; return rc; }`, a plain monotonic counter, no error path) | `7924` | `o//tool/lua/lua -e 'local u=require("unix");local d=u.opendir(".");print(d:tell());d:read();print(d:tell())'` → `0` then `1` — never nil | `cosmic/fs/dir.tl:45-50` (`wrap_dir`'s `tell`) — same `raw:tell() or -1` pattern, same EOPNOTSUPP-on-zip/Windows comment as row 9's `fd` | exact (see note below) |
| 11 | `unix.tmpfd` | 2, tuple exact | `third_party/lua/cosmo/lunix.c:1767-1770`; `libc/calls/tmpfd.c:74-96` (no arguments at all — nothing to be degenerate) | `7412` | `o//tool/lua/lua -e 'local u=require("unix");assert(u.setrlimit(u.RLIMIT_NOFILE,3));print(u.tmpfd())'` → `nil  tmpfd: EMFILE: Too many open files  24` (resource-exhaustion, environmental) | `cosmic/fs/ops.tl:392` (`temp_fd`) | exact |

**Note on rows 9 and 10 (`Dir:fd`, `Dir:tell`):** both are declared
`|nil` and their tuple shape is exact, but neither's nil branch is
demonstrable against the current build. `git log -L
'/^int dirfd/,+3:libc/stdio/dirstream.c'` shows commit `110559ce6`
("Make ZipOS and Qemu work better", 2023-08-15) deleted the
`if (dir->iszip) rc = eopnotsupp(); else if (IsWindows()) rc =
eopnotsupp();` branches `dirfd()` used to have, collapsing it to an
unconditional `return dir->fd` — three years before `1e165815` — so the
`definitions.lua` doc comment describing that removed behavior is
stale. `telldir()`'s `-1`-signaling nil branch has never been reachable
since the file's "Initial import" (`c91b3c500`): `dir->index`/`dir->tell`
is a monotonic counter with no failure path in any of this codebase's
history. Both are still recorded as class-2/tuple-exact per the
container's rubric (a correct caller's contract still admits `nil` by
declaration, and `dir->fd` is only guaranteed non-negative because
`opendir`/`fdopendir` always populate it from a real `openat()` result
— an implementation detail, not a documented invariant) rather than
forced into class-3, since class-3 in this container's usage means "the
annotation itself was already fixed to non-nil" (the `path.join` case),
which is not what happened here. `unix.Dir:fd`'s stale EOPNOTSUPP doc
comment is filed as its own small documentation-accuracy capture,
`3IjlqgEejtmPe8lbUDtHijYjLR4`, since it doesn't fit either of this
container's two capture classes.
