## Goal

G8 — the flow system. Remove the identity-based review gate from the
board machinery. Review distance is carried by the review PROCEDURE
instead (`3IYiZ9Md`): the review runs in a subagent whose context holds
the diff and the spec and nothing else. A fresh window cannot be biased
by context it does not have; an identity check was only ever a proxy for
that, and a proxy that is wrong in both directions.

**This item lands second, and the ordering is the point.** `3IYiZ9Md`
puts the rule into the skill; this removes it from the machinery. Reverse
them and there is a window where neither carries it.

## Evidence — why the proxy fails, measured 2026-08-28

`_work/flow.tl:433-444` keys on having HELD THE CLAIM, not on having
authored the diff under review:

```teal
local function built_by(i: Item, session: string): boolean
  local who = root(session)
  if root(i.claim or "") == who then return true end
  for _, name in ipairs(i.builders or {}) do
    if root(name) == who then return true end
  end
  return false
end
```

`builders` is appended by `item.record_builder` (`_work/item.tl:298`)
from exactly one site — `_work/gitverbs.tl:251`, inside `if claim ~= nil
and claim ~= "" then`. Every claim-setting move records a builder,
whatever that claim produced.

**Over-fires.** `3IUBNQZZ` carried `builders = "0b13d2b4-… e532d9f6-…
0b13d2b4-…/3IUBNQZZ"` with `claim = 05f7c552-…` and `pr = 1485`. Session
`0b13d2b4` was recorded for PR **#1484**, which it CLOSED as a duplicate;
the diff in review was #1485, which it did not write. Both active
sessions were barred, `status` read `WIP ok; ready starved`, and `next`
reported **27 blocked and skipped**. The deadlock broke only when a third
session, `3c701f9f`, appeared (`8f4a3cd5 verdict 3IUBNQZZ accept`).

**Under-fires.** Writing a spec touches only the `.md` sidecar and records
nothing, so authorship of a DECISION never disqualifies — `3IY2Bj90`,
with its own reproduction.

**A third artifact.** `record_builder` dedupes by exact name while
`built_by` compares by `root`, so an orchestrator that pulls under a bare
id and again under a minted `<session>/<item>` claim lands twice in the
list. Visible above. The field is a log of claim events, not a set of
authors.

## Change

Six files on the `board` branch. Measured today; `flow.tl` is AT the
500-line cap and `action.tl` is 5 under, so both changes are net
deletions:

```
wc -l _work/{flow.tl,action.tl,gitreview.tl,gitverdict.tl,session.tl,flow_test.tl}
  500 flow.tl   495 action.tl   110 gitreview.tl
  250 gitverdict.tl   140 session.tl   220 flow_test.tl
```

**1. `_work/flow.tl` — delete `built_by`.** The function (`:433-444`),
its record field (`:447`) and its export (`:477`). Nothing else in the
module uses it.

**2. `_work/action.tl` — remove the branch and the count it feeds.**
Delete the `built_by` test at `:194` so a `check` item is reviewable by
whoever asks. `ReviewPick.mine` then counts nothing: remove the field
(`:181-182`), its initialiser (`:192`), its increment (`:195`), the
mirror field at `:243`, the local at `:287` and the two constructor sites
(`:366`, `:369`). The terminal reason at `:430-437` currently reads
"nothing in check is this session's to judge (%d built by this session,
%d under another session's review)" — it keeps only the `reviewing` half,
so a full `check` with every item under another session's live review
still names why.

**3. `_work/gitreview.tl` — remove the claim-time refusal (`:59-66`)**,
the block whose comment reads "The same distance rule the verdict
enforces, moved to claim time". The rest of the verb — phase check,
already-yours, the claim itself — is unchanged.

**4. `_work/gitverdict.tl` — remove the verdict refusal (`:140-150`)**,
comment included. Every other refusal in the verb stays: wrong phase,
same-head, and the accept-time PR-state read.

**5. `_work/session.tl:6` — correct the doc comment**, which says the
distance rests on distinct names and cites `built_by`. Distinct names
still matter for CLAIMS; the verdict half is gone.

**6. `_work/flow_test.tl` — delete `test_built_by_roots_names`
(`:203-220`)** and add `test_a_builder_may_now_verdict_its_own_item`
asserting the reverse: an item whose `builders` and `claim` both name a
session is still offered to that session by `action.reviewable`, and
`gitverdict` records the verdict rather than refusing.

**KEEP `builders`.** It stays written, read by `show`, and described as
the audit record of who held the claim. `3IY2Bj90` wants more recording,
not less, and the review subagent's own derived identity on the verdict
is what makes isolation auditable.

## Non-goals

- Do NOT touch `skills/work/**`. That is `3IYiZ9Md`, and it lands FIRST.
- Do not remove or change `item.record_builder`, the `builders` field, or
  its `problems` validation. Only the GATE goes.
- Do not change the three verdicts, the phase rules, the WIP limits, or
  any verdict-line format.
- Do not touch `gitreview`'s claim mechanics — the review claim is
  mutual exclusion between concurrent reviewers and keeps its whole job.
- Do not change `_work/gitverbs.tl:251` or the takeover refusal above it
  at `:243-248`; a live-claim takeover stays `--force --why`.
- Do not add a replacement gate keyed on anything else. The decision is
  removal, not re-keying.

## Acceptance

Run from the `board` worktree.

- `bin/cosmic --make ci` ends `ci: PASS`.
- `bin/cosmic --make test _work/flow_test.tl` ends `test: PASS (1 file)`.
- `grep -rc 'built_by' _work/*.tl` prints `0` for every file (`flow.tl`
  3, `action.tl` 1, `gitreview.tl` 1, `gitverdict.tl` 2, `session.tl` 1,
  `flow_test.tl` 7 today).
- `grep -c 'mine' _work/action.tl` prints `0` (`9` today).
- `grep -c 'record_builder' _work/item.tl` prints `2` (`2` today) — the
  audit record survives untouched.
- `wc -l _work/flow.tl` is at most `500` and strictly less than `500`
  (`500` today — the deletion must buy headroom, not spend it).
- **The reversal, run literally.** With a fixture item in `check` whose
  `claim` and `builders` both name `S`, `gitboard verdict <id> accept
  --session S` records the verdict instead of printing `REFUSED`. This is
  the new test in `_work/flow_test.tl`; it fails before the change with
  `REFUSED: … is S's own build` and passes after.

## Enablement

Blocked on **`3IYiZ9Md`** — the skill must carry the review-isolation
rule before the machinery stops enforcing the identity gate. Recorded in
`blocked_by`. Nothing else is needed: the change is deletion plus one
test, in a tree that already builds.
