--- The gitboard verbs: every `cmd_*` behind `_work/gitboard.tl`'s
--- dispatch, over `_work.store` (persistence) and `_work.flow`
--- (policy). Split from the CLI the way `_work.verbs` splits from
--- `_work.board`. Every verb prints a `gitboard-<verb>:` verdict line
--- and returns its exit code; mutations commit locally and publish
--- through `store.publish`, whose rejected-push path rebases onto
--- concurrent state and re-checks the WIP invariant before pushing
--- again.
local child = require("cosmic.child")
local flow = require("_work.flow")
local fs = require("cosmic.fs")
local item = require("_work.item")
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

--- The WIP refusal a slice's arrival in a phase earns, or nil when it
--- may enter. The one gate `new` and `move` share.
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

local function cmd_new(s: store.Store, kind: string, id: string, title: string,
    parent: string, rank: integer, spec: string, force: boolean): integer
  local existing = store.load(s, id)
  if existing ~= nil then
    return verdict_line("new", false,
      ("item %s already exists (%s)"):format(id, existing.kind))
  end
  local phase = ""
  if kind == "slice" then
    phase = "plan"
  end
  local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local it: item.Item = {
    id = id, kind = kind, title = title, parent = parent or "",
    phase = phase, rank = rank or 0, opened = stamp,
    blocked_by = {}, claim = "", pr = 0, verdict = "",
    verdict_head = "", resolution = "",
  }
  local bad = item.problems(it)
  if #bad > 0 then
    return verdict_line("new", false, table.concat(bad, "; "))
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("new", false, aerr)
  end
  if kind == "slice" and not force then
    local refusal = wip_refusal(flow.board(all), nil, phase)
    if refusal then
      return verdict_line("new", false, "REFUSED: " .. refusal)
    end
  end
  all[#all + 1] = it
  local trace = flow.trace_problems(all)
  if #trace > 0 then
    return verdict_line("new", false, table.concat(trace, "; "))
  end
  local ok, err = commit_and_publish(s, it, spec,
    ("new %s %s (%s)"):format(kind, id, title), nil)
  if not ok then
    return verdict_line("new", false, err)
  end
  local entered = phase
  if entered == "" then
    entered = kind
  end
  return verdict_line("new", true, ("%s enters %s"):format(id, entered))
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
    ("spec %s"):format(id), it.phase)
  if not ok then
    return verdict_line("spec", false, err)
  end
  return verdict_line("spec", true, ("%s's spec replaced"):format(id))
end

--- The problems that keep a slice from `ready`: hollow or missing
--- ready-bar sections in its spec, plus any hierarchy problem. The
--- one list `check` reports and `move ID ready` enforces.
--- @param s store.Store The store
--- @param it item.Item The slice
--- @param all {item.Item} Every item
--- @return {string} Problems, empty when the slice meets the bar
local function ready_problems(s: store.Store, it: item.Item,
    all: {item.Item}): {string}
  local out = flow.trace_problems(all)
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
  if it.kind ~= "slice" then
    return verdict_line("check", true,
      ("%s is a %s — the ready bar binds slices"):format(id, it.kind))
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
      ("%s misses the ready bar (%d problem(s))"):format(id, #problems))
  end
  return verdict_line("check", true, ("%s meets the ready bar"):format(id))
end

local function cmd_status(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("status", false, aerr)
  end
  local b = flow.board(all)
  local index = flow.by_id(all)
  for _, phase in ipairs(item.PHASES) do
    print(("%-6s %d/%d"):format(phase, #(b[phase] or {}), flow.LIMITS[phase]))
    for _, i in ipairs(flow.oldest_first(b, phase)) do
      local marks = ""
      if i.claim ~= "" then marks = marks .. " @" .. i.claim end
      if i.pr ~= 0 then marks = marks .. (" pr:%d"):format(i.pr) end
      if flow.is_blocked(i, index) then marks = marks .. " [blocked]" end
      print(("  %-20s %s%s"):format(i.id, i.title, marks))
    end
  end
  local violations = flow.wip_violations(b)
  if #violations > 0 then
    return verdict_line("status", true,
      "WIP: " .. table.concat(violations, "; "))
  end
  return verdict_line("status", true, "WIP ok")
end

local function cmd_tree(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("tree", false, aerr)
  end
  local ranked, live = flow.goals(all)
  for _, g in ipairs(ranked) do
    local driven = ""
    if not live[g.id] then
      driven = " (no live work)"
    end
    print(("G%d %-18s %s%s"):format(g.rank, g.id, g.title, driven))
    for _, e in ipairs(all) do
      if e.parent == g.id and item.is_open(e) then
        local tag = e.kind
        if e.kind == "slice" then
          tag = e.phase
        end
        print(("  %-20s [%s] %s"):format(e.id, tag, e.title))
        for _, sl in ipairs(all) do
          if sl.parent == e.id and item.is_open(sl) then
            print(("    %-18s [%s] %s"):format(sl.id, sl.phase, sl.title))
          end
        end
      end
    end
  end
  local findings = 0
  for _, i in ipairs(all) do
    if i.kind == "finding" and item.is_open(i) then
      findings = findings + 1
      print(("finding: %-12s %s"):format(i.id, i.title))
    end
  end
  return verdict_line("tree", true,
    ("%d open goal(s), %d finding(s) awaiting triage"):format(#ranked, findings))
end

local function cmd_next(s: store.Store, role: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("next", false, aerr)
  end
  local action, nerr = flow.next_action(all, role)
  if action == nil then
    return verdict_line("next", false, nerr)
  end
  local target = ""
  if action.item then
    target = (" %s %s"):format(action.item.id, action.item.title)
  end
  return verdict_line("next", true,
    ("%s%s — %s"):format(action.kind, target, action.reason))
end

local function cmd_move(s: store.Store, id: string, target: string,
    claim: string, force: boolean): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("move", false, lerr)
  end
  if it.kind ~= "slice" then
    return verdict_line("move", false,
      ("%s is a %s — only slices move through phases"):format(id, it.kind))
  end
  local from = it.phase
  if from == target then
    return verdict_line("move", false,
      ("%s is already in %s"):format(id, target))
  end
  local all, aerr = store.list(s)
  if all == nil then
    return verdict_line("move", false, aerr)
  end
  if target == "ready" and not force then
    local problems = ready_problems(s, it, all)
    if #problems > 0 then
      for _, p in ipairs(problems) do
        print("  " .. p)
      end
      return verdict_line("move", false,
        ("REFUSED: %s misses the ready bar"):format(id))
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
    ("move %s %s -> %s"):format(id, from, target), from)
  if not ok then
    return verdict_line("move", false, err)
  end
  return verdict_line("move", true, ("%s %s -> %s"):format(id, from, target))
end

--- The phase each verdict sends a slice to: the three directions out
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
  if it.kind ~= "slice" then
    return verdict_line("verdict", false,
      ("%s is a %s — verdicts judge slices"):format(id, it.kind))
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
    ("verdict %s %s (%s -> %s)"):format(id, kind, from, target), from)
  if not ok then
    return verdict_line("verdict", false, err)
  end
  return verdict_line("verdict", true,
    ("%s on %s: %s -> %s"):format(kind, id, from, target))
end

--- Slice phases `done` refuses to end from without --force: the
--- mid-flow phases where an ending would make work vanish. Completing
--- from land IS the landing; a not-planned ending there would discard
--- an accept, so only "completed" passes.
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
      ("REFUSED: %s is mid-flow in %s — move it left first"):format(id, it.phase))
  end
  local from = it.phase
  if from == "" then
    from = it.kind
  end
  it.phase = ""
  it.resolution = reason
  local ok, err = commit_and_publish(s, it, nil,
    ("done %s %s (from %s)"):format(id, reason, from), from)
  if not ok then
    return verdict_line("done", false, err)
  end
  return verdict_line("done", true, ("%s %s (%s)"):format(id, reason, from))
end

local function cmd_show(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return verdict_line("show", false, lerr)
  end
  print(("%s [%s] %s"):format(it.id, it.kind, it.title))
  if it.parent ~= "" then print(("parent: %s"):format(it.parent)) end
  if it.phase ~= "" then print(("phase: %s"):format(it.phase)) end
  if it.rank ~= 0 then print(("rank: %d"):format(it.rank)) end
  if it.claim ~= "" then print(("claim: %s"):format(it.claim)) end
  if it.pr ~= 0 then print(("pr: #%d"):format(it.pr)) end
  if it.verdict ~= "" then
    print(("verdict: %s (head %s)"):format(it.verdict, it.verdict_head))
  end
  if #it.blocked_by > 0 then
    print("blocked by: " .. table.concat(it.blocked_by, " "))
  end
  if it.resolution ~= "" then print(("resolution: %s"):format(it.resolution)) end
  local spec = store.read_spec(s, id)
  if spec ~= "" then
    print("--- spec ---")
    io.write(spec)
  end
  local events = store.history(s, id)
  if events then
    for _, e in ipairs(events) do
      print(("  %s %s %s"):format(e.at, e.sha, e.subject))
    end
  end
  local state = it.phase
  if state == "" then
    state = it.resolution
    if state == "" then
      state = "open"
    end
  end
  return verdict_line("show", true, ("%s is %s"):format(id, state))
end

local function cmd_sync(s: store.Store): integer
  local ok, err = store.sync(s)
  if not ok then
    return verdict_line("sync", false, err)
  end
  return verdict_line("sync", true, "state is current")
end

local record gitverbs
  cmd_init: function(dir: string): integer
  cmd_new: function(s: store.Store, kind: string, id: string, title: string,
  parent: string, rank: integer, spec: string, force: boolean): integer
  cmd_spec: function(s: store.Store, id: string, file: string): integer
  cmd_check: function(s: store.Store, id: string): integer
  cmd_status: function(s: store.Store): integer
  cmd_tree: function(s: store.Store): integer
  cmd_next: function(s: store.Store, role: string): integer
  cmd_move: function(s: store.Store, id: string, target: string,
  claim: string, force: boolean): integer
  cmd_verdict: function(s: store.Store, id: string, kind: string,
  pr: integer, head: string): integer
  cmd_done: function(s: store.Store, id: string, reason: string,
  force: boolean): integer
  cmd_show: function(s: store.Store, id: string): integer
  cmd_sync: function(s: store.Store): integer
end

local M: gitverbs = {
  cmd_init = cmd_init,
  cmd_new = cmd_new,
  cmd_spec = cmd_spec,
  cmd_check = cmd_check,
  cmd_status = cmd_status,
  cmd_tree = cmd_tree,
  cmd_next = cmd_next,
  cmd_move = cmd_move,
  cmd_verdict = cmd_verdict,
  cmd_done = cmd_done,
  cmd_show = cmd_show,
  cmd_sync = cmd_sync,
}

return M
