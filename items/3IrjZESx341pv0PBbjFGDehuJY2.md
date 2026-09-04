# friction: 2026-09-04 work9 (/work 9 --routine)

## orchestrator
- goal: fill a 9-wide wave with disjoint band-1 builds/research.
  actually happened: only 5 of the top band-1 pullable items were
  file-disjoint from each other (Elus_cLzz, zvR2_ujhh, F6zo_pi1N,
  fmFu_8dce, 065b_HxDK); every other band-1 candidate `next` offered
  touched `_work/brief.tl`/`_work/brief_test.tl` or `_work/doctrine.tl`
  (a cluster of items all reworking the same brief-emission code).
  contributed: same collision cluster «14A3_CTsE» (an earlier pass
  today) already named — no new gap, the disjointness rule working as
  designed.
  improvement: none; noting for continuity so a future pass does not
  re-diagnose the same cluster from scratch.
- goal: use spare width for refine/triage per orchestrate step 5.
  actually happened: read the two open unparented friction-log roots
  from earlier passes today («NJCj_HQIX», «14A3_CTsE»), filed their
  two "small enough to spec directly" candidates as new band-1 items
  («l4mQ_rPh2», «4B0h_t06K»), and attached both logs under the shared
  goal root («i2De_o66q») so they are placed and workable. Left two
  candidates unfiled (a rework-brief auto-fill needing a fuller spec,
  and an attach-defaulting design choice between two approaches) —
  both need a decision this pass didn't have grounds to make alone.
  contributed: n/a — this is the intended triage action.
  improvement: none.

## build Elus_cLzz (claude, build-Elus_cLzz-07d7b9b9) — accepted (PR #1700), 338s wall, 53 tool calls
- goal: locate the exact friction paragraph text the spec names
  (`skills/work/friction.md`'s "what the agent reports" block).
  actually happened: `skills/work/friction.md` doesn't exist in the
  board-branch worktree — only `_work/`, `bin/`, `cmd/`, `items/` live
  there. One failed `wc -l` (transcript confirms: `wc:
  skills/work/friction.md: No such file or directory`) before finding
  the doc in the separate main-repo checkout at
  `/home/user/cosmic/skills/work/friction.md`. ~10s, one extra call.
  contributed: the spec cites a `main`-branch path while the agent
  builds on `board` — a genuinely different tree — and nothing in the
  brief or spec flags that the doc isn't in this worktree.
  improvement: a spec citing a path outside the target base could name
  which checkout it lives in; low value for a one-off ~10s cost, not
  filed.
- goal: satisfy the coverage ratchet for the new file cheaply.
  actually happened: `--make ci` failed "not in baseline";
  `COSMIC_COVERAGE_ENV=1 --make coverage --baseline` shifted 14
  unrelated rows per AGENTS.md's documented sensitivity warning — the
  agent diffed against a backup and hand-merged just the one new row
  (transcript: 2 repeated touches of `.cosmic-coverage`, part of the
  53 total calls). Reported by the agent as already covered by
  AGENTS.md's documented procedure — no gap, just the few calls it
  costs to execute carefully.
  contributed: n/a — working as documented.
  improvement: none.
- transcript: 207 events, 53 tool calls (Bash 35, Edit 6, Read 9,
  Write 1, ToolSearch 1, create_pull_request 1), first edit at call
  13, one error (the `wc` miss above), 3 files re-touched more than
  once (`brief.tl` x5, `brief_test.tl` x4, `.cosmic-coverage` x2) —
  consistent with iterating types/tests to green, not thrashing.

## research 065b_HxDK (claude, research-065b_HxDK-07d7b9b9) — recommendation applied (spec revised, result:c22b4d9), 404s wall, 36 tool calls
- goal: apply the spec's `## Change` instruction literally ("find
  wherever the board branch's own build defines the guard ... apply
  the same guard there").
  actually happened: that instruction assumed a fact that was false —
  `board`'s tree carries no `_make/policy.tl` of its own to patch; all
  `--make` behavior on `board` is delegated wholesale to whatever
  release `bin/cosmic.pin` names. Establishing the true shape (~6 tool
  calls: `bin/cosmic` trust-root script, `git worktree list`, grepping
  the board tree for guard strings, extracting the pinned binary's own
  embedded `_make/policy.tl`) cost real time before the spec's premise
  could be corrected rather than followed.
  contributed: `README.md` in the board worktree already documents
  this delegation model in the exact paragraph that answers the
  item's question, but nothing in the item's own spec cross-referenced
  it — the agent found it only after independently re-deriving the
  same fact by git archaeology.
  improvement: a spec whose Change assumes a fact about repo structure
  ("board owns a copy of X") that a README already states either way
  could name the README section to check first; not filed — too
  narrow to generalize into a gate.
- goal: date-order two commits by ancestry to confirm which pin
  predates a guard-adding commit.
  actually happened: `git merge-base --is-ancestor` returned a false
  negative for `a5b36f4a` vs. the guard commit (neither is an ancestor
  of the other, despite `a5b36f4a` clearly predating it by date/PR
  number) — the board repo's history isn't strictly linear across the
  sampled range. Cost ~2 extra tool calls double-checking dates before
  falling back to the authoritative check (extracting the actual
  pinned binary's embedded source), which should have been the first
  move rather than the third.
  contributed: no doctrine gap — a known git-topology trap, reported
  by the agent as its own lesson for next time.
  improvement: none generalizable; noted for the record.
- transcript: 155 events, 36 tool calls (Bash 31, Grep 3, Read 1,
  Write 1), zero errors, zero repeated commands — a clean investigation
  once past the two detours above.

## build fmFu_8dce (claude, build-fmFu_8dce-07d7b9b9) — PR #1701 opened, awaiting review, 978s wall, 121 tool calls
- goal: locate every file that needed the new `auto_merge`/queued-state
  field, when the spec's `## Change` named only `action.tl`/`flow.tl`.
  actually happened: the data has to originate in `gh.tl`/`review.tl`,
  neither named by the spec, confirmed only via a repo-wide grep; found
  the exact two-commit precedent shape (decision logic first, live
  `gitview.tl` wiring "unscoped") only by grepping `git log` for related
  prior art (commit `e0999460`) — nothing in the spec pointed at it.
  contributed: the spec's `## Change` scoped to the decision-logic
  files only, correctly, but didn't cite the precedent commit that
  would have told the builder up front this is a known two-commit
  pattern.
  improvement: a one-line pointer to the precedent commit in a spec of
  this shape ("mirrors commit X's two-commit pattern") — cheap, not
  filed (single-instance, low generalizable leverage).
- goal: fit the new field/logic into `action.tl` without breaking the
  500-line cap.
  actually happened: landed at exactly 500 lines after reclaiming
  space; the builder reported this as expected/manageable, unlike
  F6zo_pi1N's harder case below.
  contributed: n/a.
  improvement: none.
- transcript: 455 events, 121 tool calls (Bash 42, Edit 35, Read 33,
  Grep 8, Glob 1, Write 1, create_pull_request 1), first edit at call
  38, zero errors, heaviest repeat touch `action.tl` (44x) consistent
  with iterating a file at the line cap to green.
- out-of-scope finding (reported by the builder, not filed by it, per
  instructions): `_work/gitview.tl`'s `cmd_next` is not yet wired to
  call the live GitHub read and build `QueueStates` — the decision
  logic this PR adds has no live effect on `next`'s real output until
  a follow-up wires it in, mirroring how `ci_states` was wired in after
  its own decision-logic PR. Candidate below.

## build F6zo_pi1N (claude, build-F6zo_pi1N-07d7b9b9) — PR #1702 opened, awaiting review, 1103s wall, 117 tool calls
- goal: add a branch-naming success line plus tests to `_work/gitverbs.tl`
  /`_work/gitverbs_test.tl`, both already sitting at the 500-line file
  cap before this change.
  actually happened: the bulk of the session (~25 tool calls per the
  builder's own count, and the transcript shows real thrashing — 4
  separate exit-2/exit-1 probe failures while sizing the problem, e.g.
  building a scratch 501-line test file to confirm the exact lint
  message shape) went into discovering both files were AT the cap (not
  near it) and working out how much D39 "reclaim before you split"
  slack existed in each file's comments before committing to a shape.
  contributed: the spec named the files and line to change but did not
  flag that either was already at the hard cap — the builder had to
  discover "reclaim vs. split vs. stop" was the intended middle path
  from D39 alone, with no spec cue that reclamation (not a stop) was
  expected here.
  improvement: a spec touching a file already at/near the 500-line cap
  could say so explicitly ("target file is at N/500, expect to reclaim
  under D39") — a gate in the refiner's own headroom check
  (`gitboard help bar`'s "measured, not inferred" already asks for
  headroom to be measured; extending that check to flag same-file
  near-cap headroom explicitly) would transfer this for every future
  spec touching a capped file. Candidate below.
- transcript: 445 events, 117 tool calls (Bash 68, Edit 21, Read 25,
  ToolSearch 1, GitHub calls 2), first edit at call 62 (late — most of
  the session was investigation/sizing before any edit), 4 distinct
  errors (all cap-probing dead ends), heaviest repeat touch
  `gitverbs_test.tl` (22x) and `gitverbs.tl` (10x).

## review Elus_cLzz (claude, review-Elus_cLzz-07d7b9b9) — accept, merged (squash 8b1688c3), 257s wall, 39 tool calls
- goal: land the accepted PR per the brief's "Recording your verdict"
  instructions.
  actually happened: `enable_pr_auto_merge` failed ("Protected branch
  rules not configured for this branch") because the brief's generic
  text ("a main-repo PR lands by enabling auto-merge, never merging
  directly... do NOT call gitboard done") assumes a main-repo PR; this
  is a `board`-repo PR (base `board`), which `gitboard help review`'s
  own doctrine says merges directly then `done ID`. One extra `help
  review` call resolved it, then the agent merged directly and called
  `done` itself — correct per doctrine, but contrary to the generic
  brief text it was handed.
  contributed: `_work/brieftext_review.tl:78-82`'s "Recording your
  verdict" section does not branch on the item's base (`board` vs
  `main`/`master`); it states only the main-repo path.
  improvement: a gate in the tool — `brief review` could branch its
  landing instructions on the item's own `base` field, since it already
  has that value. Small enough to spec directly; not filed this pass
  (orchestrator was mid-reconciliation) — candidate below.
- transcript: 158 events, 39 tool calls (Bash 23, Edit 3, Read 4,
  ToolSearch 2, GitHub PR/merge calls 7), first edit at call 24, two
  error classes: 19x the same `cd .../scratchpad/review-1700` failing
  exit 2 (that directory does not exist — the agent never created its
  own fresh checkout there before cd-ing into it repeatedly, a real
  ~13-call detour before it worked around it) and 1x the expected
  auto-merge-refused error above.

## build zvR2_ujhh (claude, build-zvR2_ujhh-07d7b9b9) — PR #1703 opened, awaiting review, 1378s wall, 155 tool calls
- goal: determine how `cmd_new` could know "this orchestrator's own
  session" and "the previous friction: item this orchestrator filed"
  from the board log alone, as the spec's own Change section assumed
  was knowable.
  actually happened: ~15 minutes and several greps/reads across
  `_work/brief.tl`, `_work/session.tl`, `_work/identity.tl`, and item
  files before finding that `new` commits carry no session field at
  all (unlike `take`/`spec`/`verdict`) — the fact the spec's phrasing
  assumed doesn't exist on the wire. The builder inferred and
  documented a fallback interpretation ("most recent friction: item by
  anyone" rather than a true per-orchestrator fact) rather than
  stopping.
  contributed: the spec's Evidence/Change section describes an
  authorship fact ("this orchestrator's own `<orch8>`") that `new`'s
  commit shape cannot actually carry — a real spec-accuracy gap, not
  just a documentation gap.
  improvement: worth a closer look before anything builds further on
  this assumption; flagged as a candidate below rather than filed
  outright (needs someone to confirm whether `new` should gain a
  session field, which is a bigger question than this pass has room to
  settle).
- goal: fit the friction-gate implementation under the 500-line cap in
  both `gitgraph.tl` and its test file.
  actually happened: hit the cap twice in the same session — wrote the
  gate inline first (504 lines, discovered only after editing), then
  hit it again on the test file — both resolved by splitting into new
  sibling files (`gitfriction.tl`/`gitfriction_test.tl`), mirroring the
  existing `gittake.tl`/`gitverbs.tl` precedent.
  contributed: the builder's own step-1 instruction (measure headroom
  before editing) is easy to under-apply to a wholly new helper whose
  eventual size isn't known until written — same class of issue
  F6zo_pi1N hit from the opposite direction (editing an existing
  capped file).
  improvement: n/a beyond what's already tracked under F6zo_pi1N's
  candidate above — this is the same underlying gap (spec/refiner
  headroom checks don't anticipate net-new code growing a file past
  its cap), reported twice independently in one pass, which raises its
  priority. Strengthens the case for filing that candidate.
- goal: get exact `covered`/`total` numbers for new/changed
  `.cosmic-coverage` rows.
  actually happened: ~10 minutes; the pinned board-tool binary's
  coverage ratchet refusal claimed "a plain `--make coverage`" would
  print the new file's row to paste, but never did — traced to version
  skew (`_tool/coverage/newrows.tl` exists on the main tree's current
  source but not in the binary this pin carries), worked around with a
  scratch script calling `_tool.coverage.report` directly.
  contributed: a stale-pin symptom, same family as «sxzp_M1yR» (the
  coverage guard itself) — the board's pinned tool and the main tree's
  current tooling text disagree, and the disagreement reads as a
  correctness bug until traced to the pin gap.
  improvement: none beyond «sxzp_M1yR» itself, already filed; not a
  new candidate — noted as corroborating evidence that the board pin
  is stale in more than one way.
- transcript: 572 events, 155 tool calls (Bash 96, Edit 22, Read 33,
  Write 2, ToolSearch 1, create_pull_request 1), first edit at call 62
  (late — much of the session was the session/authorship investigation
  above), one Edit error (a stale string-match, single occurrence, not
  a pattern), heaviest repeat touches `gitgraph.tl` (16x) and
  `gitgraph_test.tl` (14x).

## review fmFu_8dce (claude, review-fmFu_8dce-07d7b9b9) — accept, merged (squash 4fc68d20), 311s wall, 46 tool calls
- goal: get CI status for the PR.
  actually happened: `gh` CLI is not installed in this environment;
  one wasted Bash call before falling back to the GitHub MCP tool,
  which needed a `ToolSearch` round-trip since it wasn't pre-loaded.
  contributed: nothing tells a fresh reviewer session up front that
  `gh` is absent and the MCP tools are the intended path.
  improvement: a line in the review brief template naming the GitHub
  access path (MCP tools, not `gh`) would save this for every future
  reviewer; small, high-repeat-value. Candidate below.
- goal: diff the PR against its true base to check scope.
  actually happened: a plain `git diff <base-sha>..HEAD` over-reported
  changed files, because `board`'s orphan-branch history between the
  PR's base sha and current tip includes unrelated merged items landed
  by other concurrent sessions — the range diff picks those up too.
  ~3 extra tool calls before switching to `git show --stat
  <single-commit>`, the correct way to see one PR's actual scope on
  this branch shape.
  contributed: nothing in the spec or brief calls out that `board`'s
  branch shape makes a range-diff misleading — a property of gitboard's
  per-item-commit model a reviewer has to already know or rediscover.
  improvement: a sentence in the review brief template ("this repo's
  `board` branch mixes concurrent items' history; diff the single
  commit, not a range") would transfer this for every future review.
  Candidate below (can combine with the `gh`-absence note above into
  one brief-template addition).
- correctness finding (not friction, recorded here for completeness):
  the spec's Evidence claimed `gh.tl`'s PR read "already carries the
  fields the verdict verb reads" — false; the builder added the two
  fields as part of this PR. The reviewer verified this was a necessary,
  minimal correction rather than scope creep, not a defect.
- transcript: 187 events, 46 tool calls (Bash 36, Read 1, ToolSearch 2,
  GitHub calls 7), no edits (a review), one error (the `gh`-not-found
  above), zero repeated commands.

## review 065b_HxDK round 2 (claude, review-065b_HxDK-07d7b9b9-2) — accept, 234s wall, 38 tool calls
- goal: re-verify every probe in the reworked spec.
  actually happened: all 11 probes reproduced cleanly on the first
  try, including exact numeric matches (16 rows, 3 lowered/12 raised).
  Confirmed the follow-up item «sxzp_M1yR» exists, is correctly
  parented, carries no bar problems, and that no PR or file was
  touched by the research slice (honoring Non-goals).
  contributed: n/a — clean pass.
  improvement: none; reviewer's own friction section reported "None."
- transcript: 151 events, 38 tool calls (Bash 35, ToolSearch 1, GitHub
  calls 2), no edits (a review), zero errors, zero repeated commands —
  the cleanest transcript of the pass.

## review F6zo_pi1N (claude, review-F6zo_pi1N-07d7b9b9) — accept, merged (squash a5f86242), 415s wall, 45 tool calls
- goal: confirm CI status before reviewing further.
  actually happened: `mcp__github__pull_request_read`'s `get_status`
  method returned `"state":"pending","total_count":0` even after
  merge — this repo uses GitHub Actions check-runs, not legacy commit
  statuses, so `get_status` is structurally the wrong endpoint here.
  One extra tool call (`get_check_runs`) to get the real signal.
  contributed: nothing in the review instructions names which
  PR-status method actually works on this repo.
  improvement: a sentence in the review brief template ("use
  `get_check_runs`, not `get_status` — this repo's CI is check-runs
  based"); this reviewer also independently hit the `gh`-CLI-absence
  friction already filed as «3IrgmfsqtepHZSpgU4dmzpuOKna» (second
  occurrence this pass, corroborating it). Not filed as a separate
  item — folds into that same brief-template edit; noted here as
  additional evidence for its priority.
- transcript: 183 events, 45 tool calls (Bash 33, Edit 2, Read 1,
  ToolSearch 2, GitHub calls 7), first edit at call 25 (a mutation
  test, restored), zero errors, light repeats (`gitverbs.tl` touched
  3x during mutation testing, `export SSL_USE_SYSTEM_CERTS=1` run
  twice — trivial).
- two non-blocking findings reported (a takeover-path branch-note edge
  case untested, a substring vs. exact repo match) — both correctly
  judged not to block acceptance; no action needed.

## review zvR2_ujhh (claude, review-zvR2_ujhh-07d7b9b9) — request-changes, 402s wall, 47 tool calls
- goal: get a runnable checkout to mutation-test and reproduce a
  suspected bug, without reusing the builder's own worktree.
  actually happened: the reviewer's example commands assumed the
  pre-existing board worktree (on `board`'s tip, not the PR's diff);
  had to fetch the head sha and `git worktree add` a brand-new
  checkout by hand — but the transcript shows this took 21 repeated
  `cd /tmp/.../scratchpad/review-3IqVeowA` calls failing exit 2 (the
  directory didn't exist yet) before the worktree was actually
  created there. This is the SAME failure shape review-Elus_cLzz hit
  earlier this pass (19x identical `cd`-before-`mkdir`/`worktree add`
  failures) — two independent reviewer instances this pass made the
  identical mistake.
  contributed: nothing in the review brief tells a reviewer how to
  stand up a clean worktree onto an arbitrary PR sha (as opposed to
  the pre-existing, already-built board worktree) — both reviewers
  independently reached for `cd` into a path before creating it.
  improvement: a short recipe in the review brief template — `git
  worktree add <path> <sha>` BEFORE any `cd` into it — would prevent
  this class of mistake outright; two independent occurrences in one
  pass (40 wasted calls combined) makes this the single highest-count
  friction item of the whole pass. Filed as a candidate below,
  folded into the same brief-template edit already planned for the
  `gh`-access/CI-status/diff-scope sentences (all in
  «3Irgmfsq», the review-brief-template item).
- goal: confirm the boundary-detection logic actually handles the
  concurrent-orchestrator scenario the item's own Evidence describes.
  actually happened: reviewer hand-wrote a repro test
  (`_work/zzrepro_test.tl`), iterating twice on Teal type errors
  before landing a working reproduction — found the real bug (see
  request-changes finding below). This is normal review cost, not
  friction; noted for completeness.
- finding (request-changes, confirmed correct): the boundary-detection
  code scans backward for "the previous friction: item this
  orchestrator filed" but `new` commits carry no session field, so it
  cannot actually distinguish orchestrators — exactly the gap the
  BUILDER's own friction section (this pass, same item) already
  flagged as an inferred interpretation rather than a confirmed fact.
  Two independent sessions (builder, then reviewer) hit the identical
  root cause from opposite directions; strong signal this is a real
  spec-accuracy problem worth a closer look before further items build
  on the same assumption.
- transcript: 185 events, 47 tool calls (Bash 30, Edit 4, Read 2,
  ToolSearch 2, GitHub calls 8), first edit at call 31, two error
  classes (21x the cd-before-create above, 1x an `ls o/bin` miss on
  the not-yet-built fresh worktree).

## build zvR2_ujhh rework (claude, build-zvR2_ujhh-07d7b9b9) — pushed fix (8639c37a) to PR #1703, awaiting re-review, 481s wall, 48 tool calls
- goal: locate the code the reviewer's finding pointed at.
  actually happened: the rework brief (assembled by the orchestrator
  from the item's ORIGINAL `## Change`) named `_work/gitgraph.tl`, but
  the actual logic had already moved to `_work/gitfriction.tl` in the
  same PR (split out for the file-length cap, mid-build). ~2 tool
  calls to notice the mismatch via the module's own split-notice doc
  comment.
  contributed: the hand-assembled BOUNCE_CONTEXT quoted the reviewer's
  finding (which correctly named `gitfriction.tl`) but the spec block
  pasted below it still carried the stale `gitgraph.tl` reference from
  the original spec, unedited — a small inconsistency introduced by
  the orchestrator's own manual bounce assembly.
  improvement: when hand-assembling a rework brief, the orchestrator
  could note file-location drift between the original spec and the
  as-built diff explicitly, not just paste the reviewer's finding
  verbatim; minor, not filed (a symptom of the still-unfiled
  `brief builder` rework-auto-fill candidate — see below, unchanged
  from earlier passes).
  improvement: n/a beyond the standing candidate (`gitboard brief
  builder <id>` auto-fills rework context for `state: rework` items) —
  this pass again did what «NJCj_HQIX» from an earlier pass already
  flagged as unfiled ("needs a full spec... stays here for triage").
  Now observed a SECOND time (this pass), on this exact item. Raising
  its priority; still not filed by this pass (still needs the same
  fuller spec an earlier pass deferred), but two occurrences in two
  passes is a strong signal it should be picked up next.
- goal: understand the old code's comment about event ordering before
  redesigning around it.
  actually happened: a removed comment said "collected oldest first"
  directly above a loop iterating newest-first (per `publish.history`'s
  `git log` default) — described the RESULT list's order, not the
  iteration direction, costing a few minutes of re-reading.
  contributed: a doc-comment ambiguity in the pre-existing code, not
  this item's spec.
  improvement: none actionable within this item's scope — noted by
  the builder as a documentation-precision lesson, not a gate.
- transcript: 193 events, 48 tool calls (Bash 36, Edit 3, Read 6,
  ToolSearch 1, GitHub calls 2), first edit at call 18, zero errors,
  moderate repeats consistent with iterating the fix and its test to
  green.

## review zvR2_ujhh round 2 (claude, review-zvR2_ujhh-07d7b9b9-2) — accept, merged (squash 197db280), 314s wall, 37 tool calls
- goal: verify the round-2 redesign actually closes the
  concurrent-orchestrator gap round 1 found, not just that the
  original tests still pass.
  actually happened: traced the new claim-attribution algorithm by
  hand against round 1's exact reproduced scenario, confirmed the new
  test (`test_friction_filing_is_not_satisfied_by_another_orchestrator`)
  exercises it, then mutation-tested by reintroducing the original bug
  at the attribution layer (not just the boundary-scan layer round 1
  broke) — all 3 tests failed as expected, confirming the fix is real
  and not just test-shaped.
  contributed: n/a — this is the review working as intended, and
  correctly going one level deeper than "does it pass" into "does the
  redesign structurally close the gap."
  improvement: none; this is what a round-2 adversarial review should
  do.
- goal: merge the board PR directly, per the orchestrator's note.
  actually happened: default `merge_pull_request` failed with `405
  Merge commits are not allowed on this repository`; one extra call
  with `merge_method: "squash"` succeeded. Independently, `gh` CLI
  absence cost the usual one wasted call before the MCP tools.
  contributed: neither the review brief nor `gitboard help review`
  names the repo's merge-method restriction (squash-only) — a third
  reviewer this pass had to discover a GitHub-mechanics detail by
  trial that a one-line note would have prevented.
  improvement: fold into the same board-vs-main landing-instructions
  candidate already filed («3IreoUxF.../CTFfCZV») — "merge directly"
  should say "merge via squash (`merge_method: squash` — this repo
  rejects merge commits)". Applied below rather than left as a new
  candidate.
- transcript: 155 events, 37 tool calls (Bash 28, Edit 1, Read 1,
  ToolSearch 2, GitHub calls 5), first edit at call 24 (the mutation
  test), one error (the 405 above), light repeat (one file touched
  twice during mutation testing).

## candidates
- brief review: mint a round-numbered session label instead of always
  round 1's — filed as «l4mQ_rPh2» (from an earlier pass's log,
  applied by this orchestrator this pass).
- item.tl: doc-comment the `builders` field's wire-shape mismatch with
  `decode` — filed as «4B0h_t06K» (from an earlier pass's log, applied
  this pass).
- review brief: branch accept-landing instructions on the item's base
  (board vs main), including the squash-only merge-method detail — filed
  as «3IreoUxF37RMye0hRHQ4CTFfCZV», updated twice this pass with
  corroborating evidence from three independent reviewers (Elus_cLzz,
  zvR2_ujhh round 2, and the merge-method gap).
- board pin predates the coverage-baseline COSMIC_COVERAGE_ENV guard —
  filed as «sxzp_M1yR» (research recommendation from «065b_HxDK»,
  applied this pass after round-1 review requested it be its own item).
- gitview: wire the queued-accept decision logic into `cmd_next`'s live
  path — filed as «gj7P_Db0H», blocked on «fmFu_8dce» (now merged, so
  unblocked for a future pull).
- review brief: name the GitHub MCP access path, the correct
  `get_check_runs` method, the board-branch diff-scope caveat, and the
  worktree-creation order — filed as «3Irgmfsq», updated three times
  this pass as four independent reviewers (fmFu_8dce, F6zo_pi1N,
  Elus_cLzz, zvR2_ujhh) each independently hit one or more of these;
  highest-corroboration item of the pass.
- `gitboard brief builder <id>` auto-fills `<BOUNCE_CONTEXT>` and
  worktree-reuse instructions for a `state: rework` item — NOT filed:
  needs a full spec this pass didn't have grounds to write (which
  file, exact comment-selection rule for a PR with multiple review
  comments). Second occurrence this pass (zvR2_ujhh's rework, hand-
  assembled again) on top of the one an earlier pass already logged
  under «NJCj_HQIX» — two independent occurrences across two passes;
  stays here for triage, raised priority.
- `attach` defaulting an unset `base`/`repo` from the new parent's own
  value — NOT filed: needs a design pick between two approaches (an
  earlier pass's «14A3_CTsE» already deferred this for the same
  reason); stays here for triage.
- a spec touching a file already at/near the 500-line cap, OR adding a
  wholly new file/helper whose eventual size is unknown, could flag
  headroom explicitly rather than leaving "reclaim vs. split vs. stop"
  to be rediscovered from D39 each time — NOT filed: two independent
  occurrences THIS pass (F6zo_pi1N editing a capped file, zvR2_ujhh
  writing a new helper that overflowed) make a strong case, but the
  right gate (refiner-time headroom check vs. spec-writing convention)
  needs a decision this pass didn't have room to make; stays here for
  triage, raised priority.
- `new` commits on the board carry no session field, so a spec that
  assumes "the previous friction: item THIS orchestrator filed" is
  knowable from the log alone is describing a fact the wire format
  cannot support — NOT filed: two independent sessions (the zvR2_ujhh
  builder, then its reviewer) hit this from opposite directions this
  pass, and it was worked around in-place (claim-attribution instead
  of filing-attribution) rather than fixed at the source. Worth a
  closer look at whether `new` should gain a session field, or whether
  the claim-attribution design the rework landed is the right permanent
  shape; stays here for triage.
- a spec of the "wire new field data through several files" shape
  could cite the precedent commit for that pattern (fmFu_8dce hit this
  once) — not filed, single-instance, low generalizable leverage.
- a spec whose `## Change` assumes a repo-structure fact a README
  already documents either way could name the README section to check
  first (065b_HxDK hit this once) — not filed, single-instance.
- `publish.history`'s call site in `gitgraph.tl`/`gitfriction.tl` had a
  comment describing the RESULT list's order ("collected oldest
  first") rather than the iteration direction, costing a rework builder
  a few minutes of re-reading — not filed, a one-line doc-comment fix
  too small to justify a board item on its own; noted for whoever next
  touches that code.
