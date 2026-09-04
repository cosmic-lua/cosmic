## Evidence

Builder build-rNh1_b1Se-41598fb4 (2026-09-04, working «rNh1_b1Se», PR #1697
in the `board` worktree at the repo root) ran `bin/cosmic --make coverage
--baseline` while investigating a coverage question, and it rewrote roughly
13 unrelated rows of `.cosmic-coverage`, not just the row(s) its own change
touched. Caught only because the builder inspected `git diff
.cosmic-coverage` before committing and reverted the unrelated rows by
hand, keeping only the two its change actually affected.

AGENTS.md documents this exact failure mode for the main `cosmic` repo:
"`--make coverage --baseline` therefore refuses anywhere
`COSMIC_COVERAGE_ENV=1` is not set — that lane sets it for itself; a
developer's machine never should." The board worktree (`o/board`, built
from the `board` branch's own `cosmic --make build`) apparently does not
carry — or does not enforce — that same guard: the `--baseline` rewrite
went through without refusal in this environment (not the CI recording
environment).

## Change

Confirm first: run `bin/cosmic --make coverage --baseline` in a scratch
`board`-branch worktree without `COSMIC_COVERAGE_ENV=1` set, and check
whether it refuses (per AGENTS.md's stated behavior) or silently rewrites
`.cosmic-coverage`. If it silently rewrites: find wherever the `board`
branch's own build defines the `coverage --baseline` guard (mirror of
whatever gates it in the main `cosmic` repo — likely the same source file,
since `board`'s tooling is built from `cosmic --make build` same as
`main`) and apply the same `COSMIC_COVERAGE_ENV=1` refusal there. If it
already refuses and the builder's environment happened to carry that env
var set some other way, narrow this item's Evidence instead of
implementing a redundant guard — report back rather than guessing.

## Non-goals

Not a general coverage-tooling audit — scoped to confirming and (if
missing) closing this one gap between documented behavior and the board
worktree's actual behavior.
