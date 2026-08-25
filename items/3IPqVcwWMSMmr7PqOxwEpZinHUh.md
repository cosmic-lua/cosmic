## Goal

G3 — an honest type layer, no escape hatches. The parent (`3IOegofM`)
holds the 38 decoded-data shaping `from any` casts in test files. Its
sibling slice closes the 21 whose test merely CONSUMES decoded data.
These 17 are the residue: tests whose subject IS the dynamic decode, so
a validating decode would change what is under test rather than close a
cast. The deliverable is a per-site decision — a narrowing, a call
change, or a cast whose stated reason is true — not a count that
necessarily falls to zero.

## Evidence

Measured 2026-08-25 against `whilp/cosmic` `cd87a765` (`main`). Two
files, 17 sites, every one a `from any` cast and no other cast in
either file (`grep -c -- "-- cast:" <file>` reports 10 and 7, matching
their `_build/casts_baseline.tl` rows at lines 73 and 76).

**`cosmic/json_test.tl` — 10 sites, 324 lines** (176 of headroom under
the 500-line cap). `grep -n -- "-- cast: .*from any"`:

| line | site | note |
| --- | --- | --- |
| 6 | `json.decode('{"a":1,"b":"hello"}') as {string: any}` | object |
| 14 | `json.decode('[1,2,3]') as {number}` | array |
| 103 | `json.decode(encoded) as {string: any}` | object |
| 105 | `decoded.nested as {string: boolean}` | nested read |
| 174 | `json.decode('{"a":null,"b":1}') as {string: any}` | null policy |
| 186 | `json.decode("[1,null,2]") as {any}` | null policy |
| 198 | `json.decode("[1,null,2]") as {any}` | null policy |
| 205 | `json.decode("[1,null,2]", {null_value = json.null}) as {any}` | null policy |
| 208 | `json.decode('{"a":null,"b":1}', {null_value = json.null}) as {string: any}` | null policy |
| 273 | `json.decode('"\\u0000"') as string` | scalar |

`cosmic/json.tl` already declares the two narrower entry points the
first four could use — `decode_object(str: string): {string: any} | nil,
string` (`:135`) and `decode_array(str: string): {any} | nil, string`
(`:155`). **That is the decision this slice has to make and state**:
`cosmic/json_test.tl` is the json module's own test file, so swapping
`decode` for `decode_object` at a site changes WHICH function is under
test. The five null-policy sites (174–208) pin `decode`'s handling of
JSON `null` specifically and cannot swap at all. `:273` decodes a
scalar, which neither narrower entry point accepts.

**`cosmic/literal_test.tl` — 7 sites, 453 lines** (47 of headroom, the
tighter of the two):

| line | site |
| --- | --- |
| 143–145 | `shallow.a`, `a.b`, `b.c`, each `as {string: any}` |
| 212 | `got.nested as {string: any}` |
| 251 | `got["a\tkey"] as {string: any}` |
| 270, 280 | `got["a.tl"] as {string: any}` |

`:143`–`:145` walk a deliberately-nested value to prove nesting is
accepted; `:251` proves a tab in a bracket key survives. Validating
those into a declared record would assert the shape the test is trying
to DISCOVER.

**What `cosmic.shape` can and cannot do here.** `cosmic/shape.tl` (290
lines) validates into a declared record; its contract says extra keys
are ignored, missing and `null` are the same thing, and nothing is
coerced. So a Spec can express "a table whose `a` is a table whose `b`
is a table" — `shape.record({a = shape.record({b = ...})})` — which
would close `cosmic/literal_test.tl:143`–`:145` at the cost of naming
the very nesting under test. Whether that is honest is the judgment.

**Two type facts, probe-verified at refinement** against a `--make
build` of `cd87a765` (scratch file outside the tree, `--check types`,
deleted):

- `==` accepts `any` on one side, so `decoded.a == 1` needs no cast.
- `>=` does not: `cannot use operator '>=' for types <any type> and
  integer`. Any ordering comparison on a decoded field needs a real
  type behind it.

**`is` is the third option.** AGENTS.md's narrowing section names
`if v is {string: any} then` as dispatch over `any`, which narrows
without a cast. Whether a `is`-guarded branch in a test reads as
clearer than a justified cast is per site.

**The ratchet does not have to reach zero.** `_build/casts.tl` gates
each file's `as` count against `_build/casts_baseline.tl`; a count that
falls is regenerated with the command the failure prints
(`bin/cosmic --make run _build/casts.tl --baseline`) and a count that
holds needs no change. A site that keeps its cast keeps a row.

## Change

Refinement — not implementation — must settle, per site, which of four
outcomes applies, and write the answer into this spec before it is
`ready`:

1. **call change** — `decode` becomes `decode_object`/`decode_array`,
   only where the test is not about `decode` itself;
2. **`is` narrowing** — a guarded branch replaces the cast;
3. **`shape.into`** — only where naming the shape does not pre-empt what
   the test asserts;
4. **a truer reason** — the cast stays and its `-- cast:` comment is
   rewritten to say why the value is genuinely untyped here (the test's
   subject is the dynamic decode), replacing the generic `from any`.

Outcome 4 is a legitimate answer for a majority of these 17, and the
slice is not failing if the counts barely move. What the slice may not
do is leave a site with the generic `from any` reason when a truer one
exists.

The refined `Change` names every one of the 17 lines with its chosen
outcome, so implementation makes no judgment of its own. Then it states
the expected `_build/casts_baseline.tl` rows for the two files after
the change, so `Acceptance` can check them.

## Non-goals

- **Do not change what any test asserts.** The null-policy tests
  (`cosmic/json_test.tl:174`–`:208`) and the nesting and bracket-key
  tests (`cosmic/literal_test.tl:143`–`:145`, `:251`) exist to pin
  behaviour that is deliberately dynamic. No assertion is weakened,
  reworded to a shape it did not have, or deleted because a validator
  made it redundant.
- **Do not touch the sibling slice's six files** (`_eval/score_test.tl`,
  `_eval/stage_test.tl`, `_make/pin_test.tl`,
  `cosmic/teal_config_test.tl`, `_tool/doc/index_test.tl`,
  `cosmic/fetch/verbs_test.tl`).
- **Do not touch `cosmic/json.tl`, `cosmic/literal.tl` or
  `cosmic/shape.tl`.** The `json.decode` contract — what it returns and
  how `null_value` behaves — is frozen for this slice; a test that
  reveals a contract problem files an item, it does not fix it here.
- **Do not add a combinator to `cosmic.shape`.** A shape it cannot
  express is outcome 4.
- **Do not edit `_build/casts_baseline.tl` by hand**; run the regen
  command the gate prints.
- **Do not weaken a gate**: no `.cosmicignore` entry, no coverage
  exclusion, no lint suppression.
- **Do not touch `whilp/cosmopolitan`.**

## Acceptance

To be completed by refinement, once `Change` names each site's
outcome. The floor and the two checks that are already fixed:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test cosmic/json_test.tl cosmic/literal_test.tl`
  ends `test: PASS (2 files)`.
- `git diff --name-only origin/main...HEAD` names only
  `cosmic/json_test.tl`, `cosmic/literal_test.tl` and (if any count
  fell) `_build/casts_baseline.tl`.
- **No site keeps the generic reason.**
  `grep -c -- "-- cast: .*from any" cosmic/json_test.tl
  cosmic/literal_test.tl` reports `0` for both. Today it reports 10 and
  7. A cast that survives carries a reason naming why the value is
  genuinely untyped at that site.
- `wc -l cosmic/json_test.tl cosmic/literal_test.tl` reports at most
  500 for each (453 today for the second, the tight one).

Refinement adds the exact post-change `_build/casts_baseline.tl` rows
as a `grep` with its expected number, per the ready bar's rule that a
numeric bound the spec imposes is an Acceptance command.

## Enablement

No blocker. `cosmic.shape` landed (`3IOefXSz`, PR #1370);
`json.decode_object`/`decode_array` have existed since
`cosmic/json.tl:135`/`:155`; `is` narrowing is AGENTS.md's. The reason
this item is not `ready` is not a missing mechanism — it is that
seventeen per-site judgments have not been made, and making them is
refinement's job, not the implementing session's. The cast-reason
standard is AGENTS.md ("Write the actual reason … a cast you cannot
justify is one to remove"); the comment-and-prose standard is
`skills/docs-style/SKILL.md`.
