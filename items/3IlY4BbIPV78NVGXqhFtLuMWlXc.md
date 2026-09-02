## Evidence

Reported by two builders on 2026-09-02 (cosmic-lua/cosmic#1629 on the
board branch; the builder of item 3IlI2gqd on main). The committed
`.cosmic-coverage` floors differ widely from what a developer's
environment measures: on main, `bin/cosmic --make coverage --baseline`
rewrites 173 rows (e.g. `cosmic/child/init.tl` floor 0/212 vs measured
212/246; many totals differ by 2x); on the board branch it raises 9
rows on five files the PR did not touch (`_work/action.tl` 169/172 vs
173/176, `gitshow`, `gittake`, `gitview`, `guidance`). The ratchet
refuses only declines, so the gate stays green, but AGENTS.md's
"`--make coverage --baseline` rewrites the committed floor" is unsafe
advice locally: a builder who runs it commits an environment's worth
of unrelated rows, and a builder who does not run it hand-edits the
one row they need. Re-measure at pull time: `bin/cosmic --make
coverage --baseline && git diff --stat .cosmic-coverage`.

## Change

Establish which environment the floor is recorded in (CI's `ci`
lane, by its loopback namespace and privileged identity, is the
likely answer: totals differ where sandbox and quicksand tests are
skipped locally) and make that explicit: the baseline verb refuses,
or warns and writes only the rows whose files the working tree
changed, unless `COSMIC_COVERAGE_ENV` (or an equivalent marker CI
sets) says this is the recording environment. Document the recording
environment in AGENTS.md's coverage paragraph. One PR per repo branch
that carries a `.cosmic-coverage` (main and board).

## Non-goals

- No change to the ratchet's decline rule.
- No rebaseline of unrelated rows in this item.
