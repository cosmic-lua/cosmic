
## Ended 2026-08-19: core halves landed; docs half folded into 3I4B9H4F

Measured at `f420391`: both core changes landed with PR #1209's merged
version (`12e16174`). `_eval/score.tl`'s `stage_scoring_copy` mirrors
the run-dir argument into a fresh mkdtemp staging copy — "score.tl never
writes into its input" is its stated contract, `results.json` defaults
to a temp `--out`, and the doc comment names and closes the
relative-argv double-resolution bug this item's Gap 1 measured (staging
is always absolute, so `cosmic.child`'s in-child chdir cannot re-resolve
argv[0]). The remaining docs half — the ready bar's
run-literally-from-the-root rule — is carried by 3I4B9H4F's decompose.md
slice (in `ready`), which cites this item's evidence; two rules, one
file, one PR.
