--- The state verbs: `take` (claim work, record its PR), `drop`
--- (release a claim with the gap named), `done`, `spec`, and the
--- housekeeping `init` and `sync` — every `cmd_*` behind
--- `_work/gitboard.tl`'s dispatch that is not a graph mutation. The
--- verbs that shape the graph — `new`, `attach`, `block` and its
--- `unblock` half — are `_work.gitgraph`. Both halves run over
--- `_work.store` (persistence) and `_work.flow` (policy). Verbs
--- receive FULL ids — the dispatcher resolves prefixes — and every
--- verb prints a `gitboard-<verb>:` verdict line and returns its exit
--- code. Mutations commit locally and publish through
--- `publish.publish`, whose rejected-push path drops the mutation
--- whole, re-syncs, and refuses — re-running the verb re-applies
--- every gate against the merged board.
local child = require("cosmic.child")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local gh = require("_work.gh")
local fs = require("cosmic.fs")
local health = require("_work.health")
local item = require("_work.item")
local lanes = require("_work.lanes")
local publish = require("_work.publish")
local review = require("_work.review")
local store = require("_work.store")

local function cmd_init(dir: string): integer
  if not fs.is_dir(fs.join(dir, ".git")) then
    local r, err = child.run({"git", "init", "-q", dir})
    if r == nil or not r.ok then
      return gate.verdict_line("init", false,
        err or (r and r.stderr) or "git init failed")
    end
  end
  local made, merr = fs.make_dirs(fs.join(dir, "items"))
  if not made then
    return gate.verdict_line("init", false, merr)
  end
  local kept, kerr = fs.write(fs.join(dir, "items", ".gitkeep"), "")
  if not kept then
    return gate.verdict_line("init", false, kerr)
  end
  return gate.verdict_line("init", true,
    ("state repository ready at %s"):format(dir))
end

--- spec: replace ID's spec sidecar with FILE's text, the compare-and-swap
--- against `base` proving the writer read what is there. An in-flight
--- item's spec is its claim holder's to move (`gate.spec_refusal`) — a
--- foreign write onto a live claim needs `--force --why`, same as
--- taking one over.
--- @param s store.Store The store
--- @param id string The item whose spec is replaced
--- @param file string Path to the replacement markdown
--- @param base string | nil The spec text the caller read, as a file path
--- @param session string | nil The session making the write
--- @param force boolean | nil Rewrite a foreign LIVE claim's spec
--- @param why string | nil Why --force was needed
--- @return integer Exit code
local function cmd_spec(s: store.Store, id: string, file: string,
    base?: string, session?: string, force?: boolean, why?: string): integer
  local frc = force or false
  local rsn = why or ""
  local forced = gate.force_refusal(frc, rsn)
  if forced then
    return gate.verdict_line("spec", false, "REFUSED: " .. forced)
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("spec", false, lerr)
  end
  if not frc then
    local refusal = gate.spec_refusal(it, session or "")
    if refusal then
      return gate.verdict_line("spec", false, refusal)
    end
  end
  local body, rerr = fs.read(file)
  if body == nil then
    return gate.verdict_line("spec", false, rerr)
  end
  local stale = gate.base_refusal(store.read_spec(s, id), base or "", id)
  if stale then
    return gate.verdict_line("spec", false, stale)
  end
  local ok, err = gate.commit_and_publish(s, it, body,
    ("spec %s%s"):format(id:sub(1, 8), gate.forced_suffix(frc, rsn)))
  if not ok then
    return gate.verdict_line("spec", false, err)
  end
  return gate.verdict_line("spec", true, ("%s's spec replaced"):format(id:sub(1, 8)))
end

--- The age of one item's claim, for the lease checks, read from its
--- last board commit.
--- @param s store.Store The store
--- @param it item.Item The item
--- @return health.Ages Seconds since last commit, for this item alone
local function age_of(s: store.Store, it: item.Item): health.Ages
  local ages: health.Ages = {}
  local now = os.time()
  local t = publish.touched_at(s, it.id)
  if t ~= nil and t <= now then
    ages[it.id] = now - t
  end
  return ages
end

--- The review claim inside `take`: the lock pushed BEFORE the
--- reading starts, so two sessions never verify one diff. Reached by
--- derivation, not by a verb of its own — an item awaiting a verdict,
--- taken by a session that is not its builder, can only mean the
--- review. The claim is a lease (`health`'s review horizon — short,
--- because a review's dwell is minutes) and mutual exclusion only: a
--- verdict from any session stands and consumes it.
--- @param s store.Store The store
--- @param it item.Item The item whose review is claimed
--- @param session string The reviewing session
--- @param force boolean Take over a LIVE foreign review claim
--- @param why string Why --force was needed
--- @return integer Exit code
local function take_review(s: store.Store, it: item.Item, session: string,
    force: boolean, why: string): integer
  local id8 = it.id:sub(1, 8)
  if (it.reviewer or "") == session then
    return gate.verdict_line("take", true,
      ("%s's review is already yours"):format(id8))
  end
  -- A standing foreign claim splits on the lease: a live one is a
  -- reviewer mid read-verify-verdict, taken over only on the record;
  -- a stale one is a session that stopped moving the board, and the
  -- diff is anyone's again — the takeover is noted, never gated.
  local taken = ""
  if (it.reviewer or "") ~= "" then
    if not health.is_review_stale(it, age_of(s, it)) and not force then
      return gate.verdict_line("take", false,
        ("REFUSED: %s is under review by %s — take over a live review "
          .. "with --force --why"):format(id8, it.reviewer))
    end
    taken = (" (taken over from %s)"):format(it.reviewer)
  end
  it.reviewer = session
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("review %s claimed by %s%s"):format(id8, session,
      gate.forced_suffix(force, why)))
  if not ok then
    return gate.verdict_line("take", false, err)
  end
  return gate.verdict_line("take", true,
    ("%s's review is yours%s — verdict when done consumes the claim")
    :format(id8, taken))
end

--- take: claim an item, record its PR, or claim its review — which
--- one is derived from the item's own facts, never declared.
---
--- A take of TODO work (no claim, no PR) is the pull, and it is where
--- the two quality gates bind: the spec bar (`gate.ready_problems`)
--- and the doing bound (`flow.doing_refusal`). A take of an item
--- AWAITING A VERDICT by a session that is not its builder is the
--- review claim (`take_review`). Everything else `take` does —
--- recording a PR on your own claim, re-claiming your own item,
--- taking over a stale claim — is motion on work already in flight
--- and asks neither gate.
---
--- Recording a PR is the handover to review: the number must be free
--- (no other OPEN item already carries it — `gate.pr_collision_refusal`),
--- the request is read (open, not draft, `Board:` line, CI not failing —
--- `gate.handover_refusal`), and a standing `request changes` verdict
--- clears, because the new push is a new head to judge.
--- @param s store.Store The store
--- @param id string The item to take
--- @param session string The claiming session
--- @param pr integer The PR to record, 0 for none
--- @param force boolean Take over a LIVE foreign claim
--- @param why string Why --force was needed
--- @return integer Exit code
local function cmd_take(s: store.Store, id: string, session: string,
    pr: integer, force: boolean, why: string): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("take", false, "REFUSED: " .. forced)
  end
  if (session or "") == "" then
    return gate.verdict_line("take", false,
      "REFUSED: a claim names its session — set GITBOARD_SESSION or pass "
      .. "--session")
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
  -- An item awaiting a verdict, taken by a session that is not its
  -- builder with no PR to record, is the review claim.
  if (pr or 0) == 0 and (it.pr or 0) ~= 0 and (it.verdict or "") == ""
  and (it.claim or "") ~= session then
    return take_review(s, it, session, force, why)
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
    if not health.is_stale(it, age_of(s, it)) and not force then
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
    end
  end
  it.claim = session
  item.record_builder(it, session)
  local handed = ""
  if (pr or 0) ~= 0 then
    if pr == (it.pr or 0) and (it.verdict or "") ~= "request changes"
    and (it.claim or "") == session then
      return gate.verdict_line("take", true,
        ("%s already records pr:%d"):format(id:sub(1, 8), pr))
    end
    if not force then
      local collision = gate.pr_collision_refusal(all, id, pr)
      if collision then
        return gate.verdict_line("take", false, "REFUSED: " .. collision)
      end
      local refusal = gate.handover_refusal(s, id, pr, it.repo)
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
  return gate.verdict_line("take", true,
    ("%s is yours%s%s"):format(id:sub(1, 8), taken, handed))
end

--- drop: release an item back to todo, the gap named.
---
--- A drop is the system correcting itself — an under-specified spec
--- caught before a wrong guess — so it is never refused for flow;
--- the one guard is over somebody else's LIVE claim, which is a
--- takeover of the abandoning kind and says so on the record. The
--- claim, the PR, and any standing verdict clear together: what
--- remains is the item, its spec, and the trail.
--- @param s store.Store The store
--- @param id string The item to drop
--- @param session string The dropping session
--- @param why string The gap, recorded in the commit subject
--- @param force boolean Drop another session's live claim
--- @return integer Exit code
local function cmd_drop(s: store.Store, id: string, session: string,
    why: string, force: boolean): integer
  if (why or ""):match("%S") == nil then
    return gate.verdict_line("drop", false,
      "REFUSED: a drop names the gap — pass --why '<what the spec "
      .. "cannot answer>'; the next session refines from it")
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
      ("%s's review is anyone's again — the gap is in the log"):format(
        id:sub(1, 8)))
  end
  if (it.claim or "") ~= "" and it.claim ~= (session or "")
  and not health.is_stale(it, age_of(s, it)) and not force then
    return gate.verdict_line("drop", false,
      ("REFUSED: %s is %s's live claim — the builder drops their own "
        .. "work; abandon a dead session's with --force"):format(
        id:sub(1, 8), it.claim))
  end
  it.claim = ""
  it.reviewer = ""
  it.pr = 0
  it.verdict = ""
  it.verdict_head = ""
  it.verdict_spec = ""
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("drop %s: %s"):format(id:sub(1, 8), why))
  if not ok then
    return gate.verdict_line("drop", false, err)
  end
  return gate.verdict_line("drop", true,
    ("%s is todo again — the gap is in the log"):format(id:sub(1, 8)))
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
        .. "or drop it with the gap named"):format(id:sub(1, 8), it.pr))
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
  it.resolution = reason
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("done %s %s (from %s)%s"):format(id:sub(1, 8), reason, from,
      gate.forced_suffix(force, why)))
  if not ok then
    return gate.verdict_line("done", false, err)
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
  cmd_spec: function(s: store.Store, id: string, file: string,
  base?: string, session?: string, force?: boolean, why?: string): integer
  cmd_take: function(s: store.Store, id: string, session: string,
  pr: integer, force: boolean, why: string): integer
  cmd_drop: function(s: store.Store, id: string, session: string,
  why: string, force: boolean): integer
  cmd_done: function(s: store.Store, id: string, reason: string,
  force: boolean, why: string): integer
  cmd_sync: function(s: store.Store): integer
end

local M: gitverbs = {
  cmd_init = cmd_init,
  cmd_spec = cmd_spec,
  cmd_take = cmd_take,
  cmd_drop = cmd_drop,
  cmd_done = cmd_done,
  cmd_sync = cmd_sync,
}

return M
