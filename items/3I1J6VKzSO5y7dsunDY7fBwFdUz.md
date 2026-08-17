Imported from whilp/cosmic#1222.

## Goal

G9 — the least tree that keeps its promises, via epic #1221. This is the
enabler the other three slices depend on: `cosmic.literal` becomes safe to
union-merge, which is the one property that kept the coverage floor on a
format and a parser of its own.

## Change

Three moves, in this order, in `cosmic/`.

**1. Make room first.** `cosmic/literal.tl` is at the 500-line cap with ZERO
headroom, so the contract in step 2 cannot be added to it as it stands.
Extract the lexer into a new `cosmic/_literal_lex.tl` — the flat
`_literal_*` sibling shape `cosmic/_literal_format.tl` already established
for exactly this reason, and its leading `_` keeps the module out of the
public surface. Move these five symbols and nothing else:

- the `Token` record — export it as a type, `parse_table` still needs it
- `KEYWORDS`, `long_bracket_end`, `numeral_at` — lexer-internal
- `lex` — export it as a function; `parse` is its one caller

Leave `scalar` in `literal.tl`: `parse_table` uses it, the lexer does not.
This is a move, not a rewrite — behaviour is byte-identical.

**2. State the duplicate-key contract** in `cosmic/literal.tl`. Today
`parse_table` writes `out[key] = value` at five separate sites with no
check, so `["a"] = 1` followed by `["a"] = 2` reads as 2 and nothing says
so. That is invisible in a pin (where a duplicate is a typo) and unsafe in
a floor (where a `merge=union` produces duplicates BY DESIGN).

- Fold the five assignment sites into ONE. Compute each value into a local,
  then assign at a single point where the check can live.
- Track first-seen lines in a `seen: {string: integer}` local, keyed by key,
  holding the line the key was first written on — the refusal names both
  lines and `out` does not carry them.
- `seen` is PER TABLE, declared inside `parse_table` beside `out`. A key
  repeated in two different nested tables is not a duplicate.
- Default: a repeated key is REFUSED, in the module's existing refusal
  shape — `<file>:<line>: a <noun> repeats the key '<key>' (first at line
  <n>)`.
- Opt in: add an `on_duplicate` field to the EXISTING exported `Options`
  record — do not add a second options record. Its type is
  `function(key: string, first: any, second: any): any`, and its return
  value is stored as-is; the resolver is infallible and a nil return stores
  nil. Thread it from `parse` into `parse_table`'s recursion.
- Nothing in the tree passes `on_duplicate` in this slice. #1223 is its
  first caller.

**3. Record the decision.** Add `docs/decisions/d27-one-committed-floor.md`
in the `decide` skill's four-section form — one format for every committed
floor, why it is `cosmic.literal` rather than a second text format, and the
duplicate-key contract that makes it merge-safe — and add its row to
`docs/decisions/README.md`, the derived index `_build/docs_test.tl` gates.
D26 is the highest number in use.

The measured facts this change rests on:

```facts
$ wc -l < cosmic/literal.tl
500
$ wc -l < cosmic/_literal_format.tl
216
$ wc -l < cosmic/literal_test.tl
314
$ sed -n '22,173p' cosmic/literal.tl | wc -l
152
$ sed -n '22p;173p' cosmic/literal.tl
--- One lexical token: its raw text, what it is, and the line it began on.
end
$ grep -c 'out\[key\] = ' cosmic/literal.tl
5
$ grep -ci duplicate cosmic/literal.tl
0
$ grep -c on_duplicate cosmic/literal.tl
0
$ git ls-files '*.tl' | xargs grep -l 'require("cosmic.literal")' | sort
_build/casts.tl
_build/public_surface.tl
_eval/stage.tl
_make/patch.tl
_make/pin.tl
_make/pins_test.tl
cmd/cosmic/embed_gen.tl
cosmic/format/literal_format_test.tl
cosmic/literal.tl
cosmic/literal_example.tl
cosmic/literal_test.tl
$ ls docs/decisions/ | grep -o '^d[0-9]*' | sort -V | tail -1
d26
$ grep -c 'local function test_' cosmic/format/literal_format_test.tl
3
```

The caller list is the contract-narrowing check: refusing duplicates by
default narrows `parse`/`parse_file` for all eleven files above. None of
them carries a duplicate key today, which is what makes the default safe
and what the default keeps true.

## Non-goals

No gate is migrated in this slice — `_build/casts.tl`,
`_build/public_surface.tl` and `_tool/coverage/baseline.tl` are untouched,
and no committed floor file changes a byte. No new `--make` verb (#1225).
No `.gitattributes` change (#1223).

No change to what `parse` admits or refuses beyond duplicates. In
particular the grammar does NOT grow array or integer keys — `["a"] = {12,
40}` stays refused by both halves, and finding a row shape for the coverage
floor is #1224's problem, not this slice's.

`cosmic/_literal_lex.tl` must import nothing outside `cosmic/**`.
`cosmic.literal` has to stay importable in a STRIPPED artifact, which is
why the module lexes for itself instead of borrowing `tl.lex` and why the
fmt-fixpoint test lives in `cosmic/format/`. A `require` reaching out of
the strip floor breaks the module's whole reason for existing.

Do not add another fmt-fixpoint test — three already exist in
`cosmic/format/literal_format_test.tl` and they cover the property the epic
depends on.

No change to `format`/`format_file`, to their fixed layout, or to
`*_pin.tl` files. The default refusal is what keeps pins duplicate-free.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/literal_test.tl` ends `test: PASS (1 file)`,
  with new tests covering: a duplicate key refused by default with both line
  numbers named; the same duplicate spelled `a =` on one side and `["a"] =`
  on the other; a duplicate inside a nested table; the same key in two
  DIFFERENT nested tables accepted; and `on_duplicate` resolving, with its
  return value landing in the parsed table.
- `bin/cosmic --make test _build/docs_test.tl` ends `test: PASS (1 file)`,
  which is the gate that D27's row in `docs/decisions/README.md` must
  satisfy.
- `bin/cosmic --make fetch` still resolves both pins.
- After the change, both halves are under the cap:
  `wc -l cosmic/literal.tl cosmic/_literal_lex.tl` reports each below 500.
- After the change, `git ls-files '*.tl' | xargs grep -l
  'require("cosmic.literal")' | wc -l` is still 11 — the extraction adds no
  new importer of the public module.

## Enablement

none needed — every structural wrong turn this change invites is already
caught by a gate that exists. `cosmic --check lint` fails the 500-line cap
if the contract goes in before the extraction; `--check types` fails if
`scalar` is moved out with the lexer or `Token` is not exported;
`_build/public_surface_test.tl` fails if the new module is named without
its leading `_` and becomes public API. The two choices a gate cannot make
— that a resolver's return value is stored as-is, and that duplicate
detection is per-table rather than per-file — are decided in `Change` above
and asserted by the tests `Acceptance` names.


---
_Generated by [Claude Code](https://claude.ai/code)_