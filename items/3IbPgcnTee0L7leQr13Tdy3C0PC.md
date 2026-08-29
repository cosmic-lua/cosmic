## Change

The observation half of parent 3IHDCJ3o (read its Evidence there):
`sync` learns the scheduled lanes' health and records it, so a red
release/fuzz/docs run becomes board state instead of an unseen
Actions tab. Measured 2026-08-29: `_work/gh.tl` is 140 lines and
exports `slug`, `pull`, `checks` (`grep -n "function" _work/gh.tl`);
`_work/gitverbs.tl` is 485 of the 500-line cap (`wc -l`), so the
lane logic lives in a NEW module and `cmd_sync`
(`_work/gitverbs.tl:455`) gains at most a handful of lines.

1. New `_work/lanes.tl`:
   - `LANES` — literal data: `{"release.yml", "fuzz.yml",
     "docs.yml"}` (the required set is data beside the code, per the
     parent's Direction).
   - `observe(s: store.Store): {string: string} | nil, string` —
     for each lane, GET
     `/repos/<slug>/actions/workflows/<file>/runs?per_page=1&status=completed`
     (same fetch/token pattern as `gh.checks` — read it first) and
     return `{lane: conclusion}` (`success`, `failure`, ...).
     Verify the API's response shape live against whilp/cosmic
     before coding to it. Network failure returns `nil, err`;
     sync treats that as "lanes unknown", never as red.
   - `record(s, facts): boolean, string` — write `lanes_state.tl`
     at the board root as a `cosmic.literal` file
     `{["release.yml"] = "success", ...}` and commit+push it as one
     ordinary CAS mutation with subject `sync lanes: <lane>=<c> ...`
     ONLY when the content changed; no commit when unchanged. The
     committed file is what keeps reads offline and the fact alive
     in a fresh worktree.
   - `mint(s, facts): ...` — for each lane whose conclusion is not
     `success`, ensure ONE open repair item exists: a new item field
     `lane` (string, the workflow filename) is the idempotency key —
     search open items for `lane == <file>`; when none, `new` an
     item titled `lane repair: <file> is red` carrying
     `lane = "<file>"`, parented under 3HyRdT1JQS7pCPgF3sZi2Deo66q.
     When a lane is back to `success` and its open repair item is
     UNCLAIMED, end it `not-planned`; a claimed one is left alone.
2. `_work/item.tl`: add the optional `lane` field to the item
   record/SPEC (decode + encode), defaulting absent. This file is
   shared state — the policy sibling (blocked on this item) reads
   the same field, so the field lands here, once.
3. `cmd_sync` calls `lanes.observe` + `record` + `mint` AFTER the
   rebase succeeds, and prints one line per non-success lane; a
   `nil` observe (offline, no token) prints `lanes: unknown (<err>)`
   and syncs as today. gitverbs.tl must stay ≤500 lines — the call
   block is small because the logic is in lanes.tl.
4. `_work/lanes_test.tl`: mint idempotency (two red observations,
   one item), auto-close of an unclaimed repair on green, claimed
   repair left alone, no commit when facts unchanged (record
   returns false), and observe's nil path. Use a fake facts table —
   the network call itself is exercised only live.

## Non-goals

No ordering or admission changes — the policy half (status lanes
row, admits_over_limit, finish-first placement) is the blocked
sibling item, not this diff. No expedite field of any kind (parent's
Direction, point 4). Verdict lines, refusal texts, existing commit
subjects, `flow item=` grammars untouched (`_work/flowstats_test.tl`
proves them); the one NEW commit subject is `sync lanes: ...` as
specified.
