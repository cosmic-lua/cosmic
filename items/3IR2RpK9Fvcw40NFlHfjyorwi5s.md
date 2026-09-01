## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
`cosmo.unix`'s socket, interface and network-I/O surface. A research slice: its deliverable is recorded evidence and the
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

**This slice's scope: the 21 nil-admitting bindings below.**

```text
unix.socket unix.socketpair unix.bind unix.siocgifconf 
unix.siocgifflags unix.siocsifflags unix.getsockopt unix.setsockopt 
unix.poll unix.gethostname unix.sethostname unix.listen unix.accept 
unix.connect unix.getsockname unix.getpeername unix.recv 
unix.recvfrom unix.send unix.sendto unix.shutdown
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

## Result

Re-run 2026-09-01 against `cosmic-lua/cosmopolitan` `d8afc0abe685969fea3961ce2fadcb96ecca69ed`
(a descendant of the `1e165815` measurement commit — `git merge-base
--is-ancestor 1e165815 HEAD` confirms it). Built with `make -j4
o//tool/lua/lua` (clean, ~11 minutes cold).

Re-running the exact `census.awk` command from `## Evidence` at this
commit:

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    216 EXACT
    186 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
440
```

216 + 186 + 38 = 440 — still exhaustive. Numbers moved (the tree grew
one declaration and several sibling census/contract slices landed
between the two commits — `getopt.parse` is now EXACT, `unix` dropped
127→122 NIL, several `unix.*` successes were bundled into tables by
PRs #304–#331). By module: `unix` 122, `lsqlite3` 22, `cosmo` 22, `zip`
14, `re` 5, `argon2` 1, `getopt` 0, `path`/`cov`/`repl` 0 EXACT-only
(sum 186, matches).

**This slice's scope re-derives unchanged**: all 21 bindings named in
`## Evidence` are still `NIL` at this commit (verified individually
against the fresh `census.awk` output). None has moved class since
`1e165815`, so every row below is a fresh measurement, not a bounce.
Scope count: 21. Summary table row count: 21. They match.

**Outcome: all 21 bindings classify as class 2 (environmental or
data-dependent). Zero class-1 (degenerate-input-only) and zero class-3
(exact already) rows. Zero tuple deviations found, so zero captures
are filed by this slice** — every row's `T|nil, err string, errno?`
first-`@return` line matches what the C source actually returns on
both the success and failure path (the one non-conforming behavior
found, `unix.getsockopt`'s `SO_LINGER` overload, is a success-arity bug
unrelated to nil-admission; see "Out-of-scope finding" below, filed as
a defect note rather than a class-2 capture since it is not a
failure-tuple slot-sharing deviation of the `nanosleep` kind).

Two supporting facts held across every row and are not repeated 21
times below:

- Every one of these 21 bindings already **raises** (via
  `luaL_checkinteger`/`luaL_checklstring`, standard Lua argument-type
  checking) when called with a wrong-*typed* argument (e.g.
  `unix.send(nil, ...)` — see `cosmic/net/init_test.tl:279`, which
  documents relying on exactly this). That raise path is separate from,
  and already prior to, the `nil, err, errno` tuple this census is
  about — it is why none of the 21 has a class-1 "argument-shape"
  reading: the shapes that would be degenerate misuse already raise
  before reaching the nil-admitting return.
- Where a binding has both a length/shape guard (`siocgifflags`,
  `siocsifflags`: `len >= IFNAMSIZ`) **and** a real OS-level failure
  path reachable by a correct caller (unknown interface name →
  `ENODEV`), the OS-level path is what makes it class 2: nil is not
  reachable *only* via the degenerate shape.

### Summary table

| # | Binding | Class | Probe command | Capture |
|---|---|---|---|---|
| 1 | `unix.socket` | 2 — environmental (EMFILE) | `o//tool/lua/lua -e 'local unix=require("unix"); assert(unix.setrlimit(unix.RLIMIT_NOFILE,3,3)); local fd,err,errno=unix.socket(); print(fd,err,errno)'` | n/a — tuple conforms |
| 2 | `unix.socketpair` | 2 — environmental (EMFILE) | `o//tool/lua/lua -e 'local unix=require("unix"); assert(unix.setrlimit(unix.RLIMIT_NOFILE,3,3)); local a,b,err,errno=unix.socketpair(); print(a,b,err,errno)'` | n/a — tuple conforms |
| 3 | `unix.bind` | 2 — environmental (EADDRINUSE) | `o//tool/lua/lua -e 'local unix=require("unix"); local s1=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); assert(unix.bind(s1,0x7f000001,0)); local ip,port=assert(unix.getsockname(s1)); local s2=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); local ok,err,errno=unix.bind(s2,ip,port); print(ok,err,errno)'` | n/a — tuple conforms |
| 4 | `unix.siocgifconf` | 2 — environmental (EMFILE, internal `socket()`) | `o//tool/lua/lua -e 'local unix=require("unix"); assert(unix.setrlimit(unix.RLIMIT_NOFILE,3,3)); local t,err,errno=unix.siocgifconf(); print(t,err,errno)'` | n/a — tuple conforms |
| 5 | `unix.siocgifflags` | 2 — environmental (ENODEV, unknown interface) | `o//tool/lua/lua -e 'local unix=require("unix"); local f,err,errno=unix.siocgifflags("zzz_bogus_if"); print(f,err,errno)'` | n/a — tuple conforms |
| 6 | `unix.siocsifflags` | 2 — environmental (ENODEV, unknown interface) | `o//tool/lua/lua -e 'local unix=require("unix"); local ok,err,errno=unix.siocsifflags("zzz_bogus_if",0); print(ok,err,errno)'` | n/a — tuple conforms |
| 7 | `unix.getsockopt` | 2 — environmental (EBADF, closed fd) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); unix.close(fd); local v,err,errno=unix.getsockopt(fd,unix.SOL_SOCKET,unix.SO_TYPE); print(v,err,errno)'` | n/a — tuple conforms (see out-of-scope finding on its `SO_LINGER` overload) |
| 8 | `unix.setsockopt` | 2 — environmental (EBADF, closed fd) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); unix.close(fd); local ok,err,errno=unix.setsockopt(fd,unix.SOL_SOCKET,unix.SO_REUSEADDR,true); print(ok,err,errno)'` | n/a — tuple conforms |
| 9 | `unix.poll` | 2 — environmental (EINTR, signal during wait) | `o//tool/lua/lua -e 'local unix=require("unix"); local p=assert(unix.pipe()); unix.sigaction(unix.SIGALRM,function() end); unix.setitimer(unix.ITIMER_REAL,0,0,0,300*1000*1000); local res,err,errno=unix.poll({[p.reader]=unix.POLLIN},5000); print(res,err,errno)'` | n/a — tuple conforms |
| 10 | `unix.gethostname` | 2 — environmental (buffer-fit safety check; takes zero arguments, so nil cannot be argument-shape by construction) | `o//tool/lua/lua -e 'local unix=require("unix"); print(unix.gethostname())'` (baseline; see note below on why the nil path itself has no live repro here) | n/a — tuple conforms |
| 11 | `unix.sethostname` | 2 — environmental (EPERM, unprivileged caller) | `o//tool/lua/lua -e 'local unix=require("unix"); assert(unix.setuid(65534)); local ok,err,errno=unix.sethostname("nope"); print(ok,err,errno)'` | n/a — tuple conforms |
| 12 | `unix.listen` | 2 — environmental (ENOTSOCK, valid fd of wrong kind) | `o//tool/lua/lua -e 'local unix=require("unix"); local p=assert(unix.pipe()); local ok,err,errno=unix.listen(p.reader,5); print(ok,err,errno)'` | n/a — tuple conforms |
| 13 | `unix.accept` | 2 — environmental (EAGAIN, non-blocking with nothing pending) | `o//tool/lua/lua -e 'local unix=require("unix"); local s=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM|unix.SOCK_NONBLOCK)); assert(unix.bind(s,0x7f000001,0)); assert(unix.listen(s)); local fd,ip,port,err,errno=unix.accept(s); print(fd,ip,port,err,errno)'` | n/a — tuple conforms |
| 14 | `unix.connect` | 2 — environmental (ECONNREFUSED, nothing listening) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); local ok,err,errno=unix.connect(fd,0x7f000001,1); print(ok,err,errno)'` | n/a — tuple conforms |
| 15 | `unix.getsockname` | 2 — environmental (EBADF, closed fd) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); unix.close(fd); local ip,port,err,errno=unix.getsockname(fd); print(ip,port,err,errno)'` | n/a — tuple conforms |
| 16 | `unix.getpeername` | 2 — environmental (ENOTCONN, never connected) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); local ip,port,err,errno=unix.getpeername(fd); print(ip,port,err,errno)'` | n/a — tuple conforms |
| 17 | `unix.recv` | 2 — environmental (ENOTCONN, unconnected stream socket) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); local data,err,errno=unix.recv(fd,100); print(data,err,errno)'` | n/a — tuple conforms |
| 18 | `unix.recvfrom` | 2 — environmental (EBADF, closed fd) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_DGRAM)); unix.close(fd); local data,ip,port,err,errno=unix.recvfrom(fd,100); print(data,ip,port,err,errno)'` | n/a — tuple conforms |
| 19 | `unix.send` | 2 — environmental (EPIPE, peer closed) | `o//tool/lua/lua -e 'local unix=require("unix"); local a,b=assert(unix.socketpair(unix.AF_UNIX,unix.SOCK_STREAM)); unix.close(b); unix.sigaction(unix.SIGPIPE,unix.SIG_IGN); local sent,err,errno=unix.send(a,"hi"); print(sent,err,errno)'` | n/a — tuple conforms |
| 20 | `unix.sendto` | 2 — environmental (EBADF, closed fd) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_DGRAM)); unix.close(fd); local sent,err,errno=unix.sendto(fd,"hi",0x7f000001,9); print(sent,err,errno)'` | n/a — tuple conforms |
| 21 | `unix.shutdown` | 2 — environmental (ENOTCONN, unconnected socket) | `o//tool/lua/lua -e 'local unix=require("unix"); local fd=assert(unix.socket(unix.AF_INET,unix.SOCK_STREAM)); local ok,err,errno=unix.shutdown(fd,unix.SHUT_RDWR); print(ok,err,errno)'` | n/a — tuple conforms |

Scope count: 21. Table row count: 21. Match.

### Per-row evidence detail

Each row: C source (`third_party/lua/cosmo/lunix.c`), the
`tool/net/definitions.lua` first-`@return` line census.awk classifies
on, the probe's actual output at `d8afc0abe685969fea3961ce2fadcb96ecca69ed`,
and the cosmic-side spend (`grep -rn '<binding>' cosmic/` in a
`cosmic-lua/cosmic` checkout).

1. **`unix.socket`** — `third_party/lua/cosmo/lunix.c:2171` (`LuaUnixSocket`).
   `tool/net/definitions.lua:6070` (`---@return integer|nil fd`).
   Probe output: `nil	socket: EMFILE: Too many open files	24`.
   cosmic spend: `cosmic/quicksand/proxy/dial.tl:75`,
   `cosmic/quicksand/proxy/serve.tl:342`, `cosmic/net/init.tl:41` — all
   three propagate `fd, err` onward rather than asserting.

2. **`unix.socketpair`** — `third_party/lua/cosmo/lunix.c:2182`.
   `tool/net/definitions.lua:6091` (`---@return integer|nil fd1, integer fd2`).
   Probe output (`print(a,b,err,errno)`): `nil	socketpair: EMFILE: Too many open files	24	nil`.
   cosmic spend: `cosmic/net/init.tl:66` — result assigned but not
   checked at that call site (`local fd1, fd2 = unix.socketpair(...)`,
   no error branch inline).

3. **`unix.bind`** — `third_party/lua/cosmo/lunix.c:2199`.
   `tool/net/definitions.lua:6125` (`---@return true|nil`).
   Probe output: `nil	bind: EADDRINUSE: Address already in use	98`.
   cosmic spend: `cosmic/quicksand/proxy/serve.tl:347`,
   `cosmic/net/socket.tl:324`, `cosmic/net/socket.tl:334` (the last via
   an `as function(...)` cast for the unixpath overload) — all check
   `ok, err`.

4. **`unix.siocgifconf`** — `third_party/lua/cosmo/lunix.c:2265`.
   `tool/net/definitions.lua:6140` (`---@return unix.IfAddr[]|nil addresses`).
   Probe output: `nil	siocgifconf: EMFILE: Too many open files	24`.
   cosmic spend: `cosmic/net/init.tl:308` — checked (`local raw, err = ...`).

5. **`unix.siocgifflags`** — `third_party/lua/cosmo/lunix.c:2337`
   (dispatches through the shared `LuaUnixIfreqFlagsIoctl` at
   `third_party/lua/cosmo/lunix.c:2312`).
   `tool/net/definitions.lua:6150` (`---@return integer|nil flags IFF_* bitmask`).
   Probe output: `nil	siocgifflags: ENODEV: No such device	19`.
   cosmic spend: `cosmic/quicksand/netns.tl:32` (checked) and a comment
   reference at `cosmic/quicksand/netns_test.tl:80`.

6. **`unix.siocsifflags`** — `third_party/lua/cosmo/lunix.c:2350`
   (same shared ioctl helper).
   `tool/net/definitions.lua:6162` (`---@return true|nil`).
   Probe output: `nil	siocsifflags: ENODEV: No such device	19`.
   cosmic spend: `cosmic/quicksand/netns.tl:45` — checked.

7. **`unix.getsockopt`** — `third_party/lua/cosmo/lunix.c:2104`.
   `tool/net/definitions.lua:6273` (`---@return integer|nil value`).
   Probe output: `nil	getsockopt: EBADF: Bad file descriptor	9`.
   cosmic spend: `cosmic/net/socket.tl:406` — checked. (See the
   out-of-scope finding below: this same function's `SO_LINGER`
   overload has an unrelated success-path arity bug, not exercised by
   this cosmic call site.)

8. **`unix.setsockopt`** — `third_party/lua/cosmo/lunix.c:2053`.
   `tool/net/definitions.lua:6388` (`---@return true|nil`).
   Probe output: `nil	setsockopt: EBADF: Bad file descriptor	9`.
   cosmic spend: `cosmic/quicksand/proxy/serve.tl:346` (result
   discarded), `cosmic/net/socket.tl:152` (result discarded),
   `cosmic/net/socket.tl:437,451` (checked via an `as function(...)` cast).

9. **`unix.poll`** — `third_party/lua/cosmo/lunix.c:2432`.
   `tool/net/definitions.lua:6422` (`` ---@return table<integer,integer>|nil `{[fd:int]=revents:int, ...}` ``).
   Probe output: `nil	poll: EINTR: Interrupted	4`.
   cosmic spend: `cosmic/errno.tl:59` (doc example), `cosmic/poll.tl:146`,
   `cosmic/net/connect.tl:26,28` (retries on the errno), and
   `cosmic/quicksand/proxy/http.tl:254,272` (explicit EINTR-tolerant
   retry loop, doc-referenced at `cosmic/quicksand/proxy/http_test.tl:159`).

10. **`unix.gethostname`** — `third_party/lua/cosmo/lunix.c:2383`.
    `tool/net/definitions.lua:6429` (`---@return string|nil host`).
    Probe output (baseline call, this commit): `nope-8793` (a name set
    by an earlier probe in this same run — see note). The function
    takes **zero** arguments, so by construction its `nil` path cannot
    be argument-shape; the sole `nil` branch in the C source is an
    internal safety check (`strnlen(buf, sizeof(buf)) < sizeof(buf)`,
    `enomem()` if the configured hostname doesn't leave room for a NUL
    within the `DNS_NAME_MAX + 1` = 254-byte buffer). This sandbox's
    kernel enforces `HOST_NAME_MAX` = 64 (`getconf HOST_NAME_MAX` →
    `64`), so `unix.sethostname` itself refuses (`EINVAL`) any name
    long enough to approach 254 bytes — confirmed:
    `o//tool/lua/lua -e 'local unix=require("unix"); print(unix.sethostname(string.rep("a",200)))'`
    → `nil	sethostname: EINVAL: Invalid argument	22`. So this
    specific `nil` branch has no live repro on Linux in this sandbox;
    it is classified as class 2 by construction (no arguments to be
    degenerate) and by inspection of the C source, not by a forced
    failure.
    cosmic spend: `cosmic/net/init.tl:291` — checked.

11. **`unix.sethostname`** — `third_party/lua/cosmo/lunix.c:2401`.
    `tool/net/definitions.lua:6440` (`---@return true|nil`).
    Probe output (after `unix.setuid(65534)`): `nil	sethostname: EPERM: Operation not permitted	1`.
    cosmic spend: `cosmic/quicksand/box/run.tl:230` — checked.

12. **`unix.listen`** — `third_party/lua/cosmo/lunix.c:2226`.
    `tool/net/definitions.lua:6486` (`---@return true|nil`).
    Probe output: `nil	listen: ENOTSOCK: Not a socket	88`.
    cosmic spend: `cosmic/quicksand/proxy/serve.tl:352`,
    `cosmic/net/socket.tl:343` — both checked.

13. **`unix.accept`** — `third_party/lua/cosmo/lunix.c:2412`.
    `tool/net/definitions.lua:6500` (`---@return integer|nil clientfd, uint32 ip, uint16 port`).
    Probe output (`print(fd,ip,port,err,errno)`): `nil	accept: EAGAIN: Resource temporarily unavailable	11	nil	nil`
    — the 3-value failure tuple (`nil`, error string, errno) lands in
    the first three requested locals; the extra two are `nil` because
    the call itself returns only 3 values.
    cosmic spend: `cosmic/quicksand/proxy/serve.tl:367,390`,
    `cosmic/net/socket.tl:369,371` — all checked, `serve.tl:390`
    branches on the errno explicitly.

14. **`unix.connect`** — `third_party/lua/cosmo/lunix.c:2213`.
    `tool/net/definitions.lua:6515` (`---@return true|nil`).
    Probe output: `nil	connect: ECONNREFUSED: Connection refused error	111`.
    cosmic spend: `cosmic/quicksand/proxy/dial.tl:79`,
    `cosmic/net/socket.tl:387,397`, `cosmic/net/connect.tl:80,96` —
    checked throughout, including one `as function(...)` cast.

15. **`unix.getsockname`** — `third_party/lua/cosmo/lunix.c:2250`
    (via the shared `LuaUnixGetname` at `third_party/lua/cosmo/lunix.c:2232`).
    `tool/net/definitions.lua:6523` (`---@return uint32|nil ip, uint16 port`).
    Probe output (`print(ip,port,err,errno)`): `nil	getsockname: EBADF: Bad file descriptor	9	nil`.
    cosmic spend: `cosmic/quicksand/proxy/serve.tl:358` (result
    discarded past the first value), `cosmic/net/socket.tl:294`
    (discarded).

16. **`unix.getpeername`** — `third_party/lua/cosmo/lunix.c:2258`
    (same shared `LuaUnixGetname` helper).
    `tool/net/definitions.lua:6536` (`---@return uint32|nil ip, uint16 port`).
    Probe output (`print(ip,port,err,errno)`): `nil	getpeername: ENOTCONN: Transport endpoint is not connected	107	nil`.
    cosmic spend: `cosmic/net/socket.tl:305` (discarded).

17. **`unix.recv`** — `third_party/lua/cosmo/lunix.c:2522`.
    `tool/net/definitions.lua:6550` (`---@return string|nil data`).
    Probe output: `nil	recv: ENOTCONN: Transport endpoint is not connected	107`.
    cosmic spend: `cosmic/quicksand/proxy/http.tl:43,75,284` (the last
    discards the error/errno), `cosmic/net/socket.tl:237,239` — checked
    with an EINTR retry.

18. **`unix.recvfrom`** — `third_party/lua/cosmo/lunix.c:2491`.
    `tool/net/definitions.lua:6563` (`---@return string|nil data, integer ip, integer port`).
    Probe output (`print(data,ip,port,err,errno)`): `nil	recvfrom: EBADF: Bad file descriptor	9	nil	nil`.
    cosmic spend: `cosmic/net/socket.tl:280,282` — checked with an
    EINTR retry.

19. **`unix.send`** — `third_party/lua/cosmo/lunix.c:2560`.
    `tool/net/definitions.lua:6580` (`---@return integer|nil sent`).
    Probe output: `nil	send: EPIPE: Broken pipe	32`.
    cosmic spend: `cosmic/quicksand/proxy/http.tl:61` (checked),
    `cosmic/net/socket.tl:190,192` (checked with an EINTR retry); a
    comment at `cosmic/net/init_test.tl:279` documents that
    `unix.send(nil, ...)` raises rather than returning nil — the
    argument-type-check raise noted above.

20. **`unix.sendto`** — `third_party/lua/cosmo/lunix.c:2579`.
    `tool/net/definitions.lua:6596` (`---@return integer|nil sent`).
    Probe output: `nil	sendto: EBADF: Bad file descriptor	9`.
    cosmic spend: `cosmic/net/socket.tl:218,220` — checked with an
    EINTR retry.

21. **`unix.shutdown`** — `third_party/lua/cosmo/lunix.c:2597`.
    `tool/net/definitions.lua:6614` (`---@return true|nil`).
    Probe output: `nil	shutdown: ENOTCONN: Transport endpoint is not connected	107`.
    cosmic spend: `cosmic/quicksand/proxy/http.tl:267` (wrapped in
    `pcall`, result otherwise discarded), `cosmic/net/socket.tl:177`
    (checked).

### Out-of-scope finding

`third_party/lua/cosmo/lunix.c:2139-2148` — inside `LuaUnixGetsockopt`
(`unix.getsockopt`), the `SOL_SOCKET`/`SO_LINGER` branch pushes two
values (`l.l_linger`, `l.l_onoff`) but then executes `return 1;`
(line 2148), so only the top-of-stack value (`l_onoff`, the `enabled`
boolean) is actually returned to Lua — `seconds` is silently dropped,
contradicting both the inline comment two lines above
(`// ├─→ seconds:int, enabled:bool`) and the
`tool/net/definitions.lua:6277` `@overload` annotation
(`seconds: integer, enabled: boolean`). Reproduced at
`d8afc0abe685969fea3961ce2fadcb96ecca69ed`:

```
$ o//tool/lua/lua -e '
local unix = require("unix")
local fd = assert(unix.socket(unix.AF_INET, unix.SOCK_STREAM))
assert(unix.setsockopt(fd, unix.SOL_SOCKET, unix.SO_LINGER, 5, true))
local a, b, c = unix.getsockopt(fd, unix.SOL_SOCKET, unix.SO_LINGER)
print("a=", a, "b=", b, "c=", c)
'
a=	true	b=	nil	c=	nil
```
(`a` here is the dropped-arity `enabled` boolean, not `seconds` — the
value ordering doc-declares first.) This is a success-path arity bug,
unrelated to nil-admission (the failure tuple this census governs is
unaffected), so it is out of this slice's scope; not fixed, filed
separately as `3IkCZjvsgMDfhZH1TB0Slra1T3x` under this item's parent, since it
is not a `nanosleep`-family capture.
