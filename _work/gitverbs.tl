--- The gitboard verbs: every `cmd_*` behind `_work/gitboard.tl`'s
--- dispatch, over `_work.store` (persistence) and `_work.flow`
--- (policy). Verbs receive FULL ids — the dispatcher resolves
--- prefixes — and every verb prints a `gitboard-<verb>:` verdict line
--- and returns its exit code. Mutations commit locally and publish
--- through `store.publish`, whose rejected-push path rebases onto
--- concurrent state and re-checks the WIP invariant before pushing
--- again.
---
--- Decomposition and triage are both `attach`: giving an item a
--- parent is the whole operation, because roles derive from the graph
--- — a captured item becomes work by gaining a parent, and a phased
--- item becomes a container (losing its phase) the moment a child
--- attaches under it. Priority is the other half of triage and has
--- its own verb, `compare`, because an item can be placed without
--- being adopted and adopted without being compared.
local child = require("cosmic.child")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local fs = require("cosmic.fs")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
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

local function cmd_new(s: store.Store, title: string, parent: string,
    spec: string, repo: string, force: boolean, why: string): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("new", false, "REFUSED: " .. forced)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("new", false, aerr)
  end
  local index = flow.by_id(all)
  local phase = ""
  local parent_item: item.Item = nil
  if parent ~= "" then
    parent_item = index[parent]
    if parent_item == nil then
      return gate.verdict_line("new", false, ("no item %s"):format(parent))
    end
    phase = "plan"
  end
  local it: item.Item = {
    id = ksuid.new(), title = title, parent = parent, repo = repo or "",
    phase = phase, beats = {},
    blocked_by = {}, claim = "", pr = 0, verdict = "",
    verdict_head = "", resolution = "",
  }
  local bad = item.problems(it)
  if #bad > 0 then
    return gate.verdict_line("new", false, table.concat(bad, "; "))
  end
  if phase ~= "" and not force then
    -- A phased parent is a workable leaf, and gaining a child takes it
    -- off the board in this same commit — so the slot the child fills
    -- is the one the parent leaves. Net-zero decomposition is admitted
    -- however full the column is; only a parent already off the board
    -- (a container) makes this a real arrival.
    local refusal = gate.wip_refusal(flow.board(all), nil, phase,
      parent_item.phase or "")
    if refusal then
      return gate.verdict_line("new", false, "REFUSED: " .. refusal)
    end
  end
  local also: {item.Item} = {}
  if parent_item ~= nil then
    also = gate.dephased_container(parent_item)
  end
  local ok, err = gate.commit_and_publish(s, it, spec,
    ("new %s %s%s"):format(it.id:sub(1, 8), title,
      gate.forced_suffix(force, why)), nil, also)
  if not ok then
    return gate.verdict_line("new", false, err)
  end
  local entered = "triage — attach it under something, or compare it"
  if phase ~= "" then
    entered = "plan"
  end
  return gate.verdict_line("new", true, ("%s enters %s"):format(it.id, entered))
end

local function cmd_attach(s: store.Store, id: string, parent: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("attach", false, aerr)
  end
  local index = flow.by_id(all)
  local it = index[id]
  local parent_item = index[parent]
  if it == nil then
    return gate.verdict_line("attach", false, ("no item %s"):format(id))
  end
  if parent_item == nil then
    return gate.verdict_line("attach", false, ("no item %s"):format(parent))
  end
  if id == parent then
    return gate.verdict_line("attach", false, "an item cannot parent itself")
  end
  local up = flow.root_of(parent_item, index)
  if up == nil then
    return gate.verdict_line("attach", false,
      ("%s's own parent chain is broken"):format(parent:sub(1, 8)))
  end
  local cur = parent_item
  while cur ~= nil do
    if cur.id == id then
      return gate.verdict_line("attach", false,
        ("attaching under %s would make a cycle"):format(parent:sub(1, 8)))
    end
    cur = index[cur.parent or ""]
  end
  it.parent = parent
  -- Adoption makes a leaf workable: it enters plan, ungated — triage
  -- is a decision already made, the same admission the label board
  -- gave findings.
  if item.is_open(it) and (it.phase or "") == ""
  and not flow.has_open_children(all, id) then
    it.phase = "plan"
  end
  local bad = item.problems(it)
  if #bad > 0 then
    return gate.verdict_line("attach", false, table.concat(bad, "; "))
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("attach %s under %s"):format(id:sub(1, 8), parent:sub(1, 8)), nil,
    gate.dephased_container(parent_item))
  if not ok then
    return gate.verdict_line("attach", false, err)
  end
  return gate.verdict_line("attach", true,
    ("%s now under %s%s"):format(id:sub(1, 8), parent:sub(1, 8),
      (it.phase ~= "" and " — workable, in plan") or ""))
end

--- block/unblock: the `blocked_by` field as a verb, so the landing
--- order between two slices is recorded the same way every other
--- board fact is — one mutation, one commit, one refusal when it does
--- not hold. Hand-editing the field was the standing workaround, and
--- it wrote duplicate ids and ids of items that do not exist; both
--- are refused here, and an existing duplicate is collapsed by the
--- next write.
---
--- A block RECORDS ITS REASON: one cheap command sequences whole
--- chains behind the blocker, and an edge nobody can later judge —
--- does this still bind, or did the spec grow its own workaround? —
--- can only be resolved by whoever remembers writing it. The reason
--- travels on the item (`block_reason`), rendered by `show`, and is
--- what a session weighs before dropping the edge.
--- @param s store.Store The store
--- @param id string The waiting item
--- @param blocker string The item it waits on
--- @param remove boolean True to drop the blocker instead of adding it
--- @param reason string What concretely cannot proceed; required to add
--- @return integer 0 on success, 1 otherwise
local function cmd_block(s: store.Store, id: string, blocker: string,
    remove: boolean, reason: string): integer
  local verb = remove and "unblock" or "block"
  if not remove and (reason or ""):match("%S") == nil then
    return gate.verdict_line(verb, false,
      "REFUSED: a block records why the edge binds — pass --reason "
      .. "'<what concretely cannot proceed until the blocker ends>'")
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line(verb, false, aerr)
  end
  local index = flow.by_id(all)
  local it = index[id]
  if it == nil then
    return gate.verdict_line(verb, false, ("no item %s"):format(id))
  end
  if index[blocker] == nil then
    return gate.verdict_line(verb, false, ("no item %s"):format(blocker))
  end
  if id == blocker then
    return gate.verdict_line(verb, false, "an item cannot block itself")
  end
  -- A blocker that already waits on this item, through any chain,
  -- would leave both permanently unpullable — and `next` would say
  -- nothing, because it just skips what is blocked.
  if not remove and flow.waits_on(index, blocker, id) then
    return gate.verdict_line(verb, false,
      ("%s already waits on %s — blocking would deadlock both"):format(
        blocker:sub(1, 8), id:sub(1, 8)))
  end
  local kept: {string} = {}
  local seen: {string: boolean} = {}
  local had = false
  for _, b in ipairs(it.blocked_by or {}) do
    if b == blocker then
      had = true
    elseif not seen[b] then
      seen[b] = true
      kept[#kept + 1] = b
    end
  end
  if remove and not had then
    return gate.verdict_line(verb, false,
      ("%s does not wait on %s"):format(id:sub(1, 8), blocker:sub(1, 8)))
  end
  -- Refused rather than re-recorded: a second block with a new reason
  -- would silently rewrite the first one's, and the reason is the
  -- record a later unblock is judged against.
  if not remove and had then
    return gate.verdict_line(verb, false,
      ("%s already waits on %s"):format(id:sub(1, 8), blocker:sub(1, 8)))
  end
  if not remove then
    kept[#kept + 1] = blocker
  end
  it.blocked_by = kept
  local reasons = it.block_reason or {}
  if remove then
    reasons[blocker] = nil
  else
    reasons[blocker] = reason
  end
  it.block_reason = reasons
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("%s %s on %s"):format(verb, id:sub(1, 8), blocker:sub(1, 8)), it.phase)
  if not ok then
    return gate.verdict_line(verb, false, err)
  end
  local shape = "now waits on"
  if remove then
    shape = "no longer waits on"
  end
  return gate.verdict_line(verb, true,
    ("%s %s %s (%d blocker(s))"):format(id:sub(1, 8), shape,
      blocker:sub(1, 8), #kept))
end

local function cmd_spec(s: store.Store, id: string, file: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("spec", false, lerr)
  end
  local body, rerr = fs.read(file)
  if body == nil then
    return gate.verdict_line("spec", false, rerr)
  end
  local ok, err = gate.commit_and_publish(s, it, body,
    ("spec %s"):format(id:sub(1, 8)), it.phase)
  if not ok then
    return gate.verdict_line("spec", false, err)
  end
  return gate.verdict_line("spec", true, ("%s's spec replaced"):format(id:sub(1, 8)))
end

local function cmd_check(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("check", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("check", false, aerr)
  end
  local problems = gate.ready_problems(s, it, all)
  for _, p in ipairs(problems) do
    print("  " .. p)
  end
  if #problems > 0 then
    return gate.verdict_line("check", false,
      ("%s misses the ready bar (%d problem(s))"):format(id:sub(1, 8),
        #problems))
  end
  return gate.verdict_line("check", true,
    ("%s meets the ready bar"):format(id:sub(1, 8)))
end

local function cmd_move(s: store.Store, id: string, target: string,
    claim: string, pr: integer, force: boolean, why: string): integer
  local forced = gate.force_refusal(force, why)
  if forced then
    return gate.verdict_line("move", false, "REFUSED: " .. forced)
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("move", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("move", false, aerr)
  end
  local r = flow.role(it, all)
  if r ~= "work" then
    return gate.verdict_line("move", false,
      ("%s is a %s — only workable leaves move through phases"):format(
        id:sub(1, 8), r))
  end
  local from = it.phase
  if from == target then
    return gate.verdict_line("move", false,
      ("%s is already in %s"):format(id:sub(1, 8), target))
  end
  -- The bar is asked of the item AS IT WOULD BE in the target phase,
  -- so a repair move out of no-phase is judged on where it lands.
  it.phase = target
  if target == "ready" and not force then
    local problems = gate.ready_problems(s, it, all)
    if #problems > 0 then
      for _, p in ipairs(problems) do
        print("  " .. p)
      end
      return gate.verdict_line("move", false,
        ("REFUSED: %s misses the ready bar"):format(id:sub(1, 8)))
    end
  end
  -- A handover to check is a handover to a REVIEWER, and the reviewer
  -- follows the pr field to the diff — as does the landing step that
  -- reads it back. Without one the item says "judge something" and
  -- names nothing.
  if target == "check" and (pr or 0) == 0 and (it.pr or 0) == 0 and not force then
    return gate.verdict_line("move", false,
      ("REFUSED: a handover to check names its PR — pass --pr N"))
  end
  if target == "check" and not force then
    local refusal = gate.handover_refusal(s, id,
      (pr or 0) ~= 0 and pr or it.pr, it.repo)
    if refusal then
      return gate.verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  -- `land` holds work whose review is FINISHED, and the only action
  -- there is the merge `gitboard land` performs from the verdict and
  -- PR it reads back. An arrival carrying neither is an item `next`
  -- answers `finish` for and `land` refuses, forever.
  if target == "land" and not force then
    local refusal = gate.land_refusal(it)
    if refusal then
      return gate.verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  if claim ~= nil and claim ~= "" then
    it.claim = claim
  end
  if pr ~= nil and pr ~= 0 then
    it.pr = pr
  end
  if flow.is_return(from, target) then
    it.claim = ""
    -- A verdict describes one head in one phase. Moving leftward out
    -- of a judged phase says that head is no longer what the item is,
    -- so the judgment goes with it — otherwise rework re-enters land
    -- on the old accept and merges what nobody reviewed.
    if from == "check" or from == "land" then
      it.verdict = ""
      it.verdict_head = ""
      it.enable = ""
    end
  end
  local bad = item.problems(it)
  if #bad > 0 then
    return gate.verdict_line("move", false, table.concat(bad, "; "))
  end
  if not force then
    local refusal = gate.wip_refusal(flow.board(all), from, target)
    if refusal then
      return gate.verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("move %s %s -> %s%s"):format(id:sub(1, 8), from, target,
      gate.forced_suffix(force, why)), from)
  if not ok then
    return gate.verdict_line("move", false, err)
  end
  return gate.verdict_line("move", true,
    ("%s %s -> %s"):format(id:sub(1, 8), from, target))
end

--- Phases `done` refuses to end from without --force: the mid-flow
--- phases where an ending would make work vanish. Completing from
--- land IS the landing; a not-planned ending there would discard an
--- accept, so only "completed" passes.
local NO_DONE: {string: boolean} = {ready = true, ["do"] = true}

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
  local refused = NO_DONE[it.phase]
  or (it.phase == "land" and reason ~= "completed")
  if refused and not force then
    return gate.verdict_line("done", false,
      ("REFUSED: %s is mid-flow in %s — move it left first"):format(
        id:sub(1, 8), it.phase))
  end
  local from = it.phase
  if from == "" then
    from = "unphased"
  end
  it.phase = ""
  it.resolution = reason
  local back = gate.rephased_parent(it, all)
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("done %s %s (from %s)%s"):format(id:sub(1, 8), reason, from,
      gate.forced_suffix(force, why)), from, back)
  if not ok then
    return gate.verdict_line("done", false, err)
  end
  local returned = ""
  if #back > 0 then
    returned = (" — %s was its last open child, so %s returns to plan")
    :format(id:sub(1, 8), back[1].id:sub(1, 8))
  end
  return gate.verdict_line("done", true,
    ("%s %s (%s)%s"):format(id:sub(1, 8), reason, from, returned))
end

local function cmd_sync(s: store.Store): integer
  local ok, err = store.sync(s)
  if not ok then
    return gate.verdict_line("sync", false, err)
  end
  return gate.verdict_line("sync", true, "state is current")
end

local record gitverbs
  cmd_init: function(dir: string): integer
  cmd_new: function(s: store.Store, title: string, parent: string,
  spec: string, repo: string, force: boolean, why: string): integer
  cmd_attach: function(s: store.Store, id: string, parent: string): integer
  cmd_block: function(s: store.Store, id: string, blocker: string,
  remove: boolean, reason: string): integer
  cmd_spec: function(s: store.Store, id: string, file: string): integer
  cmd_check: function(s: store.Store, id: string): integer
  cmd_move: function(s: store.Store, id: string, target: string,
  claim: string, pr: integer, force: boolean, why: string): integer
  cmd_done: function(s: store.Store, id: string, reason: string,
  force: boolean, why: string): integer
  cmd_sync: function(s: store.Store): integer
end

local M: gitverbs = {
  cmd_init = cmd_init,
  cmd_new = cmd_new,
  cmd_attach = cmd_attach,
  cmd_block = cmd_block,
  cmd_spec = cmd_spec,
  cmd_check = cmd_check,
  cmd_move = cmd_move,
  cmd_done = cmd_done,
  cmd_sync = cmd_sync,
}

return M
