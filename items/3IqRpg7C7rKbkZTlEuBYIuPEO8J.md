# friction: 2026-09-04 work9 (/work 9, scheduled)

Pass: claimed and fanned out 9 disjoint items (8 builders + 1 research
slice) across cosmic-lua/cosmic and cosmic-lua/cosmopolitan, drained 9
sequential reviews plus 2 more opportunistic reviews on items filed
mid-pass and picked up by concurrent sessions, filed 4 follow-up items
(2 real product bugs found in review, 2 tooling countermeasures below).
Indicators below are read from `cosmic _tool/friction.tl <transcript>`
(events, tool calls, wallclock, the four token counts, errors, repeated
commands) run against every dispatched subagent's `.output` transcript;
the orchestrator section is from this session's own tool-call history.

## orchestrator

- **Worktree branch mismatch, all 9 recreated.** Goal: stand up one
  fresh worktree per claimed item before spawning its builder. Actually
  happened: created all 9 with `git worktree add <path> origin/main
  --detach`; only after emitting `gitboard brief builder <id>` for each
  did the brief text ("It is on a fresh branch `<id[:8]>`...") reveal
  they needed to be on a NAMED branch, not detached — had to
  `git worktree remove --force` all 9 and recreate with
  `-b <branch> <path> <base>`. Contributed: nothing in
  `gitboard help orchestrate`'s "one fresh worktree per agent" bullet or
  in `take`'s success output states the branch name up front; only the
  brief (emitted after worktree setup, in the sequence I followed)
  names it. Improvement: state the branch-naming convention
  (`<id>`'s first 8 characters) directly in `gitboard help orchestrate`
  next to the worktree-per-agent rule, or have `take`'s own success
  line print it (`take` already prints the item id; one more field is
  cheap) so worktree setup order doesn't matter. Cost: ~18 extra `git
  worktree` calls (9 remove + 9 re-add); not filed — self-corrected
  within the pass, low recurrence risk once known.

- **"One claim per worker" refusal.** Goal: claim a second item for the
  wave the same way the first was claimed. Actually happened:
  `gitboard take FeC7_Ri35` (no `--session`) refused:
  `"a3a5e5ce-... already holds 3IpIfJ5G — one claim per worker; drop it
  or finish it first."` Contributed: `gitboard help orchestrate` does
  say to mint a distinct session name per agent, but the first
  successful claim (under the implicit default identity) worked without
  one, masking the requirement until the second claim. Improvement:
  doctrine already covers this — a closer read on the first claim would
  have caught it; not filed. Cost: one failed call + one `help take`
  read.

- **Push races on the shared board, always recoverable.** Goal: record
  a PR handover or close a completed item. Actually happened: at least
  3 occasions (`done` on qqTp_aJfw, `take --pr` on mZos_IITG, `set
  --repo` on the CI-infra item) hit `"lost the push race — ... re-run
  the verb"` or a rejected push (`cannot lock ref 'refs/heads/board'`);
  a plain retry succeeded every time (once discovering the value was
  already correct from a concurrent session's write). Contributed: the
  board is worked by several concurrent orchestrator sessions at once —
  confirmed directly, since items «EMdb_HFX2», «djEO_SQWp», «t6Ez_X2rm»,
  «CRn8_vfb0», «DkPc_u6TG», «arYr_TKlS» all appeared mid-pass, none
  claimed by this session. Improvement: none needed — gitboard already
  fails loud and names the fix (retry); noting only so a future
  orchestrator doesn't treat the first failure as fatal. Not filed.

- **`gitboard new --repo` refused twice before the real sequence was
  found.** Goal: file a new item with its target repo set in one call.
  Actually happened: `gitboard new TITLE --spec-file F --repo
  OWNER/NAME` refused outright — `"claim/reviewer/pr/verdict/repo/base
  belong to worked items, not roots"` — on both the maxmind item and
  the CI-infra item, before discovering by trial and error that the
  working sequence is `new` (enters triage) → `attach ID PARENT` → `set
  ID --repo OWNER/NAME`. Contributed: `gitboard help new` lists `--repo
  OWNER/NAME` as one of its options, which reads as usable at creation
  time; the refusal message names what's disallowed but not the actual
  fix (attach first). Improvement: append the fix to the refusal
  message itself, the way other gitboard refusals in this pass
  consistently did (the coverage-env refusal, the CI board-check
  refusal both name the next step) — small, in-tool message change.
  Cost: 2 failed calls per occurrence, 2 occurrences; left as a
  candidate below rather than filed (low individual cost, no numeric
  measurement to back a bar-clearing spec beyond the two reproductions
  above).

- **Shallow-clone "unrelated histories" false alarm during a real merge
  conflict.** Goal: resolve what should have been a 1-line merge
  conflict between the fU6l_yGKY branch and `origin/master`, which had
  independently landed a conflicting fix (PR #378) for the same log
  line. Actually happened: `git merge origin/master` first failed
  outright with `fatal: refusing to merge unrelated histories` (the
  worktree's clone was shallow); after `git fetch --unshallow`, the
  merge then showed ~150 files / 94 commits as changed, which read as
  alarming until `git rev-list --count <merge-base>..origin/master`
  confirmed it was real upstream churn (not a git malfunction) —
  several extra investigative commands before trusting the single real
  conflict underneath. Contributed: nothing wrong in the repo; the
  default worktree clone depth plus a fast-moving, multi-session-shared
  upstream collided, and git's own error text doesn't hint "your clone
  is shallow." Improvement: state once in `gitboard help orchestrate`:
  "a worktree merge that looks unexpectedly large, or fails with
  'unrelated histories,' is probably a shallow-clone artifact — `git
  fetch --unshallow` before investigating further." Not filed — one-off,
  self-diagnosed within the pass, low recurrence risk (specific to
  editing a file a concurrent session also touched).

- **A CI failure investigation that paid for itself.** Goal: get
  mZos_IITG's PR green. Actually happened: `ci` failed deterministically
  (confirmed via one sanctioned re-run, identical failure) on a
  `git ls-tree` call `board_paths()` makes as the non-root `builder`
  user — root-caused to an `actions/checkout` credential-`includeIf`
  permission gap unrelated to this item's own diff. This cost real
  investigative time (reading job logs twice, reading `pr.yml` in full,
  confirming the failure was deterministic not a flake) but was NOT
  wasted: filed as its own item («djEO_SQWp»), picked up and fixed by a
  concurrent session, merged, and the fix directly unblocked mZos_IITG
  (green after a merge-in and re-push). Contributed / improvement: N/A
  — this is the system working as designed (CI-red rooted out,
  ported/filed rather than silently worked around); recorded here only
  because it was the single largest orchestrator time sink in the pass
  and is worth knowing it was time well spent.

## build FeC7_Ri35 (a17393e6089b1012c) — merged, 837s wall, 60 tool calls
- Goal: document why the two `env as tl.Env` casts survive generation 1.
  Actually happened: spent 2 calls probing for `o/bootstrap`/`o/_types`
  with `ls` before it existed (exit code 2 both times), then a `sleep
  60; echo waited` blocked by the harness at call 28 — ended that turn
  with no progress, needing an orchestrator resume. tokens: in=126
  out=653 cache_read=5,049,555 cache_create=182,639. Contributed: the
  brief's bootstrap step doesn't say "just run `--make fetch`, don't
  probe for its output first"; the sleep block is the pattern named in
  the orchestrator's "gitboard brief: warn against sleep" candidate
  below. Improvement: covered by that filed item («LmNB_gMXm»).

## build fU6l_yGKY (ad20a200cfa062810) — merged, 1009s wall, 69 tool calls
- Goal: fix the dead `finger.*` demo references. Actually happened:
  attempted its own `git rebase origin/master` to pick up upstream
  changes, hit a real conflict (`CONFLICT (add/add)` in two workflow
  files), abandoned the rebase and pushed unrebased per its own report —
  correct call (per orchestrate doctrine, cross-item merge conflicts are
  the orchestrator's to resolve, not a builder's), but the attempt
  itself was pure sunk cost since the real, correct merge had to be
  redone from scratch by the orchestrator afterward (see orchestrator
  section). tokens: in=140 out=657 cache_read=7,096,960
  cache_create=254,501. Contributed: the builder brief doesn't say
  "if you hit a conflict pulling in upstream changes, stop and report
  it rather than attempting rebase/merge yourself" — it only says to
  push and open a PR, silent on what to do if the push/PR step reveals
  a conflict with a concurrently-merged change. Improvement: candidate,
  not filed on its own (folds into the same "brief text" leverage
  point as the sleep-antipattern item; a single occurrence here, not
  independently bar-clearing).

## build eDVe_UY1D (a0e8b02a81321639b) — merged, 2166s wall, 110 tool calls
- Goal: add `check.swap_members`, route 4 copied mock-swap helpers
  through it. Actually happened: two full `--make ci` runs failed
  (`ci_run1.log`, `ci_run2.log`, both exit 1) before a third went green;
  one `Read` call failed on malformed JSON input (self-inflicted, 88-byte
  payload cut off); the harness `sleep 90` block hit once (call 55).
  tokens: in=224 out=2725 cache_read=13,326,457 cache_create=363,390 —
  the highest token spend of any builder this pass, consistent with the
  4-file, cross-module scope of the change. Contributed: no single
  identifiable brief/tool gap beyond the sleep pattern (already
  covered); the two failed CI runs read as ordinary iteration on a
  genuinely tricky change (the `pcall`-vs-`xpcall` typing wrinkle it
  had to work around). Improvement: none beyond the filed sleep item.

## build wkmX_zNkM (aca08d21266b6bf60) — merged, 1243s wall, 119 tool calls
- Goal: print the would-be `.cosmic-coverage` row for a file missing
  from the baseline. Actually happened: clean build overall (1 error,
  the sleep block at call 90); heaviest file-read repetition of any
  builder (`_tool/coverage/baseline.tl` read 20 times, its own new
  `_tool/coverage/newrows.tl` 6 times) while iterating the extraction
  and re-verifying the 500-line cap on `baseline.tl` (`wc -l` run 7
  times) that forced the new-file split. tokens: in=246 out=3344
  cache_read=17,225,998 cache_create=515,854 — highest cache-read of
  any builder. Contributed: the repeated `wc -l` checks suggest the
  brief's "the file's own line-cap status" wasn't stated up front (it
  was discovered by measuring, each time a change to `baseline.tl` was
  considered). Improvement: candidate — briefs for an item whose spec
  already discusses a near-cap file (this one's spec explicitly named
  `check.tl is 358 lines`-style facts for OTHER items) could carry the
  target file's current line count as a stated fact rather than have
  the builder re-measure it repeatedly; low individual cost, not filed.

## build mZos_IITG (a2e154d44fbc5501f) — merged after rework, 1172s wall, 68 tool calls
- Goal: declare doc-path reads roots, fail loud under CI. Actually
  happened: one `--check-format`/`--check-types` invocation used a
  retired flag spelling (`--check-format` instead of `--check fmt`),
  refused with a helpful redirect; the harness sleep block hit once
  (call 12). This is the item whose PR then hit the real CI-infra bug
  (see orchestrator section) — none of that cost is in this agent's own
  transcript, since the fix and re-merge were orchestrator-side. tokens:
  in=126 out=780 cache_read=5,667,922 cache_create=261,679. Contributed:
  the retired-flag typo is ordinary command-recall error, not a brief
  gap (the correct spelling is in AGENTS.md's own examples).
  Improvement: none identified beyond the two filed items.

## build qqTp_aJfw (ad46335d22c9e3403) — merged, 1643s wall, 120 tool calls
- Goal: lock the `.gcda` read-merge-write in `libc/intrin/gcov.c`.
  Actually happened: two `Read` calls failed because the agent's cwd was
  `/home/user/cosmic/o/board` (the gitboard worktree) rather than its
  own `/home/user/wt-qqTp_aJfw` — a state-tracking slip costing 2 calls
  before correcting the path; a `MODE=cov` build under `timeout 590`
  was killed (exit 143) once before a working invocation was found; the
  harness sleep block hit once (call 101). tokens: in=234 out=768
  cache_read=16,801,350 cache_create=514,983 — highest cache-read
  alongside wkmX_zNkM's, reflecting the C-layer investigation
  (`libc/calls/pledge-linux.c`, `PLEDGED(FLOCK)`) this item needed.
  Contributed: the cwd slip is self-inflicted (no brief/tool gap); the
  build timeout is the ordinary cost of a from-scratch `MODE=cov` build
  in this repo, not a process gap. Improvement: none identified.

## build CWvd_jsxd (acf346c15b0485c88) — merged, 698s wall, 15 tool calls
- Goal: restore the dropped slot-2 assertion in `test_latin1_roundtrip`.
  Actually happened: cleanest run of the pass — 0 errors, no repeated
  probing beyond re-reading the 2 touched files once each, fastest wall
  time of any builder. tokens: in=30 out=408 cache_read=794,638
  cache_create=74,746 — an order of magnitude below every other
  builder's cache-read, consistent with the item's narrow, single-file,
  well-evidenced spec. Contributed: nothing negative to report — kept
  here as the pass's positive baseline: a precisely-scoped spec with
  its exact replacement code already written out (as this item's did)
  produces the cheapest, fastest, error-free run. Improvement: N/A;
  worth citing as the comparison point for the "spec precision pays for
  itself" observation in future refining.

## build 24pv_Z1Dj (acf7e5c933c667bd7) — merged, 1522s wall, 76 tool calls
- Goal: extend `_make/engine.tl`'s `TEST_BIN` detection to a content
  rule. Actually happened: ordinary iteration (timed `--make test` run 3
  times to get the before/after warm-build numbers the spec's evidence
  section asked for); the harness sleep block hit once (call 28).
  tokens: in=152 out=1887 cache_read=6,580,572 cache_create=213,922.
  Contributed / improvement: none beyond the filed sleep item.

## research 1j6D_hfCe (adf21b3a8545ff417, resumed twice) — accepted after rework, 5868s wall (across all resumes), 72 tool calls
- Goal: get a day-separated re-measurement of the `re_match_log_line`
  regression claim. Actually happened: by far the longest-running agent
  in the pass (5868s — ~7x the next-longest builder), and its FIRST
  measurement sub-run had to be entirely discarded: it seeded each
  worktree's `o/3p` by `cp -r`-ing an already-fetched cache instead of
  running `--make fetch` per worktree, which (most likely via
  mtime-based incremental-build staleness tracking) produced binaries
  that didn't reproduce when a fresh-context reviewer rebuilt the exact
  same two commits from scratch and got different hashes. The reviewer
  also caught a real arithmetic bug in that sub-run's own analysis (a
  Python slice bug: `old[:6]`/`new[:6]` took the first 6 of 12 pairs
  rather than actually excluding pairs 7 and 8, turning a claimed
  "+0.08%, converges to zero" into what should have read "-1.94%, a
  sign-flipped swing of comparable size"). On rework, the agent
  root-caused the hash mismatch (confirmed the build system itself is
  deterministic; the `cp -r` shortcut was the actual cause), redid the
  full 12-pair measurement on properly-built, hash-verified binaries,
  and its corrected reading REVERSED the sub-run's original "no stable
  direction" conclusion to "regression" — a materially different answer
  the reviewer's fresh-context pass earned by refusing to accept
  unreproduced numbers. tokens: in=148 out=952 cache_read=6,625,469
  cache_create=209,197. Contributed: nothing in this item's spec or the
  research brief said "seed each build worktree via its own real
  `--make fetch`; a copied `o/3p` cache is not equivalent" — this is
  exactly the kind of fact a spec should carry but did not, discovered
  by building (and by review, not by the builder's own sub-run).
  Improvement: the corrected item's own spec now states this explicitly
  for the next day-separated session ("Build each side with a real,
  per-checkout `bin/cosmic --make fetch`... no shortcuts... this item's
  own session 1 showed does not reproduce"), so the fix is already
  encoded where the next puller will read it — no further action beyond
  what the item's own reworked spec already carries.

## review CWvd_jsxd (ace7e384dec993191) — accept, 198s wall, 25 tool calls
- Clean, fast review; 0 errors; matches the builder's own clean run.
  tokens: in=48 out=146 cache_read=1,400,285 cache_create=46,402.
  Nothing to report.

## review FeC7_Ri35 (a23c12809cbe0d5cf) — accept, 245s wall, 23 tool calls
- One error: a scratch-clone `cd` into a directory it had just
  simulated deleting generated types from — recovered same call.
  tokens: in=44 out=466 cache_read=1,456,650 cache_create=56,207.
  Nothing to report beyond ordinary review mechanics.

## review fU6l_yGKY (a643718cee3aad83a) — accept, 438s wall, 46 tool calls
- Goal: adversarially review the finger-module fix plus the
  orchestrator's own manual merge-conflict resolution. Actually
  happened: hit the harness sleep block once (call 20); two `pkill`
  calls to clear a stray concurrent build both returned exit 1 (nothing
  matched — harmless, but worth noting as wasted defensive calls).
  tokens: in=90 out=169 cache_read=3,658,850 cache_create=157,800.
  Contributed / improvement: the sleep block is the filed item; the
  `pkill` misses are minor and not independently worth filing.

## review eDVe_UY1D (a1077b93ba5b667f6) — DUPLICATE, wasted, 1513s wall, 39 tool calls
- Full independent adversarial review (fresh clone, rebuild, `--make
  ci`, a live pcall-vs-xpcall Teal-checker probe, two separate mutation
  tests) that reached `accept` — then found at verdict time that a
  DIFFERENT concurrent orchestrator session, using the identical
  conventional session label `review-eDVe_UY1D-1`, had already recorded
  `accept` and merged the PR minutes earlier: `gitboard verdict` refused
  with `"3Ip8vSUa already carries an accept — land it."` tokens: in=72
  out=179 cache_read=2,850,975 cache_create=201,144 — entirely spent for
  no board-state change. Contributed / improvement: filed as
  «RxN2_253n» (review session labels collide across concurrent
  orchestrator sessions on the same board).

## review qqTp_aJfw (a8a9ab1897a5e6d03) — accept, 661s wall, 52 tool calls
- Two errors: the harness sleep block once (call 24), and one `Monitor`
  call with an invalid parameter shape (`target`/`action` unexpected,
  `description` missing) — a tool-usage slip, self-corrected next call.
  tokens: in=102 out=265 cache_read=4,593,553 cache_create=194,694.
  Contributed: the `Monitor` misuse suggests the tool's parameter shape
  wasn't obvious from context; not measured elsewhere in this pass, so
  left unfiled (single occurrence).

## review wkmX_zNkM (a9550f469023ddd05) — accept, 307s wall, 31 tool calls
- Clean; 0 errors. tokens: in=60 out=263 cache_read=2,096,881
  cache_create=68,921. Nothing to report.

## review 24pv_Z1Dj (acced7356a5b04fef) — accept, 272s wall, 24 tool calls
- Clean; 0 errors; fastest and cheapest review of the pass. tokens:
  in=44 out=159 cache_read=1,375,607 cache_create=51,898. Nothing to
  report.

## review djEO_SQWp (a81aa182cdc882927) — DUPLICATE, wasted, 363s wall, 41 tool calls
- Full independent review (read the PR's own CI job log line-by-line,
  verified the `_make/refstamp.tl` graceful-failure claim, ran a local
  shell repro of the `includeIf`-strip commands in a throwaway git
  repo) that reached `accept` — then found, same as eDVe_UY1D's review
  above, that a different concurrent session had already claimed and
  landed the verdict under the identical label `review-djEO_SQWp-1`
  before this review finished: `"3IqHFc4B already carries an accept —
  land it."` tokens: in=74 out=199 cache_read=3,356,187
  cache_create=122,311. Contributed / improvement: same filed item as
  eDVe_UY1D's duplicate, «RxN2_253n» — this is the SECOND occurrence in
  one pass, strengthening that item's evidence.

## review research 1j6D_hfCe, first pass (af8fcf6198a0e4bef) — request-changes, 617s wall, 36 tool calls
- Found the unreproduced binary hashes and the pooled-mean arithmetic
  error described in the research agent's own section above. One
  self-inflicted setup error: attempted to rebuild an old scratch
  worktree (`wt-old`) that had never had `--make fetch` run in it,
  failing with a missing-pin error before switching to a correct fresh
  clone. tokens: in=66 out=249 cache_read=2,514,990 cache_create=89,906.
  Contributed / improvement: this review's own findings ARE the
  countermeasure already folded into 1j6D_hfCe's reworked spec (see that
  item's section above) — no separate action needed.

## review mZos_IITG (a65b34f29a497fc8e) — accept, 261s wall, 37 tool calls
- Goal: adversarially review the doc-paths declaration plus the
  orchestrator's own unreviewed merge-in of the CI-infra fix. Actually
  happened: hit the harness sleep block once (call 8, this time a
  standalone `sleep 90` with no trailing command — the block fires on
  bare `sleep` too, not just `sleep N; <cmd>`); one incidental `gh auth
  status` probe failed (`gh: command not found` — this environment uses
  the GitHub MCP tools, not the `gh` CLI; harmless, self-corrected).
  tokens: in=70 out=185 cache_read=2,627,107 cache_create=79,894.
  Contributed: a 9th occurrence of the sleep-block pattern (bringing the
  pass total to 9 of 19 dispatched agents, 47%) — the standalone-`sleep`
  form strengthens «LmNB_gMXm»'s evidence that the brief fix should
  cover both `sleep N; <cmd>` and bare `sleep N`. Improvement: already
  covered by the filed item.

## candidates

- gitboard brief: warn agents against `sleep N; <cmd>` when waiting on
  a backgrounded build — filed as «LmNB_gMXm»
- gitboard: review session labels collide across concurrent orchestrator
  sessions on the same board, wasting full duplicate reviews — filed as
  «RxN2_253n»
- `gitboard new --repo` refusal message should name the fix (attach
  first, then `set --repo`) instead of only naming what's disallowed —
  stays here for triage: two low-cost occurrences (2 failed calls each),
  no independent numeric measurement beyond the two reproductions logged
  above
- builder brief should say what to do on a real upstream merge conflict
  discovered while pushing/opening a PR (stop and report, don't attempt
  rebase yourself) — stays here for triage: one occurrence (fU6l_yGKY's
  build), folds into the same brief-text leverage point as the filed
  sleep item but is a distinct instruction
- `gitboard help orchestrate` could note that an unexpectedly large or
  "unrelated histories" merge inside a worktree is likely a shallow-clone
  artifact, fixed by `git fetch --unshallow` — stays here for triage:
  one occurrence, self-diagnosed, low recurrence risk
- an item whose spec already discusses a near-cap file's line count
  could carry that count as a stated fact so a builder doesn't
  re-measure it repeatedly (`wc -l` run 7 times in wkmX_zNkM's build) —
  stays here for triage: low individual cost, not independently
  bar-clearing
