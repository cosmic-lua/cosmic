# Performance hypothesis backlog

Companion to `lib/perf/OPTIMIZE.md` (the operating manual — read that
first). This directory is the log: one file per hypothesis, each a
concrete, evidence-backed starting point for one optimization round.

## Layout

One entry per file, named `NNN-slug.md` (zero-padded, e.g.
`004-startup-runtime-boot-floor.md`). One entry never grows past a few
dozen lines, so the repo's 500-line-per-file cap is never a reason to
split or archive anything again. Numbers are permanent IDs — never
renumber or reuse one, even for rejected entries.

Every entry starts with the same fields:

```markdown
# NN. short imperative title

- status: open | done (YYYY-MM-DD) | rejected (YYYY-MM-DD)
- layer: cosmic | cosmopolitan
- scenario: the perf scenario(s) that measure it
```

- `layer: cosmic` — the fix lives in this repo (Teal wrappers,
  `lib/cosmic/*.tl`).
- `layer: cosmopolitan` — the fix lives in whilp/cosmopolitan (C
  bindings, Lua runtime, APE loader, zip filesystem). Work these with
  the loop in `lib/perf/optimize/cosmopolitan.md`.

## How to work the backlog

1. Find open entries: `grep -l "status: open" lib/perf/backlog/*.md`
2. Pick ONE. Run the loop in `lib/perf/OPTIMIZE.md` (for
   `layer: cosmopolitan`, also read `lib/perf/optimize/cosmopolitan.md`).
3. Update the entry's file in the same commit as the fix:
   - `done` — record the commit, and before/after numbers copied from
     `perf-compare` output.
   - `rejected` — record the measured numbers and why the hypothesis
     was wrong. Rejected entries stay in the directory forever; they
     save the next agent from re-testing a dead end.
4. Add new entries as `status: open` files (next unused number) when a
   report line or code read suggests one. An entry needs evidence — a
   measured number, a code path read, a sibling comparison — not just a
   guess.
