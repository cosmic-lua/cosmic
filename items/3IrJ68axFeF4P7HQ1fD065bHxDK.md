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

### Confirmed 2026-09-04 (research pass, isolated `board`-branch worktree)

Reproduced exactly, with no `COSMIC_COVERAGE_ENV` set anywhere in the
shell: `bin/cosmic --make coverage --baseline` ran to completion (exit
0), printed no refusal, and silently rewrote 15 of 16 rows in
`.cosmic-coverage` (3 lowered, 12 raised) — none of them touched by any
pending change, since the worktree was otherwise clean. The file was
restored by hand afterward; the worktree was left clean (`git diff`
empty).

**Root cause is a stale pin, not a missing guard in board-owned code.**
The `board` branch defines no `cmd/cosmic`, no `_make/`, and no `3p/`
tree of its own — `bin/cosmic`'s trust-root script only attempts a tree
build of `o/bin/cosmic` when `o/3p` exists (it doesn't here), so every
`--make` verb on this branch, including `coverage --baseline`, always
runs under whatever release `bin/cosmic.pin` names. There is no second
copy of `_make/policy.tl` (or any guard logic) living in the board tree
to patch — the entire coverage/baseline implementation is main's
`_make/policy.tl`, embedded wholesale in the pinned release binary.

This is already known and documented, not a new discovery:
`README.md`'s own doctrine paragraph (`.cosmic-coverage is recorded in
the board workflow's ci job`) states verbatim: "the coverage machinery
itself lives on `main` (`_make/policy.tl`, embedded in whatever release
`bin/cosmic.pin` here resolves to), not in this tree, so `--make
coverage --baseline` run from a private clone still rewrites the whole
floor with THIS machine's measurement ... once `bin/cosmic.pin` carries
a release built from a `main` that refuses `--baseline` outside
`COSMIC_COVERAGE_ENV=1` ..., the same refusal applies here
automatically, and `board.yml`'s `ci` job already sets that marker for
itself so a whole-floor rewrite stays possible from the one place it
should be." `.github/workflows/board.yml` does indeed already set
`COSMIC_COVERAGE_ENV: "1"` for its own job, with a comment stating "this
marker is inert until that pin carries it, and load-bearing from the
moment it does."

**The pin is confirmed stale relative to the guard.** The `board`
branch's `bin/cosmic.pin` (as of this research) names
`2026-08-31-a5b36f4` (commit `a5b36f4a`, "Move to Lua 5.5.1 (#1594)").
Extracting that release binary's own embedded `.tl/_make/policy.tl`
(`unzip -p o/bootstrap/cosmic .tl/_make/policy.tl`) shows **no**
`is_recording_env`, `COSMIC_COVERAGE_ENV`, or `REFUSED` string anywhere
in it — `write_baseline` in that release writes the rewrite
unconditionally. On the main `cosmic` repo's current tree, `_make/policy.tl`
has `is_recording_env()` (checks `os.getenv("COSMIC_COVERAGE_ENV") ==
"1"`) gating `write_baseline`'s entry, printing `"coverage --baseline
REFUSED: this machine is not the ..."` and returning non-zero when unset.
Main's own `bin/cosmic.pin` (as of 2026-09-04) points at release
`2026-09-04-f9f31a2`, and `git merge-base --is-ancestor` confirms that
commit's history includes the guard. So: **main's current pin already
carries the fix; the board branch's pin does not.**

There is exact precedent for the needed action: commit `c9867d10` ("Bump
board's cosmic.pin to main's release and regen coverage baseline
(#1505)") previously bumped `bin/cosmic.pin` (url + sha256) and
regenerated `.cosmic-coverage` together in one commit, for an unrelated
pin-staleness gap (`cosmic.shape` module-not-found). This is the same
shape of fix, needed again for this gap.

### Reviewed 2026-09-04 (review-065b_HxDK-07d7b9b9, request-changes)

Every probe above was independently re-run and matched exactly (pin
values, guard presence/absence, live reproduction counts, ancestry,
README/board.yml text, precedent commit). The one gap: this item's
`## Change` read as prose instructions for a future implementer, but
research's own bar (`gitboard help bar`) requires findings to become
items, never a widened diff or unattached implementer prose — and no
such follow-up item existed. Fixed below: the fix is now filed as its
own item.

## Change

The fix this research identified is filed as item «sxzp_M1yR»
(`3IrfJ5s62kkTyyzSWGqsxzpM1yR`, "board pin predates the coverage
--baseline COSMIC_COVERAGE_ENV guard: bump bin/cosmic.pin to main's
release"), attached under the same parent
(`3HyRdT1JQS7pCPgF3sZi2Deo66q`, "G8 — the flow system") as this item,
carrying the pin-bump-and-regen steps this research pass drafted. This
item's own deliverable — confirming the gap exists and identifying its
exact fix — is complete; the fix itself is «sxzp_M1yR»'s to build.

## Non-goals

Not a general coverage-tooling audit — scoped to confirming and closing
this one gap between documented behavior and the board worktree's actual
behavior. Not building the fix here — that is «sxzp_M1yR»'s scope.
