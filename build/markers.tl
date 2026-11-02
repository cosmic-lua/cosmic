--- The markers that hold a finding of the checker where it occurs, in place of a count in a file of the tree's: a comment
--- `-- checked: map_field, nil_not_allowed` at the end of the line a finding is reported at. [`build.ceilings`] judges a file
--- against them; this module reads and rewrites the text.
---
--- A marker is a stage's name and a colon (`-- checked:`) and a list of codes of that stage, each a code alone or `code*N`
--- for N findings of it on the line. The stages are those of [`build.ceilings`] that have a line to hold: `scoped`,
--- `declared`, `checked` and `untyped`. Each keeps its own markers because a code can be a code of two (`float_key` is
--- both a `declared` and a `checked` finding), and a line may hold the markers of several in the one comment:
--- `-- declared: float_key -- checked: map_field`. Where the line already ends in a comment of its own the markers follow the
--- words of that comment (`x -- why -- checked: map_field`). A line that ends inside a long string or a long comment cannot
--- take a trailing comment, since the marker would be the text of the string: the marker is then a comment on the line
--- above, a line of its own that begins `-- checked:` (three dashes are a doc comment, which is no marker), and it holds
--- the line below it.
---
--- The text is read with the lexer, so that `-- checked:` inside a string is no marker. A comment that has the words but
--- whose list is not codes alone (a sentence) is no marker, and `cosmic fix` leaves it alone.
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")

local record Markers
  --- A place a marker holds or is wanted: the `count` findings of `code` of `stage` on `line` of `file`.
  record Spot
    file: string
    line: integer
    stage: string
    code: string
    count: integer
  end

  --- The codes of one stage that one comment holds.
  record Segment
    stage: string
    --- The codes in the order written.
    codes: {string}
    --- The findings it holds of each code.
    counts: {string: integer}
  end

  --- One comment that holds markers.
  record Mark
    --- The line it holds: the line of its comment, or the line below a comment of its own.
    line: integer
    --- The line its comment is on.
    at: integer
    --- Whether the comment is a line of its own, holding the line below.
    alone: boolean
    --- The bytes of the text it spans, from `--` to the end of the line.
    first: integer
    last: integer
    --- The words of the comment before the first marker, "" where it begins with one.
    prefix: string
    segments: {Segment}
  end

  --- What a text holds.
  record Read
    marks: mut {Mark}
    --- The lines that end inside a long string or a long comment: no trailing comment can be written there.
    open: mut {integer: boolean}
  end

  --- The markers of `text`, a file named `name`. A text without a marker's words is not lexed.
  read: function(text: string, name: string): Read

  --- The findings that `text` marks of each code of each stage, in all: the count the ratchet holds a file to, by `<stage>
  --- <code>`.
  counts: function(text: string, name: string): {string: integer}

  --- The text with the findings of `spots` (which are of one file) no longer marked: a marker's count lowered by the spot's,
  --- the marker removed where it reaches none, and a comment of a marker's alone deleted with its line.
  without: function(text: string, name: string, spots: {Spot}): string

  --- `line`, a line of source, without the markers that end it: they are comments of the checker's, not part of what the line
  --- declares, so a signature shown from the line is shown without them.
  bare: function(line: string): string

  --- The words that open a marker of each stage (`-- checked:`), in the order of the stages.
  keys: function(): {string}

  --- Whether `text` has the words of any stage's marker, so that it is worth lexing.
  mentions: function(text: string): boolean

end

--- The stages that have markers, in the order a comment writes them.
local STAGES <const>: {string} = { "scoped", "declared", "checked", "untyped" }

local find, sub = string.find, string.sub

--- The codes each stage has, which are the only words a marker reads: any other comment that happens to follow the words
--- (`-- checked: done`) is prose, left alone by every edit.
local KNOWN: mut {string: mut {string: boolean}} = {}

local function know(stage: string, codes: {string})
  local known: mut {string: boolean} = {}
  for _, code in ipairs(codes) do
    known[code] = true
  end
  KNOWN[stage] = known
end

know("scoped", Scopes.codes)
know("declared", Declarations.codes)
know("checked", Check.codes)
know("untyped", { "call" })

--- The codes of `list`, a marker's text after the stage and colon, with their counts, or nil where it is not a list of codes
--- of that stage alone.
local function codes_of(stage: string, list: string): {string}?, {string: integer}
  local codes: mut {string} = {}
  local counts: mut {string: integer} = {}
  local trimmed = list:gsub("^%s+", "")
  local rest = trimmed:gsub("%s+$", "")
  if rest == "" then
    return nil, counts
  end
  local known = KNOWN[stage] or {}
  for item in (rest .. ","):gmatch("%s*([^,]*),") do
    local code, times = item:match("^([a-z][a-z_]*)%*(%d+)$")
    if code == nil then
      code = item:match("^([a-z][a-z_]*)$")
      times = "1"
    end
    local n = math.tointeger(tonumber(times))
    if code == nil or n == nil or n < 1 or counts[code] ~= nil or known[code] ~= true then
      return nil, counts
    end
    codes[#codes + 1] = code
    counts[code] = n
  end
  return codes, counts
end

--- The words that open the markers of `stage`.
local function key_of(stage: string): string
  return "-- " .. stage .. ":"
end

--- The markers in the comment `text` (from `--` to the end of the line): the words before the first and the segment of
--- each stage, or nil where it holds none or one is not a list of codes. A comment of its own holds a marker only when it
--- begins with one.
local function in_comment(text: string, alone: boolean): string, {Markers.Segment}?
  -- Where each marker begins: the key at the start of the comment or after a space.
  local starts: mut {integer} = {}
  local stage_at: mut {integer: string} = {}
  for _, stage in ipairs(STAGES) do
    local key = key_of(stage)
    local at = 1
    while true do
      local start = find(text, key, at, true)
      if start == nil then
        break
      end
      if start == 1 or sub(text, start - 1, start - 1):match("%s") ~= nil then
        starts[#starts + 1] = start
        stage_at[start] = stage
      end
      at = start + 1
    end
  end
  if #starts == 0 then
    return "", nil
  end
  table.sort(starts)
  local first = assert(starts[1])
  if alone and first ~= 1 then
    return "", nil
  end
  local segments: mut {Markers.Segment} = {}
  for i, start in ipairs(starts) do
    local stage = assert(stage_at[start])
    local stop = (starts[i + 1] or #text + 2) - 1
    local codes, counts = codes_of(stage, sub(text, start + #key_of(stage), stop - 1))
    if codes == nil then
      return "", nil
    end
    segments[#segments + 1] = { stage = stage, codes = codes, counts = counts }
  end
  local before = sub(text, 1, first - 1)
  local prefix = before:gsub("%s+$", "")
  return prefix, segments
end

--- Lexes `text` and fills `out`: its open lines, and its markers if it has any.
local function scan(text: string, name: string, out: Markers.Read)
  local tokens = Lexer.lex(text, name).tokens
  for i = 1, Lexer.count(tokens) do
    local y, yend = Lexer.y(tokens, i), Lexer.yend(tokens, i)
    if yend > y then
      for line = y, yend - 1 do
        out.open[line] = true
      end
    end
    local comments = tokens.comments[i]
    if comments ~= nil then
      for _, comment in ipairs(comments) do
        -- A comment on the line the token before it ends on trails code; any other is a line of its own.
        local alone = i == 1 or comment.y ~= Lexer.yend(tokens, i - 1)
        local prefix, segments = in_comment(comment.text, alone)
        if segments ~= nil then
          local line = comment.y
          if alone then
            line = comment.y + 1
          end
          out.marks[#out.marks + 1] = {
            line = line, at = comment.y, alone = alone, first = comment.offset,
            last = comment.offset + #comment.text - 1, prefix = prefix, segments = segments,
          }
        end
      end
    end
  end
end

function Markers.keys(): {string}
  local out: mut {string} = {}
  for _, stage in ipairs(STAGES) do
    out[#out + 1] = key_of(stage)
  end
  return out
end

function Markers.mentions(text: string): boolean
  for _, stage in ipairs(STAGES) do
    if find(text, key_of(stage), 1, true) ~= nil then
      return true
    end
  end
  return false
end

--- The markers of the texts read lately, by text: a run reads each file of the tree for several checks, and the lexing
--- is what it costs. A text is kept as the file it is, so the name is not part of the key (it only names errors).
local lately: mut {string: Markers.Read} = {}
local lately_count = 0

function Markers.read(text: string, name: string): Markers.Read
  local out: Markers.Read = { marks = {}, open = {} }
  if not Markers.mentions(text) then
    return out
  end
  local again = lately[text]
  if again ~= nil then
    return again
  end
  scan(text, name, out)
  -- Bounded, so that a long run over many trees does not keep every text it saw.
  if lately_count >= 4096 then
    lately = {}
    lately_count = 0
  end
  lately[text] = out
  lately_count = lately_count + 1
  return out
end

function Markers.counts(text: string, name: string): {string: integer}
  local out: mut {string: integer} = {}
  for _, mark in ipairs(Markers.read(text, name).marks) do
    for _, segment in ipairs(mark.segments) do
      for code, n in pairs(segment.counts) do
        local key = segment.stage .. " " .. code
        out[key] = (out[key] or 0) + n
      end
    end
  end
  return out
end

function Markers.bare(line: string): string
  local best: integer? = nil
  for _, stage in ipairs(STAGES) do
    local key = key_of(stage)
    local at = 1
    while true do
      local start = find(line, key, at, true)
      if start == nil then
        break
      end
      if start > 1 and sub(line, start - 1, start - 1):match("%s") ~= nil then
        local _, segments = in_comment(sub(line, start), true)
        if segments ~= nil and (best == nil or start < best) then
          best = start
        end
      end
      at = start + 1
    end
  end
  if best == nil then
    return line
  end
  local kept = sub(line, 1, best - 1)
  return (kept:gsub("%s+$", ""))
end

--- `code`, or `code*n` for n findings.
local function piece(code: string, n: integer): string
  if n == 1 then
    return code
  end
  return code .. "*" .. tostring(n)
end

--- The comment for `segments` in the order of the stages, after the words `prefix`, or "" where there is neither.
local function render(prefix: string, segments: {Markers.Segment}): string
  local parts: mut {string} = {}
  if prefix ~= "" then
    parts[1] = prefix
  end
  for _, stage in ipairs(STAGES) do
    for _, segment in ipairs(segments) do
      if segment.stage == stage and #segment.codes > 0 then
        local codes: mut {string} = {}
        for _, code in ipairs(segment.codes) do
          codes[#codes + 1] = piece(code, assert(segment.counts[code]))
        end
        parts[#parts + 1] = key_of(stage) .. " " .. table.concat(codes, ", ")
      end
    end
  end
  return table.concat(parts, " ")
end

--- The spots of `spots` by line, each line's counts by `<stage> <code>`.
local function by_line(spots: {Markers.Spot}): {integer: {string: integer}}, {integer}
  local out: mut {integer: mut {string: integer}} = {}
  local lines: mut {integer} = {}
  for _, spot in ipairs(spots) do
    local held = out[spot.line] or {}
    if out[spot.line] == nil then
      out[spot.line] = held
      lines[#lines + 1] = spot.line
    end
    local key = spot.stage .. " " .. spot.code
    held[key] = (held[key] or 0) + spot.count
  end
  table.sort(lines)
  return out, lines
end

--- A piece of `text` to replace: bytes `first` to `last` become `with`.
local record Edit
  first: integer
  last: integer
  with: string
end

--- `text` with `edits` made, from the last so that the places hold.
local function applied(text: string, edits: mut {Edit}): string
  table.sort(edits, function(a: Edit, b: Edit): boolean return a.first > b.first end)
  local out = text
  for _, edit in ipairs(edits) do
    out = sub(out, 1, edit.first - 1) .. edit.with .. sub(out, edit.last + 1)
  end
  return out
end

--- The segments of `mark` with `change` (by `<stage> <code>`) added to each count, negative to remove: the codes keep the
--- order they were written in and new ones follow in order; a code that reaches none is gone, and a stage with no code left.
local function changed(mark: Markers.Mark?, change: {string: integer}): {Markers.Segment}
  local order: mut {string: mut {string}} = {}
  local counts: mut {string: mut {string: integer}} = {}
  for _, stage in ipairs(STAGES) do
    order[stage] = {}
    counts[stage] = {}
  end
  if mark ~= nil then
    for _, segment in ipairs(mark.segments) do
      local codes, held = assert(order[segment.stage]), assert(counts[segment.stage])
      for _, code in ipairs(segment.codes) do
        if held[code] == nil then
          codes[#codes + 1] = code
        end
        held[code] = (held[code] or 0) + assert(segment.counts[code])
      end
    end
  end
  local keys: mut {string} = {}
  for key in pairs(change) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local stage = assert(key:match("^(%S+) "))
    local code = assert(key:match(" (%S+)$"))
    local codes, held = assert(order[stage]), assert(counts[stage])
    if held[code] == nil then
      codes[#codes + 1] = code
    end
    held[code] = (held[code] or 0) + assert(change[key])
  end
  local out: mut {Markers.Segment} = {}
  for _, stage in ipairs(STAGES) do
    local codes, held = assert(order[stage]), assert(counts[stage])
    local kept: mut {string} = {}
    local kept_counts: mut {string: integer} = {}
    for _, code in ipairs(codes) do
      local n = assert(held[code])
      if n > 0 then
        kept[#kept + 1] = code
        kept_counts[code] = n
      end
    end
    if #kept > 0 then
      out[#out + 1] = { stage = stage, codes = kept, counts = kept_counts }
    end
  end
  return out
end

function Markers.without(text: string, name: string, spots: {Markers.Spot}): string
  local gone = by_line(spots)
  local edits: mut {Edit} = {}
  local left: mut {integer: mut {string: integer}} = {}
  for _, mark in ipairs(Markers.read(text, name).marks) do
    local wanted = gone[mark.line]
    if wanted ~= nil then
      local drop = left[mark.line] or {}
      if left[mark.line] == nil then
        for key, n in pairs(wanted) do drop[key] = n end
        left[mark.line] = drop
      end
      -- What is to go is taken from the markers of the line in turn, so that one that holds the line twice (a comment above
      -- and one at its end) loses it once.
      local negative: mut {string: integer} = {}
      for _, segment in ipairs(mark.segments) do
        for code, n in pairs(segment.counts) do
          local key = segment.stage .. " " .. code
          local owed = drop[key] or 0
          local taken = math.min(n, owed)
          if taken > 0 then
            negative[key] = (negative[key] or 0) - taken
            drop[key] = owed - taken
          end
        end
      end
      if next(negative) ~= nil then
        local rest = render(mark.prefix, changed(mark, negative))
        if rest ~= "" then
          edits[#edits + 1] = { first = mark.first, last = mark.last, with = rest }
        else
          -- The comment goes: a line of its own with its break, a trailing one with the spaces before it.
          local from = mark.first
          while from > 1 and sub(text, from - 1, from - 1):match("[ \t]") ~= nil do
            from = from - 1
          end
          local to = mark.last
          if mark.alone then
            if sub(text, to + 1, to + 1) == "\r" then to = to + 1 end
            if sub(text, to + 1, to + 1) == "\n" then to = to + 1 end
          end
          edits[#edits + 1] = { first = from, last = to, with = "" }
        end
      end
    end
  end
  return applied(text, edits)
end

return Markers
