--- The review verdict and the move it implies: one verb, one commit,
--- recording what a planner judged and where that sends the item.
---
--- `check` is the only phase a verdict may end — that phase means
--- exactly "awaiting a planner verdict", and an accept given anywhere
--- else would carry unreviewed work into `land` past every gate
--- between them. The other two guards are what keep a verdict
--- informative rather than ceremonial: a head already judged has
--- nothing new to say, and a non-accept verdict files the
--- countermeasure its bounce is evidence for.
local flow = require("_work.flow")
local gate = require("_work.gitgate")
local item = require("_work.item")
local store = require("_work.store")

--- The phase each verdict sends an item to: the three directions out
--- of check.
local VERDICT_MOVES: {string: string} = {
  ["accept"] = "land",
  ["request changes"] = "do",
  ["reject"] = "plan",
}

--- Whether an `--enable` value is one of the two shapes a filed
--- countermeasure takes: the id of an item that exists, or `none`
--- carrying a reason. Anything else — a bare `none`, an id of nothing
--- — is the trailer not actually being filled in.
--- @param value string The --enable argument
--- @param index {string: item.Item} Items by id
--- @return boolean True when the value names a real countermeasure
local function is_enablement(value: string, index: {string: item.Item}): boolean
  local reason = value:match("^none[:%s]%s*(.+)$")
  if reason ~= nil then
    return reason:match("%S") ~= nil
  end
  return index[value] ~= nil
end

local function cmd_verdict(s: store.Store, id: string, kind: string,
    pr: integer, head: string, enable: string): integer
  local target = VERDICT_MOVES[kind]
  if target == nil then
    return gate.verdict_line("verdict", false, ("unknown verdict: %s"):format(kind))
  end
  local it, lerr = store.load(s, id)
  if it == nil then
    return gate.verdict_line("verdict", false, lerr)
  end
  local all, aerr = store.list(s)
  if all == nil then
    return gate.verdict_line("verdict", false, aerr)
  end
  -- Prefixes resolve here rather than in the dispatcher, which cannot:
  -- an --enable value is either an id or a reasoned `none`, and only
  -- this verb knows which grammar it is looking at. Resolution failing
  -- is not an error yet — the enablement check below names both shapes.
  local filed = enable or ""
  if kind ~= "accept" and filed ~= ""
  and filed:match("^none[:%s]") == nil then
    local resolved = store.resolve(s, filed)
    if resolved ~= nil then
      filed = resolved
    end
  end
  -- Every non-accept verdict carries information about why a presumed
  -- ready item was not, and that information is lost unless it is
  -- filed. The trailer is where the planner names the countermeasure —
  -- or says, on the record, that this item's own spec was the fault.
  if kind ~= "accept" and not is_enablement(filed, flow.by_id(all)) then
    return gate.verdict_line("verdict", false,
      ("REFUSED: a %s verdict files its countermeasure — pass "
        .. "--enable <item-id> or --enable 'none: <reason>'"):format(kind))
  end
  -- `check` means exactly "awaiting a planner verdict", so it is the
  -- one phase a verdict may end. Judging from anywhere else would let
  -- an accept carry unreviewed work straight into land, past every
  -- gate between them.
  if (it.phase or "") ~= "check" then
    local where = it.phase
    if where == "" then
      where = "no phase"
    end
    return gate.verdict_line("verdict", false,
      ("%s is in %s — a verdict judges work in check"):format(
        id:sub(1, 8), where))
  end
  -- A verdict judges a head. Judging the same one twice says nothing
  -- new happened between them, which is the state review.md calls
  -- "nothing to judge" rather than a fresh round.
  if (head or "") ~= "" and head == (it.verdict_head or "") then
    return gate.verdict_line("verdict", false,
      ("REFUSED: %s already carries a %s verdict on head %s — nothing "
        .. "new to judge"):format(id:sub(1, 8), it.verdict, head:sub(1, 7)))
  end
  local from = it.phase
  it.verdict = kind
  it.verdict_head = head or ""
  it.enable = ""
  if kind ~= "accept" then
    it.enable = filed
  end
  if pr ~= nil and pr ~= 0 then
    it.pr = pr
  end
  it.phase = target
  -- A verdict is a decision already made: an accept enters land and a
  -- send-back is a return, so no WIP gate applies in any direction.
  local ok, err = gate.commit_and_publish(s, it, nil,
    ("verdict %s %s (%s -> %s)"):format(id:sub(1, 8), kind, from, target),
    from)
  if not ok then
    return gate.verdict_line("verdict", false, err)
  end
  return gate.verdict_line("verdict", true,
    ("%s on %s: %s -> %s"):format(kind, id:sub(1, 8), from, target))
end

local record gitverdict
  cmd_verdict: function(s: store.Store, id: string, kind: string,
  pr: integer, head: string, enable: string): integer
end

local M: gitverdict = {
  cmd_verdict = cmd_verdict,
}

return M
