--- stall: record that the board handed out nothing, ON the board. A
--- session that runs out of actions used to end with its diagnosis in
--- a terminal nobody reads again; this verb converts that ending into
--- ONE standing capture — an unparented item titled by the stall's
--- cause — created the first time and refreshed (title and evidence
--- line) each time after, so the stall is a timestamped board object
--- the triage step surfaces instead of a vanished session log.
---
--- The verb judges for itself whether the board is stalled: it asks
--- the same ordering `next` answers from, with standing stall
--- captures excluded (the capture this verb writes lands in triage,
--- and "triage the stall capture" answering "are we stalled?" would
--- refuse every refresh). Anything actionable refuses the verb — a
--- stall record over a board that has work is noise with a timestamp.
local act = require("_work.action")
local gate = require("_work.gitgate")
local item = require("_work.item")
local ksuid = require("_work.ksuid")
local store = require("_work.store")

--- The title prefix that makes the capture findable and singular.
local STALL_PREFIX < const > = "flow stalled: "

--- The most title the cause contributes; the full reason goes in the
--- evidence line, the title stays scannable in a listing.
local TITLE_MAX < const > = 90

--- Whether an item is the standing stall capture: open, unparented,
--- titled by this verb.
--- @param i item.Item The item
--- @return boolean True for a live stall capture
local function is_stall_capture(i: item.Item): boolean
  return item.is_open(i) and item.is_root(i)
  and i.title:find(STALL_PREFIX, 1, true) == 1
end

--- stall: refuse when the board has work, else create or refresh the
--- standing capture.
--- @param s store.Store The store
--- @return integer 0 on success, 1 otherwise
local function cmd_stall(s: store.Store): integer
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("stall", false, aerr)
  end
  local considered: {item.Item} = {}
  local standing: item.Item = nil
  for _, i in ipairs(all) do
    if is_stall_capture(i) then
      if standing == nil then
        standing = i
      end
    else
      considered[#considered + 1] = i
    end
  end
  local a = act.next_action(considered, "")
  if a.kind ~= "none" and a.kind ~= "unblock" then
    return gate.verdict_line("stall", false,
      ("REFUSED: the board is not stalled — next answers %s"):format(a.kind))
  end
  local cause = a.reason
  local title_cause = cause
  if #title_cause > TITLE_MAX then
    title_cause = title_cause:sub(1, TITLE_MAX - 3) .. "..."
  end
  local stamp = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local evidence = ("- %s `gitboard next` (unnamed): %s — %s\n"):format(
    stamp, a.kind, cause)
  if standing ~= nil then
    standing.title = STALL_PREFIX .. title_cause
    local body = store.read_spec(s, standing.id)
    if body == "" then
      body = "## Evidence\n\n"
    end
    local ok, err = gate.commit_and_publish(s, standing, body .. evidence,
      ("stall %s refreshed"):format(standing.id:sub(1, 8)), standing.phase)
    if not ok then
      return gate.verdict_line("stall", false, err)
    end
    return gate.verdict_line("stall", true,
      ("%s refreshed — the stall stands, latest cause recorded"):format(
        standing.id:sub(1, 8)))
  end
  local fresh: item.Item = {
    id = ksuid.new(), title = STALL_PREFIX .. title_cause, parent = "",
    phase = "", beats = {}, blocked_by = {}, claim = "", pr = 0,
    verdict = "", verdict_head = "", enable = "", resolution = "",
  }
  local bad = item.problems(fresh)
  if #bad > 0 then
    return gate.verdict_line("stall", false, table.concat(bad, "; "))
  end
  local ok, err = gate.commit_and_publish(s, fresh,
    "## Evidence\n\n" .. evidence,
    ("stall %s recorded"):format(fresh.id:sub(1, 8)), nil)
  if not ok then
    return gate.verdict_line("stall", false, err)
  end
  return gate.verdict_line("stall", true,
    ("%s enters triage — the stall is on the board"):format(fresh.id))
end

local record gitstall
  cmd_stall: function(s: store.Store): integer
end

local M: gitstall = {
  cmd_stall = cmd_stall,
}

return M
