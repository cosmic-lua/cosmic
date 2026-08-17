--- One work item as a committed file: `items/<id>.tl` in the state
--- repository, read/written through `cosmic.literal`, with its prose
--- spec (the ready-bar sections) in a markdown sidecar `items/<id>.md`.
--- The hierarchy is first-class: an item's `kind` says what it is —
--- a long-lived ranked `goal`, an `epic` decomposing one, a `slice`
--- an implementer pulls, or a `finding` (captured evidence, parentless
--- until a planner adopts it into a slice). Phase belongs to open
--- slices ONLY, which is what dissolves the label board's carve-outs:
--- an epic cannot crowd a phase it never occupies, and filing a
--- finding cannot collide with a WIP limit it never counts against.
local record Item
  --- The filename stem and the one name other items use: a slug.
  id: string
  --- "goal" | "epic" | "slice" | "finding"
  kind: string
  title: string
  --- The id this item decomposes: epics name a goal, slices name an
  --- epic or a goal; "" for goals and unadopted findings.
  parent: string
  --- Board phase; open slices only, "" otherwise.
  phase: string
  --- Goals only: 1 is the top promise. 0 elsewhere.
  rank: integer
  --- ISO 8601 stamp of creation; age ordering ("oldest first").
  opened: string
  --- Open items this one waits on. Stored as one "id id" string —
  --- the literal domain has no lists.
  blocked_by: {string}
  --- The session that claimed it; slices only, "" when unclaimed.
  claim: string
  --- The PR under review; slices only, 0 when none.
  pr: integer
  --- Standing review verdict: "" | "accept" | "request changes"
  --- | "reject".
  verdict: string
  --- Head commit the verdict was written against.
  verdict_head: string
  --- Why a finished item ended: "completed" | "not-planned"; "" while
  --- open. A non-empty resolution IS what "done" means.
  resolution: string
end

local KINDS: {string: boolean} = {
  goal = true, epic = true, slice = true, finding = true,
}

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

--- Whether a string is a well-formed item id: a lowercase slug that
--- can be a filename stem and a `blocked_by` reference.
--- @param id string Candidate id
--- @return boolean True for ^[a-z][a-z0-9-]*$ of at most 40 bytes
local function is_id(id: string): boolean
  if id == nil or #id < 1 or #id > 40 then
    return false
  end
  return id:match("^%l[%l%d%-]*$") ~= nil
end

--- Whether an item is open: done is nothing more than a recorded
--- resolution.
--- @param it Item The item
--- @return boolean True while resolution is empty
local function is_open(it: Item): boolean
  return (it.resolution or "") == ""
end

--- The problems an item has, empty when it is valid. One list rather
--- than first-failure, so a hand-edited file reports everything wrong
--- with it at once.
--- @param it Item The item
--- @return {string} Problems, possibly empty
local function problems(it: Item): {string}
  local out: {string} = {}
  if not is_id(it.id or "") then
    out[#out + 1] = ("id must be a slug: %s"):format(tostring(it.id))
  end
  if not KINDS[it.kind or ""] then
    out[#out + 1] = ("unknown kind: %s"):format(tostring(it.kind))
  end
  if it.title == nil or it.title == "" then
    out[#out + 1] = "title must be non-empty"
  end
  if it.opened == nil or it.opened == "" then
    out[#out + 1] = "opened stamp must be set"
  end
  if not VERDICTS[it.verdict or ""] then
    out[#out + 1] = ("unknown verdict: %s"):format(tostring(it.verdict))
  end
  if not RESOLUTIONS[it.resolution or ""] then
    out[#out + 1] = ("unknown resolution: %s"):format(tostring(it.resolution))
  end
  local kind = it.kind or ""
  if kind == "slice" then
    if (it.parent or "") == "" then
      out[#out + 1] = "a slice needs a parent"
    end
    if is_open(it) then
      if not PHASE_SET[it.phase or ""] then
        out[#out + 1] = ("an open slice needs a phase, got: %s"):format(
          tostring(it.phase))
      end
    elseif (it.phase or "") ~= "" then
      out[#out + 1] = "a done slice carries no phase"
    end
  else
    if (it.phase or "") ~= "" then
      out[#out + 1] = ("only slices are phased; a %s is not"):format(kind)
    end
    if (it.claim or "") ~= "" or (it.pr or 0) ~= 0
    or (it.verdict or "") ~= "" then
      out[#out + 1] = ("claim/pr/verdict belong to slices; a %s carries none")
      :format(kind)
    end
  end
  if kind == "goal" then
    if (it.rank or 0) < 1 then
      out[#out + 1] = "a goal needs a rank of 1 or more"
    end
    if (it.parent or "") ~= "" then
      out[#out + 1] = "a goal has no parent"
    end
  elseif (it.rank or 0) ~= 0 then
    out[#out + 1] = ("rank belongs to goals; a %s carries none"):format(kind)
  end
  if kind == "epic" and (it.parent or "") == "" then
    out[#out + 1] = "an epic needs a parent goal"
  end
  for _, b in ipairs(it.blocked_by or {}) do
    if not is_id(b) then
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
    kind = tostring(t.kind or ""),
    title = tostring(t.title or ""),
    parent = tostring(t.parent or ""),
    phase = tostring(t.phase or ""),
    rank = math.tointeger(tonumber(tostring(t.rank or "0"))) or 0,
    opened = tostring(t.opened or ""),
    blocked_by = blocked,
    claim = tostring(t.claim or ""),
    pr = math.tointeger(tonumber(tostring(t.pr or "0"))) or 0,
    verdict = tostring(t.verdict or ""),
    verdict_head = tostring(t.verdict_head or ""),
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
    kind = it.kind,
    title = it.title,
    opened = it.opened,
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
  if (it.resolution or "") ~= "" then t.resolution = it.resolution end
  return t
end

local record item
  type Item = Item
  PHASES: {string}
  is_id: function(id: string): boolean
  is_open: function(it: Item): boolean
  problems: function(it: Item): {string}
  decode: function(t: {string: any}): Item | nil, string
  encode: function(it: Item): {string: any}
end

local M: item = {
  PHASES = PHASES,
  is_id = is_id,
  is_open = is_open,
  problems = problems,
  decode = decode,
  encode = encode,
}

return M
