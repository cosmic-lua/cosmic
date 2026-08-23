--- The phase verbs: `move` and `done` (the phase crossings), `spec`,
--- and the housekeeping `init` and `sync` — every `cmd_*` behind
--- `_work/gitboard.tl`'s dispatch that is not a graph mutation. The
--- verbs that shape the graph — `new`, `attach`, `block` and its
--- `unblock` half — are `_work.gitgraph`. Both halves run over
--- `_work.store` (persistence) and `_work.flow` (policy). Verbs
--- receive FULL ids — the dispatcher resolves prefixes — and every
--- verb prints a `gitboard-<verb>:` verdict line and returns its exit
--- code. Mutations commit locally and publish through
--- `store.publish`, whose rejected-push path rebases onto concurrent
--- state and re-checks the WIP invariant before pushing again.
local child = require("cosmic.child")
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local fs = require("cosmic.fs")
local item = require("_work.item")
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
    return gate.set_in_place(s, it, claim, pr)
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
  -- The claim is what `next` reads to withhold a verdict from the
  -- item's builder, so a handover naming nobody hands the diff to
  -- everyone, its builder included. Rework is where this bites: the
  -- claim stays with the first builder by design, so a second session
  -- taking the rework has to say so.
  if target == "check" and (claim or "") == "" and (it.claim or "") == ""
  and not force then
    return gate.verdict_line("move", false,
      "REFUSED: a handover to check names its builder — pass --claim <session>")
  end
  if target == "check" and not force then
    local refusal = gate.handover_refusal(s, id,
      (pr or 0) ~= 0 and pr or it.pr, it.repo)
    if refusal then
      return gate.verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  -- `land` holds work whose review is FINISHED, and what remains
  -- there is a merge, followed by the `gitboard land` that reads it
  -- from the verdict and PR the item carries. An arrival carrying
  -- neither is an item `next` answers `finish` for and `land`
  -- refuses, forever.
  if target == "land" and not force then
    local refusal = gate.land_refusal(it)
    if refusal then
      return gate.verdict_line("move", false, "REFUSED: " .. refusal)
    end
  end
  -- A claim is a lease over work in progress. Taking over a live one
  -- is legitimate — a session dies, another picks the item up — but it
  -- is never SILENT: the takeover disqualifies the earlier holder as
  -- reviewer, so it goes through --force --why and into the log.
  if claim ~= nil and claim ~= "" and claim ~= it.claim
  and (it.claim or "") ~= "" and not force then
    return gate.verdict_line("move", false,
      ("REFUSED: %s is claimed by %s — take over a live claim with "
        .. "--force --why"):format(id:sub(1, 8), it.claim))
  end
  if claim ~= nil and claim ~= "" then
    it.claim = claim
    item.record_builder(it, claim)
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
      gate.forced_suffix(force, why)), from, nil, force)
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
      gate.forced_suffix(force, why)), from, back, force)
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
  cmd_spec: function(s: store.Store, id: string, file: string): integer
  cmd_move: function(s: store.Store, id: string, target: string,
  claim: string, pr: integer, force: boolean, why: string): integer
  cmd_done: function(s: store.Store, id: string, reason: string,
  force: boolean, why: string): integer
  cmd_sync: function(s: store.Store): integer
end

local M: gitverbs = {
  cmd_init = cmd_init,
  cmd_spec = cmd_spec,
  cmd_move = cmd_move,
  cmd_done = cmd_done,
  cmd_sync = cmd_sync,
}

return M
