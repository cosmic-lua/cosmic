G3, under `3IOK4SZH` — the third of the dynamic-value boundary's three
closures: the 17-site residue that no declaration can fix, because the
value genuinely is unknown where it crosses.

Measured 2026-08-25 against `dbca9e77` with
`git ls-files '*.tl' | xargs grep -n -- "-- cast: .*from any"`:

- **`pcall` verdicts** — `cosmic/sqlite/extras.tl:32,60,102` (`why as
  string`, `verdict as string`); `cosmic/_teal_engine.tl:248`
  (`result_or_err as TlResult`); `cmd/cosmic/main.tl:480,482`
  (`results[1] as boolean`, `results[2] as string`).
- **`package.loaded` / indirected stdlib** —
  `cosmic/_seal_coverage.tl:21,22,26` and
  `cosmic/coverage/init.tl:93,96,98` reach a module through a table index
  to keep the checker from binding it statically;
  `cosmic/coverage/init.tl:124` is the `os_mod["exit"]` indirection.
- **Test and harness sites** — `_perf/harness_test.tl:16,43`;
  `_tool/benchmark.tl:182`; `_perf/run.tl:130`; `cosmic/rand_test.tl:145`
  (`rand.choice({...}) as string`, which may instead be a generic-return
  fix in `cosmic/rand.tl`).

`cosmic/coverage/init.tl` carries six `from any` casts in all; only the
three named above are this class — the other three are the binding
boundary class and close in `whilp/cosmopolitan`, so a slice here must
not claim the file whole.

The mechanism is an `is` guard at the point of use rather than a cast,
which is a per-site judgment, not one API. Refinement's job is to decide
which of the 17 are genuinely irreducible (and so keep a cast with a
better-than-`from any` reason) and which have a guard available — and to
check whether `cosmic/rand.tl`'s `choice` should return the element type
instead, which would take its site out of this class entirely.
