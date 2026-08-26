## Goal

G3 — an honest type layer. One declaration produces **26 of the 358**
unguarded-nil sites `docs/design/nil-flow.md` measured
(`docs/design/nil-flow.md`'s producer table,
`o/_types/types_gen/cosmo/path.d.tl:40` `join`, 26 sites). It is the
single largest mechanical win in the census, and closing it is one of
the four blockers on 3IPXRRd2, the strict-mode endgame.

## Evidence

`o/_types/types_gen/cosmo/path.d.tl:40` declares:

```text
  join: function(str?: string, ...: string): string | nil
```

generated from `tool/net/definitions.lua` in whilp/cosmopolitan, whose
prose says: "Specifying no arguments will raise an error. If `nil`
arguments are specified, then they're skipped over. If exclusively `nil`
arguments are passed, then `nil` is returned."

Probed against the pinned cosmos (2026-08-26,
`o/bin/cosmic -e 'local p = require("cosmo.path") ...'`):

```text
join("")        →  ""      (empty string, NOT nil)
join("","")     →  ""
join("a")       →  "a"
join("a", nil)  →  "a"
join(nil, "b")  →  "b"
join(nil)       →  nil
join()          →  error "missing argument"
```

So the nil member is reachable for exactly one input shape — every
argument nil — and no site in this tree passes it: every call passes at
least one argument whose own declared type is non-nil `string`.

The seven call sites, measured 2026-08-26 with
`grep -rn 'cosmo_path\.join(' cosmic/` (7 hits, plus one test site in
`3p/`, out of scope below):

```text
cosmic/fs/path.tl:28    return cosmo_path.join(...)            <- the wrapper
cosmic/fs/path.tl:415   return cosmo_path.join(dir, p:sub(3))
cosmic/fs/walk.tl:72    local full_path = cosmo_path.join(dir, entry)
cosmic/fs/find.tl:252   local full_path = cosmo_path.join(current_dir, entry)
cosmic/fs/find.tl:317   table.insert(out, cosmo_path.join(dir, entry))
cosmic/fs/tree.tl:28    local s = cosmo_path.join(src, entry)
cosmic/fs/tree.tl:29    local d = cosmo_path.join(dst, entry)
```

The cost is a cascade, not 26 independent sites: `cosmic/fs/tree.tl`'s
`s` and `d` are then spent as arguments and concatenation operands, and
the census counts each spend. Census rows per file
(`grep -c '^<file>	' docs/design/nil-flow-sites.tsv`, 2026-08-26):
`cosmic/fs/tree.tl` 12, `cosmic/fs/find.tl` 11, `cosmic/fs/walk.tl` 7,
`cosmic/fs/path.tl` 6. Those rows include other producers, and the tsv
carries no producer column, so it cannot be filtered to this
declaration — which is why Acceptance below does not try to count 26.

`cosmic/fs/path.tl:28` is where the lie already lives:

```teal
--- Nil arguments are skipped; exclusively nil returns nil.
--- @return string The joined path
local function join(...: string): string
  return cosmo_path.join(...)
end
```

The signature and the doc comment contradict each other in three lines.

## The shape, decided

**Assert once, at the wrapper, and route every other caller through
it.** Not a `definitions.lua` change, and not 26 guards.

The item was written offering two shapes. A third landed since:
D23 was amended 2026-08-26 (PR #1384, `AGENTS.md:237`) to license
exactly this — "a `cosmic.*` module may `assert` a `cosmo.*` binding
return whose declared `| nil` is unreachable for the arguments that call
passes, provided the assert carries a trailing `-- assert: <why the nil
cannot occur>` comment". This site is the archetype the amendment was
argued from, and it is what makes the third shape the cheapest correct
one:

- **Rejected: declare `str` required in `definitions.lua`** so the
  return is `string`. It fixes the type by making the honest case
  unspeakable: `join(nil)` really does return nil at the C boundary, so
  the generated declaration would start lying to a dynamic caller. It
  also couples this slice to a cosmopolitan release and a cosmos pin
  bump for a defect that is entirely on this side — spending a union
  whose nil our own arguments cannot produce.
- **Rejected: 26 guards on the cosmic side.** Twenty-six edits for one
  root cause, and every one of them a guard on a branch that cannot be
  taken.
- **Chosen: one assert.** Six call sites become one, the union is
  disposed of where its unreachability can be argued in a comment a
  reader can check, and nothing outside cosmic moves.

## Change

**1. `cosmic/fs/path.tl` — the wrapper asserts.** Replace the body of
`join` (line 28) so the binding's union is disposed of once:

```teal
--- Concatenate path components.
--- Absolute paths in later arguments reset the result.
--- Nil arguments are skipped. Calling with no arguments, or with every
--- argument nil, is a caller error and throws.
--- @param ... string Path components to join
--- @return string The joined path
local function join(...: string): string
  local joined = cosmo_path.join(...)
  -- assert: cosmo.path.join returns nil only when every argument is
  -- nil, and this signature declares them all non-nil string
  return assert(joined, "path.join: every argument was nil")
end
```

The signature does NOT change: it already declares `string`, which is
what the 26 downstream sites read.

**2. `cosmic/fs/path.tl:415`** — `expand_user`'s tail call — uses the
local `join` instead of `cosmo_path.join`.

**3. `cosmic/fs/walk.tl:72`, `cosmic/fs/find.tl:252`,
`cosmic/fs/find.tl:317`, `cosmic/fs/tree.tl:28-29`** — each requires
`cosmic.fs.path` and calls its `join`. `cosmic/fs/path.tl` requires only
`cosmo.unix` and `cosmo.path`, so no import cycle is possible; `find.tl`
and `tree.tl` already require sibling `cosmic.fs.*` modules the same
way. Drop the `cosmo_path` import from `walk.tl` and `tree.tl` once
their last call goes — `--check types` fails on an unused local, so this
is not optional. `find.tl` KEEPS its import: `cosmo_path.isdir` at
`cosmic/fs/find.tl:356` still uses it, and that call is out of scope.

Measured headroom 2026-08-26 (`wc -l`): `cosmic/fs/path.tl` **486**
(14 lines under the 500-line cap — the change above adds 3 net lines,
so it fits, and nothing else may be added to this file in this diff),
`cosmic/fs/find.tl` 399, `cosmic/fs/walk.tl` 168,
`cosmic/fs/tree.tl` 122.

**4. `cosmic/fs/path_test.tl`** (465 lines, 21 `join(` sites today):
add one test pinning the new contract — `join("a", "b")` is a plain
string, and `join()` with no arguments throws — called on the line
after its `end`, per AGENTS.md.

## Non-goals

- **Do not touch `whilp/cosmopolitan`.** No `definitions.lua` edit, no
  C change, no cosmos pin bump, no type regen. The C contract is honest
  and stays frozen; the defect is this side's.
- **Do not add a cast at any site.** `assert` plus its `-- assert:`
  comment is the licensed shape; a cast is not.
- **Do not add guards at the 26 downstream sites.** They close because
  the wrapper's return is a plain `string`; a diff that also guards them
  has not understood the cascade.
- **Do not change `join`'s signature or `cosmic.fs`'s re-export.** It is
  already `(...: string): string`, and `cosmic.fs.join` is the public
  name AGENTS.md's mapping table names.
- **Do not touch `3p/tl/tl_test.tl:17`.** It is a test site under `3p/`
  and belongs to the `check.must` sweep, board item 3IQfILPQ.
- **Do not fix sites belonging to other producers.** This slice owns one
  declaration; the census rows counted above include others.
- **Do not add a lint for the `-- assert:` convention.** Board item
  3IQfhI33.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/fs/path_test.tl` ends `test: PASS`.
- `grep -rn 'cosmo_path\.join(' cosmic/ | wc -l` reports `1` (today
  `7`) — the wrapper is the only remaining caller.
- `grep -c -- '-- assert:' cosmic/fs/path.tl` reports `1` (today `0`).
- `grep -rn 'cosmo_path' cosmic/fs/walk.tl cosmic/fs/tree.tl | wc -l`
  reports `0` (today `4`: one import and one or two `join` calls each) —
  the now-unused import went with the last call.
- `grep -rn 'cosmo_path' cosmic/fs/find.tl | wc -l` reports `2` (today
  `4`) — `find.tl` keeps its import for `cosmo_path.isdir` at line 356,
  which this slice does not touch.
- `wc -l cosmic/fs/path.tl` reports at most `500`.
- `git diff --name-only origin/main` lists only files under `cosmic/fs/`
  — no `3p/`, no `docs/`, no `AGENTS.md`.

The census's own Method (`docs/design/nil-flow.md`, `## Method`) is NOT
an acceptance command: it needs a throwaway strict checker that is not
committed and was deleted, so it cannot be run literally. The greps
above are the runnable contract; the 26 rows close because the wrapper's
declared `string` is now true.

## Enablement

none needed. The doctrine that licenses the shape landed 2026-08-26 with
PR #1384 (D23 amended) and is restated at `AGENTS.md:237`; the
`narrow-assert-decl` patch (`3p/tl/tl_patch.tl`) already makes `assert`
narrow in expression position; `cosmic/time.tl` is the worked example of
the same shape (board item 3IPXQcgW). No blocker, and nothing in
whilp/cosmopolitan has to move first.
