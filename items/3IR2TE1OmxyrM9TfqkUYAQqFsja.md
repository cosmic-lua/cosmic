## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
the whole `cosmo.lsqlite3` surface. A research slice: its deliverable is recorded evidence and the
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
nothing is silently dropped.

**This slice's scope: the 22 nil-admitting bindings below.**

```text
lsqlite3.open lsqlite3.open_memory lsqlite3.config
lsqlite3.Database:db_filename lsqlite3.Database:prepare
lsqlite3.Database:readonly lsqlite3.Database:rows
lsqlite3.Database:serialize lsqlite3.Database:urows
lsqlite3.Database:wal_checkpoint
lsqlite3.Statement:bind_parameter_name lsqlite3.Statement:get_type
lsqlite3.Statement:get_uvalues lsqlite3.Statement:get_value
lsqlite3.Statement:rows lsqlite3.Statement:urows
lsqlite3.VM:bind_parameter_name lsqlite3.VM:get_type
lsqlite3.VM:get_uvalues lsqlite3.VM:get_value lsqlite3.VM:rows
lsqlite3.VM:urows
```

## Change

Classify every binding in this slice's scope into exactly one class,
with evidence:

1. **degenerate-input-only** — nil reachable only for an argument shape
   no correct caller passes (the `path.join(nil)` class, closed by
   #276). Each is a raise-candidate: file one capture per binding,
   unparented, then `attach` it under this item's parent container
   with `--repo cosmic-lua/cosmopolitan`.
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
"exact") back onto THIS item.

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

## Result (worked 2026-09-01, cosmic-lua/cosmopolitan `fd0884d9`)

Re-run of the census at `fd0884d9`: 211 EXACT / 191 NIL / 38 NONE = 440.
`lsqlite3` is unchanged at 22 NIL of 108 declarations, and the 22
bindings are byte-identical to the scope list above — 22 scope
entries, 22 summary rows below, match.

`lsqlite3.Statement` and `lsqlite3.VM` are documented aliases of the
same C userdata type and metatable (`tool/net/lsqlite3.c:122`, one
`vmlib` registry) — every `Statement:X`/`VM:X` pair shares one C
function and one reachability argument; each still gets its own row
per the Acceptance bar, citing the shared function.

### Summary table (22 rows = 22 scope entries)

| # | binding | class | disposition | capture |
|---|---|---|---|---|
| 1 | `lsqlite3.open` | 2, tuple-deviation (wrong slot order) | needs fix | CAP-A |
| 2 | `lsqlite3.open_memory` | 2, tuple-deviation (same fn as #1) | needs fix | CAP-A |
| 3 | `lsqlite3.config` | 2, tuple-deviation (numeric code, not string) | needs fix | CAP-B |
| 4 | `Database:db_filename` | 2, verified — no error channel claimed | clean | exact |
| 5 | `Database:prepare` | 2, tuple-deviation (numeric code, not string) | needs fix | CAP-C |
| 6 | `Database:readonly` | 2, verified correct `T\|nil,string` | clean | exact |
| 7 | `Database:rows` | 3 (outer never nil — inner per-row nil is iterator protocol) | clean | exact |
| 8 | `Database:serialize` | **defect: crash (free() vs sqlite3_free())** | urgent fix | CAP-D |
| 9 | `Database:urows` | 3 (outer never nil) | clean | exact |
| 10 | `Database:wal_checkpoint` | 2, tuple-deviation (numeric code, not string) | needs fix | CAP-E |
| 11 | `Statement:bind_parameter_name` | 2, verified — legitimate data (anonymous param) | clean | exact |
| 12 | `Statement:get_type` | 2, verified — legitimate data | clean | exact |
| 13 | `Statement:get_uvalues` | 2, verified — legitimate data | clean | exact |
| 14 | `Statement:get_value` | 2, verified — legitimate data (SQL NULL) | clean | exact |
| 15 | `Statement:rows` | 3 (outer never nil) | clean | exact |
| 16 | `Statement:urows` | 3 (outer never nil) | clean | exact |
| 17 | `VM:bind_parameter_name` | 2, verified (alias of #11) | clean | exact |
| 18 | `VM:get_type` | 2, verified (alias of #12) | clean | exact |
| 19 | `VM:get_uvalues` | 2, verified (alias of #13) | clean | exact |
| 20 | `VM:get_value` | 2, verified (alias of #14) | clean | exact |
| 21 | `VM:rows` | 3 (alias of #7) | clean | exact |
| 22 | `VM:urows` | 3 (alias of #9) | clean | exact |

6 rows needed a fix (5 distinct captures — #1/#2 share CAP-A since they
are the same C function); 16 rows verify clean.

### Note on class 3 for `rows`/`urows` (rows 7, 9, 15, 16, 21, 22)

The census's `|nil` match fires on these six because the declared type
is `fun(...): (string|number|nil)[]? iterator, ...` — the `|nil`/`?`
describes the returned iterator closure's PER-CALL value (a SQL NULL
column, or the standard Lua stateless-iterator "no more rows"
termination), never the outer `rows()`/`urows()` call itself. Traced
in `tool/net/lsqlite3.c`: `Database:rows`/`urows` (`db_rows`/`db_urows`
at 1728/1737, via `db_do_rows` at 1708) `lua_error()` on a bad-SQL
prepare (line 1717-1720) rather than returning nil; `Statement:rows`/
`VM:rows` (`dbvm_rows`/`dbvm_urows` at 1696/1704) only wrap an
already-open, already-checked VM and never fail at the outer call at
all. The outer binding is EXACT; the inner per-row nil is idiomatic
Lua `for`-loop protocol, not a failure contract, so no capture is
filed.

### Detail per row

**`lsqlite3.open`/`open_memory`** — `tool/net/lsqlite3.c:2407-2437`
(shared `lsqlite_do_open`); `definitions.lua:552-567`. Failure pushes
the numeric SQLite result code in slot 2 and the string message in
slot 3 — reversed from this repo's own "error always in slot 2"
convention. Probe: `s.open("/nonexistent_dir_zzz_9f3/x.db",
s.OPEN_READONLY)` → `nil  14  unable to open database file` (number
then string). Cosmic-side spend: `cosmic/sqlite/init.tl:410-430`
reassembles `nil, errmsg or ("error code " .. tostring(errcode))` by
hand to work around it; `open_memory` has zero cosmic call sites.

**`lsqlite3.config`** — `tool/net/lsqlite3.c:2461-2499`;
`definitions.lua:576-595`. Failure returns `nil, <integer rc>` with no
string at all (`pusherr` pushes only a bare integer). Probe:
`s.config(999999)` → `nil  21` (SQLITE_MISUSE, no message); also
reachable environmentally — `s.config(s.CONFIG_SINGLETHREAD)` after
`open_memory()` has already initialized SQLite → same `nil 21`.
Cosmic-side spend: zero call sites.

**`Database:db_filename`** — `tool/net/lsqlite3.c` (verified exact:
returns a bare `nil` for an unknown attached-db name, no separate
error channel claimed by its annotation). Probe:
`db:db_filename("nosuchdb")` → `nil`.

**`Database:prepare`** — `tool/net/lsqlite3.c:1597-1617`;
`definitions.lua:867-876`. Failure pushes the numeric SQLite code in
slot 2 where the success path puts the SQL tail string — the doc
comment itself concedes callers must re-fetch the message via
`db:errmsg()`. Probe: `db:prepare("NOT VALID SQL")` → `nil  1` (number,
no message). Cosmic-side spend: `cosmic/sqlite/init.tl:268-277` and
`cosmic/sqlite/stmt_cache.tl:55-70` both re-call `db:errmsg()`
separately because slot 2 is unusable as a message.

**`Database:readonly`** — verified correct `T|nil, string`. Probe:
`db:readonly("nosuchdb")` → `nil  unknown (not attached) database name`
(string).

**`Database:rows`/`urows`/`Statement:rows`/`urows`/`VM:rows`/`urows`**
— see class-3 note above; outer call never nil, inner per-row nil is
iterator protocol. Bad SQL raises a Lua error (not nil) at the outer
call, confirmed live: `pcall(function() return db:rows("NOT VALID
SQL") end)` → `false, "near \"NOT\": syntax error"`.

**`Database:serialize`** — see CAP-D: a genuine memory-corruption
crash (`free()` called on an `sqlite3_malloc`-owned buffer), not a
tuple-shape question. Probe: `db:serialize()` on any database segfaults
(exit 139).

**`Database:wal_checkpoint`** — `tool/net/lsqlite3.c:931-942`;
`definitions.lua:974-978`. Failure pushes the numeric code with no
message. Probe: `db:wal_checkpoint(nil,"nosuchdb")` → `nil  nil  1`
(the third value, `1`, is the bare integer errno; no string). Cosmic-
side spend: zero call sites.

**`Statement:bind_parameter_name`/`get_type`/`get_uvalues`/`get_value`
and their `VM:` aliases** — verified: nil reflects legitimate SQL data
(an anonymous bind parameter, a SQL NULL column value), not a failure
channel at all; no error string is ever claimed or needed. Cosmic-side
spend: `cosmic/sqlite/bind.tl:88` (`if name then ... end`, treats
anonymous-parameter nil as ordinary data);
`cosmic/sqlite/row_iter.tl:81` (`row[col] = raw_stmt:get_value(idx)`,
SQL NULL flows straight to Lua nil).

Row count: 22 scope entries, 22 rows above — counts match, per
Acceptance.
