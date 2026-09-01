## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
the filesystem namespace half of `cosmo.unix` — creating, naming, removing and re-permissioning paths. A research slice: its deliverable is recorded evidence and the
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

**This slice's scope: the 22 nil-admitting bindings below.**

```text
unix.open unix.access unix.mkdir unix.makedirs unix.mkdtemp 
unix.mkstemp unix.chdir unix.unlink unix.rmdir unix.rename 
unix.link unix.symlink unix.readlink unix.realpath unix.getcwd 
unix.rmrf unix.truncate unix.ftruncate unix.chown unix.chmod 
unix.utimensat unix.futimens
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

## Summary

**Re-derivation at the working commit** (`16298b57894b763ede708019861d0b44bdad2cdf`,
2026-09-01, descendant of `1e165815`):
`awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c`
now reads `216 EXACT, 186 NIL, 38 NONE` (440 total; `grep -c '^function '`
also 440 — still exhaustive). Per-module NIL: `unix` 122 (was 127 —
5 unrelated fixes landed since `1e165815`: nanosleep's remainder
bundling, sigpending/clearenv tightening, getrlimit bundling,
raise/sigprocmask raising, and the Dir readdir/EOF fix — none touch
this slice), `lsqlite3` 22, `cosmo` 22, `zip` 14, `re` 5, `getopt` 0
(was 1 — `d66ca077` #317, `getopt.parse` raising on argument-shape
errors instead of returning `nil, err`, landed before this working
commit), `argon2` 1 (122+22+22+14+5+0+1=186, matching the stated
total). Direct lookup of the 22 scope bindings against the current
walk shows **all 22 remain `NIL`** — the scope list is unchanged, not
a bounce.

**Row count: 22. Scope count: 22. Match.**

Class 1 (degenerate-input-only): **0 bindings.** Every binding in this
slice is a thin wrapper around a real POSIX filesystem syscall
(`openat`, `mkdirat`, `renameat`, `truncate`, …); a correct caller can
always meet ENOENT/EEXIST/EACCES/ENOTDIR/EBADF/etc. at runtime — bad
*argument types* already raise via `luaL_checkstring`/`luaL_checkinteger`
before any nil-tuple is produced, so no binding's nil is reachable
*only* through a degenerate call shape.

Class 2 (environmental/data-dependent, tuple deviation — capture filed):
**1 binding — `unix.mkstemp`.**

Class 3 (environmental/data-dependent, tuple already exact — no
action): **21 bindings.**

All 21 class-3 bindings share the same evidenced shape: the C
implementation returns exactly one success value via `SysretBool`
(`true`) or `SysretInteger` (an integer, `0` for the two `utimensat`/
`futimens` cases) on success, and exactly `nil, err:string, errno:int`
via `LuaUnixSysretErrno` (lunix.c:219, confirmed to push exactly those
3 values) on failure — matching `T|nil, err string, errno?` with
nothing else sharing a slot. Every row's probe below was run with
`o//tool/lua/lua`, built via `make -j$(nproc) o//tool/lua/lua`.

| # | binding | class | definitions.lua | C source (`third_party/lua/cosmo/lunix.c` unless noted) | cosmic-side spend | capture |
|---|---|---|---|---|---|---|
| 1 | `unix.open` | 3 exact already | :4489-4497 | `LuaUnixOpen` :1753-1762 (`SysretInteger`) | 11 call sites, all destructure `fd, err[, eno]` and branch on `not fd` | exact |
| 2 | `unix.access` | 3 | :5077-5080 | `LuaUnixAccess` :413-422 (`SysretBool`) | `cosmic/fs/ops.tl:257` | exact |
| 3 | `unix.mkdir` | 3 | :5106-5109 | `LuaUnixMkdir` :424-433 | `cosmic/errno.tl:11`, `cosmic/fs/dir.tl:116` | exact |
| 4 | `unix.makedirs` | 3 | :5122-5125 | `LuaUnixMakedirs` :435-443 | `cosmic/fs/dir.tl:130`, `cosmic/fs/tree.tl:83` | exact |
| 5 | `unix.mkdtemp` | 3 | :5140-5143 | `LuaUnixMkdtemp` :1772-1793 | `cosmic/fs/ops.tl:356` | exact |
| 6 | `unix.mkstemp` | **2 tuple deviation** | :5160-5164 (`---@return integer\|nil fd, string path` at :5161) | `LuaUnixMkstemp` :1795-1817 | 3 call sites; 2 of 3 already comment the deviation explicitly (`cosmic/fs/ops.tl:380-381`, `cosmic/fs/file.tl:92-94`, both: `-- The binding returns (fd, path) on success and (nil, Errno) on failure.`); `cosmic/embed/init.tl:375` relies on the same shape (`local tmp_fd, tmp_path = unix.mkstemp(...)`, branching on `not tmp_fd`) but carries no comment naming the hazard — corrected from the prior claim that all 3 sites comment it | `3Ik1baEQLHTdUTbycfSXst5dUlw` |
| 7 | `unix.chdir` | 3 | :5168-5171 | `LuaUnixChdir` :453-459 | `cosmic/quicksand/box/run.tl:132`, `cosmic/fs/dir.tl:155`, `cosmic/child/init.tl:384` | exact |
| 8 | `unix.unlink` | 3 | :5181-5184 | `LuaUnixUnlink` :461-469 | 6 call sites | exact |
| 9 | `unix.rmdir` | 3 | :5193-5196 | `LuaUnixRmdir` :471-479 | `cosmic/fs/dir.tl:142` | exact |
| 10 | `unix.rename` | 3 | :5203-5207 | `LuaUnixRename` :481-490 | `cosmic/fs/ops.tl:127`, `cosmic/fs/file.tl:125` | exact |
| 11 | `unix.link` | 3 | :5215-5220 | `LuaUnixLink` :492-502 | `cosmic/fs/ops.tl:184` | exact |
| 12 | `unix.symlink` | 3 | :5230-5233 | `LuaUnixSymlink` :504-513 | `cosmic/fs/ops.tl:197`, `cosmic/fs/tree.tl:50` | exact |
| 13 | `unix.readlink` | 3 | :5247-5251 | `LuaUnixReadlink` :538-561 | `cosmic/fs/ops.tl:209`, `cosmic/fs/tree.tl:37` | exact (see out-of-scope finding: its `dirfd` param doc is stale — separate capture filed) |
| 14 | `unix.realpath` | 3 | :5256-5260 | `LuaUnixRealpath` :884-895 | `cosmic/fs/ops.tl:222` | exact |
| 15 | `unix.getcwd` | 3 | :5373-5376 | `LuaUnixGetcwd` :564-577 | 5 call sites in `cosmic/fs/dir.tl`, `cosmic/fs/path.tl` | exact |
| 16 | `unix.rmrf` | 3 | :5386-5388 | `LuaUnixRmrf` :445-451 | `cosmic/fs/ops.tl:237` | exact |
| 17 | `unix.truncate` | 3 | :6004-6006 | `LuaUnixTruncate` :1854-1861 | `cosmic/fs/file.tl:79` | exact |
| 18 | `unix.ftruncate` | 3 | :6013-6015 | `LuaUnixFtruncate` :1863-1871 | `cosmic/fd.tl:133` | exact |
| 19 | `unix.chown` | 3 | :5349-5351 | `LuaUnixChown` :515-525 | `cosmic/fs/ops.tl:289` | exact |
| 20 | `unix.chmod` | 3 | :5362-5364 | `LuaUnixChmod` :527-536 | 6 call sites | exact |
| 21 | `unix.utimensat` | 3 | :5300-5304 | `LuaUnixUtimensat` :1636-1650 | `cosmic/fs/ops.tl:159,170,324` | exact |
| 22 | `unix.futimens` | 3 | :5334-5338 | `LuaUnixFutimens` :1652-1664 | `cosmic/fs/ops.tl:340` | exact |

### Probe transcripts (run against `o//tool/lua/lua` from the cosmopolitan repo root)

```
$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd,e,eno=unix.open(d.."/missing/f") print(fd,e,eno) unix.rmdir(d)'
nil	open: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local ok,e,eno=unix.access(d.."/missing",unix.F_OK) print(ok,e,eno) unix.rmdir(d)'
nil	access: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local ok,e,eno=unix.mkdir(d) print(ok,e,eno) unix.rmdir(d)'
nil	mkdir: EEXIST: File exists	17

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd=unix.open(d.."/f",unix.O_WRONLY|unix.O_CREAT) unix.close(fd) local ok,e,eno=unix.makedirs(d.."/f/child") print(ok,e,eno) unix.unlink(d.."/f") unix.rmdir(d)'
nil	makedirs: ENOTDIR: Not a directory	20

$ o//tool/lua/lua -e 'local unix=require"unix" local p,e,eno=unix.mkdtemp("/tmp/fsns-nosuchdir-xyz/XXXXXX") print(p,e,eno)'
nil	mkdtemp: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd,path=unix.mkstemp(d.."/t_XXXXXX") print("success:",fd,path) unix.close(fd) unix.unlink(path) local fd2,e,eno=unix.mkstemp("/tmp/fsns-nosuchdir-xyz/t_XXXXXX") print("failure:",fd2,e,eno) unix.rmdir(d)'
success:	3	/tmp/fsns6wm9g0/t_z1w70h
failure:	nil	mkstemp: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.chdir("/tmp/fsns-nosuchdir-xyz") print(ok,e,eno)'
nil	chdir: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.unlink("/tmp/fsns-nosuchdir-xyz/f") print(ok,e,eno)'
nil	unlink: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd=unix.open(d.."/f",unix.O_WRONLY|unix.O_CREAT) unix.close(fd) local ok,e,eno=unix.rmdir(d.."/f") print(ok,e,eno) unix.unlink(d.."/f") unix.rmdir(d)'
nil	rmdir: ENOTDIR: Not a directory	20

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.rename("/tmp/fsns-nosuchdir-xyz/a","/tmp/fsns-nosuchdir-xyz/b") print(ok,e,eno)'
nil	rename: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.link("/tmp/fsns-nosuchdir-xyz/a","/tmp/fsns-nosuchdir-xyz/b") print(ok,e,eno)'
nil	link: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd=unix.open(d.."/f",unix.O_WRONLY|unix.O_CREAT) unix.close(fd) local ok,e,eno=unix.symlink(d.."/f",d.."/f") print(ok,e,eno) unix.unlink(d.."/f") unix.rmdir(d)'
nil	symlink: EEXIST: File exists	17

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd=unix.open(d.."/f",unix.O_WRONLY|unix.O_CREAT) unix.close(fd) local p,e,eno=unix.readlink(d.."/f") print(p,e,eno) unix.unlink(d.."/f") unix.rmdir(d)'
nil	readlink: EINVAL: Invalid argument	22

$ o//tool/lua/lua -e 'local unix=require"unix" local p,e,eno=unix.realpath("/tmp/fsns-nosuchdir-xyz/f") print(p,e,eno)'
nil	realpath: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") unix.chdir(d) unix.rmdir(d) local p,e,eno=unix.getcwd() print(p,e,eno)'
nil	getcwd: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.rmrf("/tmp/fsns-nosuchdir-xyz") print(ok,e,eno)'
nil	rmrf: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.truncate("/tmp/fsns-nosuchdir-xyz/f",0) print(ok,e,eno)'
nil	truncate: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd=unix.open(d.."/f",unix.O_WRONLY|unix.O_CREAT) unix.close(fd) local ok,e,eno=unix.ftruncate(fd,0) print(ok,e,eno) unix.unlink(d.."/f") unix.rmdir(d)'
nil	ftruncate: EBADF: Bad file descriptor	9

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.chown("/tmp/fsns-nosuchdir-xyz/f",0,0) print(ok,e,eno)'
nil	chown: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.chmod("/tmp/fsns-nosuchdir-xyz/f",0644) print(ok,e,eno)'
nil	chmod: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local ok,e,eno=unix.utimensat("/tmp/fsns-nosuchdir-xyz/f") print(ok,e,eno)'
nil	utimensat: ENOENT: No such file or directory	2

$ o//tool/lua/lua -e 'local unix=require"unix" local d=unix.mkdtemp("/tmp/fsnsXXXXXX") local fd=unix.open(d.."/f",unix.O_WRONLY|unix.O_CREAT) unix.close(fd) local ok,e,eno=unix.futimens(fd) print(ok,e,eno) unix.unlink(d.."/f") unix.rmdir(d)'
nil	futimens: EBADF: Bad file descriptor	9
```

### Out-of-scope finding (filed separately, not part of this slice's capture count)

`unix.readlink`'s second parameter is documented as a directory fd but
is actually a buffer size — a doc/implementation parameter-meaning
mismatch, not a nil-tuple shape question, so it sits outside this
slice's scope. Filed as its own capture, `3Ik1c2WOTJDdwydaOx8PqCYYKXS`.
