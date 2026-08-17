--- One work item as a committed file: `items/<ksuid>.tl` in the state
--- repository, read/written through `cosmic.literal`, with its prose
--- spec (the ready-bar sections) in a markdown sidecar
--- `items/<ksuid>.md`. There is ONE record and no kind field — an
--- item's role emerges from where it sits in the dependency graph,
--- the same way a file's role in cosmic emerges from its position:
---
---   a ranked root        is a goal (long-lived, ordered by rank)
---   an unranked root     is a finding (captured evidence, awaiting triage)
---   a parented item
---     with open children is a container being decomposed
---     with none          is workable — the only thing that holds a PHASE
---
--- What this file validates is per-item shape (fields, exclusivity
--- rules); what needs the whole graph — leaf-ness, the trace to a
--- ranked root — lives in `_work.flow`. The id carries creation time
--- (`_work.ksuid`), so nothing here records when.
local ksuid = require("_work.ksuid")

local record Item
  --- The filename stem and the one name other items use: a KSUID.
  id: string
  title: string
  --- The id this item decomposes; "" for roots.
  parent: string
  --- Board phase; workable items only, "" otherwise.
  phase: string
  --- Roots only: 1 is the top promise. 0 means unranked.
  rank: integer
  --- Open items this one waits on. Stored as one "id id" string —
  --- the literal domain has no lists.
  blocked_by: {string}
  --- The session that claimed it; "" when unclaimed.
  claim: string
  --- The PR under review; 0 when none.
  pr: integer
  --- Standing review verdict: "" | "accept" | "request changes"
  --- | "reject".
  verdict: string
  --- Head commit the verdict was written against.
  verdict_head: string
  --- The countermeasure a non-accept verdict filed: an item id, or
  --- "none: <reason>". "" when no such verdict stands.
  enable: string
  --- Why a finished item ended: "completed" | "not-planned"; "" while
  --- open. A non-empty resolution IS what "done" means.
  resolution: string
end

local PHASES: {string} = {"plan", "ready", "do", "check", "land"}

local PHASE_SET: {string: boolean} = {}
for _, p in ipairs(PHASES) do
  PHASE_SET[p] = true
end

local VERDICTS: {string: boolean} = {
  [""] = true,
  ["accept"] = true,
  ["request changes"] = true,
  ["reject"] = true,
}

local RESOLUTIONS: {string: boolean} = {
  [""] = true,
  ["completed"] = true,
  ["not-planned"] = true,
}

--- Whether an item is open: done is nothing more than a recorded
--- resolution.
--- @param it Item The item
--- @return boolean True while resolution is empty
local function is_open(it: Item): boolean
  return (it.resolution or "") == ""
end

--- Whether an item is a root: no parent. A ranked root is a goal; an
--- unranked one is a finding awaiting triage.
--- @param it Item The item
--- @return boolean True when parentless
local function is_root(it: Item): boolean
  return (it.parent or "") == ""
end

--- The problems an item has on its own, empty when it is valid. One
--- list rather than first-failure, so a hand-edited file reports
--- everything wrong with it at once.
--- @param it Item The item
--- @return {string} Problems, possibly empty
local function problems(it: Item): {string}
  local out: {string} = {}
  if not ksuid.is_id(it.id or "") then
    out[#out + 1] = ("id must be a ksuid: %s"):format(tostring(it.id))
  end
  if it.title == nil or it.title == "" then
    out[#out + 1] = "title must be non-empty"
  end
  if not VERDICTS[it.verdict or ""] then
    out[#out + 1] = ("unknown verdict: %s"):format(tostring(it.verdict))
  end
  if not RESOLUTIONS[it.resolution or ""] then
    out[#out + 1] = ("unknown resolution: %s"):format(tostring(it.resolution))
  end
  if (it.rank or 0) < 0 then
    out[#out + 1] = "rank must be 0 (unranked) or positive"
  end
  if (it.rank or 0) > 0 and not is_root(it) then
    out[#out + 1] = "rank belongs to roots; a parented item carries none"
  end
  local phase = it.phase or ""
  if phase ~= "" then
    if not PHASE_SET[phase] then
      out[#out + 1] = ("unknown phase: %s"):format(phase)
    end
    if is_root(it) then
      out[#out + 1] = "a root is never phased; phase needs a parent"
    end
    if not is_open(it) then
      out[#out + 1] = "a done item carries no phase"
    end
  end
  if is_root(it) and ((it.claim or "") ~= "" or (it.pr or 0) ~= 0
    or (it.verdict or "") ~= "" or (it.enable or "") ~= "") then
    out[#out + 1] = "claim/pr/verdict belong to worked items, not roots"
  end
  for _, b in ipairs(it.blocked_by or {}) do
    if not ksuid.is_id(b) then
      out[#out + 1] = ("blocked_by names a non-id: %s"):format(tostring(b))
    end
  end
  return out
end

--- An item from the table `cosmic.literal` parsed, with zero values
--- filled in and every field validated.
--- @param t {string: any} Parsed literal table
--- @return Item | nil The item
--- @return string Error message listing every problem
local function decode(t: {string: any}): Item | nil, string
  local blocked: {string} = {}
  for ref in tostring(t.blocked_by or ""):gmatch("%S+") do
    blocked[#blocked + 1] = ref
  end
  local it: Item = {
    id = tostring(t.id or ""),
    title = tostring(t.title or ""),
    parent = tostring(t.parent or ""),
    phase = tostring(t.phase or ""),
    rank = math.tointeger(tonumber(tostring(t.rank or "0"))) or 0,
    blocked_by = blocked,
    claim = tostring(t.claim or ""),
    pr = math.tointeger(tonumber(tostring(t.pr or "0"))) or 0,
    verdict = tostring(t.verdict or ""),
    verdict_head = tostring(t.verdict_head or ""),
    enable = tostring(t.enable or ""),
    resolution = tostring(t.resolution or ""),
  }
  local bad = problems(it)
  if #bad > 0 then
    return nil, table.concat(bad, "; ")
  end
  return it
end

--- The literal table an item writes: zero values omitted, so the file
--- carries only what is set and a diff shows only what moved.
--- @param it Item The item
--- @return {string: any} Table for `cosmic.literal.format_file`
local function encode(it: Item): {string: any}
  local t: {string: any} = {
    id = it.id,
    title = it.title,
  }
  if (it.parent or "") ~= "" then t.parent = it.parent end
  if (it.phase or "") ~= "" then t.phase = it.phase end
  if (it.rank or 0) ~= 0 then t.rank = it.rank end
  if #(it.blocked_by or {}) > 0 then
    t.blocked_by = table.concat(it.blocked_by, " ")
  end
  if (it.claim or "") ~= "" then t.claim = it.claim end
  if (it.pr or 0) ~= 0 then t.pr = it.pr end
  if (it.verdict or "") ~= "" then t.verdict = it.verdict end
  if (it.verdict_head or "") ~= "" then t.verdict_head = it.verdict_head end
  if (it.enable or "") ~= "" then t.enable = it.enable end
  if (it.resolution or "") ~= "" then t.resolution = it.resolution end
  return t
end

local record item
  type Item = Item
  PHASES: {string}
  is_open: function(it: Item): boolean
  is_root: function(it: Item): boolean
  problems: function(it: Item): {string}
  decode: function(t: {string: any}): Item | nil, string
  encode: function(it: Item): {string: any}
end

local M: item = {
  PHASES = PHASES,
  is_open = is_open,
  is_root = is_root,
  problems = problems,
  decode = decode,
  encode = encode,
}

return M
