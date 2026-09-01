## Goal

G3, via the cosmo-contracts container: the inventory that turns "two
bindings fixed" into "the boundary is exact", for one slice of it —
the tail modules — `cosmo.re`, `cosmo.getopt` and `cosmo.argon2` together. A research slice: its deliverable is recorded evidence and the
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

**This slice's scope: the 7 nil-admitting bindings below.**

```text
re.Regex:search re.Regex:match re.Regex:find re.search re.compile getopt.parse argon2.hash_encoded
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

## Result

Re-measured 2026-09-01 against `cosmic-lua/cosmopolitan` master
`fd0884d9` (`1e165815..fd0884d9` touches `tool/net/definitions.lua` in
7 commits — `#307` unix.isatty return-type fix, `#309`
unix.capget slot-sharing fix, `#304` lcov's instruction budget, none
in `re`/`getopt`/`argon2`). Overall census at `fd0884d9`: 211 EXACT /
191 NIL / 38 NONE = 440 declarations
(`grep -c '^function ' tool/net/definitions.lua` = 440; unix now 126
NIL, not 127 — `#307`/`#309` fixed one row each; `path`/`cov`/`repl`
still 0). **This slice's scope is unchanged**: re-running `census.awk`
filtered to `re.`/`getopt.`/`argon2.` at `fd0884d9` yields the same 7
bindings named above, byte-identical.

Built `o//tool/lua/lua` at `fd0884d9` (`make -j$(nproc) o//tool/lua/lua`,
default MODE). All 7 bindings load via `require("cosmo.re")`,
`require("cosmo.getopt")`, `require("cosmo.argon2")` (not bare
globals). 7 rows for 7 scope entries — counts match.

| binding | class | probe (from repo root) | capture id / exact |
|---|---|---|---|
| `re.Regex:search` | 2, tuple deviates | `o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:search("xxabxx"))'` | CAPTURE-1 |
| `re.Regex:match` | 2, tuple deviates | `o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:match("xxabxx"))'` | CAPTURE-2 |
| `re.Regex:find` | 2, tuple deviates | `o//tool/lua/lua -e 'local re=require("cosmo.re"); local rx=re.compile("(a)(b)"); print(rx:find("xxabxx"))'` | CAPTURE-3 |
| `re.search` | 2, tuple deviates | `o//tool/lua/lua -e 'local re=require("cosmo.re"); print(re.search("[invalid", "xxabxx"))'` | CAPTURE-4 |
| `re.compile` | 2, tuple exact | `o//tool/lua/lua -e 'local re=require("cosmo.re"); print(re.compile("[invalid"))'` | exact |
| `getopt.parse` | 1, degenerate-input-only | `o//tool/lua/lua -e 'local getopt=require("cosmo.getopt"); print(getopt.parse("not-a-table", "h"))'` | CAPTURE-5 |
| `argon2.hash_encoded` | 2, tuple exact | `o//tool/lua/lua -e 'local argon2=require("cosmo.argon2"); print(argon2.hash_encoded("password", "short", {}))'` | exact |

Detail per row:

**`re.Regex:search`** — `tool/net/lre.c:175-187` (`LuaReRegexSearch`),
calling `LuaReSearchImpl` (`lre.c:66-93`); `definitions.lua:1440`.
Class 2: nil is reachable both benignly (no-match, a bare single
`nil`) and via a genuine `regexec()` engine failure (`lre.c:64-65`), a
data-dependent path a correct caller can meet by construction. Tuple
deviates: `definitions.lua:1434-1438` declares slot 2 as
`{string}|string|nil` — the capture-groups table on a match and the
error string on a failure share one slot (the `unix.nanosleep`-class
deviation). Cosmic-side spend: `grep -rn ':search(' cosmic/` → zero
hits; `cosmic/re.tl` calls `:match` instead per its own comment.

**`re.Regex:match`** — same C function as `search`
(`lre.c:227`, `kLuaReRegexMeth[]` maps both names to
`LuaReRegexSearch`); `definitions.lua:1462`. Same class/deviation.
Cosmic-side spend (non-empty): `cosmic/re.tl:188-196` calls
`regex:match(text)` and must hand-decode the shared slot at runtime
(`if caps then ... else ... end` to tell a captures table from an
error string) — this is the deviation's live cost.

**`re.Regex:find`** — `tool/net/lre.c:189-210` (`LuaReRegexFind`),
via `LuaReFindImpl` (`lre.c:102-131`); `definitions.lua:1492`. Class 2,
same reachability. Tuple deviates: slot 2 is `integer|string|nil`, the
absolute stop offset on a match sharing a slot with the error string
on failure. Cosmic-side spend: `cosmic/re.tl:280` and `:326` both
guard the shared slot.

**`re.search`** (module-level) — `tool/net/lre.c:136-153`
(`LuaReSearch`, compile-then-search-once); `definitions.lua:1527`.
Class 2: nil reachable via a bad pattern at compile time (data-
dependent, demonstrated live) or a `regexec` engine failure at search
time. Tuple deviates, identical shape to `search`/`match`. Cosmic-side
spend: `grep -rn '\bre\.search(' cosmic/` → zero hits.

**`re.compile`** — `tool/net/lre.c:155-170` (`LuaReCompile`), via
`LuaReCompileImpl` (`lre.c:42-59`); `definitions.lua:1549`. Class 2:
nil only on `regcomp()` failure for a malformed, normally
caller/user-supplied pattern string — data-dependent, not a shape
violation. Tuple verified exact: clean `re.Regex|nil` / `string?` with
nothing else sharing a slot. Cosmic-side spend: heavily used, cleanly
narrowed — `cosmic/re.tl:100-106` and `:153-159` both do a plain
`if not result then return nil, err end`.

**`getopt.parse`** — `tool/net/lgetopt.c:59-251` (`LuaGetoptParse`);
`definitions.lua:1634`. Class 1, degenerate-input-only: every one of
its 11 `FAIL(...)` sites (`lgetopt.c:71,73,75,81,86,93,96,100,102,106,115`)
rejects an argument-shape violation of the function's own contract —
none is reachable via valid input data or an external/environmental
condition; `getopt_long()` itself is never consulted before these
checks pass, and its own runtime outcomes (unknown/missing option)
report through the success path's `result.unknown`/`result.missing`
fields, not through this nil slot. Cosmic-side spend:
`cosmic/flags/getopt.tl:91-94` and `cosmic/flags/parse.tl:117-120`
both defensively guard `if not res/r0 then return nil, err end`, but
by construction (typed `LongOpt` records, `args` always `{string}`
from `proc`) this path is unreachable from cosmic's own call sites —
exactly the raise-candidate shape.

**`argon2.hash_encoded`** — `tool/net/largon2.c:116-216`
(`largon2_hash_encoded`); `definitions.lua:1788`. Class 2: nil only
when `argon2{d,id,i}_hash_encoded()` returns a non-`ARGON2_OK` code —
reachable with normal-looking numeric/string config a correct caller
can pass (e.g. a salt shorter than `ARGON2_MIN_SALT_LENGTH`, 8 bytes)
— data-dependent, not a type violation. Tuple verified exact: clean
`string|nil ascii` / `string? error`. Cosmic-side spend:
`cosmic/hash.tl:212-215` — clean narrow; cosmic's own `hash_password`
wrapper never exposes `salt` to its caller (always CSPRNG-generated at
the required 16 bytes), so the salt-too-short path specifically is
unreachable *through cosmic*, but is directly reachable on the raw
binding this census scopes.

Row count: 7 scope entries, 7 rows above — counts match, per Acceptance.
