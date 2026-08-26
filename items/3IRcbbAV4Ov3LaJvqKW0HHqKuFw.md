## Goal

The parent `3IOFN9bn` is the hypothesis that the compact literal
encode pays more for its Teal guard than for its C encoding, and the
`optimize` skill makes the compare gate that hypothesis's acceptance.
The gate cannot see it: `_perf` has no compact scenario, so every
number the parent quotes is ad hoc and no fix to it could be
regression-gated. This slice is the instrument, not the fix.

## Evidence

Measured 2026-08-26 against main `3053b87d`:

- `grep -n 'name = "' _perf/bench/literal_bench.tl` → four scenarios,
  at `:111`, `:121`, `:131`, `:140`: `literal_parse_floor`,
  `literal_format_floor`, `literal_parse_pin`, `literal_format_pin`.
- `grep -c compact _perf/bench/literal_bench.tl` → `0`. No scenario
  anywhere in `_perf/bench/` exercises the compact layout
  (`grep -rc 'layout' _perf/bench/*.tl | awk -F: '$2>0'` prints
  nothing).
- The layout is public API: `cosmic/literal.tl:457-463` reads
  `opts.layout` and dispatches `"compact"` to
  `_literal_format.format_compact`.
- **Correction to the parent's citation.** It cites the domain walk as
  `cosmic/_literal_format.tl:395-407`; that range is `format_compact`
  itself. `is_compact_writable`, the walk, is `:339-362`, and its two
  per-item predicates are `is_compact_string` at `:61-63` (one
  `s:find("\27", 1, true)`) and `is_compact_scalar` at `:81-92`.
- `wc -l < _perf/bench/literal_bench.tl` → `159`: 341 lines of headroom
  under the 500-line cap.
- The existing `FLOOR` fixture is compact-writable as built, so it
  exercises the C path rather than the renderer fallback: `build_floor`
  (`:52-59`) makes 100 rows keyed `cosmic/module%03d.tl` holding
  `{covered = i * 3, total = i * 4}` — string keys with no byte 27 and
  no reserved word, integer scalars only.

## Change

**`_perf/bench/literal_bench.tl`** — add one scenario, and nothing
else:

- A `local FLOOR_COMPACT_SOURCE = check.must(literal.format(FLOOR,
  {layout = "compact"}))` is NOT needed; the scenario formats, it does
  not parse a prebuilt source.
- Add a fifth entry to the `scenarios()` table, placed immediately
  after `literal_format_floor` (`:121-129`) so it meets the same heap
  as the floor scenario it is compared against:

  ```teal
  {
    name = "literal_format_floor_compact",
    fn = function(_: any): any
      return (literal.format(FLOOR, {layout = "compact"}))
    end,
    check = function(_: any, res: any): boolean, string
      return verify("literal_format_floor_compact", res, FLOOR_ROWS,
        FLOOR_KEY, "covered", FLOOR_COVERED)
    end,
  },
  ```

  `verify` parses a string result back before probing it, so the check
  holds the compact writer to the reader's bar — which is exactly the
  fidelity the parent says a fold must not move.
- Extend the module's header comment to say the file now covers both
  layouts, and why the compact one is here: it is the bulk writer whose
  guard cost the parent hypothesis is about, and a hypothesis with no
  scenario has no gate.

## Non-goals

- **No change to `cosmic/_literal_format.tl` or `cosmic/literal.tl`.**
  This slice measures; the parent's other children change the encode.
  A diff that touches either file is out of scope even if it looks
  like a win.
- **No new fixture.** The existing `FLOOR` is reused as-is; do not add
  a second, larger payload to match the parent's ad-hoc 221KB one.
  Sizing the scenario for the parent's numbers is its own question and
  would change the existing floor scenarios' heap.
- **No compare-gate run as acceptance.** Adding a scenario adds a row a
  prior baseline does not have; there is nothing to compare it against
  yet. The first compare against it belongs to whichever child
  actually changes the encode.
- **No renaming or reordering of the four existing scenarios** — their
  names are the keys a stored baseline JSON is joined on.
- **`whilp/cosmopolitan` is not touched.** The C-encoder fold the
  parent names as one candidate is a separate item under the same
  parent, carrying that repo.

## Acceptance

Run from the repo root:

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _perf/perf_test.tl` passes: that test derives
  its module list from `_perf/bench/*_bench.tl`, runs every scenario
  end to end at tiny settings, and fails a scenario with no functional
  check or a duplicate name.
- `grep -c 'literal_format_floor_compact' _perf/bench/literal_bench.tl`
  prints `2` (today: `0`) — the name and its `verify` argument.
- `bin/cosmic --make run _perf/run.tl --out o/perf/current.json` ends
  with the run's own verdict line, and
  `grep -c 'literal_format_floor_compact' o/perf/current.json` prints
  `1` or more. `o/` is build output and is never committed.

## Enablement

none needed. The scenario record shape, the `verify` helper and the
`check.must` fixture idiom are all in this one file already, and
`_perf/perf_test.tl` picks the new scenario up with no registration
step — the module list is derived from the glob.
