--- Best-effort parser over an eval workspace's agent-written prose:
--- NOTES.md (sections (b) and (f)) and final.txt (the five-line
--- reply). Never the check modules' business — checks score the
--- produced artifact, never the agent's claims — but score.tl folds
--- this alongside the check to fill the row's journal-derived fields.
---
--- Everything here is heuristic over free-form text an agent wrote
--- under a loose format instruction, not a machine-readable format:
--- a field that doesn't parse is left nil, never guessed.
local fs = require("cosmic.fs")
local str = require("cosmic.string")

--- NOTES.md section headings this module looks for, keyed by the
--- letter frame.md's deliverables list uses ((a) through (f)). Only
--- (b) and (f) are parsed -- (a), (c), (d), (e) are prose this slice
--- has no field for (the "e" attempts numbers come from final.txt
--- instead, which is closer to machine-readable).
local SECTION_LETTERS < const >: {string} = {"a", "b", "c", "d", "e", "f"}

--- One parsed journal.
local record Journal
  --- NOTES.md section (f), heuristically classified. nil when NOTES.md
  --- is missing, has no (f) section, or the section's text does not
  --- clearly read as either answer.
  self_report_clean: boolean
  --- NOTES.md section (b), one entry per line/bullet, verbatim (marker
  --- stripped, whitespace trimmed). Empty when unparseable.
  friction: {string}
  --- final.txt's five-line reply, second line. nil when final.txt is
  --- missing, short, or the line has no leading integer.
  attempts_first_build: integer
  --- final.txt's five-line reply, third line. Same nil rule.
  attempts_green_ci: integer
end

--- One "(x)" heading's raw position in NOTES.md, before body bounds
--- are resolved.
local record Hit
  letter: string
  pos: integer
  line_start: integer
  line_end: integer
end

--- One "(x)" section's body bounds in NOTES.md: `notes:sub(body_start,
--- next_start - 1)` is the section's text.
local record Section
  letter: string
  body_start: integer
  next_start: integer
end

--- The position right after the last "\n" before `pos` -- i.e. where
--- the line containing `pos` begins. 1 when `pos` is on the first
--- line (no preceding newline).
--- @param notes string The full text
--- @param pos integer A byte position into notes
--- @return integer The start of the line pos falls on
local function line_start_at(notes: string, pos: integer): integer
  -- `.` matches any byte including "\n", so the greedy `.*` consumes
  -- up to the LAST newline before pos, leaving the capture at the
  -- start of pos's own line.
  return notes:sub(1, pos - 1):match(".*\n()") or 1
end

--- Find every "(x)" section heading in NOTES.md, in the order they
--- appear, with each section's body bounds. A heading is any line
--- containing "(x)" for one of SECTION_LETTERS -- agents format these
--- as "## (b) Friction points", "(b) Friction:", etc., and this is
--- deliberately loose about the rest of the line. A section's body
--- ends at the START of the next heading's line (not at its "(") so
--- that heading's own prefix (e.g. "## ") never bleeds into the
--- previous section's body as a phantom last line.
--- @param notes string NOTES.md's full contents
--- @return {Section} The sections found, in document order
local function find_sections(notes: string): {Section}
  local hits: {Hit} = {}
  for letter_pos, letter in notes:gmatch("()%(([a-fA-F])%)") do
    local l = letter:lower()
    local is_letter = false
    for _, want in ipairs(SECTION_LETTERS) do
      if l == want then is_letter = true end
    end
    if is_letter then
      local line_end = notes:find("\n", letter_pos, true) or (#notes + 1)
      hits[#hits + 1] = {
        letter = l,
        pos = letter_pos,
        line_start = line_start_at(notes, letter_pos),
        line_end = line_end,
      }
    end
  end
  table.sort(hits, function(a: Hit, b: Hit): boolean return a.pos < b.pos end)
  local sections: {Section} = {}
  for i, hit in ipairs(hits) do
    local next_start = (#notes + 1)
    if hits[i + 1] then
      next_start = hits[i + 1].line_start
    end
    sections[#sections + 1] = {
      letter = hit.letter,
      body_start = hit.line_end + 1,
      next_start = next_start,
    }
  end
  return sections
end

--- The body text of the LAST heading found for `letter` -- an agent
--- that restates a heading (e.g. inside its own journey log) should
--- not shadow the real section, so the final occurrence wins.
--- @param notes string NOTES.md's full contents
--- @param letter string One of SECTION_LETTERS
--- @return string|nil The section body, or nil when no such heading exists
local function section_body(notes: string, letter: string): string | nil
  local sections = find_sections(notes)
  local body: string = nil
  for _, s in ipairs(sections) do
    if s.letter == letter then
      body = notes:sub(s.body_start, s.next_start - 1)
    end
  end
  return body
end

--- Strip a leading list marker ("-", "*", "1.", "1)") from one line.
--- @param line string A raw line from a section body
--- @return string The line with its marker (if any) removed and trimmed
local function strip_marker(line: string): string
  local stripped = line:match("^%s*[%-%*]%s+(.*)$")
  or line:match("^%s*%d+[%.%)]%s+(.*)$")
  or line
  return str.trim(stripped)
end

--- Parse NOTES.md section (b) into a verbatim, per-item friction list.
--- @param notes string NOTES.md's full contents
--- @return {string} The friction items, in order; empty if unparseable
local function parse_friction(notes: string): {string}
  local body = section_body(notes, "b")
  if not body then
    return {}
  end
  local items: {string} = {}
  for _, raw in ipairs(str.lines(body)) do
    local line = strip_marker(raw)
    if line ~= "" then
      items[#items + 1] = line
    end
  end
  return items
end

--- Classify NOTES.md section (f) -- the context self-report -- as
--- clean (no contamination admitted) or not. The prompt asks two
--- things: (i) did anything besides the prompt mention cosmic/Teal/
--- skills/task lists, and (ii) any prior familiarity brought in. Any
--- affirmative admission on either makes the report NOT clean; an
--- explicit denial on both (typically spelled "none"/"no"/"nothing")
--- makes it clean. Text that does neither clearly (e.g. hedged, or
--- the section is empty) is left nil -- best-effort, never guessed.
--- @param notes string NOTES.md's full contents
--- @return boolean|nil true clean, false contaminated, nil unparseable
local function parse_self_report_clean(notes: string): boolean
  local body = section_body(notes, "f")
  if not body then
    return nil
  end
  local trimmed = str.trim(body)
  if trimmed == "" then
    return nil
  end
  local lowered = trimmed:lower()
  -- Contamination markers beat a denial found elsewhere in the same
  -- section: any one honest admission means the report is not clean,
  -- even if the agent also wrote "otherwise none" somewhere else.
  -- Multi-word phrases, not bare "familiar"/"recall"/"recogni" --
  -- those collide with the denial itself ("no prior FAMILIARity",
  -- "nothing I RECALL"), which would misclassify a clean report as
  -- contaminated on the very word it used to deny contamination.
  local contaminated = lowered:find("%f[%a]yes%f[%A]")
  or lowered:find("i am familiar with", 1, true)
  or lowered:find("i was familiar with", 1, true)
  or lowered:find("i recognized", 1, true)
  or lowered:find("i recognize", 1, true)
  or lowered:find("i recall", 1, true)
  or lowered:find("i knew", 1, true)
  or lowered:find("already knew", 1, true)
  if contaminated then
    return false
  end
  local clean = lowered:find("none", 1, true)
  or lowered:find("nothing", 1, true)
  or lowered:find("%f[%a]no%f[%A]")
  if clean then
    return true
  end
  return nil
end

--- Extract the leading integer from one line of final.txt's reply,
--- e.g. "2 attempts" or "attempts to first build: 3" both yield the
--- first digit run found on the line.
--- @param line string One line of final.txt
--- @return integer|nil The parsed count, or nil if the line has no digits
local function parse_attempt_count(line: string): integer
  local digits = line:match("%d+")
  if not digits then
    return nil
  end
  return math.tointeger(tonumber(digits))
end

--- Parse final.txt's five-line reply for the two attempt counts.
--- Lines 2 and 3 are, per frame.md: attempts to first build, attempts
--- to green ci. A file with fewer than 3 lines, or a line 2/3 with no
--- digits, leaves the corresponding field nil.
--- @param final_txt string final.txt's full contents
--- @return integer|nil attempts_first_build
--- @return integer|nil attempts_green_ci
local function parse_attempts(final_txt: string): integer, integer
  local ls = str.lines(final_txt)
  local first_build: integer = nil
  local green_ci: integer = nil
  if ls[2] then
    first_build = parse_attempt_count(ls[2])
  end
  if ls[3] then
    green_ci = parse_attempt_count(ls[3])
  end
  return first_build, green_ci
end

--- Parse one task workspace's journal: NOTES.md (if present) and
--- final.txt (if present). Missing files leave every field they would
--- have supplied at nil/empty -- a missing journal is not an error
--- here, since score.tl already reports the workspace itself missing
--- as row.status = "error" before this ever runs.
--- @param workspace string Absolute path to the task's workspace
--- @return Journal The parsed (possibly all-nil) journal
local function parse(workspace: string): Journal
  local j: Journal = {friction = {}}
  local notes = fs.read(fs.join(workspace, "NOTES.md"))
  if notes then
    j.self_report_clean = parse_self_report_clean(notes)
    j.friction = parse_friction(notes)
  end
  local final_txt = fs.read(fs.join(workspace, "final.txt"))
  if final_txt then
    j.attempts_first_build, j.attempts_green_ci = parse_attempts(final_txt)
  end
  return j
end

local record journal_module
  type Journal = Journal
  parse: function(workspace: string): Journal
end

local M: journal_module = {
  parse = parse,
}

return M
