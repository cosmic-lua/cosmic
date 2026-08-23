## Goal

G6 — the defining paths, ratcheted, and no silent bugs in them.
`cosmic.literal` is the codec behind every `*_pin.tl` (`cosmic --make
fetch` reads them through it), every committed ratchet floor
(`_tool/floor.tl`), the patch reader (`_make/patch.tl`) and the eval
suite loader (`_eval/stage.tl`) — and it is the one codec `_fuzz` does
not cover. This slice closes that on the pure-Teal implementation, and
the harness it leaves behind is what a second implementation of the
same grammar gets held against (its sibling items).

## Evidence

Measured 2026-08-23 on `main` at `30ab0ce3`.

**The gap, in one command.** `grep -rn "cosmic.literal" _fuzz/` prints
nothing: zero matches. `ls _fuzz/` lists `compress_fuzz_test.tl`,
`json_fuzz_test.tl`, `re_fuzz_test.tl`, `sse_fuzz_test.tl`,
`tar_fuzz_test.tl`, `url_fuzz_test.tl` — six properties files, none of
them literal's. The parent research item asserted that "the `_fuzz`
driver already fuzzes the Teal side"; that is not true today, and the
correction is why this slice exists as its own item.

**The harness to follow** is `_fuzz/json_fuzz_test.tl` (173 lines): it
declares its generators as `source.Recorder` draws, states its domain
bounds in a comment block as deliberate rather than incidental, and
runs every property through `_fuzz.driver` (465 lines) so a failure
names the seed, the iteration and the input in base64, and `FUZZ_SEED`
replays it. `_fuzz/source.tl` is 108 lines. The daily deep run is
`FUZZ_ITERS=50000` (`.github/workflows/fuzz.yml:5`), 2000 on that
workflow's own `pull_request` trigger.

**The code under test**, with the sizes that say nothing needs to move:

```
$ wc -l cosmic/literal.tl cosmic/_literal_lex.tl cosmic/_literal_format.tl
  402 cosmic/literal.tl
  163 cosmic/_literal_lex.tl
  273 cosmic/_literal_format.tl
```

The reader's promise is in `cosmic/literal.tl:1-17`: a file read this
way declares values and nothing else, and everything outside the
grammar is refused by name with the line it was found on — never
thrown, because a throw in the module whose whole promise is that
reading a file cannot do anything takes the process down. That promise
is exactly what a totality property tests.

Note for whoever pulls this: PR #1346 adds an options argument to
`format` (a `"compact"` layout beside the default `"pin"`). If it has
landed, cover both layouts in the round-trip property — the layouts
admit the same values, so it is one extra loop, not a second property.
If it has not, write the property against `format(v)` alone and leave
the layout loop out; do not wait for it and do not adopt the option
here.

## Change

One new file, `_fuzz/literal_fuzz_test.tl`, in the shape of
`_fuzz/json_fuzz_test.tl` (module doc comment with an `--- env:
FUZZ_SEED FUZZ_ITERS` line, generators as `source.Recorder` draws,
each property registered on `_fuzz.driver`). Nothing else moves.

A value generator drawing the grammar's domain: nested `{string: any}`
tables to a bounded depth, with string, boolean, integer and finite
float values, and string keys and values drawn from an alphabet that
includes the bytes that make an encoder and a parser disagree —
quotes, backslash, newline, tab, `\0`, a byte above 0x7f, and the
brace/bracket/comment punctuation of the grammar itself.

Four properties:

1. **totality** — `literal.parse(s)` on arbitrary bytes (up to a
   bounded length) answers: a table or `nil, string`, never a throw
   and never a hang. This is the module's founding promise stated as a
   property.
2. **round trip** — for a generated value `v`, `literal.parse(
   literal.format(v))` deep-equals `v` (`cosmic.deep`, as
   `json_fuzz_test.tl` uses it).
3. **refusal is total too** — `literal.format` on a generated value
   from a WIDENED domain (one that also draws functions, cycles,
   non-string keys, NaN and the infinities) either returns source that
   `parse` reads back as the value, or refuses with a string; it never
   throws and never returns source `parse` then rejects. This is the
   property that catches a writer emitting what its own reader cannot
   read.
4. **mutation** — take a valid formatted source, mutate one byte or
   splice a fragment, and `parse` still answers. Same shape as the
   json properties' corrupted-encoding case.

State every domain bound in a comment block, saying for each whether
it is a real contract (the grammar refuses it) or a known defect with
its board item — the pattern `json_fuzz_test.tl` sets at its own
bounds comment. Board item `3ICDKhO3` (a flat table at depth 33
renders inline past the cap `parse` refuses) is a known round-trip
break: bound the generator's depth below it and name the item in the
comment, rather than generating a failure that is already filed.

## Non-goals

- **Do not change `cosmic/literal.tl`, `cosmic/_literal_lex.tl` or
  `cosmic/_literal_format.tl`.** If a property finds a real defect,
  that is a board capture (`gitboard new` with the seed, the
  iteration and the base64 input from the driver's own failure
  output), and the generator is bounded away from it with the item id
  in the comment. A fuzz slice that also fixes what it finds cannot
  say which of the two the green run proves.
- **Do not touch `_fuzz/driver.tl`, `_fuzz/source.tl` or
  `_fuzz/shrink.tl`.** The harness is what it is; if a property needs
  a draw the recorder does not have, that is its own item.
- **Do not add a literal entry to `.github/workflows/fuzz.yml`.** The
  workflow runs `--make test _fuzz`, which picks the new file up by
  position; nothing lists the properties.
- **Do not adopt PR #1346's `"compact"` layout as the default
  anywhere**, and do not make this slice depend on it landing.

## Acceptance

```
bin/cosmic --make ci
bin/cosmic --make test _fuzz/literal_fuzz_test.tl
FUZZ_ITERS=5000 bin/cosmic --make test _fuzz/literal_fuzz_test.tl
FUZZ_SEED=20260823 FUZZ_ITERS=200 bin/cosmic --make test _fuzz/literal_fuzz_test.tl
wc -l _fuzz/literal_fuzz_test.tl
git diff --stat -- cosmic/ _fuzz/driver.tl _fuzz/source.tl _fuzz/shrink.tl
```

- `bin/cosmic --make ci` ends `ci: PASS`. If the coverage ratchet
  fails, run exactly the regen command its failure message prints and
  commit the result.
- both `--make test` runs pass, the second at 5000 iterations per
  property, which is the depth the daily workflow multiplies rather
  than the depth CI pays.
- the seeded run passes and prints the seed it used, so a failure is
  replayable — run it twice and read the same seed line.
- `wc -l _fuzz/literal_fuzz_test.tl` prints a number at or under 500
  (the file cap; `_fuzz/url_fuzz_test.tl` is 299 and is the largest
  properties file today).
- `git diff --stat` over `cosmic/` and the three harness files prints
  nothing.

## Enablement

none needed. The harness to copy is named with its line count, the
promise under test is quoted by `file:line`, the gap is a single grep
with its measured output, the known round-trip defect to bound away
from is named by board id, and the interaction with the one in-flight
PR that touches the same module is stated both ways.
