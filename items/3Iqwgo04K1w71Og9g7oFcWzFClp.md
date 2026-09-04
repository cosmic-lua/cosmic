# friction: 2026-09-04 work9 (/work 9 --routine)

## orchestrator
- goal: open the friction log before the first board verb, per
  `skills/work/friction.md` step 1.
  actually happened: ran `sync`, `next`, `show`, and `take fuXz_MkSX`
  before creating this file — four board verbs ahead of the log.
  contributed: the skill bootstrap text (`skills/work/SKILL.md`) states
  the loop steps (sync, reconcile, review, build, refine) without
  repeating the friction-log-first rule inline; that rule lives only in
  `friction.md`, which is not read until the orchestrator goes looking
  for it deliberately.
  improvement: `skills/work/SKILL.md`'s `--routine` bullet already
  points at `friction.md`; the countermeasure with more leverage is in
  the tool itself — `gitboard sync` (or the first verb of a `--routine`
  pass) could print a one-line reminder ("open the friction log before
  the next verb") the first time a session runs under `--routine`, so
  the rule is enforced at the gate rather than relying on the session
  to read a doc section before acting. Doc-only fix in the meantime:
  restate the ordering rule inline in `SKILL.md`'s `--routine` section
  itself rather than only in `friction.md`.

- goal: fill exactly the placeholders `gitboard brief builder FacE_b8sh`'s
  verdict line named (`<WORKTREE>`, `<BOUNCE_CONTEXT>`, `<HEAD_SHA>`)
  before pasting the body to the agent.
  actually happened: `<HEAD_SHA>` does not appear as a real template
  slot anywhere in the emitted body — it only appears twice inside the
  pasted spec's own Evidence/Change prose (lines 40, 55 of the saved
  brief), quoting the CODE this very item is about to fix
  (`brief review` currently "fills `<HEAD_SHA>` from a placeholder");
  one extra `grep -n HEAD_SHA` and a read of the surrounding lines
  (~2 tool calls, under a minute) to confirm it was spec text, not an
  unfilled slot, before proceeding.
  contributed: the verdict line's placeholder list is naive
  string-matching over the whole rendered body — it does not
  distinguish a literal `<TOKEN>`-shaped string quoted inside the
  spec from an actual unfilled placeholder the template itself left
  open, so any item whose spec happens to describe angle-bracket
  placeholder syntax (as a bug report about placeholders would) makes
  the verdict line lie about what still needs filling.
  improvement: `gitboard brief`'s placeholder scan should only match
  its own template's placeholder positions (a known, fixed set per
  kind), never text sourced from the spec sidecar — a gate in the
  tool, since a doc note would not stop the next spec that happens to
  quote `<...>` syntax from tripping the same false positive.

## build fNbu_EfXc (claude, orchestrator subagent) — PR #1690, 247s, 25 tool calls, ~1.68M tokens (cache-read heavy)
- goal: change `_perf/baseline.tl`'s default `--asset` from `perf.json`
  to `cosmic-lua` and reword `_perf/compare_test.tl:245`'s comment,
  per the spec's re-measure-at-pickup note.
  actually happened: clean run — 25 tool calls, first edit at call 6,
  ci green on the first `--make ci`, one repeated read of
  `_perf/baseline.tl` (6x) while locating and editing all three cited
  sites plus running the mutation test. Agent's own report: the
  constant's name had drifted from `DEFAULT_ASSET` to `ASSET_NAME`
  (anticipated by the spec's "line numbers move" caveat) but nothing
  else moved.
  contributed: n/a — the spec's re-measure discipline held up.
  improvement: none needed; agent reported no friction.

## build Fthm_rSFG (claude, orchestrator subagent) — PR #1691, 256s, 18 tool calls, ~1.13M tokens (cache-read heavy)
- goal: seed `o/bootstrap/cosmic` and `o/bootstrap/cosmic.pin` into
  `_make/fixpoint_test.tl`'s `seed_pins` so the fixpoint test's gen2
  build stops refusing on the declared-but-absent bootstrap read.
  actually happened: clean run — 18 tool calls, first edit at call 9,
  reproduced the exact failure from the spec before editing, one
  repeated file read/edit (3x) and one repeated fixpoint-test rerun
  (2x) around the mutation test (stash the fix, reproduce, pop the
  stash). Agent's own report: spec matched the tree exactly, no
  judgment calls needed.
  contributed: n/a.
  improvement: none needed; agent reported no friction.

## build kHQO_XvLX (claude, orchestrator subagent) — PR #1692, 283s, 24 tool calls, ~1.73M tokens (cache-read heavy)
- goal: add `test_every_gate_lane_strips_includeif_and_fetches_the_board_ref`
  to `_build/workflows_test.tl`, deriving the `--make ci` job set and
  asserting each strips `includeIf.gitdir` and fetches `origin/board`.
  actually happened: clean run — 24 tool calls, first edit at call 9,
  evidence re-run matched the spec exactly (same line count, same
  grep results), mutation test (delete `release.yml`'s fetch line,
  confirm the new test names it, restore) passed on the first try,
  `bin/cosmic --make ci` green (~4 min, includes coverage). One
  repeated file read/edit (2x) and one repeated narrow-test rerun (2x)
  around the mutation test.
  contributed: n/a.
  improvement: none needed; agent reported no friction.

## orchestrator
- goal: spawn reviews for the two PRs that landed mid-pass (#1690,
  #1691) as soon as they were ready, per "reviews outrank pulls."
  actually happened: checked CI on both via
  `mcp__github__pull_request_read get_check_runs` before claiming
  either review — #1690 had all 5 checks green, #1691's `repro` job
  was still `in_progress`. Claimed and spawned the review for #1690
  only; held off on #1691's review claim until its CI settles, to
  avoid the exact waste «FacE_b8sh» (itself in this wave) is fixing:
  a review agent burning tool calls only to stop immediately because
  CI was still running on the head it read.
  contributed: `gitboard help review` rule 1 ("Red or still running
  ends the review immediately") plus «FacE_b8sh»'s own Evidence
  section describing the identical waste from a prior pass.
  improvement: none — the doctrine already says to check first; the
  friction would have been in NOT checking. Filed here as a positive
  observation, not a countermeasure to file.

## orchestrator
- goal: fill the wave to N=9 with disjoint pulls from the 23 pullable
  todo items, after the four `next` alternates for the main-repo items
  ran out.
  actually happened: the next four `next` alternates (`HKdD_OAYN`,
  `rNh1_b1Se`, `Elus_cLzz`, plus later `CTe6_lxfv`) turned out to be an
  eight-item cluster all touching `_work/brief.tl` or
  `_work/brieftext.tl` (per `HKdD_OAYN`'s own Evidence, which had
  already hand-compared six of the eight `show` outputs in a prior
  pass). Read `HKdD_OAYN`, `rNh1_b1Se`, and `Elus_cLzz`'s full specs
  (3 `show` calls, ~1 minute) to confirm the collision before deciding
  to pull only one item from the whole cluster (`FacE_b8sh`, already
  claimed) and skip the rest this wave; `CTe6_lxfv` was pulled instead
  because its Change touches `_work/doctrine.tl`/`_work/doctrine_test.tl`,
  outside the cluster.
  contributed: `HKdD_OAYN` is itself the board's own fix for this
  exact gap (`show`/`next` surfacing file-overlap between open items)
  — it is not yet built, so this pass paid the same hand-comparison
  cost `HKdD_OAYN`'s Evidence already measured once.
  improvement: none beyond what `HKdD_OAYN` already proposes; once it
  lands, `show`/`next` surfacing the overlap directly removes this
  cost for every future pass. Left `HKdD_OAYN`, `rNh1_b1Se`, and
  `Elus_cLzz` untaken rather than risk it being built as a `_work/brief.tl`
  edit that then collides with `FacE_b8sh`'s in-flight PR on the same
  file.

## candidates
- gitboard brief's placeholder-verdict false positive on spec text
  shaped like a placeholder (`<HEAD_SHA>` quoted inside «FacE_b8sh»'s
  own spec) — not filed: needs a look at `_work/brief.tl`'s actual
  placeholder-scan implementation to write a correct spec, which this
  pass didn't have time for; stays here for triage.
- a `--routine` pass's first board verb reminding the session to open
  the friction log first (this pass opened it four verbs late) — not
  filed: the doctrine already names the fix (`skills/work/SKILL.md`
  restating the ordering rule inline) and it is a one-line doc edit a
  refiner can spec directly from this entry; stays here for triage.
