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
--- — a finding becomes work by gaining a parent, and a phased item
--- becomes a container (losing its phase) the moment a child attaches
--- under it.
local child = require("cosmic.child")
local flow = require("_work.flow")
local fs = require("cosmic.fs")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local store = require("_work.store")

--- Print a verb's verdict line and return its exit code.
--- @param verb string The verb
--- @param ok boolean Whether it succeeded
--- @param detail string What happened
--- @return integer 0 on success, 1 otherwise
local function verdict_line(verb: string, ok: boolean, detail: string): integer
  print(("gitboard-%s: %s"):format(verb, detail))
  if ok then
    return 0
  end
  return 1
end

--- The WIP refusal an arrival in a phase earns, or nil when it may
--- enter. The one gate `new` and `move` share.
--- @param b flow.Board The board
--- @param from string Current phase, or nil for an entry
--- @param to string Target phase
--- @return string | nil The refusal
local function wip_refusal(b: flow.Board, from: string, to: string): string
  local limit = flow.LIMITS[to]
  if limit == nil or #(b[to] or {}) < limit
  or flow.admits_over_limit(from, to) then
    return nil
  end
  return ("%s is at %d/%d — drain it before pulling more"):format(
    to, #(b[to] or {}), limit)
end

--- Save an item and publish the commit, re-checking the WIP gate
--- against the merged state when the push loses a race.
--- @param s store.Store The store
--- @param it item.Item The mutated item
--- @param spec string Replacement spec, or nil to leave the sidecar alone
--- @param message string Commit subject
--- @param from string Phase the mutation left, or nil for an entry
--- @return boolean True once committed (and pushed, given a remote)
--- @return string Error message
local function commit_and_publish(s: store.Store, it: item.Item, spec: string,
    message: string, from: string): boolean, string
  local saved, serr = store.save(s, it, spec, message)
  if not saved then
    return false, serr
  end
  return store.publish(s, function(): string
      local merged = store.list(s)
      if merged == nil then
        return "state repository unreadable after rebase"
      end
      -- The mutated item is already IN the merged state; ask whether its
      -- phase ended up over-limit with an arrival the limit may refuse.
      local limit = flow.LIMITS[it.phase]
      local b = flow.board(merged)
      if limit ~= nil and #(b[it.phase] or {}) > limit
      and not flow.admits_over_limit(from, it.phase) then
        return ("%s is over %d after a concurrent move"):format(it.phase, limit)
      end
      return nil
    end)
end

--- De-phase an item that just became a container: a child attached
--- under it, so it is no longer workable and leaves the board. Its
--- claim clears with the phase.
--- @param s store.Store The store
--- @param parent item.Item The item that gained a child
--- @return boolean True on success (or nothing to do)
--- @return string Error message
local function dephase_container(s: store.Store,
    parent: item.Item): boolean, string
  if (parent.phase or "") == "" then
    return true
  end
  local was = parent.phase
  parent.phase = ""
  parent.claim = ""
  return store.save(s, parent,
    nil, ("decompose %s: left %s, now a container"):format(
      parent.id:sub(1, 8), was))
end

local function cmd_init(dir: string): integer
  if not fs.is_dir(fs.join(dir, ".git")) then
    local r, err = child.run({"git", "init", "-q", dir})
    if r == nil or not r.ok then
      return verdict_line("init", false,
        err or (r and r.stderr) or "git init failed")
    end
  end
  local made, merr = fs.make_dirs(fs.join(dir, "items"))
  if not made then
    return verdict_line("init", false, merr)
  end
  local kept, kerr = fs.write(fs.join(dir, "items", ".gitkeep"), "")
  if not kept then
    return verdict_line("init", false, kerr)
  end
  return verdict_line("init", true,
    ("state repository ready at %s"):format(dir))
end

local function cmd_new(s: store.Store, title: string, parent: string,
    rank: integer, spec: string, force: boolean): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("new", false, aerr)
  end
  local index = flow.by_id(all)
  local phase = ""
  local parent_item: item.Item = nil
  if parent ~= "" then
    parent_item = index[parent]
    if parent_item == nil then
      return verdict_line("new", false, ("no item %s"):format(parent))
    end
    phase = "plan"
  end
  local it: item.Item = {
    id = ksuid.new(), title = title, parent = parent,
    phase = phase, rank = rank or 0,
    blocked_by = {}, claim = "", pr = 0, verdict = "",
    verdict_head = "", resolution = "",
  }
  local bad = item.problems(it)
  if #bad > 0 then
    return verdict_line("new", false, table.concat(bad, "; "))
  end
  if phase ~= "" and not force then
    local refusal = wip_refusal(flow.board(all), nil, phase)
    if refusal then
      return verdict_line("new", false, "REFUSED: " .. refusal)
    end
  end
  if parent_item ~= nil then
    local cleared, derr = dephase_container(s, parent_item)
    if not cleared then
      return verdict_line("new", false, derr)
    end
  end
  local ok, err = commit_and_publish(s, it, spec,
    ("new %s %s"):format(it.id:sub(1, 8), title), nil)
  if not ok then
    return verdict_line("new", false, err)
  end
  local entered = "a root — rank it as a goal, or triage it as a finding"
  if phase ~= "" then
    entered = "plan"
  elseif (rank or 0) > 0 then
    entered = ("goal, rank %d"):format(rank)
  end
  return verdict_line("new", true, ("%s enters %s"):format(it.id, entered))
end

local function cmd_attach(s: store.Store, id: string, parent: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("attach", false, aerr)
  end
  local index = flow.by_id(all)
  local it = index[id]
  local parent_item = index[parent]
  if it == nil then
    return verdict_line("attach", false, ("no item %s"):format(id))
  end
  if parent_item == nil then
    return verdict_line("attach", false, ("no item %s"):format(parent))
  end
  if id == parent then
    return verdict_line("attach", false, "an item cannot parent itself")
  end
  local up = flow.root_of(parent_item, index)
  if up == nil then
    return verdict_line("attach", false,
      ("%s's own parent chain is broken"):format(parent:sub(1, 8)))
  end
  local cur = parent_item
  while cur ~= nil do
    if cur.id == id then
      return verdict_line("attach", false,
        ("attaching under %s would make a cycle"):format(parent:sub(1, 8)))
    end
    cur = index[cur.parent or ""]
  end
  it.parent = parent
  it.rank = 0
  -- Adoption makes a leaf workable: it enters plan, ungated — triage
  -- is a decision already made, the same admission the label board
  -- gave findings.
  if item.is_open(it) and (it.phase or "") == ""
  and not flow.has_open_children(all, id) then
    it.phase = "plan"
  end
  local bad = item.problems(it)
  if #bad > 0 then
    return verdict_line("attach", false, table.concat(bad, "; "))
  end
  local cleared, derr = dephase_container(s, parent_item)
  if not cleared then
    return verdict_line("attach", false, derr)
  end
  local ok, err = commit_and_publish(s, it, nil,
    ("attach %s under %s"):format(id:sub(1, 8), parent:sub(1, 8)), nil)
  if not ok then
    return verdict_line("attach", false, err)
  end
  return verdict_line("attach", true,
    ("%s now under %s%s"):format(id:sub(1, 8), parent:sub(1, 8),
      (it.phase ~= "" and " — workable, in plan") or ""))
end

local function cmd_spec(s: store.Store, id: string, file: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("spec", false, lerr)
  end
  local body, rerr = fs.read(file)
  if body == nil then
    return verdict_line("spec", false, rerr)
  end
  local ok, err = commit_and_publish(s, it, body,
    ("spec %s"):format(id:sub(1, 8)), it.phase)
  if not ok then
    return verdict_line("spec", false, err)
  end
  return verdict_line("spec", true, ("%s's spec replaced"):format(id:sub(1, 8)))
end

--- The problems that keep an item from `ready`: it must be workable,
--- its spec must fill the ready-bar sections, and the whole graph
--- must be traceable. The one list `check` reports and `move ID
--- ready` enforces.
--- @param s store.Store The store
--- @param it item.Item The item
--- @param all {item.Item} Every item
--- @return {string} Problems, empty when the item meets the bar
local function ready_problems(s: store.Store, it: item.Item,
    all: {item.Item}): {string}
  local out = flow.trace_problems(all)
  local r = flow.role(it, all)
  if r ~= "work" then
    out[#out + 1] = ("%s is a %s, not workable"):format(it.id:sub(1, 8), r)
  end
  for _, gap in ipairs(flow.ready_gaps(store.read_spec(s, it.id))) do
    out[#out + 1] = ("spec section missing or empty: %s"):format(gap)
  end
  return out
end

local function cmd_check(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("check", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("check", false, aerr)
  end
  local problems = ready_problems(s, it, all)
  for _, p in ipairs(problems) do
    print("  " .. p)
  end
  if #problems > 0 then
    return verdict_line("check", false,
      ("%s misses the ready bar (%d problem(s))"):format(id:sub(1, 8),
        #problems))
  end
  return verdict_line("check", true,
    ("%s meets the ready bar"):format(id:sub(1, 8)))
end

local function cmd_move(s: store.Store, id: string, target: string,
    claim: string, force: boolean): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("move", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("move", false, aerr)
  end
  local r = flow.role(it, all)
  if r ~= "work" then
    return verdict_line("move", false,
      ("%s is a %s — only workable leaves move through phases"):format(
        id:sub(1, 8), r))
  end
  local from = it.phase
  if from == target then
    return verdict_line("move", false,
      ("%s is already in %s"):format(id:sub(1, 8), target))
  end
  if target == "ready" and not force then
    local problems = ready_problems(s, it, all)
    if #problems > 0 then
      for _, p in ipairs(problems) do
        print("  " .. p)
      end
      return verdict_line("move", false,
        ("REFUSED: %s misses the ready bar"):format(id:sub(1, 8)))
    end
  end
  it.phase = target
  if claim ~= nil and claim ~= "" then
    it.claim = claim
  end
  if flow.is_return(from, target) then
    it.claim = ""
  end
  local bad = item.problems(it)
  if #bad > 0 then
    return verdict_line("move", false, table.concat(bad, "; "))
  end
  if not force then
    local refusal = wip_refusal(flow.board(all), from, target)
    if refusal then
      return verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  local ok, err = commit_and_publish(s, it, nil,
    ("move %s %s -> %s"):format(id:sub(1, 8), from, target), from)
  if not ok then
    return verdict_line("move", false, err)
  end
  return verdict_line("move", true,
    ("%s %s -> %s"):format(id:sub(1, 8), from, target))
end

--- The phase each verdict sends an item to: the three directions out
--- of check.
local VERDICT_MOVES: {string: string} = {
  ["accept"] = "land",
  ["request changes"] = "do",
  ["reject"] = "plan",
}

local function cmd_verdict(s: store.Store, id: string, kind: string,
    pr: integer, head: string): integer
  local target = VERDICT_MOVES[kind]
  if target == nil then
    return verdict_line("verdict", false, ("unknown verdict: %s"):format(kind))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("verdict", false, lerr)
  end
  if (it.phase or "") == "" then
    return verdict_line("verdict", false,
      ("%s is not on the board — verdicts judge phased work"):format(
        id:sub(1, 8)))
  end
  local from = it.phase
  it.verdict = kind
  it.verdict_head = head or ""
  if pr ~= nil and pr ~= 0 then
    it.pr = pr
  end
  it.phase = target
  -- A verdict is a decision already made: an accept enters land and a
  -- send-back is a return, so no WIP gate applies in any direction.
  local ok, err = commit_and_publish(s, it, nil,
    ("verdict %s %s (%s -> %s)"):format(id:sub(1, 8), kind, from, target),
    from)
  if not ok then
    return verdict_line("verdict", false, err)
  end
  return verdict_line("verdict", true,
    ("%s on %s: %s -> %s"):format(kind, id:sub(1, 8), from, target))
end

--- Phases `done` refuses to end from without --force: the mid-flow
--- phases where an ending would make work vanish. Completing from
--- land IS the landing; a not-planned ending there would discard an
--- accept, so only "completed" passes.
local NO_DONE: {string: boolean} = {ready = true, ["do"] = true}

local function cmd_done(s: store.Store, id: string, reason: string,
    force: boolean): integer
  if reason ~= "completed" and reason ~= "not-planned" then
    return verdict_line("done", false, ("unknown reason: %s"):format(reason))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("done", false, lerr)
  end
  local refused = NO_DONE[it.phase]
  or (it.phase == "land" and reason ~= "completed")
  if refused and not force then
    return verdict_line("done", false,
      ("REFUSED: %s is mid-flow in %s — move it left first"):format(
        id:sub(1, 8), it.phase))
  end
  local from = it.phase
  if from == "" then
    from = "unphased"
  end
  it.phase = ""
  it.resolution = reason
  local ok, err = commit_and_publish(s, it, nil,
    ("done %s %s (from %s)"):format(id:sub(1, 8), reason, from), from)
  if not ok then
    return verdict_line("done", false, err)
  end
  return verdict_line("done", true,
    ("%s %s (%s)"):format(id:sub(1, 8), reason, from))
end

local function cmd_sync(s: store.Store): integer
  local ok, err = store.sync(s)
  if not ok then
    return verdict_line("sync", false, err)
  end
  return verdict_line("sync", true, "state is current")
end

local record gitverbs
  verdict_line: function(verb: string, ok: boolean, detail: string): integer
  cmd_init: function(dir: string): integer
  cmd_new: function(s: store.Store, title: string, parent: string,
  rank: integer, spec: string, force: boolean): integer
  cmd_attach: function(s: store.Store, id: string, parent: string): integer
  cmd_spec: function(s: store.Store, id: string, file: string): integer
  cmd_check: function(s: store.Store, id: string): integer
  cmd_move: function(s: store.Store, id: string, target: string,
  claim: string, force: boolean): integer
  cmd_verdict: function(s: store.Store, id: string, kind: string,
  pr: integer, head: string): integer
  cmd_done: function(s: store.Store, id: string, reason: string,
  force: boolean): integer
  cmd_sync: function(s: store.Store): integer
end

local M: gitverbs = {
  verdict_line = verdict_line,
  cmd_init = cmd_init,
  cmd_new = cmd_new,
  cmd_attach = cmd_attach,
  cmd_spec = cmd_spec,
  cmd_check = cmd_check,
  cmd_move = cmd_move,
  cmd_verdict = cmd_verdict,
  cmd_done = cmd_done,
  cmd_sync = cmd_sync,
}

return M
