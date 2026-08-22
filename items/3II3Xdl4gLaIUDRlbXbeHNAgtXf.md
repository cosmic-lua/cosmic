## Goal

G8 — the flow system. `_work/gitverbs.tl` has run out of room, and it
is the file nearly every remaining flow item must edit. Split it along
the seam the module already has, so the next five slices have
somewhere to land.

## Evidence

Measured 2026-08-22 at board head `98b1c6bf`: `wc -l <
_work/gitverbs.tl` is **485**, fifteen lines under the 500-line lint
cap. Every one of these open G8 items must edit it —

- `3I9igGsG` (a PR shared by two in-flight items) — `cmd_move`
- `3IFUskgH` (a research slice reaching check without a PR) —
  `cmd_move`
- `3ICGEn7b` (rework pushing to the PR's own branch) — `cmd_move`
- `3IFWAdlL` (no verb renames an item) — a new verb
- `3ID0uFdf` (no verb sets an item's repo) — a new verb
- `3IEv60qj` (`done` from land asserts completion it never checked) —
  `cmd_done`

— and fifteen lines does not fit one of them, let alone two at once.

The cost is already paid, twice, in one afternoon. whilp/cosmic#1321
had to move `cmd_check` into `_work/gitview.tl` and the same-phase
write into `gate.set_in_place` purely to fit, and the board carries
`3IHsna5c` recording three slices that each measured this file's
headroom correctly and together overflowed it. Both were forced
relocations discovered mid-merge, which is the expensive place to
discover them.

## Change

Move the GRAPH verbs out; leave the PHASE verbs behind. This is the
same "split by subject" the module set already uses — `gitview` holds
the whole-board reads, `gitshow` the single-item read, `gitverbs` the
mutations — carried one level further.

1. **New `_work/gitgraph.tl`** carrying, moved VERBATIM (no logic
   changes, no renames, no reordering):
   - `cmd_new` (`_work/gitverbs.tl:45-109`)
   - `cmd_attach` (`:110-182`)
   - `cmd_block` and its `unblock` half (`:183-260`)

   These are the verbs that shape the GRAPH — a parent edge, a blocker
   edge, an item's existence — and roles derive from the graph, so
   they are one subject. Carry each function's doc comment with it,
   and carry over exactly the requires the moved code uses.

2. **`_work/gitverbs.tl` keeps** `cmd_init`, `cmd_spec`, `cmd_move`,
   `cmd_done`, `cmd_sync` — the phase crossings plus the two
   housekeeping verbs — and drops the moved names from its record and
   its returned table. Update its module doc comment to say what it
   now holds and to name `_work.gitgraph` as the other half.

3. **`_work/gitboard.tl`** requires the new module and points the
   `new`, `attach`, `block` and `unblock` dispatch lines at it
   (`grep -c 'verbs\.' _work/gitboard.tl` is 8 today; four of those
   move). `wc -l < _work/gitboard.tl` is 319.

4. **Tests follow their subject.** `_work/gitverbs_test.tl` is 479
   lines; move the cases that drive the moved verbs into a new
   `_work/gitgraph_test.tl`, carrying whatever fixture helpers they
   need. A test that drives BOTH halves (a decomposition that also
   asserts a phase) stays in `gitverbs_test.tl` and requires both
   modules — do not split a single test function.

## Non-goals

- **No behaviour change of any kind.** This is a move. No verb gains
  or loses a refusal, a message, a parameter, or a return. Every
  verdict-line string stays byte-identical — `status`, `next` and the
  `work` skill all read them.
- Do NOT take the opportunity to fix anything you notice in the moved
  code. Report it instead; it becomes a board item.
- No change to `_work/gitgate.tl`, `_work/flow.tl`, `_work/item.tl` or
  `_work/store.tl`.
- No new verb, and no change to the CLI surface: `gitboard help` must
  list exactly the same verbs with the same summaries and options.
- `cmd_init` stays in `gitverbs.tl` despite creating the repository —
  it is not a graph mutation and moving it would mean a third home.

## Acceptance

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/gitverbs_test.tl _work/gitgraph_test.tl`
  ends `test: PASS`.
- The point of the exercise, as bounds: `wc -l < _work/gitverbs.tl`
  **≤ 320** (it is 485 today) and `wc -l < _work/gitgraph.tl` ≤ 300
  and `wc -l < _work/gitgraph_test.tl` ≤ 400 and
  `wc -l < _work/gitverbs_test.tl` ≤ 400.
- `o/bin/gitboard help` lists the same 19 verbs it lists today —
  capture `o/bin/gitboard help` before the change and `diff` it
  against the same output after; the diff must be empty.
- `o/bin/gitboard status` and `o/bin/gitboard next` both still end in
  their normal verdict lines against the live board.

## Enablement

none needed — the split follows the `gitview`/`gitshow` precedent
established in whilp/cosmic#1317, whose commit message states the
same reasoning (the one read of a single item left the module of
whole-board reads because that module was against the cap). The
wrong turn to predict is improving the moved code in passing: a
behaviour change hidden inside a 200-line move is invisible to
review, which is why `Non-goals` forbids it and why the
`gitboard help` diff is an Acceptance command rather than a claim.
