--- The `compare` verb: the priority relation as a mutation, so a
--- judgment about which of two items matters more is recorded the
--- same way every other board fact is — one commit, one verdict line,
--- one refusal when it does not hold. `hold`/`unhold` live beside it:
--- a root's standing in the derived order is what both verbs govern.
---
--- Its own module rather than another entry in `_work.gitverbs`,
--- which sits close enough to the file-length cap that the cap has
--- already caused a defect there once.
---
--- The edge is written on the WINNER, as one more id in its `beats`.
--- Recording `A > B` therefore touches exactly one item file — unless
--- the direct reverse edge stands, in which case the reversal is one
--- commit over both items: the old judgment removed where it lives,
--- the new one added, never half of each. An order that puts the
--- loser above the winner only TRANSITIVELY is refused — no single
--- edge can honestly reverse a conclusion several comparisons built.
local gate = require("_work.gitgate")
local item = require("_work.item")
local prio = require("_work.priority")
local store = require("_work.store")

--- Record `winner` outranking `loser`, reversing a standing direct
--- edge the other way in the same commit.
--- @param s store.Store The store
--- @param winner string The item ranked above
--- @param loser string The item ranked below
--- @return integer 0 on success, 1 otherwise
local function cmd_compare(s: store.Store, winner: string,
    loser: string): integer
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("compare", false, aerr)
  end
  local index = prio.index_of(all)
  local it = index[winner]
  if it == nil then
    return gate.verdict_line("compare", false, ("no item %s"):format(winner))
  end
  -- A standing direct edge the other way is reversed, not refused:
  -- the overturned judgment leaves the log in the same commit that
  -- records its replacement. Removed in memory first, so the cycle
  -- check below judges the order as the write would leave it.
  local lo = index[loser]
  local reversed = false
  if lo ~= nil then
    local kept: {string} = {}
    for _, b in ipairs(lo.beats or {}) do
      if b == winner then
        reversed = true
      else
        kept[#kept + 1] = b
      end
    end
    if reversed then
      lo.beats = kept
    end
  end
  local refusal = prio.edge_refusal(index, winner, loser)
  if refusal then
    return gate.verdict_line("compare", false, "REFUSED: " .. refusal)
  end
  local kept: {string} = {}
  local seen: {string: boolean} = {}
  for _, b in ipairs(it.beats or {}) do
    if not seen[b] and b ~= loser then
      seen[b] = true
      kept[#kept + 1] = b
    end
  end
  kept[#kept + 1] = loser
  it.beats = kept
  local also: {item.Item} = {}
  local note = ""
  if reversed then
    also[#also + 1] = lo
    note = (" (reversing %s over %s)"):format(loser:sub(1, 8),
      winner:sub(1, 8))
  end
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("compare %s over %s%s"):format(winner:sub(1, 8), loser:sub(1, 8), note),
    also)
  if not ok then
    return gate.verdict_line("compare", false, err)
  end
  -- The standing after the write, not the edge just made: one edge is
  -- a judgment, and what the session wants to see is where the item
  -- now sits once transitivity has closed everything it implies.
  local band, own = prio.key_of(prio.positions(store.list(s) or all), winner)
  return gate.verdict_line("compare", true,
    ("%s now outranks %s%s (band %d, outranks %d)"):format(winner:sub(1, 8),
      loser:sub(1, 8), note, band, own))
end

--- Mark a root HELD: its win condition verified, so intake walks past
--- it — without ending it. A held root keeps every edge and its place
--- in the derived order, and it is still open: evidence filed under it
--- (`new --parent`, `attach`) clears the marker in the same commit, so
--- a hold is never a decision that needs reopening. The reason rides
--- in the commit subject and the verdict line, not on the item — the
--- log is the record, exactly as it is for a comparison.
--- @param s store.Store The store
--- @param id string The root held
--- @param reason string Why the win condition holds; required
--- @return integer 0 on success, 1 otherwise
local function cmd_hold(s: store.Store, id: string, reason: string): integer
  if (reason or ""):match("%S") == nil then
    return gate.verdict_line("hold", false,
      "REFUSED: hold records why the win condition holds — pass --reason "
      .. "'<what was verified, and how>'")
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("hold", false, lerr)
  end
  if not item.is_root(it) then
    return gate.verdict_line("hold", false,
      ("REFUSED: %s is not a root — only an outcome's win condition holds"):format(
        id:sub(1, 8)))
  end
  if not item.is_open(it) then
    return gate.verdict_line("hold", false,
      ("REFUSED: %s is done (%s) — a finished root is not held"):format(
        id:sub(1, 8), it.resolution))
  end
  if it.is_held then
    return gate.verdict_line("hold", false,
      ("%s is already held"):format(id:sub(1, 8)))
  end
  it.is_held = true
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("hold %s %s"):format(id:sub(1, 8), reason))
  if not ok then
    return gate.verdict_line("hold", false, err)
  end
  return gate.verdict_line("hold", true,
    ("%s held: %s — intake walks past it until evidence is filed under it")
    :format(id:sub(1, 8), reason))
end

--- Clear a root's hold marker by hand: the correction for an erroneous
--- hold, where filing a child would record evidence that does not exist.
--- @param s store.Store The store
--- @param id string The root released
--- @return integer 0 on success, 1 otherwise
local function cmd_unhold(s: store.Store, id: string): integer
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("unhold", false, lerr)
  end
  if not item.is_open(it) then
    return gate.verdict_line("unhold", false,
      ("REFUSED: %s is done (%s) — a finished root is not released"):format(
        id:sub(1, 8), it.resolution))
  end
  if not it.is_held then
    return gate.verdict_line("unhold", false,
      ("%s is not held"):format(id:sub(1, 8)))
  end
  it.is_held = false
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("unhold %s"):format(id:sub(1, 8)))
  if not ok then
    return gate.verdict_line("unhold", false, err)
  end
  return gate.verdict_line("unhold", true,
    ("%s no longer held — intake offers it again"):format(id:sub(1, 8)))
end

local record gitcompare
  cmd_compare: function(s: store.Store, winner: string,
  loser: string): integer
  cmd_hold: function(s: store.Store, id: string, reason: string): integer
  cmd_unhold: function(s: store.Store, id: string): integer
end

local M: gitcompare = {
  cmd_compare = cmd_compare,
  cmd_hold = cmd_hold,
  cmd_unhold = cmd_unhold,
}

return M
