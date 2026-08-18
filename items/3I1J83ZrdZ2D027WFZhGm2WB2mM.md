Imported from whilp/cosmic#1223.

## Goal

G9 — the least tree that keeps its promises, via epic #1221.

#1222 landed (board item 3I1J6VKz).

## Change

Add the shared floor helper and move both `_build` gates onto it. They
already read and write `cosmic.literal`, so this slice is small by
construction — which is the evidence that the epic's format pick was right.

**`_tool/floor.tl` + `_tool/floor_test.tl`.** Two functions and an options
record, over `cosmic.literal`:

- `read(path: string, opts?: Options): {string: any} | nil, string` —
  `literal.parse_file`, forwarding `noun` and `on_duplicate`.
- `write(path: string, value: any): boolean, string` —
  `literal.format_file`.
- `Options` carries `noun` and `on_duplicate` and nothing else.

It lands in `_tool/` rather than `_build/` because `_tool/coverage/baseline.tl`
must require it in #1224 and `_build/` is repo-only. `_make/policy.tl`
already requires `_tool.coverage.baseline`, so a cross-tree require into
`_tool/` is established; `_build/` requiring `_tool/` is new but is the same
shape.

The helper owns bytes and resolution FORWARDING only. It holds no
comparison, no judgment, and no per-gate resolver of its own — whether 7
casts is worse than 5, and whether a missing name is a failure, stay in the
gates. That is the same split `_build/ratchet.tl` already makes between
reading a table and judging its rows.

**`_build/casts.tl` and `_build/public_surface.tl`** call the helper instead
of `cosmic.literal`. Four call sites, two per file: `baseline()` swaps
`literal.parse_file` for `floor.read`, `main()` swaps `literal.format_file`
for `floor.write`, and the `require("cosmic.literal")` line goes.

**Neither gate passes `on_duplicate`.** Both take #1222's refusal default,
and this CORRECTS the epic's sketch, which said the higher count wins for
casts. Two reasons it is wrong. The casts baseline is a ceiling, not a
floor — the gate fails when a file carries MORE casts than the baseline —
so "higher wins" is the direction that lets a merge silently permit casts
nobody reviewed. And both gates compare exactly in BOTH directions, so a
resolved duplicate can only ever produce a failure anyway; refusing at the
reader names the real problem (two branches disagreed about one key) and
points at the regen, instead of laundering it into a comparison failure
about a number neither branch wrote.

**`.gitattributes` gains `merge=union` for both `_build/*_baseline.tl`**,
with a comment recording the pairing: both files are one sorted
`["key"] = value,` per line, so the common collision is two branches
touching alphabetically adjacent keys, and union yields the correct union
with no duplicate keys at all. A duplicate arises only when both branches
changed the SAME key, which is a real disagreement, and the reader refuses
it and names the regen command.

The measured facts this change rests on:

```facts
$ git ls-files | grep -c '^_tool/floor'
0
$ git ls-files '*.tl' | xargs grep -l 'require("cosmic.literal")' | grep -c '^_build/'
2
$ grep -n 'literal\.\(parse_file\|format_file\)(' _build/casts.tl _build/public_surface.tl
_build/casts.tl:97:  local data, err = literal.parse_file(path or BASELINE)
_build/casts.tl:124:  local ok, err = literal.format_file(BASELINE, counts)
_build/public_surface.tl:94:  local data, err = literal.parse_file(path or BASELINE)
_build/public_surface.tl:121:  local ok, err = literal.format_file(BASELINE, set)
$ wc -l < _build/casts.tl
156
$ wc -l < _build/public_surface.tl
150
$ grep -c 'merge=union' .gitattributes
1
$ grep -rn 'require("_tool' _make/policy.tl
12:local baseline = require("_tool.coverage.baseline")
$ git ls-files | grep -c '^cosmic/embed/floor.tl'
1
```

## Non-goals

`_build/casts_baseline.tl` and `_build/public_surface_baseline.tl` must be
byte-identical before and after for an unchanged tree — this is a machinery
swap, not a reformat, and a diff on either floor in this PR is a bug.

No change to either gate's comparison direction (casts still fails both
ways; the surface is still an exact set), to their failure wording, or to
what they measure — the failure contract and the regen verb are #1225.

No change to `cosmic/literal.tl`; #1222 already landed the contract this
slice consumes.

Do not touch `cosmic/embed/floor.tl`. It is the STRIP floor — what a
stripped artifact keeps — an unrelated meaning of the word that happens to
share a name. There is no module-path collision (`_tool.floor` versus
`cosmic.embed.floor`) and no reason to rename either.

Nothing in `_tool/coverage/` moves in this slice, and `.cosmic-coverage`
does not change. #1224 owns the coverage floor and is file-disjoint from
this one.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _tool/floor_test.tl` ends `test: PASS (1 file)`,
  covering: a floor round-tripping through `write` then `read`; a duplicate
  key refused through `floor.read` with the key named; and an
  `on_duplicate` resolver forwarded through the helper, with its return
  value landing.
- Both `_build` floors regenerate byte-identically on an unchanged tree —
  this command prints exactly `clean`:
  `bin/cosmic --make run _build/casts.tl --baseline >/dev/null && bin/cosmic --make run _build/public_surface.tl --baseline >/dev/null && git diff --quiet _build/casts_baseline.tl _build/public_surface_baseline.tl && echo clean`
- No `_build` file requires `cosmic.literal` any more — this command prints
  exactly `0` (its pre-change value is `2`, recorded as a fact above):
  `git ls-files '*.tl' | xargs grep -l 'require("cosmic.literal")' | grep -c '^_build/'`
- `grep -c 'merge=union' .gitattributes` is `3` (pre-change value `1`,
  recorded as a fact above).

## Enablement

none needed — #1222 (board item 3I1J6VKz) landed; the duplicate-key
contract it establishes is what this slice's `on_duplicate` default relies
on.

Beyond that, none needed. The one silent failure available here is a
reformatted baseline, and the byte-identity command in `Acceptance` is a
gate on exactly that. The one place an implementer would otherwise have to
reconcile a contradiction — the epic's "higher count wins" sketch for casts
— is decided in `Change` above with its reasoning, rather than left to be
rediscovered at review.


---
_Generated by [Claude Code](https://claude.ai/code)_
