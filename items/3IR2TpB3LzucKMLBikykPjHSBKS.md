## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
the whole `cosmo.zip` surface — readers, writers and appenders. A research slice: its deliverable is recorded evidence and the
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

**This slice's scope: the 14 nil-admitting bindings below.**

```text
zip.open zip.from zip.create zip.append zip.validate_name 
zip.Reader:stat zip.Reader:read zip.Reader:save zip.Writer:add 
zip.Writer:close zip.Appender:add zip.Appender:add_file 
zip.Appender:remove zip.Appender:close
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
  (`o/tool/lua/lua -e '...'`) demonstrating the reachability class
- the cosmic-side spend: `grep -rn '<binding>' cosmic/` in a cosmic
  checkout (one exists at `/home/user/cosmic`), listing the wrapper
  sites that guard or assert it today

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
  cosmopolitan repo root against `o/tool/lua/lua`, built by
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

Re-measured 2026-09-01 against `cosmic-lua/cosmopolitan` master
`6713a349`, which is 32 commits past `1e165815` on the same line
(`git merge-base --is-ancestor 1e165815 HEAD` confirms it), so #276 and
#277 are still settled ancestors. Re-running the census:

```text
$ awk -f census.awk tool/net/definitions.lua | cut -f1 | sort | uniq -c
    211 EXACT
    191 NIL
     38 NONE
$ grep -c '^function ' tool/net/definitions.lua
440
```

211 + 191 + 38 = 440. Totals moved by one function (a binding landed
since `1e165815`) and by a couple of EXACT/NIL reclassifications
upstream of `zip`, but the `zip` row is unchanged:

```text
$ awk -F'\t' '$1=="NIL"{print $2}' <(awk -f census.awk tool/net/definitions.lua) | sed 's/[:.].*//' | sort | uniq -c
      1 argon2
     22 cosmo
      1 getopt
     22 lsqlite3
      5 re
    126 unix
     14 zip
```

`zip` still carries exactly 14 NIL rows, and re-listing them
(`awk -F'\t' '$1=="NIL" && $2 ~ /^zip\./' …`) reproduces this item's
scope list byte-for-byte:

```text
zip.Appender:add
zip.Appender:add_file
zip.Appender:close
zip.Appender:remove
zip.Reader:read
zip.Reader:save
zip.Reader:stat
zip.Writer:add
zip.Writer:close
zip.append
zip.create
zip.from
zip.open
zip.validate_name
```

**14 scope bindings, 14 summary rows below — no additions, no drops, no
moves.**

Built once for this slice's probes: `make -j$(nproc) o//tool/lua/lua`
(clean build, ~4 minutes on 4 cores), giving `o/tool/lua/lua` (Lua
5.5). Every probe below is a self-contained one-liner, runnable
verbatim from the cosmopolitan repo root against that binary.

### Classification

All 14 are **class 2 (environmental or data-dependent)**. Every one of
them has at least one nil-reachable path that a correct, well-formed
caller can hit at runtime — a missing/unreadable file, a corrupted or
foreign zip archive, an absent archive entry, a disk-write failure, or
(for `Writer:close`) a double-close under ordinary cleanup patterns
(`assert(...)`, then a deferred close in an error path). Per the
Change's class-1 test ("nil reachable **only** for an argument shape no
correct caller passes"), none of the 14 qualifies for class 1: each has
a real environmental/data-dependent nil path standing beside whatever
argument-shape validation it also does, so the union rule keeps the
whole binding in class 2.

**Tuple shape**: every one of the 14 fails via `SysError`, `ZipError`,
or `WriterSysError` (`tool/net/lzip.c:119-139`), each of which pushes
exactly `(nil, string)` — two values, no third slot, ever. No binding
in this slice returns an errno integer or shares slot 2 with a
non-error remainder (the `unix.nanosleep` pattern). **Zero tuple
deviations found** — the union's shape is exactly `T|nil, string`
(`errno?` unused but that is compliant: it is optional).

**Consequence for filing**: zero class-1 raise-candidates, zero
class-2 tuple-deviation captures. Nothing from this slice attaches
under the parent container.

### Summary table

| # | Binding | Class | C cite | definitions.lua | Probe (run from repo root) | Cosmic-side spend |
|---|---|---|---|---|---|---|
| 1 | `zip.open` | 2 — env/data | `tool/net/lzip.c:2153` (`LuaZipOpen`, dispatches to `LuaZipCreate:1086`/`LuaZipAppend:1421`/`LuaZipOpenReader:246`) | `tool/net/definitions.lua:1866` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local r,err=zip.open("/nonexistent/path/x.zip","r"); print(r,err)'` → `nil  /nonexistent/path/x.zip: No such file or directory` | `cosmic/zip.tl:208-240` (`open()`): calls `zip.open` at lines 215/217, `if not handle then return nil, err or "failed to open zip archive" end` |
| 2 | `zip.from` | 2 — env/data | `tool/net/lzip.c:365` (`LuaZipFrom`) | `tool/net/definitions.lua:1875` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local r,err=zip.from("not a zip file at all, too short"); print(r,err)'` → `nil  not a zip file` | `cosmic/zip.tl:249-265` (`open_string()`): calls `zip.from` at lines 257/259, same `if not handle` guard |
| 3 | `zip.create` | 2 — env/data | `tool/net/lzip.c:1086` (`LuaZipCreate`) | `tool/net/definitions.lua:1884` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local w,err=zip.create("/nonexistent_dir_xyz/out.zip"); print(w,err)'` → `nil  /nonexistent_dir_xyz/out.zip: No such file or directory` | `cosmic/zip.tl:225` (inside `open()`, `mode=="write"` branch): same `if not handle` guard |
| 4 | `zip.append` | 2 — env/data | `tool/net/lzip.c:1421` (`LuaZipAppend`) | `tool/net/definitions.lua:1895` | `printf 'garbage not a zip 1234567890123456789012345' > /tmp/corrupt.zip && o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local a,err=zip.append("/tmp/corrupt.zip"); print(a,err)'` → `nil  not a zip file` | `cosmic/zip.tl:235` (inside `open()`, append branch): same `if not handle` guard |
| 5 | `zip.validate_name` | 2 — env/data | `tool/net/lzip.c:2177` (`LuaZipValidateName`, via `ValidateEntryName`) | `tool/net/definitions.lua:1904` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local ok,err=zip.validate_name("../../etc/passwd"); print(ok,err)'` → `nil  unsafe path (contains '..' or starts with '/')` | **none** — `grep -rn validate_name cosmic/` has zero hits. Cosmic does not call this binding at all: `cosmic/zip.tl:269` and `cosmic/fs/path.tl:435` reimplement the same check independently as `fs.is_unsafe_entry_name`, which `zip.tl`'s own comment calls "THE guard ... for zip, tar and embed" |
| 6 | `zip.Reader:stat` | 2 — env/data | `tool/net/lzip.c:502` (`LuaZipReaderStat`) | `tool/net/definitions.lua:1950` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local w=assert(zip.create("/tmp/sample.zip")); assert(w:add("hello.txt","hi")); assert(w:close()); local r=assert(zip.open("/tmp/sample.zip","r")); local st,err=r:stat("missing.txt"); print(st,err)'` → `nil  entry not found: missing.txt` | `cosmic/zip.tl:119-123` (`a:stat`): `if not raw.reader then return nil, mode_err(...) end; return raw.reader:stat(name)` — nil passes through unchanged |
| 7 | `zip.Reader:read` | 2 — env/data | `tool/net/lzip.c:672` (`LuaZipReaderRead`, via `ReaderSlurpEntry:549`) | `tool/net/definitions.lua:1958` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local r=assert(zip.open("/tmp/sample.zip","r")); local c,err=r:read("missing.txt"); print(c,err)'` → `nil  entry not found: missing.txt` | `cosmic/zip.tl:125-129` (`a:read`): same pass-through pattern as `stat` |
| 8 | `zip.Reader:save` | 2 — env/data | `tool/net/lzip.c:703` (`LuaZipReaderSave`, via `ReaderSlurpEntry:549`) | `tool/net/definitions.lua:1970` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local r=assert(zip.open("/tmp/sample.zip","r")); local ok,err=r:save("hello.txt","/nonexistent_dir_xyz/out.bin"); print(ok,err)'` → `nil  open dest: No such file or directory` | `cosmic/zip.tl:131-137` (`a:save`): `local ok, err = raw.reader:save(...); if not ok then return false, err or "save failed" end` — the ONLY reader op cosmic folds nil into `false` rather than passing through (matches its declared `boolean, string`, not `T|nil`) |
| 9 | `zip.Writer:add` | 2 — env/data | `tool/net/lzip.c:1181` (`LuaZipWriterAdd`) | `tool/net/definitions.lua:1987` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local w=assert(zip.create("/tmp/w.zip")); assert(w:add("a.txt","one")); local ok,err=w:add("a.txt","two"); print(ok,err)'` → `nil  duplicate entry name` | `cosmic/zip.tl:139-152` (`a:add`, writer branch line 142): `local ok, err = raw.writer:add(...); if not ok then return false, err or "add failed" end` |
| 10 | `zip.Writer:close` | 2 — env/data | `tool/net/lzip.c:1301` (`LuaZipWriterClose`) | `tool/net/definitions.lua:1995` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local w=assert(zip.create("/tmp/w2.zip")); assert(w:close()); local ok,err=w:close(); print(ok,err)'` → `nil  zip writer is already closed`. A genuinely environmental variant also confirmed by code inspection: any `write()`/`WriteCdirEntry`/`WriteZipEocd` failure during flush returns `WriterSysError(L, w, ...)` → e.g. `write cdir entry: Bad file descriptor` when the fd is closed out from under the writer | `cosmic/zip.tl:170-183` (`a:close`, writer branch line 175): `if not ok then return false, "zip: close failed: " .. (err or "unknown error") end` — cosmic's own `close()` is idempotent (`if closed then return true end`, line 171) BEFORE ever calling the raw close, so cosmic callers never observe the raw "already closed" nil — only the raw disk-write-failure path is user-visible through the wrapper |
| 11 | `zip.Appender:add` | 2 — env/data | `tool/net/lzip.c:1804` (`LuaZipAppenderAdd`, via `AppenderAddBytes:1701`) | `tool/net/definitions.lua:2010` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local a=assert(zip.append("/tmp/app.zip")); assert(a:add("a.txt","one")); local ok,err=a:add("a.txt","two"); print(ok,err)'` → `nil  duplicate entry name` | `cosmic/zip.tl:139-152` (`a:add`, appender branch line 147): same `if not ok then return false, err or "add failed" end` |
| 12 | `zip.Appender:add_file` | 2 — env/data | `tool/net/lzip.c:1829` (`LuaZipAppenderAddFile`, via `AppenderAddBytes:1701`) | `tool/net/definitions.lua:2024` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local a=assert(zip.append("/tmp/app2.zip")); local ok,err=a:add_file("a.txt","/nonexistent_source_xyz.txt"); print(ok,err)'` → `nil  open source: No such file or directory` | `cosmic/zip.tl:154-160` (`a:add_file`): `local ok, err = raw.appender:add_file(...); if not ok then return false, err or "add_file failed" end` |
| 13 | `zip.Appender:remove` | 2 — env/data | `tool/net/lzip.c:1919` (`LuaZipAppenderRemove`) | `tool/net/definitions.lua:2038` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local a=assert(zip.append("/tmp/app3.zip")); assert(a:add("a.txt","one")); local ok,err=a:remove("missing.txt"); print(ok,err)'` → `nil  entry not found` | `cosmic/zip.tl:162-168` (`a:remove`): `local ok, err = raw.appender:remove(name); if not ok then return false, err or "remove failed" end` |
| 14 | `zip.Appender:close` | 2 — env/data | `tool/net/lzip.c:1964` (`LuaZipAppenderClose`) | `tool/net/definitions.lua:2046` | `o/tool/lua/lua -e 'local zip=require("cosmo.zip"); local unix=require("cosmo.unix"); assert(unix.sigaction(unix.SIGXFSZ, unix.SIG_IGN)); local a=assert(zip.append("/tmp/app4.zip")); assert(a:add("a.txt", string.rep("x",200))); assert(unix.setrlimit(unix.RLIMIT_FSIZE,64,64)); local ok,err=a:close(); print(ok,err)'` → `nil  write data: No such file or directory` (a genuine disk-write failure forced via `RLIMIT_FSIZE`, with `SIGXFSZ` ignored so `write(2)` returns `EFBIG` instead of killing the process). Note: closing twice is NOT nil-reachable here — `LuaZipAppenderClose` treats `a->fd == -1` as an idempotent no-op returning `true` (`tool/net/lzip.c:1967-1970`), unlike `Writer:close` | `cosmic/zip.tl:170-183` (`a:close`, appender branch line 179): same `if not ok then return false, "zip: close failed: ..." end`; cosmic's own idempotent guard at line 171 means, as with `Writer:close`, only the raw disk-write-failure path is reachable through the wrapper |

Row count: **14** (matches the 14-binding scope list above).

Class-1 rows: **0**. Class-2 tuple-deviation rows: **0**. No captures
filed under the parent container for this slice.

### Cosmic-side pattern, in short

`cosmic/zip.tl`'s single `Archive` wrapper (`make_archive`,
`cosmic/zip.tl:102-190`) treats every raw `nil` from all four
`zip.Reader`/`zip.Writer`/`zip.Appender` methods it calls as "falsy",
using `if not raw.X:method(...) then` throughout — it never depends on
`nil` specifically vs. `false`, and for the four constructors
(`zip.open`/`zip.from`/`zip.create`/`zip.append`) it checks `if not
handle then`. This means cosmic's own contract (`boolean, string` for
every effect method, `T|nil, string` for `list`/`stat`/`read`) is
already robust to any of these 14 bindings changing their failure
tuple's first slot between `nil` and `false`, as long as slot 2 stays
the error string alone — consistent with finding no tuple deviations
above.
