--- The state verbs: `take` (claim work, record its handover), `drop` (return a lease, the
--- item untouched), `done`, and the housekeeping `init` and `sync` — every `cmd_*` behind
--- `_work/gitboard.tl`'s dispatch that is not a graph mutation. The verbs that shape the
--- graph — `new`, `attach`, `block` and its `unblock` half — are `_work.gitgraph`; the
--- spec sidecar's own verb is `_work.gitspec`; the two takes `take` reaches by derivation
--- — the review claim and the research handover — are `_work.gittake`. All of them run
--- over `_work.store` (persistence) and `_work.flow` (policy). Verbs receive FULL ids —
--- the dispatcher resolves prefixes — and every verb prints a `gitboard-<verb>:` verdict
--- line and returns its exit code. Mutations commit locally and publish through
--- `publish.publish`, whose rejected-push path drops the mutation whole, re-syncs, and
--- refuses — re-running the verb re-applies every gate against the merged board.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local gittake = require("_work.gittake")
local health = require("_work.health")
local item = require("_work.item")
local lanes = require("_work.lanes")
local publish = require("_work.publish")
local review = require("_work.review")
local store = require("_work.store")

--- init: prepare a state repository at `dir` — the mechanics live in
--- `store.init_repo`, alongside `open`, the other half of the same
--- contract; this is just its verdict line.
--- @param dir string The directory to prepare
--- @return integer Exit code
local function cmd_init(dir: string): integer
  local ok, err = store.init_repo(dir)
  if not ok then
    return gate.verdict_line("init", false, err)
  end
  return gate.verdict_line("init", true,
    ("state repository ready at %s"):format(dir))
end

--- take: claim an item, record its handover, or claim its review —
--- which one is derived from the item's own facts, never declared.
---
--- A take of TODO work (no claim, no PR) is the pull, and it is where
--- the two quality gates bind: the spec bar (`gate.ready_problems`)
--- and the doing bound (`flow.doing_refusal`). A take of an item
--- AWAITING A VERDICT by a session that is not its builder is the
--- review claim (`gittake.take_review`). Everything else `take` does
--- — recording a handover on your own claim, re-claiming your own
--- item, taking over a stale claim — is motion on work already in
--- flight and asks neither gate.
---
--- Recording a PR is the handover to review: the number must be free
--- (no other OPEN item already carries it — `gate.pr_collision_refusal`),
--- the request is read (open, not draft, `Board:` line, on the item's
--- own `base` when it names one, CI not failing — `gate.handover_refusal`),
--- and a standing `request changes` verdict clears, because the new
--- push is a new head to judge. `--result` is the same handover for
--- a research slice, whose deliverable is the spec rather than a diff
--- (`gittake.take_result`); an item carries one kind or the other.
--- @param s store.Store The store
--- @param id string The item to take
--- @param session string The claiming session
--- @param pr integer The PR to record, 0 for none
--- @param force boolean Take over a LIVE foreign claim
--- @param why string Why --force was needed
--- @param result boolean Record the research handover instead of a PR
--- @return integer Exit code
local function cmd_take(s: store.Store, id: string, session: string,
    pr: integer, force: boolean, why: string, result?: boolean): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("take", false, "REFUSED: " .. forced)
  end
  if (session or "") == "" then
    return gate.verdict_line("take", false,
      "REFUSED: a claim names its session — set GITBOARD_SESSION or pass "
      .. "--session")
  end
  -- The identity shape gate: a dash-led name is a flag a mangled argv
  -- absorbed, refused before it can enter claim, builders, or (via
  -- the review-claim derivation below) reviewer.
  local bad_session = item.identity_refusal(session)
  if bad_session then
    return gate.verdict_line("take", false, "REFUSED: " .. bad_session)
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("take", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("take", false, aerr)
  end
  local r = flow.role(it, all)
  if r ~= "work" then
    return gate.verdict_line("take", false,
      ("%s is a %s — only workable leaves are taken"):format(id:sub(1, 8), r))
  end
  if not item.is_open(it) then
    return gate.verdict_line("take", false,
      ("%s is done (%s)"):format(id:sub(1, 8), it.resolution))
  end
  -- The research handover is the claim holder's own motion: it asks
  -- none of the gates below and never takes over.
  if result then
    return gittake.take_result(s, it, session, pr)
  end
  -- An item awaiting a verdict — a PR, or a research handover — taken
  -- by a session that is not its builder with no PR to record, is the
  -- review claim. A bounced item keeps its stale "request changes"
  -- verdict until the fresh verdict lands, so that state routes the
  -- same way for a session that is not the recorded builder — the
  -- original builder's own takes still fall through to the build path
  -- below (the rework).
  local verdict = it.verdict or ""
  if (pr or 0) == 0 and ((it.pr or 0) ~= 0 or (it.result or "") ~= "")
  and (it.claim or "") ~= session
  and (verdict == "" or verdict == "request changes") then
    -- CI still running is the one state worth waiting out: a red head
    -- is already a decided fact a reviewer can act on (a quick request
    -- changes), but a running one is not yet known either way, so
    -- claiming the review now only burns a reader on a verdict it
    -- cannot give. `head_checks` reads nil on no GitHub reach (no
    -- origin, no token, a network error) — exactly the cases this
    -- refuses nothing for, same as before this gate existed. One call
    -- does the whole read: the sha and run list needed for the
    -- refusal text ride the returned record, so nothing here
    -- re-fetches the PR or its checks a second time.
    if (it.pr or 0) ~= 0 and not force then
      local hc, _herr = gh.head_checks(s, it.pr, it.repo)
      if hc ~= nil and hc.state == "running" then
        local sha7 = "?"
        if hc.head_sha ~= "" then
          sha7 = hc.head_sha:sub(1, 7)
        end
        local done = 0
        for _, run in ipairs(hc.runs) do
          if run.status == "completed" then done = done + 1 end
        end
        return gate.verdict_line("take", false, ("REFUSED: %s's head %s "
            .. "has CI running (%d of %d checks done) — review when it "
            .. "settles"):format(id:sub(1, 8), sha7, done, #hc.runs))
      end
    end
    return gittake.take_review(s, it, session, force, why)
  end
  -- Re-taking your own claim with nothing new to record is a no-op,
  -- not a mutation: there is no change for the commit to carry.
  if (it.claim or "") == session and (pr or 0) == 0 then
    return gate.verdict_line("take", true,
      ("%s is already yours"):format(id:sub(1, 8)))
  end
  -- The takeover rule: a claim is a lease. A live foreign claim is a
  -- builder mid loop on a machine the board cannot see, taken over
  -- only on the record; a stale one is anyone's again, noted.
  local taken = ""
  if (it.claim or "") ~= "" and it.claim ~= session then
    if not health.is_stale(it, gate.age_of(s, it)) and not force then
      return gate.verdict_line("take", false,
        ("REFUSED: %s is claimed by %s — take over a live claim with "
          .. "--force --why"):format(id:sub(1, 8), it.claim))
    end
    taken = (" (taken over from %s)"):format(it.claim)
  end
  local was_todo = not flow.is_doing(it)
  if was_todo then
    local blocked: {string} = {}
    local index = flow.by_id(all)
    for _, b in ipairs(it.blocked_by or {}) do
      if flow.binds(index, b) then
        blocked[#blocked + 1] = b:sub(1, 8)
      end
    end
    if #blocked > 0 and not force then
      return gate.verdict_line("take", false,
        ("REFUSED: %s waits on %s — finish the blocker first, or drop "
          .. "the edge if it no longer binds"):format(id:sub(1, 8),
          table.concat(blocked, " ")))
    end
    if not force then
      local problems = gate.ready_problems(s, it, all)
      if #problems > 0 then
        for _, p in ipairs(problems) do
          print("  " .. p)
        end
        return gate.verdict_line("take", false,
          ("REFUSED: %s misses the spec bar — refine it first"):format(
            id:sub(1, 8)))
      end
      local bound = flow.doing_refusal(all, it)
      if bound then
        return gate.verdict_line("take", false, "REFUSED: " .. bound)
      end
      local unreviewed = gate.review_debt_refusal(all, session, it)
      if unreviewed then
        return gate.verdict_line("take", false, "REFUSED: " .. unreviewed)
      end
    end
  end
  -- One claim per session, never forced away: a collision here is
  -- never repair, unlike a takeover. Only a genuinely NEW claim asks —
  -- a re-take of the session's own item leaves `it.claim` unchanged
  -- and never reaches this.
  if (it.claim or "") ~= session then
    local collision = gate.second_claim_refusal(s, all, id, session)
    if collision then
      return gate.verdict_line("take", false, collision)
    end
  end
  it.claim = session
  local recorded, ierr = item.record_involvement(it.builders, session)
  if not recorded then
    return gate.verdict_line("take", false, "REFUSED: " .. ierr)
  end
  local handed = ""
  if (pr or 0) ~= 0 then
    -- Skip the collision/handover checks (a network round trip) on
    -- an already-recorded number — `store.save`'s clean diff, below,
    -- is what calls this a no-op.
    local already_recorded = pr == (it.pr or 0) and (it.claim or "") == session
    and (it.verdict or "") ~= "request changes"
    if (it.result or "") ~= "" then
      return gate.verdict_line("take", false,
        ("REFUSED: %s carries a research handover — a deliverable is a "
          .. "diff or board state, never both"):format(id:sub(1, 8)))
    end
    if not already_recorded and not force then
      local collision = gate.pr_collision_refusal(all, id, pr)
      if collision then
        return gate.verdict_line("take", false, "REFUSED: " .. collision)
      end
      local refusal = gate.handover_refusal(s, id, pr, it.repo, it.base)
      if refusal then
        return gate.verdict_line("take", false, "REFUSED: " .. refusal)
      end
    end
    it.pr = pr
    -- A new head to judge: the rework's send-back is spent, so the
    -- item is awaiting a verdict again. The judged head stays in
    -- verdict_head, which is how a reviewer sees what moved.
    if it.verdict == "request changes" then
      it.verdict = ""
    end
    handed = (" pr:%d — awaiting review"):format(pr)
  end
  local bad = item.problems(it)
  if #bad > 0 then
    return gate.verdict_line("take", false, table.concat(bad, "; "))
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("take %s by %s%s%s"):format(id:sub(1, 8), session,
      (pr or 0) ~= 0 and (" pr:%d"):format(pr) or "",
      gate.forced_suffix(force, why)))
  if not ok then
    return gate.verdict_line("take", false, err)
  end
  if store.is_noop(err) then
    return gate.verdict_line("take", true, err)
  end
  local base = it.base
  if base == "" then
    base = it.repo:find("cosmopolitan", 1, true) and "master" or "main"
  end
  local branch = handed == "" and (" — branch %s off %s"):format(id:sub(1, 8), base) or ""
  return gate.verdict_line("take", true,
    ("%s is yours%s%s%s"):format(id:sub(1, 8), taken, handed, branch))
end

--- drop: return the lease — the claim (or the review claim alone)
--- releases, and the ITEM, its blockers included, is untouched.
---
--- Releasing without blocking is an assertion about which side
--- stopped: a drop says the WORKER did (a dead wave agent, a session
--- out of budget, a review nobody can finish), so the item is safe to
--- re-offer as-is. An item that cannot proceed — a spec gap, a
--- reopened decision — is not dropped bare: the question becomes its
--- own item (`new`, parented so it is placed), the item `block`s on
--- it, and only then does the claim return, so it waits on the answer
--- instead of bouncing cold to a session that would hit the same
--- wall. Never refused for flow; the one guard is somebody else's
--- LIVE claim (a takeover of the abandoning kind, said on the
--- record). Claim, handover (PR or research result), and any standing
--- verdict clear together: what remains is the item, its spec, its
--- blockers, and the trail.
--- @param s store.Store The store
--- @param id string The item to drop
--- @param session string The dropping session
--- @param why string Why the session lets go, in the commit subject
--- @param force boolean Drop another session's live claim
--- @return integer Exit code
local function cmd_drop(s: store.Store, id: string, session: string,
    why: string, force: boolean): integer
  if (why or ""):match("%S") == nil then
    return gate.verdict_line("drop", false,
      "REFUSED: a drop names why the session lets go — pass --why "
      .. "'<the worker-side reason>'. An ITEM that cannot proceed is "
      .. "not dropped bare: `new` the question and `block` on it first")
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("drop", false, lerr)
  end
  if not flow.is_doing(it) then
    return gate.verdict_line("drop", false,
      ("%s is not in flight — nothing to drop"):format(id:sub(1, 8)))
  end
  -- A drop by the session holding only the REVIEW lock releases the
  -- review, not the item: the diff still awaits its verdict, and the
  -- builder's claim is not the reviewer's to bounce.
  if (it.reviewer or "") ~= "" and it.reviewer == (session or "")
  and (it.claim or "") ~= (session or "") then
    it.reviewer = ""
    local rok, rerr = gate.commit_and_publish(s, it, nil,
      ("drop %s review: %s"):format(id:sub(1, 8), why))
    if not rok then
      return gate.verdict_line("drop", false, rerr)
    end
    return gate.verdict_line("drop", true,
      ("%s's review is anyone's again — the reason is in the log"):format(
        id:sub(1, 8)))
  end
  if (it.claim or "") ~= "" and it.claim ~= (session or "")
  and not health.is_stale(it, gate.age_of(s, it)) and not force then
    return gate.verdict_line("drop", false,
      ("REFUSED: %s is %s's live claim — the builder drops their own "
        .. "work; abandon a dead session's with --force"):format(
        id:sub(1, 8), it.claim))
  end
  it.claim = ""
  it.reviewer = ""
  it.pr = 0
  it.result = ""
  it.verdict = ""
  it.verdict_head = ""
  it.verdict_spec = ""
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("drop %s: %s"):format(id:sub(1, 8), why))
  if not ok then
    return gate.verdict_line("drop", false, err)
  end
  -- Which queue the released item lands in decides the line: blocked
  -- items wait on their question, bare todo is re-offered as-is, and
  -- the bare line names the block-first recovery while the dropping
  -- session still has the context to file the question.
  local all, _lerr = store.list(s)
  if all ~= nil and flow.is_blocked(it, flow.by_id(all)) then
    return gate.verdict_line("drop", true,
      ("%s released — it waits on its open blocker(s), not the queue")
      :format(id:sub(1, 8)))
  end
  return gate.verdict_line("drop", true,
    ("%s is todo again, re-offered as-is — a bare drop says the item "
      .. "is fine; if it cannot proceed, `new` the question and "
      .. "`block %s <question>` first"):format(id:sub(1, 8), id:sub(1, 8)))
end

local function cmd_done(s: store.Store, id: string, reason: string,
    force: boolean, why: string): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("done", false, "REFUSED: " .. forced)
  end
  if reason ~= "completed" and reason ~= "not-planned" then
    return gate.verdict_line("done", false, ("unknown reason: %s"):format(reason))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("done", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("done", false, aerr)
  end
  -- An open PR is work mid-review: ending the item under it makes the
  -- diff vanish from the board while it still exists on GitHub. An
  -- unreviewed PR is dropped or judged first.
  if (it.pr or 0) ~= 0 and (it.verdict or "") ~= "accept" and not force then
    return gate.verdict_line("done", false,
      ("REFUSED: %s has PR #%d awaiting a verdict — done after an accept, "
        .. "or `drop` releases the handover"):format(id:sub(1, 8), it.pr))
  end
  -- A PR-less item that was ever worked is evidence mid-review the same
  -- way: `verdict` now judges it too (re-running the spec's recorded
  -- checks in place of a diff, per skills/work/SKILL.md), so ending it
  -- here with no accept would carry the same unreviewed claim of
  -- success the PR guard above exists to stop. This keys on `builders`
  -- — the append-only record of every session that ever held the claim
  -- — rather than the LIVE claim: `drop` clears `claim` without
  -- touching `builders`, so a live-claim check lets take -> drop -> done
  -- complete worked research silently, with no verdict and no --force.
  -- An item never claimed (no builders, ever) carries no such claim of
  -- success, so it is untouched. `--force --why` is the same repair —
  -- ending an item nothing will ever review (an obsolete slice, a
  -- duplicate) still goes through, named on the record.
  if (it.pr or 0) == 0 and #(it.builders or {}) > 0 and (it.verdict or "") ~= "accept"
  and not force then
    return gate.verdict_line("done", false,
      ("REFUSED: %s has no PR and no accept — an evidence-only item takes "
        .. "a verdict too; record one (`gitboard verdict`), or end it "
        .. "without review via --force --why"):format(id:sub(1, 8)))
  end
  -- The accepted path verifies the merge before ending the item: an
  -- item ended over an unmerged request says the work landed when it
  -- did not, and nothing downstream would catch it. Whether the merge
  -- happened is the one fact the board cannot hold itself, so the
  -- request is read every time (a local-only board has none to read).
  if (it.pr or 0) ~= 0 and (it.verdict or "") == "accept"
  and publish.has_origin(s) and not force then
    local p, perr = gh.pull(s, it.pr, it.repo)
    if p == nil then
      return gate.verdict_line("done", false,
        ("cannot read PR #%d: %s"):format(it.pr, perr))
    end
    local blocked = review.blocks_land(p, it.verdict_head, id)
    if blocked then
      return gate.verdict_line("done", false, "REFUSED: " .. blocked)
    end
    -- A merge cannot be undone, so a head that moved past the one the
    -- accept judged is not a refusal: refusing would strand the item
    -- forever. Say it loudly instead, so the substitution is in the
    -- log rather than nowhere.
    if review.head_moved(p, it.verdict_head) then
      print(("gitboard-done: WARNING PR #%d merged at %s but the accept "
          .. "judged %s"):format(it.pr, (p.head_sha or ""):sub(1, 7),
          (it.verdict_head or ""):sub(1, 7)))
    end
  end
  local from = flow.is_doing(it) and flow.substate(it) or "todo"
  if flow.role(it, all) ~= "work" then
    from = flow.role(it, all)
  end
  it.claim = ""
  it.reviewer = ""
  it.is_held = false
  it.resolution = reason
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("done %s %s (from %s)%s"):format(id:sub(1, 8), reason, from,
      gate.forced_suffix(force, why)))
  if not ok then
    return gate.verdict_line("done", false, err)
  end
  if store.is_noop(err) then
    return gate.verdict_line("done", true, err)
  end
  -- A parent whose last open child just ended is workable again by
  -- derivation — nothing to write, but worth saying: verifying the
  -- outcome its children were supposed to deliver is the next thing
  -- anyone does with it.
  local returned = ""
  local parent = flow.by_id(all)[it.parent or ""]
  if parent ~= nil and item.is_open(parent) then
    local siblings = false
    for _, other in ipairs(all) do
      if other.parent == parent.id and other.id ~= it.id
      and item.is_open(other) then
        siblings = true
        break
      end
    end
    if not siblings then
      returned = (" — %s was %s's last open child: verify its outcome "
        .. "holds, then end it"):format(id:sub(1, 8), parent.id:sub(1, 8))
    end
  end
  return gate.verdict_line("done", true,
    ("%s %s (%s)%s"):format(id:sub(1, 8), reason, from, returned))
end

-- Lane health (`_work.lanes`): a `nil` observe (offline, no token)
-- prints and is never treated as red; `at_sync` does the observe /
-- record / mint pipeline and hands back the lines to print, keeping
-- this module under its 500-line cap.
local function cmd_sync(s: store.Store): integer
  local ok, err = publish.sync(s)
  if not ok then
    return gate.verdict_line("sync", false, err)
  end
  for _, line in ipairs(lanes.at_sync(s)) do
    print(line)
  end
  return gate.verdict_line("sync", true, "state is current")
end

local record gitverbs
  cmd_init: function(dir: string): integer
  cmd_take: function(s: store.Store, id: string, session: string,
  pr: integer, force: boolean, why: string, result?: boolean): integer
  cmd_drop: function(s: store.Store, id: string, session: string,
  why: string, force: boolean): integer
  cmd_done: function(s: store.Store, id: string, reason: string,
  force: boolean, why: string): integer
  cmd_sync: function(s: store.Store): integer
end

local M: gitverbs = {
  cmd_init = cmd_init,
  cmd_take = cmd_take,
  cmd_drop = cmd_drop,
  cmd_done = cmd_done,
  cmd_sync = cmd_sync,
}

return M
