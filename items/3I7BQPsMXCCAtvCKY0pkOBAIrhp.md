## Goal

G9, via the ratchet-unification container: one floor format for every
committed floor. The coverage floor's rows are pairs, a row must be ONE
line for `merge=union` to merge rows, and nothing today can write a
one-line nested table — this is the enabler 3I1J9Xhg is blocked on.

## Owner decision, 2026-08-19

Keep the grammar closed and add the inline LAYOUT rule; sequence
admission was considered and declined. (Confirmed by the goal owner.)

## Change

Measured 2026-08-19 at `f420391` — the formatter is the private module
`cosmic/_literal_format.tl` (216 lines), so no public contract moves:

1. In `render_table` (line 119), the nested-table branch (~137–142)
   currently always emits `lead .. "{"`, recurses, then `pad .. "},"`.
   New rule: when EVERY value of the nested table is a scalar
   (vacuously true for the empty table), render the whole entry on one
   line — `lead .. "{ " .. <sorted "[key] = value," entries joined by
   one space, last comma kept> .. " },"` (empty: `lead .. "{},"`). A
   nested table containing a table keeps today's multi-line layout.
   Key sorting, quoting, `MAX_DEPTH`, and every refusal are untouched.
2. Update the module doc's layout paragraph (~156–165) — it states the
   fixed layout, and the inline case joins that statement.
3. **Tests** (`cosmic/literal_test.tl`, 381 lines, 119 of headroom):
   `parse(format(v))` round-trips a flat nested table; the rendered text
   for `{["a.tl"] = {["covered"] = 1, ["total"] = 2}}` is exactly three
   lines; a doubly-nested table stays multi-line; the empty nested
   inline form parses back. The stated `format` contract "output is a
   fmt fixpoint" (literal.tl:389) must hold for the new layout — assert
   it the way the existing fixpoint coverage does, and if
   `cosmic --check fmt` rewraps the one-line form, that is a refusal of
   this design to surface at implementation, not to paper over.

Blast radius, measured: no committed file changes bytes — the two
`_build` floors hold only scalars (`grep -c '= {' _build/casts_baseline.tl`
is 0), and the only other writer is the coverage collector's `.cov`
bodies under `o/` (uncommitted; content-keyed caches re-key once).

## Non-goals

- no grammar change: sequences stay refused by parse AND format; no new
  options on `format`/`format_file`; `_tool/floor.tl` untouched (it
  forwards).
- no consumer migration — 3I1J9Xhg does the coverage-floor conversion
  and stays a separate, blocked item.

## Acceptance

- `bin/cosmic --make test cosmic/literal_test.tl` ends
  `test: PASS (1 files)`.
- `o/bin/cosmic -e 'print((require("cosmic.literal").format({["a.tl"] = {["covered"] = 1, ["total"] = 2}})))'`
  prints exactly 3 lines.
- `bin/cosmic --make ci` ends `ci: PASS` with no committed floor
  changing bytes (`git diff --stat` shows only source and tests).

## Enablement

none needed — the render branch, doc paragraph, headroom, writers, and
the fixpoint contract are all measured above; the one open risk (fmt
rewrapping) is named with its resolution path.
