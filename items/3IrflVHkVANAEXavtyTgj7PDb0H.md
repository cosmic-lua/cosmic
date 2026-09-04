## Change

Wire the queued-accept decision logic «fmFu_8dce» (PR #1701) adds into
`_work/gitview.tl`'s live `next` path, the same way `ci_states` was
wired into `cmd_next` for CI-awareness — this PR's own Non-goals
("no polling, no new verb") left the wiring itself unscoped, and
without it `next`'s real-world output never reflects the new
`queued` state; the decision logic stays dead code until this lands.

Measured 2026-09-04 against «fmFu_8dce»'s branch: `_work/gitview.tl`
has no reference to `is_queued` or a queue-states map anywhere (`grep
-n "is_queued\|QueueStates" _work/gitview.tl` — no output). The
existing precedent, `ci_states` (`_work/gitview.tl:62-73`):

```
local function ci_states(s: store.Store, all: {item.Item}): act.CiStates
  local out: act.CiStates = {}
  for _, i in ipairs(all) do
    if item.is_open(i) and flow.stage_rank(i) == flow.STAGE_REVIEW
    and (i.pr or 0) ~= 0 then
      local hc = gh.head_checks(s, i.pr, i.repo)
      if hc ~= nil then
        out[i.id] = hc.state
      end
    end
  end
  return out
end
```

`cmd_next` (`_work/gitview.tl:340-347`) passes `ci_states(s, all)` as
`next_report_live`'s last argument.

Add `queue_states(s, all): act.QueueStates`, same file, same shape:
iterate `all`, and for each item where `item.is_open(i)` and its stage
is the accepted/awaiting-merge stage (whatever `flow.stage_rank`
returns for an accepted item — read `flow.tl`'s stage constants rather
than guessing the name) with `(i.pr or 0) ~= 0`, call
`gh.pull(s, i.pr, i.repo)` and set `out[i.id] = review.is_queued(p)`
when the call succeeds. Thread `queue_states(s, all)` into
`cmd_next`'s call to `next_report_live` (and `next_report_live`'s own
signature) as the new `QueueStates` parameter «fmFu_8dce»'s
`_work/action.tl`/`_work/flow.tl` already accept, exactly where
`ci_states(s, all)` is passed today.

`_work/gitview_test.tl`: a fixture item with `auto_merge` set on its
recorded PR renders as queued through the live path; one without does
not — mirroring however `ci_states`'s own live-path test (if one
exists in this file) is structured.

## Non-goals

No change to `ci_states`, `next_action`, or the decision logic
«fmFu_8dce» already built — this item only threads the existing
function through to the live command.
