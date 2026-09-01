## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s sandbox, namespace, mount and resource-limit surface. A research slice: its deliverable is recorded evidence and the
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

**This slice's scope: the 16 nil-admitting bindings below.**

```text
unix.chroot unix.unshare unix.setns unix.mount unix.unmount 
unix.pivot_root unix.pledge unix.unveil 
unix.landlock_create_ruleset unix.landlock_add_rule 
unix.landlock_add_net_rule unix.landlock_restrict_self unix.sysconf 
unix.uname unix.setrlimit unix.getrlimit
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

## Results

Re-measured 2026-09-01 against `cosmic-lua/cosmopolitan` (the
`whilp/cosmopolitan` fork's canonical remote) at `9ca98b646166a8f5`,
16 commits ahead of the parent's `1e165815`. None of the 16 touched
`definitions.lua` between the two commits (verified by
`git log --oneline 1e165815..HEAD -- tool/net/definitions.lua`, then
diffing each hit against the scope's binding names); the only
scope-adjacent hit was a comment edit to `unix.isatty`'s doc mentioning
pledge, not a scope binding itself.

Re-running `census.awk` at HEAD:

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    212 EXACT
    190 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
440
```

By module (`unix` 126, `lsqlite3` 22, `cosmo` 22, `zip` 14, `re` 5,
`argon2` 1, `getopt` 0). Diffing the two commits' NIL rows directly
(not just the per-module counts) finds exactly two bindings changed
bucket, both accounted for: `getopt.parse` left NIL (#317, now raises
on argument-shape errors instead of returning `nil, err`), and
`unix.isatty` left NIL (#307, its declared return type was fixed —
`fd0884d91`). No binding entered NIL. `capget` (#309), `openpty`
(#311), and `nanosleep` (#315) changed their return *shape* inside the
already-NIL bucket (fixing a tuple-slot deviation, same defect class
this item's `getrlimit` finding below repeats) without crossing the
EXACT/NIL boundary, so they don't show up in this diff. Neither moved
binding is in this slice's scope; re-checking each of the 16
individually against the fresh `census_out.txt` confirms all 16 are
still `NIL` at HEAD, so **the scope list is unchanged**: same 16
bindings, same classification universe. This is a refreshed
measurement, not a blocker.

Classifying each of the 16: **all are class 2** (environmental/
data-dependent) — none is class 1 (degenerate-input-only) and none is
class 3 (exact already). Every one of the 16 implementations
(`third_party/lua/cosmo/lunix.c`) routes its only failure path through
`SysretBool`/`SysretInteger`/`LuaUnixSysretErrno`, which push `nil,
error:string, errno:int` strictly on the underlying syscall's own
`rc == -1`; none of the 16 has a hand-written shape check ahead of the
syscall that could return nil for a merely-wrong-typed argument (a
`grep` for `lua_pushnil`/`luaL_error`/`luaL_argerror` inside each
function's body, beyond the standard `luaL_check*` argument coercions
that already raise on a type violation, comes back empty for all 16).
So nil is reachable in every row, but only via a real runtime
condition (missing capability, absent kernel feature, bad resource ID,
busy/absent mount point, ENOSYS on an unsupported host) that a
correctly-typed caller can hit — never via an argument shape a typed
caller couldn't produce.

**16 rows for 16 bindings in scope — counts match.**

### Summary table

| binding | class | probe command | capture id / exact |
|---|---|---|---|
| `unix.chroot` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").chroot("/nonexistent-chroot-target-xyz"))'` | exact |
| `unix.unshare` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").unshare(-1))'` | exact |
| `unix.setns` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").setns(999999, 0))'` | exact |
| `unix.mount` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").mount("none","/nonexistent-target-xyz","tmpfs",0,nil))'` | exact |
| `unix.unmount` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").unmount("/nonexistent-target-xyz",0))'` | exact |
| `unix.pivot_root` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").pivot_root("/tmp","/tmp"))'` | exact |
| `unix.pledge` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").pledge("not_a_real_promise_xyz", nil))'` | exact |
| `unix.unveil` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").unveil("", nil))'` | exact |
| `unix.landlock_create_ruleset` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").landlock_create_ruleset())'` | exact |
| `unix.landlock_add_rule` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").landlock_add_rule(999999, 0, 1, 0))'` | exact |
| `unix.landlock_add_net_rule` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").landlock_add_net_rule(999999, 443, 1, 0))'` | exact |
| `unix.landlock_restrict_self` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").landlock_restrict_self(999999, 0))'` | exact |
| `unix.sysconf` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").sysconf(999999))'` | exact |
| `unix.uname` | 2 (environmental) | `o//tool/lua/lua -e 'local u=require("unix").uname(); print(u.sysname, u.machine)'` (success shown; failure is `ENOSYS` "on metal" per `libc/calls/uname.c:134`, not reproducible on this Linux probe host) | exact |
| `unix.setrlimit` | 2 (environmental) | `o//tool/lua/lua -e 'print(require("unix").setrlimit(999999, 100, 100))'` | exact |
| `unix.getrlimit` | 2 (environmental), **tuple deviation** | `o//tool/lua/lua -e 'print(require("unix").getrlimit(require("unix").RLIMIT_NOFILE)); print(require("unix").getrlimit(-1))'` | **capture: "cosmo.unix.getrlimit: soft/hard success pair shares slot 2 with the failure tuple's error string"** (filed under `3IQtgMjycyFrxa8xT2ZqwOHfdJl`, `--repo cosmic-lua/cosmopolitan`) |

### Detailed evidence

- **`unix.chroot`** — C: `third_party/lua/cosmo/lunix.c:908-911`. Defs:
  `tool/net/definitions.lua:5665-5669`
  (`---@return true|nil` / `---@return string? error` / `---@return unix.Errno? errno`).
  Probe: `nil	chroot: ENOENT: No such file or directory	2`. Cosmic
  spend: `grep -rn 'unix\.chroot(' cosmic/` → 0 hits; unwrapped today.

- **`unix.unshare`** — C: `lunix.c:921-924`. Defs: `definitions.lua:7425-7429`.
  Probe: `nil	unshare: EINVAL: Invalid argument	22`. Cosmic spend: 6
  call sites, all guarded (`local ok, err = unix.unshare(...)` or
  narrower) — `cosmic/quicksand/proc.tl:241`,
  `cosmic/quicksand/init_test.tl:92,129`, `cosmic/quicksand/netns.tl:91,103`,
  `cosmic/quicksand/init.tl:126`, `cosmic/quicksand/box/run.tl:211`.

- **`unix.setns`** — C: `lunix.c:935-940`. Defs: `definitions.lua:7435-7440`.
  Probe: `nil	setns: EBADF: Bad file descriptor	9`. Cosmic spend: 2
  call sites, guarded — `cosmic/quicksand/netns.tl:77`,
  `cosmic/quicksand/proxy/dial.tl:67`.

- **`unix.mount`** — C: `lunix.c:962-971`. Defs: `definitions.lua:7444-7452`.
  Probe: `nil	mount: ENOENT: No such file or directory	2`. Cosmic
  spend: `grep -rn 'unix\.mount(' cosmic/` → 0 hits; only prose mentions
  of "mount" elsewhere (`cosmic/quicksand/proc.tl`,
  `cosmic/quicksand/init_test.tl`, `cosmic/quicksand/init.tl`,
  `cosmic/fs/types.tl`), no wrapper.

- **`unix.unmount`** — C: `lunix.c:981-986`. Defs: `definitions.lua:7457-7462`.
  Probe: `nil	unmount: ENOENT: No such file or directory	2`. Cosmic
  spend: `grep -rn 'unmount' cosmic/` → 0 hits at all; wholly unwrapped
  and unmentioned.

- **`unix.pivot_root`** — C: `lunix.c:995-1000`. Defs:
  `definitions.lua:7467-7472`. Probe: `nil	pivot_root: EBUSY: Device or
  resource busy	16` (this probe host's `/` is not a private mount
  namespace, which is itself the documented precondition — an
  environmental fact, not an argument-shape one). Cosmic spend:
  capability-detection only — `cosmic/quicksand/init.tl:211`
  (`pivot_root = is_linux and unix.pivot_root ~= nil`) and
  `cosmic/quicksand/types.tl:116`, `cosmic/quicksand/init_test.tl:25` —
  the binding itself is never called, only tested for existence.

- **`unix.pledge`** — C: `lunix.c:2344-2349`. Defs:
  `definitions.lua:7078-7081`. Probe: `nil	pledge: EINVAL: Invalid
  argument	22`. Cosmic spend: 2 call sites, guarded —
  `cosmic/sandbox/pledge.tl:99` (`local ok, _, eno = unix.pledge(nil, nil)`,
  a documented feature probe), `cosmic/sandbox/pledge.tl:128`.

- **`unix.unveil`** — C: `lunix.c:2354-2358`. Defs:
  `definitions.lua:7143-7147`. Probe: `nil	unveil: ENOSYS: Function not
  implemented	38`, using the `unveil("", nil)` feature-probe form
  (`libc/calls/unveil.c:436-454`). Note: `unveil`'s ordinary form
  (non-empty `path`) silently converts an internal `ENOSYS` into a
  fabricated success by design — `libc/calls/unveil.c:462-465`,
  "`if (rc == -1 && errno == ENOSYS) { errno = e; rc = 0; }`", documented
  at `libc/calls/unveil.c:326-328` ("then zero is returned and nothing
  happens... because the files are still unveiled") — so on this probe
  host (landlock unsupported: confirmed by `landlock_create_ruleset()`
  returning `ENOSYS` above), a malformed-permissions or too-long-path
  call to ordinary `unveil(path, perms)` also returns `true`, not `nil`,
  because the `ENOSYS` short-circuit in `sys_unveil_linux`
  (`libc/calls/unveil.c:210-211`) fires before the argument checks at
  `libc/calls/unveil.c:212-213` (bad permissions XOR), `241-242`
  (`ENAMETOOLONG`), and `246-248` (`ELOOP`) are ever reached. On a
  landlock-capable host those checks run and can return `nil`, which is
  why this row is still class 2, not class 3 — the failure is real, just
  gated on landlock support, another environmental fact. Cosmic spend: 3
  call sites, guarded — `cosmic/sandbox/unveil.tl:109`
  (`local ok, err, eno = unix.unveil(path, permissions)`),
  `cosmic/sandbox/unveil.tl:130` (the commit call), plus doc-comment
  cross-references in `cosmic/quicksand/init.tl:216` and
  `cosmic/quicksand/init_test.tl:257`.

- **`unix.landlock_create_ruleset`** — C: `lunix.c:1135-1161`. Defs:
  `definitions.lua:7541-7548`. Probe: `nil	landlock_create_ruleset:
  ENOSYS: Function not implemented	38` (argless ABI-probe form; this
  probe host's kernel lacks Landlock). Cosmic spend: 4 call sites,
  guarded — `cosmic/sandbox/landlock.tl:270,352,354,356`.

- **`unix.landlock_add_rule`** — C: `lunix.c:1178-1190`. Defs:
  `definitions.lua:7553-7560`. Probe: `nil	landlock_add_rule: ENOSYS:
  Function not implemented	38`. Cosmic spend: 1 call site, guarded —
  `cosmic/sandbox/landlock.tl:392`.

- **`unix.landlock_add_net_rule`** — C: `lunix.c:1206-1217`. Defs:
  `definitions.lua:7567-7574`. Probe: `nil	landlock_add_net_rule:
  ENOSYS: Function not implemented	38`. Cosmic spend: 1 call site,
  guarded — `cosmic/sandbox/landlock.tl:408`.

- **`unix.landlock_restrict_self`** — C: `lunix.c:1231-1237`. Defs:
  `definitions.lua:7584-7589`. Probe: `nil	landlock_restrict_self:
  ENOSYS: Function not implemented	38`. Cosmic spend: 1 call site,
  guarded — `cosmic/sandbox/landlock.tl:439`.

- **`unix.sysconf`** — C: `lunix.c:4325-4337`. Defs:
  `definitions.lua:5782-5787`. Probe: `nil	sysconf: EINVAL: Invalid
  argument	22` (an `SC_*`-shaped but unrecognized/unsupported-on-this-
  platform name — portability, not a type violation). Cosmic spend: 1
  call site, guarded — `cosmic/sys.tl:84`.

- **`unix.uname`** — C: `lunix.c:4345-4365`. Defs:
  `definitions.lua:5805-5809`. Probe (success):
  `Linux	x86_64`. `uname()` takes no arguments, so there is no
  argument-shape axis at all; its one documented failure is `@raise
  ENOSYS on metal` (`libc/calls/uname.c:134,169` — cosmopolitan's
  bare-metal target, which is a real cosmopolitan deployment mode
  though not one of cosmic's own shipped platforms per
  `AGENTS.md`'s "Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD"
  list). Not reproducible from this Linux probe host; classed
  environmental (a correct caller running cosmopolitan bare-metal code
  meets it) rather than exact-already, on the binding's own contract.
  Cosmic spend: 1 call site, guarded — `cosmic/sys.tl:111`.

- **`unix.setrlimit`** — C: `lunix.c:1242-1249`. Defs:
  `definitions.lua:6800-6805`. Probe: `nil	setrlimit: EINVAL: Invalid
  argument	22`. Cosmic spend: 1 call site, guarded (`boolean, string`
  wrapper) — `cosmic/proc/rusage.tl:59`.

- **`unix.getrlimit`** — C: `lunix.c:1254-1264`. Defs:
  `definitions.lua:6808-6813`
  (`---@return integer|nil soft, integer hard` / `---@return string?
  error` / `---@return unix.Errno? errno` — one `@return` tag naming
  two positions, `soft` and `hard`, then two more tags for
  `error`/`errno`). On success the C function pushes exactly 2 values
  (`soft`, `hard`, both integers, `return 2;`); on failure it returns
  `LuaUnixSysretErrno`'s fixed 3 values (`nil, error:string, errno:int`,
  confirmed at `lunix.c:219-238`). Probe:
  ```
  $ o//tool/lua/lua -e '
  local unix = require("unix")
  print(unix.getrlimit(unix.RLIMIT_NOFILE))
  print(unix.getrlimit(-1))
  '
  20000	20000
  nil	getrlimit: EINVAL: Invalid argument	22
  ```
  Slot 2 is `hard` (a plain, non-nullable `integer`, per the
  annotation) on success and the error string on failure — the exact
  `unix.nanosleep`/`remnanos` deviation the Change section names as the
  archetype, except `getrlimit`'s annotation is *more* misleading than
  the pre-fix `nanosleep`'s: `nanosleep` at least declared slot 2 as
  `integer|string`, honestly admitting the string; `getrlimit` declares
  it as bare `integer`. **Tuple deviation — capture required.** Cosmic
  spend: 1 call site, and it is the smoking gun —
  `cosmic/proc/rusage.tl:41-47` already works around this exact hazard
  by destructuring positionally and checking `if soft == nil then`,
  with the comment (verbatim, lines 43-44): "On failure the binding
  returns (nil, err, errno): the error string arrives in the second
  slot, where the hard limit would have been." The wrapper is correct;
  the underlying binding's raw shape is the defect, undocumented as
  such until this slice.

## Out-of-scope notes

None. No defect was found outside this slice's 16-binding scope during
this research pass.
