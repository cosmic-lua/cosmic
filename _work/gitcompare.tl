--- The `compare` and `uncompare` verbs: the priority relation as a
--- mutation, so a judgment about which of two items matters more is
--- recorded the same way every other board fact is — one commit, one
--- verdict line, one refusal when it does not hold.
---
--- Its own module rather than another entry in `_work.gitverbs`,
--- which sits close enough to the file-length cap that the cap has
--- already caused a defect there once. `_work.gitland` and
--- `_work.gitverdict` split out for the same reason.
---
--- The edge is written on the WINNER, as one more id in its `beats`.
--- Recording `A > B` therefore touches exactly one item file, and the
--- order everything renders in is derived from the accumulated edges
--- by `_work.priority` rather than stored anywhere.
local gate = require("_work.gitgate")
local prio = require("_work.priority")
local store = require("_work.store")

--- Record (or drop) `winner` outranking `loser`.
---
--- A comparison is ASKED one pair at a time and transitivity closes
--- the rest, so this deliberately refuses an edge that contradicts
--- one already committed instead of quietly reversing it: the earlier
--- judgment is data. Overturning it is `uncompare` then `compare` —
--- two commits, both of them in the log.
--- @param s store.Store The store
--- @param winner string The item ranked above
--- @param loser string The item ranked below
--- @param remove boolean True to drop the edge instead of adding it
--- @return integer 0 on success, 1 otherwise
local function cmd_compare(s: store.Store, winner: string, loser: string,
    remove: boolean): integer
  local verb = remove and "uncompare" or "compare"
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line(verb, false, aerr)
  end
  local index = prio.index_of(all)
  local it = index[winner]
  if it == nil then
    return gate.verdict_line(verb, false, ("no item %s"):format(winner))
  end
  if not remove then
    local refusal = prio.edge_refusal(index, winner, loser)
    if refusal then
      return gate.verdict_line(verb, false, "REFUSED: " .. refusal)
    end
  end
  local kept: {string} = {}
  local seen: {string: boolean} = {}
  local had = false
  for _, b in ipairs(it.beats or {}) do
    if b == loser then
      had = true
    elseif not seen[b] then
      seen[b] = true
      kept[#kept + 1] = b
    end
  end
  if remove and not had then
    return gate.verdict_line(verb, false,
      ("%s does not outrank %s"):format(winner:sub(1, 8), loser:sub(1, 8)))
  end
  if not remove then
    kept[#kept + 1] = loser
  end
  it.beats = kept
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("%s %s over %s"):format(verb, winner:sub(1, 8), loser:sub(1, 8)),
    it.phase)
  if not ok then
    return gate.verdict_line(verb, false, err)
  end
  -- The standing after the write, not the edge just made: one edge is
  -- a judgment, and what the session wants to see is where the item
  -- now sits once transitivity has closed everything it implies.
  local band, own = prio.key_of(prio.positions(store.list(s) or all), winner)
  local shape = "now outranks"
  if remove then
    shape = "no longer outranks"
  end
  return gate.verdict_line(verb, true,
    ("%s %s %s (band %d, outranks %d)"):format(winner:sub(1, 8), shape,
      loser:sub(1, 8), band, own))
end

local record gitcompare
  cmd_compare: function(s: store.Store, winner: string, loser: string,
  remove: boolean): integer
end

local M: gitcompare = {
  cmd_compare = cmd_compare,
}

return M
