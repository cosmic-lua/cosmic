## Access

read access to `cosmic-lua/cosmic` (the running prerelease binary and
its embedded `--docs` output cited below in Repro) — same-owner as
the board's own origin.

## Finding

`cosmic --docs cosmo.<submodule>` (e.g. `cosmo.lsqlite3`, `cosmo.unix`)
renders the module's reference under a dotted heading that reads
exactly like a field-access path (`cosmo.lsqlite3`, `cosmo.unix`), but
neither of the two ways a reader would naturally try to reach that
value from that heading works — only a third, unstated form does.
Nothing in the rendered doc states the actual require path, so a
reader has to discover it by trial and error against three
candidates, two of which fail with errors that do not point at the
fix.

## Repro

Verified against the `cosmic-lua/cosmic` prerelease `2026-09-02-c60dcf1`
(`cosmos 2026.08.31-6dfa6728a, Lua 5.5`), the same checksum-verified
binary used in the sibling item `3Iqe1uKLxDDYZxfiZjiD1LnVbfl`.

`cosmic --docs cosmo.lsqlite3` heads its output:

```
# lsqlite3

Type declarations for the `lsqlite3` module.
```

reached via the query `cosmo.lsqlite3` — a natural reading is either
"a `require("cosmo.lsqlite3")` module" or "the `lsqlite3` field of
`require("cosmo")`". Both the obvious guesses fail:

```teal
local cosmo = require("cosmo")
local lsqlite3 = cosmo.lsqlite3          -- guess 1: field access
```
```
error: invalid key 'lsqlite3' in record 'cosmo' of type cosmo
  hint: the value's record type does not declare this key — check the
  spelling; and a function on your MODULE's record is dot-called with
  the value first (`store.add(db, ...)`), never colon-called
  (`db:add(...)`) — see `cosmic --docs guide.gotchas`
```

The hint talks about dot-call vs colon-call, which has nothing to do
with the actual problem (wrong require path), and does not name
`require("cosmo.lsqlite3")` anywhere.

```teal
local lsqlite3 = require("lsqlite3")     -- guess 2: bare module name
```
```
error: module 'lsqlite3' not found

Did you mean?
  cosmo.lsqlite3

Try: require("cosmo.lsqlite3")
```

This second, unrelated guess is the one that happens to surface the
right answer — an accident of the fuzzy-match suggestion, not
anything the `cosmo.lsqlite3` doc page itself states.

```teal
local lsqlite3 = require("cosmo.lsqlite3")   -- works
```

Confirmed the same pattern holds for another `cosmo/*.d.tl` submodule,
not just lsqlite3 — `cosmo.unix` behaves identically:

```
$ ./cosmic-lua -e 'local u = require("cosmo.unix"); print(type(u))'
table
$ ./cosmic-lua -e 'local c = require("cosmo"); print(c.unix)'
nil
```

(the second form is silent — `nil` with no error at all — because
`-e` runs unchecked; under `--check types` strict it is the same loud
"invalid key" error as the lsqlite3 case.)

## Scope

Not yet localized to a specific doc-rendering file — likely
`cosmic/doc/show.tl` or `_tool/doc/dtl.tl` (the `.d.tl` doc-comment
extraction path), based on `_tool/doc/`'s layout, but not confirmed by
reading that source. The `cosmo.d.tl` top-level surface (`Url`,
`EncoderOptions`, etc. — plain type declarations, not modules) and the
`cosmo/*.d.tl` submodules (`unix`, `path`, `getopt`, `lsqlite3`, `re`,
`argon2`, `zip`, `repl`, per AGENTS.md's Type Generation section) look
identical under `--docs` today; only the submodules need a require
line, since the top-level ones are not required at all, only
referenced by type.

## Why it matters

AGENTS.md is explicit that `require("cosmo")` (and by implication its
submodules) is for "library internals implementing wrappers" — the one
place cosmo.* is expected to be reached from user code at all is
inside `cosmic/*.tl`. A reader who does need to go there (implementing
a wrapper, or reaching a binding `cosmic.*` doesn't yet expose, like
`create_function` before `3If5tfhKFddBtGv2wqkEs2aEOny` lands) hits this
exact confusion first, with no signal in the doc that would shortcut
the trial-and-error. A one-line "require as: `cosmo.lsqlite3`" (module
path, distinct from the field-access reading the heading otherwise
suggests) on every `cosmo/*.d.tl` submodule's doc page would close it
for the whole family in one place, not just lsqlite3.
