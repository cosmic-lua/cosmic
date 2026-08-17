--- One board card as a committed file: the coordination state of one
--- GitHub issue, held in `cards/<issue>.tl` of a state repository and
--- read/written through `cosmic.literal`, so a card can declare values
--- and nothing else. The issue itself (the spec) and the PR (the fix)
--- stay on GitHub; the card carries only what moves — phase, markers,
--- claim, verdict — which is exactly the state the label-and-comment
--- board keeps in GitHub today. `to_issue` adapts a card to
--- `_work.model`'s Issue so every flow rule (WIP limits, pull order,
--- returns) applies unchanged over this backend.
local model = require("_work.model")

--- Phases a card may carry: the board's five, plus the terminal one.
--- A done card is off the board (store.board excludes it) but stays in
--- the tree as the record `stats` replays.
local DONE < const > = "done"

--- A card's fields. Absent-in-file reads as the zero value here, and
--- zero values are omitted on write, so a fresh card is three lines.
local record Card
  issue: integer
  title: string
  phase: string
  epic: boolean
  finding: boolean
  enable: boolean
  --- Open issues this card waits on; same-board numbers. Stored in the
  --- file as one "#7 #9" string — the literal domain has no lists.
  blocked_by: {integer}
  --- The session that claimed it; "" when unclaimed.
  claim: string
  --- The PR under review; 0 when none is open.
  pr: integer
  --- The standing review verdict: "" | "accept" | "request changes"
  --- | "reject".
  verdict: string
  --- Head commit the verdict was written against.
  verdict_head: string
  --- Why a done card ended: "completed" | "not-planned"; "" while open.
  resolution: string
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

--- Whether a phase name is one a card may carry.
--- @param phase string Phase name
--- @return boolean True for the board's five phases and "done"
local function is_phase(phase: string): boolean
  if phase == DONE then
    return true
  end
  for _, p in ipairs(model.PHASES) do
    if p == phase then
      return true
    end
  end
  return false
end

--- The problems a card has, empty when it is valid. One list rather
--- than first-failure, so a hand-edited card reports everything wrong
--- with it at once.
--- @param c Card The card
--- @return {string} Problems, possibly empty
local function problems(c: Card): {string}
  local out: {string} = {}
  if c.issue == nil or c.issue < 1 then
    out[#out + 1] = "issue must be a positive integer"
  end
  if c.title == nil or c.title == "" then
    out[#out + 1] = "title must be non-empty"
  end
  if c.phase == nil or not is_phase(c.phase) then
    out[#out + 1] = ("unknown phase: %s"):format(tostring(c.phase))
  end
  if not VERDICTS[c.verdict or ""] then
    out[#out + 1] = ("unknown verdict: %s"):format(tostring(c.verdict))
  end
  if not RESOLUTIONS[c.resolution or ""] then
    out[#out + 1] = ("unknown resolution: %s"):format(tostring(c.resolution))
  end
  if c.phase == DONE and (c.resolution or "") == "" then
    out[#out + 1] = "a done card needs a resolution"
  end
  if c.phase ~= DONE and (c.resolution or "") ~= "" then
    out[#out + 1] = "only a done card carries a resolution"
  end
  for _, b in ipairs(c.blocked_by or {}) do
    if b < 1 then
      out[#out + 1] = ("blocked_by names a non-issue: %d"):format(b)
    end
  end
  return out
end

--- A card from the table `cosmic.literal` parsed, with zero values
--- filled in and every field validated.
--- @param t {string: any} Parsed literal table
--- @return Card | nil The card
--- @return string Error message listing every problem
local function decode(t: {string: any}): Card | nil, string
  local blocked: {integer} = {}
  for ref in tostring(t.blocked_by or ""):gmatch("#?(%d+)") do
    blocked[#blocked + 1] = math.tointeger(tonumber(ref))
  end
  local c: Card = {
    issue = math.tointeger(tonumber(tostring(t.issue or ""))),
    title = tostring(t.title or ""),
    phase = tostring(t.phase or ""),
    epic = t.epic == true,
    finding = t.finding == true,
    enable = t.enable == true,
    blocked_by = blocked,
    claim = tostring(t.claim or ""),
    pr = math.tointeger(tonumber(tostring(t.pr or "0"))) or 0,
    verdict = tostring(t.verdict or ""),
    verdict_head = tostring(t.verdict_head or ""),
    resolution = tostring(t.resolution or ""),
  }
  local bad = problems(c)
  if #bad > 0 then
    return nil, table.concat(bad, "; ")
  end
  return c
end

--- The literal table a card writes: zero values omitted, so the file
--- carries only what is set and a diff shows only what moved.
--- @param c Card The card
--- @return {string: any} Table for `cosmic.literal.format_file`
local function encode(c: Card): {string: any}
  local t: {string: any} = {
    issue = c.issue,
    title = c.title,
    phase = c.phase,
  }
  if c.epic then t.epic = true end
  if c.finding then t.finding = true end
  if c.enable then t.enable = true end
  if #(c.blocked_by or {}) > 0 then
    local refs: {string} = {}
    for _, b in ipairs(c.blocked_by) do
      refs[#refs + 1] = ("#%d"):format(b)
    end
    t.blocked_by = table.concat(refs, " ")
  end
  if (c.claim or "") ~= "" then t.claim = c.claim end
  if (c.pr or 0) ~= 0 then t.pr = c.pr end
  if (c.verdict or "") ~= "" then t.verdict = c.verdict end
  if (c.verdict_head or "") ~= "" then t.verdict_head = c.verdict_head end
  if (c.resolution or "") ~= "" then t.resolution = c.resolution end
  return t
end

--- The card as `_work.model` sees it. The model reads blockers from
--- body text ("Blocked by: #N"), so the adapter renders `blocked_by`
--- in that grammar — the model stays byte-identical across backends.
--- @param c Card The card
--- @param repo string "owner/name", for the issue URL
--- @return model.Issue The model's view
local function to_issue(c: Card, repo: string): model.Issue
  local body = ""
  if #(c.blocked_by or {}) > 0 then
    local refs: {string} = {}
    for _, b in ipairs(c.blocked_by) do
      refs[#refs + 1] = ("#%d"):format(b)
    end
    body = "Blocked by: " .. table.concat(refs, " ")
  end
  return {
    number = c.issue,
    title = c.title,
    phase = c.phase,
    epic = c.epic,
    finding = c.finding,
    enable = c.enable,
    assignee = c.claim or "",
    url = ("https://github.com/%s/issues/%d"):format(repo, c.issue),
    body = body,
  }
end

local record card
  type Card = Card
  DONE: string
  is_phase: function(phase: string): boolean
  problems: function(c: Card): {string}
  decode: function(t: {string: any}): Card | nil, string
  encode: function(c: Card): {string: any}
  to_issue: function(c: Card, repo: string): model.Issue
end

local M: card = {
  DONE = DONE,
  is_phase = is_phase,
  problems = problems,
  decode = decode,
  encode = encode,
  to_issue = to_issue,
}

return M
