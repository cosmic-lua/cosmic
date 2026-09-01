## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s descriptor-level I/O and terminal control. A research slice: its deliverable is recorded evidence and the
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

**This slice's scope: the 17 nil-admitting bindings below.**

```text
unix.close unix.read unix.write unix.dup unix.pipe unix.fcntl 
unix.fsync unix.fdatasync unix.lseek unix.copy_file_range 
unix.isatty unix.tiocgwinsz unix.tcgetattr unix.tcsetattr 
unix.ioctl unix.openpty unix.login_tty
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

## Result — re-measured 2026-09-01 at `2faa31131f3b7e64cd4d895a777987d28d01255c`

Re-running the `census.awk` command from `## Evidence` at the commit
this slice was worked at (`2faa3113`, HEAD of
`/home/user/worktrees/95kn-research` at measurement time — a descendant
of `1e165815`) reproduces the exact same aggregate: 209 EXACT / 192 NIL
/ 38 NONE (439 total), and the same per-module NIL breakdown (`unix`
127, `lsqlite3` 22, `cosmo` 22, `zip` 14, `re` 5, `getopt` 1, `argon2`
1). Re-deriving the scope list by grepping the 17 named bindings out of
the NIL rows confirms all 17 are still classified NIL at this commit —
the scope list is unchanged from `1e165815`; no binding in it moved
class. Nothing in the `## Change` shape broke: every failure-branch
tuple across the slice is still exactly `(nil, error:string,
errno:integer)` at the C level (`LuaUnixSysretErrno`,
`third_party/lua/cosmo/lunix.c:219-238`, doc comment: "The fork's error
convention: nil, err:string, errno:integer").

**Scope count: 17. Summary row count: 17. They match.**

None of the 17 bindings are class 1 (degenerate-input-only). Every one
is a real OS descriptor/tty syscall whose documented failure modes
(EBADF from an fd invalidated by a race or a prior close, EINTR from
signal delivery during a blocking call, ENOSPC/EIO, EMFILE/ENFILE from
descriptor-table exhaustion, ENOTTY for a terminal ioctl on a non-tty
fd, ENOSYS for `copy_file_range` on a platform without the syscall) are
all failures a correct, well-formed caller can hit at runtone — there
is no "argument shape no correct caller passes" to raise on for a
value (a file descriptor, a request code) whose validity is inherently
a property of process state, not of the argument's shape. All 17 are
class 2. Four of the 17 have a class-2 tuple deviation from the
declared `T|nil, err string, errno?` shape and get their own capture,
each already independently rediscovered and defensively worked around
inside `cosmic/tty.tl` and `cosmic/fd.tl` (see each row's cosmic-side
spend) — closing them at the root removes tribal knowledge the wrapper
authors currently have to carry by hand.

### Summary table

| binding | class | probe (from repo root, after `make -j$(nproc) o//tool/lua/lua`) | capture id |
|---|---|---|---|
| `unix.close` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").close(999999))'` → `nil	close: EBADF: Bad file descriptor	9` | exact |
| `unix.read` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").read(999999))'` → `nil	read: EBADF: Bad file descriptor	9` | exact |
| `unix.write` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").write(999999, "x"))'` → `nil	write: EBADF: Bad file descriptor	9` | exact |
| `unix.dup` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").dup(999999))'` → `nil	dup: EBADF: Bad file descriptor	9` | exact |
| `unix.pipe` | 2, **deviation** | `(ulimit -n 20 && o//tool/lua/lua -e 'local u=require("unix");local fds={};for i=1,50 do local r,w,e,en=u.pipe();if not r then print(r,w,e,en);break end;fds[#fds+1]=r;fds[#fds+1]=w end')` → `nil	pipe: EMFILE: Too many open files	24	nil` (writer's slot holds the error string; the real errno lands one slot further right than declared) | ****3IiFbL6K**** |
| `unix.fcntl` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").fcntl(999999, require("unix").F_GETFD))'` → `nil	fcntl: EBADF: Bad file descriptor	9` (generic annotation is honestly `any|nil ...`, vararg, so the 5-value `F_GETLK` success case is not falsely claimed as fixed-shape) | exact |
| `unix.fsync` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").fsync(999999))'` → `nil	fsync: EBADF: Bad file descriptor	9` | exact |
| `unix.fdatasync` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").fdatasync(999999))'` → `nil	fdatasync: EBADF: Bad file descriptor	9` | exact |
| `unix.lseek` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").lseek(999999, 0))'` → `nil	lseek: EBADF: Bad file descriptor	9` | exact |
| `unix.copy_file_range` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").copy_file_range(999999, 999998, 10))'` → `nil	copy_file_range: EBADF: Bad file descriptor	9` | exact |
| `unix.isatty` | 2, **deviation** | `o//tool/lua/lua -e 'print(require("unix").isatty(999999))'` → `false	nil	nil` (docs promise `nil, "…EBADF…", errno` for a bad fd; the implementation's `rc == -1` check is dead code because libc `isatty()` never returns -1, so EBADF/EPERM silently collapse into `false`, a value not even in the declared `true|nil` union) | ****3IiFcAtW**** |
| `unix.tiocgwinsz` | 2, **deviation** | `o//tool/lua/lua -e 'print(require("unix").tiocgwinsz(999999))'` → `nil	tiocgwinsz: EBADF: Bad file descriptor	9` for the raw call; destructured as `local rows,cols,err,errno=…` on failure `cols` receives the error string and `err` receives the errno integer | ****3IiFbfUJ**** |
| `unix.tcgetattr` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").tcgetattr(999999))'` → `nil	tcgetattr: EBADF: Bad file descriptor	9` | exact |
| `unix.tcsetattr` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").tcsetattr(999999, require("unix").TCSANOW, {}))'` → `nil	tcsetattr: EBADF: Bad file descriptor	9` | exact |
| `unix.ioctl` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").ioctl(999999, 0x5413))'` → `nil	ioctl: EBADF: Bad file descriptor	9` (slot 1's `(true|nil\|string)` union is a single wide slot, not a shared one — no deviation) | exact |
| `unix.openpty` | 2, **deviation** | `(ulimit -n 15 && o//tool/lua/lua -e 'local u=require("unix");local fds={};for i=1,30 do local a,b,c,d,e=u.openpty();if not a then print(a,b,c,d,e);break end;fds[#fds+1]=a;fds[#fds+1]=b end')` → `nil	openpty: EMFILE: Too many open files	24	nil	nil` (`sfd` receives the error string, `name` receives the errno integer — two slots shift, the worst instance in this slice) | ****3IiFbuoO**** |
| `unix.login_tty` | 2, exact | `o//tool/lua/lua -e 'print(require("unix").login_tty(999999))'` → `nil	login_tty: EBADF: Bad file descriptor	9` | exact |

17 rows, 17 in scope — they match. No class-1 rows, no class-3 rows (none of the 17 moved to EXACT since `1e165815`).

### Out-of-scope finding (reported, not adopted into this slice)

`unix.capget` (`tool/net/definitions.lua`, `---@return integer|nil
effective, integer permitted, integer inheritable` immediately above
`function unix.capget(pid) end`) has the identical shared-slot pattern
as `unix.pipe`/`unix.tiocgwinsz`/`unix.openpty` — a 3-value success
tuple whose middle two positions collide with `(err, errno)` on
failure. `unix.capget` is not in this slice's 17-binding scope list and
belongs to whatever census slice covers the capability-bits family; it
is named here per this item's `## Non-goals` ("say so in this item's
summary rather than adopting it") and is not one of the four captures
below.
