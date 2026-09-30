--- The links a text holds, read off the text alone: what the build's
--- parse records of every Teal source ([`build.importer`]), keyed by the
--- source's hash, and what `cosmic fix` checks ([`build.links`]). Nothing
--- here reads a file, a database or the tree: a link's words, where
--- it is and what the file it is in declares are functions of the
--- source's bytes, which is what lets a parse keep them. What a link
--- resolves to is [`build.link_resolve`]'s.
---
--- See [`build.links`] for the forms a link takes and what is prose.

local String = require("cosmic.string")
local ast = require("build.ast")
local type compiler = require("build.compiler")
local scopes = require("build.scopes")

local record link_text
  --- One link of a text, or one definition a reference link reads.
  record Link
    --- The line its `[` is on, counted from 1, and the byte of that
    --- line it is.
    line: integer
    column: integer
    --- "shortcut", "inline", "reference" or "definition".
    form: string
    --- What is between its first brackets.
    text: string
    --- Where it points.
    target: string
    --- A reference's or a definition's label.
    label: string | nil
  end

  --- A stretch of one file's comment text, markers taken off, and the
  --- line of the file it starts on. `starts`, when given, holds the byte
  --- of the file each of its lines begins at, 0 for a line whose text
  --- is not one stretch of the file (two comments joined on one line).
  record Block
    line: integer
    text: string
    starts: {integer} | nil
  end

  --- A code span of a text that no link holds, as [`plain_spans`] finds
  --- it: the line it is on, counted from 1, the byte of that line its
  --- first backtick is, the span as written, backticks and all, and
  --- what it holds.
  record Span
    line: integer
    column: integer
    written: string
    content: string
  end

  --- What a Teal source declares (`declarations`): where a comment
  --- stands, and at its top level as far as a plain span may be linked
  --- to it.
  record Declarations
    --- What a comment on `line` sees declared.
    at: function(line: integer): Declared
    --- Each module-level name, dotted as [`Declared.names`] holds it,
    --- that nothing else of the file declares.
    module_level: {string: boolean}
  end

  --- What a file declares, for the first step of resolution.
  record Declared
    --- Each name, and each dotted path of a record's field or member:
    --- a set to look up, not to walk, since a Teal file's inherits what
    --- every comment of the file sees (`__index`).
    names: {string: boolean}
    --- Each local bound to `require` of a module, and that module.
    aliases: {string: string}
  end

  --- One comment's lines with its markers taken off, the line of the
  --- file it starts on, and whether it is a doc comment (`---`). A Teal
  --- comment also says the byte of its line its text starts at
  --- (`column`), counted from 1. `starts`, when given, holds the byte
  --- of the file each line's text begins at.
  record Comment
    line: integer
    lines: {string}
    doc: boolean
    column: integer
    starts: {integer} | nil
  end

  --- A link a Teal source's comments hold, as the build records it:
  --- the link, whether its comment is a doc comment, and what the
  --- first step of resolution reads of the file for its target
  --- ([`build.link_resolve`]): whether the file declares the name
  --- (`own`), and the module the name's first part is an alias of
  --- (`alias`, "" for none).
  record Found
    link: Link
    doc: boolean
    own: boolean
    alias: string
  end
end

--- A label as a definition and a reference both match it: case and
--- runs of whitespace aside.
function link_text.label_key(label: string): string
  return String.trim((label:gsub("%s+", " "))):lower()
end

--- Where to go on from the backtick at `at`: past the code span it
--- opens, or past its run of backticks when no run as long closes it
--- and they are plain text.
--- A code span ends with its paragraph, which ends at the byte `limit`.
local function past_code_span(text: string, at: integer, limit: integer): integer
  local run = #text:match("^`+", at)
  local j = at + run
  while true do
    local s, e = text:find("`+", j)
    if s == nil or s > limit then
      return at + run
    end
    if e - s + 1 == run then
      return e + 1
    end
    j = e + 1
  end
end

--- The `]` that closes the `[` at `at`, brackets nested, code spans and
--- escapes passed over; nil when the end of its paragraph, the byte
--- `limit`, comes first.
local function closing_bracket(text: string, at: integer, limit: integer): integer | nil
  local depth = 1
  local j = at + 1
  while j < limit and j <= #text do
    local c = text:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == "`" then
      j = past_code_span(text, j, limit)
    elseif c == "[" then
      depth = depth + 1
      j = j + 1
    elseif c == "]" then
      depth = depth - 1
      if depth == 0 then
        return j
      end
      j = j + 1
    else
      j = j + 1
    end
  end
  return nil
end

--- The column `s`'s leading spaces and tabs reach, from `s` at
--- `start` (0 when not given), a tab going on to the next multiple of
--- four as CommonMark counts one, and the byte that follows them.
local function indent_of(s: string, start?: integer): integer, integer
  local column, at = start or 0, 1
  while true do
    local c = s:sub(at, at)
    if c == " " then
      column = column + 1
    elseif c == "\t" then
      column = column + 4 - column % 4
    else
      return column, at
    end
    at = at + 1
  end
end

--- The run that opens a fenced code block at the start of `content`:
--- three or more backticks, with none in the info string after them,
--- or three or more tildes.
local function fence_opener(content: string): string | nil
  local ticks = content:match("^```+")
  if ticks ~= nil then
    return content:find("`", #ticks + 1, true) == nil and ticks or nil
  end
  return content:match("^~~~+")
end

--- Whether `content` is a thematic break: three or more of one of
--- `-`, `*` or `_`, and nothing else but spaces.
local function thematic(content: string): boolean
  local mark = content:match("^[-*_]")
  if mark == nil then
    return false
  end
  local marks = content:gsub("[ \t]", "")
  return #marks >= 3 and marks:match("^%" .. mark .. "+$") ~= nil
end

--- Whether `content` is an ATX heading: one to six `#` and a space or
--- nothing after them.
local function heading(content: string): boolean
  local marks = content:match("^#+")
  return marks ~= nil and #marks <= 6 and (#content == #marks or content:match("^#+[ \t]") ~= nil)
end

--- Whether `content`, indented less than code past its container,
--- starts a block that ends the paragraph before it, where any other
--- line continues that paragraph (CommonMark's lazy continuation).
--- `within` says the paragraph is in the container the line is in: a
--- list item then starts a list there, which it does only when it
--- holds something and, ordered, counts from 1. A line that falls out
--- of the paragraph's container starts any list item, a sibling of one
--- open (`10.` after `9.`) among them.
local function interrupts(content: string, within: boolean): boolean
  if fence_opener(content) ~= nil or content:match("^<!%-%-") ~= nil or heading(content) or
      thematic(content) or content:match("^>") ~= nil then
    return true
  end
  if within then
    return content:match("^[-+*][ \t]+%S") ~= nil or content:match("^1[.)][ \t]+%S") ~= nil
  end
  local marker = content:match("^[-+*]") or content:match("^%d%d?%d?%d?%d?%d?%d?%d?%d?[.)]")
  return marker ~= nil and content:sub(#marker + 1):match("^[ \t]") ~= nil or content == marker
end

--- The number of `>` a line is quoted to, what follows them and the
--- column of space after each, and the column that starts at. A tab
--- after a `>` gives it one column and leaves the rest of its width.
local function unquoted(line: string): integer, string, integer
  local depth, column = 0, 0
  while true do
    local _, marker = line:find("^ ? ? ?>")
    if marker == nil then
      return depth, line, column
    end
    depth = depth + 1
    column = column + marker
    line = line:sub(marker + 1)
    local c = line:sub(1, 1)
    if c == " " then
      line = line:sub(2)
      column = column + 1
    elseif c == "\t" then
      line = (" "):rep(3 - column % 4) .. line:sub(2)
      column = column + 1
    end
  end
end

--- Where the paragraph of each byte of `text` ends, given the lines
--- that go on with the paragraph of the line before them
--- (`continues`): the line break after its last line, or one past the
--- text's end. A line that is no paragraph's (a heading) is one alone.
local function paragraph_ends(text: string, continues: {integer: boolean}): function(integer): integer
  local starts: {integer} = { 1 }
  for at in text:gmatch("()\n") do
    starts[#starts + 1] = at + 1
  end
  local ends: {integer} = {}
  local stop = #text + 1
  for number = #starts, 1, -1 do
    ends[number] = stop
    if not continues[number] then
      stop = starts[number] - 1
    end
  end
  return function(at: integer): integer
    local low, high = 1, #starts
    while low < high do
      local mid = (low + high + 1) // 2
      if starts[mid] <= at then low = mid else high = mid - 1 end
    end
    return ends[low]
  end
end

--- `text` with each HTML comment within a paragraph, as CommonMark
--- reads one (`<!-->`, `<!--->`, or `<!--` up to the first `-->`),
--- blanked byte for byte. A code span or an escape that comes first
--- holds its `<!--` as text, and so does one whose paragraph ends
--- first: `continues` holds each line that goes on with the paragraph
--- of the line before it.
local function without_inline_comments(text: string, continues: {integer: boolean}): string
  if text:find("<!--", 1, true) == nil then
    return text
  end
  local ends = paragraph_ends(text, continues)
  local pieces: {string} = {}
  local from = 1
  local at = text:find("[\\`<]", 1)
  while at ~= nil do
    local c = text:sub(at, at)
    if c == "\\" then
      at = at + 2
    elseif c == "`" then
      at = past_code_span(text, at, ends(at))
    elseif text:sub(at, at + 3) == "<!--" then
      local stop: integer | nil
      if text:sub(at + 4, at + 4) == ">" then
        stop = at + 4
      elseif text:sub(at + 4, at + 5) == "->" then
        stop = at + 5
      else
        local _, close = text:find("-->", at + 4, true)
        stop = close
      end
      if stop ~= nil and stop < ends(at) then
        pieces[#pieces + 1] = text:sub(from, at - 1)
        pieces[#pieces + 1] = (text:sub(at, stop):gsub("[^\n]", " "))
        from = stop + 1
        at = stop + 1
      else
        at = at + 1
      end
    else
      at = at + 1
    end
    at = text:find("[\\`<]", at)
  end
  pieces[#pieces + 1] = text:sub(from)
  return table.concat(pieces)
end

--- `text` with what CommonMark shows as code, or hides, taken out of
--- it, so that a link-shaped bracket there is read as no link: each
--- line of a fenced or an indented code block and of an HTML block
--- that is a comment left empty, and an HTML comment within a paragraph
--- blanked byte for byte, so what is left keeps its lines and columns;
--- and, by its number, each line that goes on with the paragraph of the
--- line before it, where a code span, a link's text or an HTML comment
--- may go on too. [`without_code`] is its text alone.
---
--- It follows CommonMark's containers as far as these need. A line is
--- indented code when it is indented four columns or more past its
--- container and continues no paragraph; the container is the list
--- item the line is in, whose content starts past its marker and the
--- one to four spaces after it, or else the text's least indented line,
--- which a comment's text starts past. A blockquote's lines are read
--- past their `>`. A fence or an HTML comment closes at its end or
--- where its list item or quote does.
---
--- A comment's text is read as a Markdown file is, since the forms a
--- link takes are Markdown's and a doc shows it as Markdown.
---
--- Left out, as the tree does not need them: HTML blocks other than a
--- comment, and a quote begun inside a list item (`1. > x`).
local function visible_of(text: string): string, {integer: boolean}
  local lines: {string} = {}
  local least: integer | nil = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
    if line:find("%S") ~= nil then
      local column = indent_of(line)
      if least == nil or column < least then
        least = column
      end
    end
  end
  local out: {string} = {}
  -- The open fence's run, the column its container's content starts at
  -- and the quote it is in.
  local fence: string | nil = nil
  local fence_base, fence_depth = 0, 0
  -- Whether an HTML comment block is open, and its container's column
  -- and quote as a fence's.
  local in_comment = false
  local comment_base, comment_depth = 0, 0
  -- Each line that goes on with the paragraph of the line before it.
  local continues: {integer: boolean} = {}
  -- The column each open list item's content starts at, innermost last.
  local items: {integer} = {}
  local paragraph = false
  local quotes = 0
  for number, line in ipairs(lines) do
    local depth, rest, start = unquoted(line)
    local blank = rest:find("%S") == nil
    -- The column as the line has it, which a tab's stop is counted
    -- from, and as its container reads it.
    local raw, from = indent_of(rest, start)
    local shift = depth == 0 and math.min(least or 0, raw) or start
    local column = raw - shift
    local content = rest:sub(from)
    local hidden = false
    if in_comment and (blank or depth >= comment_depth and column >= comment_base) then
      hidden = true
      in_comment = line:find("-->", 1, true) == nil
    elseif fence ~= nil and depth > fence_depth and
        (fence_depth > 0 or indent_of(line) - (least or 0) >= fence_base) then
      -- A `>` in the fence's container, past its quote, is its code.
      hidden = true
    elseif fence ~= nil and (blank or depth == fence_depth and column >= fence_base) then
      hidden = true
      local closer = content:match("^" .. fence:sub(1, 1) .. "+")
      if closer ~= nil and #closer >= #fence and column - fence_base < 4 and
          content:sub(#closer + 1):match("^[ \t]*$") ~= nil then
        fence = nil
      end
    elseif blank then
      paragraph = false
    else
      -- Its container closed: the fence or the comment ends with it.
      fence = nil
      in_comment = false
      -- Whether the line goes on with the paragraph before it.
      local continued = false
      if depth ~= quotes then
        continued = paragraph and depth < quotes and (column >= 4 or not interrupts(content, false))
        if not continued then
          items = {}
          quotes = depth
          paragraph = false
        end
      end
      local open = #items
      while open > 0 and column < items[open] do
        open = open - 1
      end
      local base = open > 0 and items[open] or 0
      if not continued and paragraph then
        local near = column - base < 4
        if near and open == #items and
            (content:match("^=+[ \t]*$") ~= nil or content:match("^%-+[ \t]*$") ~= nil) then
          -- A setext heading's underline, which ends the paragraph; out
          -- of the paragraph's list item, it is no underline.
          continued = true
          paragraph = false
        elseif not near or not interrupts(content, open == #items) then
          continued = true
        end
      end
      continues[number] = continued and paragraph
      if not continued then
        for index = #items, open + 1, -1 do
          items[index] = nil
        end
        paragraph = false
        if column - base >= 4 then
          hidden = true
        else
          -- Each list item the line opens, `- 1. x` two of them.
          while not thematic(content) do
            local marker = content:match("^[-+*]") or content:match("^%d%d?%d?%d?%d?%d?%d?%d?%d?[.)]")
            local after = marker ~= nil and content:sub(#marker + 1) or ""
            if marker == nil or after ~= "" and after:match("^[ \t]") == nil then
              break
            end
            local reached, past = indent_of(after, raw + #marker)
            local spaces = reached - raw - #marker
            local body = after:sub(past)
            if body == "" or spaces > 4 then
              -- Past five spaces, the item's content is indented code.
              items[#items + 1] = column + #marker + 1
              hidden = body ~= ""
              content = ""
              break
            end
            raw = reached
            column = reached - shift
            items[#items + 1] = column
            content = body
          end
          if content == "" or hidden then
            paragraph = false
          elseif fence_opener(content) ~= nil then
            fence = fence_opener(content)
            fence_base = #items > 0 and items[#items] or 0
            fence_depth = depth
            hidden = true
          elseif content:match("^<!%-%-") ~= nil then
            hidden = true
            in_comment = content:find("-->", 3, true) == nil
            comment_base = #items > 0 and items[#items] or 0
            comment_depth = depth
          else
            paragraph = not heading(content) and not thematic(content)
          end
        end
      end
    end
    out[number] = hidden and "" or line
  end
  return without_inline_comments(table.concat(out, "\n"), continues), continues
end

--- `text` with what CommonMark shows as code, or hides, taken out of
--- it, as [`visible_of`] takes it out.
function link_text.without_code(text: string): string
  return (visible_of(text))
end

--- The target a shortcut's text names: the text when it is one code
--- span alone, without its backticks.
function link_text.shortcut_target(inner: string): string | nil
  local ticks = inner:match("^`+")
  if ticks == nil or #inner <= 2 * #ticks or inner:sub(-#ticks) ~= ticks then
    return nil
  end
  local content = inner:sub(#ticks + 1, -#ticks - 1)
  if content:find("`", 1, true) ~= nil then
    return nil
  end
  local target = String.trim(content)
  return target ~= "" and target or nil
end

--- The destination of an inline link, from what its parentheses
--- hold: a URL or path with no space, or one in `<>`, and after it at
--- most a quoted title. Nil when it cannot be one -- a space in it, a
--- pattern's or an expression's characters, a `%` that does not open a
--- percent-escape -- and the brackets before it are prose.
local function destination(raw: string): string | nil
  raw = String.trim(raw)
  local target, rest = raw:match("^<([^<>\n]*)>(.*)$")
  if target == nil then
    target, rest = raw:match("^(%S+)(.*)$")
  end
  if target == nil or target == "" then
    return nil
  end
  rest = String.trim(rest)
  if rest ~= "" and rest:match('^".*"$') == nil and rest:match("^'.*'$") == nil and
      rest:match("^%(.*%)$") == nil then
    return nil
  end
  if target:find("[%+%*%^%$%[%]{}|\\()]") ~= nil and target:match("^%a[%w+.-]*://") == nil then
    return nil
  end
  if (target:gsub("%%%x%x", "")):find("%", 1, true) ~= nil then
    return nil
  end
  return target
end

--- Every link of `text`, a text as [`visible_of`] leaves it with
--- the lines that go on with a paragraph (`continues`), and every
--- definition it holds, in order of the line each is on, and each code
--- span no link holds, added to `spans` when it is given. Every form but
--- the three a link takes is passed over.
local function scan(text: string, continues: {integer: boolean}, spans?: {link_text.Span}): {link_text.Link}
  local ends = paragraph_ends(text, continues)
  local starts: {integer} = { 1 }
  for at in text:gmatch("()\n") do
    starts[#starts + 1] = at + 1
  end
  local function line_of(at: integer): integer
    local low, high = 1, #starts
    while low < high do
      local mid = (low + high + 1) // 2
      if starts[mid] <= at then low = mid else high = mid - 1 end
    end
    return low
  end
  local function column_of(at: integer): integer
    return at - starts[line_of(at)] + 1
  end

  local out: {link_text.Link} = {}
  local defined: {string: string} = {}
  local definition_lines: {integer: boolean} = {}
  for number, start in ipairs(starts) do
    local label, target = text:match("^[ \t]*%[([^%]\n]+)%]:[ \t]*(%S+)", start)
    -- A footnote (`[^1]: ...`) defines no link.
    if label ~= nil and target ~= nil and label:sub(1, 1) ~= "^" then
      target = target:match("^<(.*)>$") or target
      local key = link_text.label_key(label)
      if defined[key] == nil then
        defined[key] = target
      end
      definition_lines[number] = true
      out[#out + 1] = { line = number, column = text:find("[", start, true) - start + 1, form = "definition",
        text = label, target = target, label = label }
    end
  end

  --- The link opened by the `[` at `at`, added to `out`; the index to
  --- go on from, or nil when the bracket is prose.
  local function link_at(at: integer): integer | nil
    local before = at > 1 and text:sub(at - 1, at - 1) or ""
    if before:match("[%w_%]%)%%]") ~= nil then
      return nil
    end
    local long = text:match("^%[=*%[", at)
    if long ~= nil then
      return at + #long
    end
    local close = closing_bracket(text, at, ends(at))
    if close == nil or text:sub(at + 1, at + 1) == "^" then
      return nil
    end
    local inner = text:sub(at + 1, close - 1)
    local after = text:sub(close + 1, close + 1)
    local line, column = line_of(at), column_of(at)
    if after == "(" then
      local stop = text:find(")", close + 2, true)
      if stop == nil then
        return nil
      end
      local raw = text:sub(close + 2, stop - 1)
      if raw:find("\n", 1, true) ~= nil then
        return nil
      end
      local target = destination(raw)
      if target == nil then
        return nil
      end
      out[#out + 1] = { line = line, column = column, form = "inline", text = inner, target = target }
      return stop + 1
    elseif after == "[" then
      local stop = text:find("]", close + 2, true)
      if stop == nil then
        return nil
      end
      local label = text:sub(close + 2, stop - 1)
      if label == "" then
        label = inner
      end
      -- With no definition of its label, CommonMark shows the brackets
      -- as they are (`[i][j]`, `[%a_][%w_]*`): prose.
      local target = defined[link_text.label_key(label)]
      if target == nil then
        return nil
      end
      out[#out + 1] = { line = line, column = column, form = "reference", text = inner,
        target = target, label = label }
      return stop + 1
    end
    local found = defined[link_text.label_key(inner)]
    if found ~= nil then
      out[#out + 1] = { line = line, column = column, form = "reference", text = inner, target = found,
        label = inner }
      return close + 1
    end
    local target = link_text.shortcut_target(inner)
    if target ~= nil then
      out[#out + 1] = { line = line, column = column, form = "shortcut", text = inner, target = target }
      return close + 1
    end
    return nil
  end

  -- Only a `\`, a backtick or a `[` starts anything: the scan goes
  -- from one to the next.
  local at = text:find("[\\`%[]", 1)
  while at ~= nil and at <= #text do
    local c = text:sub(at, at)
    if definition_lines[line_of(at)] then
      local next_line = text:find("\n", at, true)
      at = next_line ~= nil and next_line + 1 or #text + 1
    elseif c == "\\" then
      at = at + 2
    elseif c == "`" then
      local past = past_code_span(text, at, ends(at))
      local run = #text:match("^`+", at)
      local written = text:sub(at, past - 1)
      if spans ~= nil and past > at + run and written:find("\n", 1, true) == nil then
        spans[#spans + 1] = { line = line_of(at), column = column_of(at), written = written,
          content = written:sub(run + 1, -run - 1) }
      end
      at = past
    elseif c == "[" then
      at = link_at(at) or at + 1
    end
    at = text:find("[\\`%[]", at)
  end
  table.sort(out, function(a: link_text.Link, b: link_text.Link): boolean
    return a.line < b.line or a.line == b.line and a.column < b.column
  end)
  return out
end

--- Every link of `text` and every definition it holds, in order of the
--- line each is on; a pure function of the text.
function link_text.parse(text: string): {link_text.Link}
  return scan(visible_of(text))
end

--- Every code span of `text` that could be made a shortcut link by
--- putting brackets around it, and would read as one: outside a link, a
--- definition, a fenced or indented code block, an HTML comment and a
--- heading, on one line, holding no space at either end, and with
--- nothing beside it that would read the brackets as something else --
--- a word, `]`, `)`, `%` or `!` before it (an index, a pattern, an
--- image), a `(` or `[` after it (an inline link or a reference), or a
--- `:` after it at the start of a line, of a list item or of a quote (a
--- definition).
function link_text.plain_spans(text: string): {link_text.Span}
  if text:find("`", 1, true) == nil then
    return {}
  end
  local visible, continues = visible_of(text)
  local found: {link_text.Span} = {}
  scan(visible, continues, found)
  local lines: {string} = {}
  for line in (visible .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local out: {link_text.Span} = {}
  for _, span in ipairs(found) do
    local line = lines[span.line] or ""
    local before = line:sub(1, span.column - 1)
    local after = line:sub(span.column + #span.written, span.column + #span.written)
    local kept = span.content ~= "" and span.content == String.trim(span.content) and
      line:match("^%s*#+%s") == nil and
      before:match("[%w_%]%)%%!]$") == nil and after ~= "(" and after ~= "[" and
      not (after == ":" and (before:match("^[%s>]*$") ~= nil or before:match("^[%s>]*[-*+]%s+$") ~= nil or
        before:match("^[%s>]*%d+[.)]%s+$") ~= nil))
    if kept then
      out[#out + 1] = span
    end
  end
  return out
end

--- A Teal or Lua line comment's text, after `--` and any more dashes;
--- nil for a long comment (`--[[ ... ]]`), which holds code set aside
--- rather than prose.
local function teal_comment(text: string): {string} | nil
  if text:match("^%-%-%[=*%[") ~= nil then
    return nil
  end
  return { (text:gsub("^%-%-+", "")) }
end

--- Comments on consecutive lines, joined into blocks: a definition
--- holds for the block it is in.
function link_text.blocks_of(comments: {link_text.Comment}): {link_text.Block}
  local out: {link_text.Block} = {}
  local current: {string} = {}
  local starts: {integer} = {}
  local first, next_line = 0, -1
  local function flush()
    if #current > 0 then
      out[#out + 1] = { line = first, text = table.concat(current, "\n"), starts = starts }
    end
    current = {}
    starts = {}
  end
  for _, comment in ipairs(comments) do
    local lines = comment.lines
    local at = comment.starts or {}
    if #current > 0 and comment.line == next_line - 1 then
      -- A second comment on the line the one before it ended on.
      current[#current] = current[#current] .. " " .. lines[1]
      starts[#current] = 0
      for index = 2, #lines do
        current[#current + 1] = lines[index]
        starts[#current] = at[index] or 0
      end
    else
      if comment.line ~= next_line then
        flush()
        first = comment.line
      end
      for index, line in ipairs(lines) do
        current[#current + 1] = line
        starts[#current] = at[index] or 0
      end
    end
    next_line = comment.line + #lines
  end
  flush()
  return out
end

--- Every link and definition in `blocks`, each on the line of the file
--- it is on.
function link_text.in_blocks(blocks: {link_text.Block}): {link_text.Link}
  local out: {link_text.Link} = {}
  for _, block in ipairs(blocks) do
    for _, link in ipairs(link_text.parse(block.text)) do
      link.line = link.line + block.line - 1
      out[#out + 1] = link
    end
  end
  return out
end

--- The line comments `tokens`, Teal `source`'s token stream, carry, in
--- the order of their lines.
function link_text.comments_of(tokens: {compiler.Token}, source: string): {link_text.Comment}
  local comments: {link_text.Comment} = {}
  local line_starts = ast.line_starts(source)
  for _, token in ipairs(tokens) do
    for _, comment in ipairs(token.comments or {}) do
      local lines = teal_comment(comment.text)
      if lines ~= nil then
        local column = comment.x + #comment.text - #lines[1]
        comments[#comments + 1] = { line = comment.y, lines = lines,
          doc = comment.text:match("^%-%-%-") ~= nil, column = column,
          starts = { ast.offset_of(line_starts, comment.y, column) } }
      end
    end
  end
  table.sort(comments, function(a: link_text.Comment, b: link_text.Comment): boolean
    return a.line < b.line
  end)
  return comments
end

--- The line comments of Teal `source`, lexed with `built` (which
--- `name` is given to), in the order of their lines.
function link_text.teal_comments(built: compiler, source: string, name: string): {link_text.Comment}
  local tokens, _ = built.lex(source, name)
  return link_text.comments_of(tokens, source)
end

--- Whether `source` could hold a link at all: none can be written
--- without a `[` and one of these.
function link_text.may_link(source: string): boolean
  return source:find("[", 1, true) ~= nil and (source:find("`]", 1, true) ~= nil or
    source:find("](", 1, true) ~= nil or source:find("][", 1, true) ~= nil or
    source:find("]:", 1, true) ~= nil)
end

--- The name `target` could be, as the first two steps of resolution
--- read one: a target with no anchor shaped as a name or a dotted path
--- (`read`, [`Fs.read`], `Box:grow`), a call's `()` left off; nil
--- for one that is no name.
function link_text.name_of(target: string): string | nil
  if target:find("#", 1, true) ~= nil then
    return nil
  end
  local name = target:gsub("%(%)$", "")
  if name:match("^[%a_][%w_]*$") ~= nil or name:match("^[%a_][%w_]*[%.:][%a_][%w_%.:]*$") ~= nil then
    return name
  end
  return nil
end

--- Teal's keywords, which name nothing a file declares.
local KEYWORDS <const>: {string: boolean} = {
  ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
  ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["goto"] = true,
  ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
  ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
  ["while"] = true, ["record"] = true, ["enum"] = true, ["interface"] = true, ["type"] = true,
  ["global"] = true, ["as"] = true, ["is"] = true, ["where"] = true,
}

--- Whether the token `tk` is a name.
local function is_name(tk: string | nil): boolean
  return tk ~= nil and tk:match("^[%a_][%w_]*$") ~= nil and not KEYWORDS[tk]
end

--- What the Teal source `parsed` declares where each of its comments
--- stands, and what it declares at its top level and nowhere else.
---
--- A comment sees what Lua would have in scope at the token it stands
--- before -- the lexer hands a comment to the next token -- and
--- whatever the file declares for good:
---
--- - Each name its top-level block binds (a local, a `local function`,
---   a type, an alias `local Fs = require("m")`), wherever the comment
---   is: the chunk's names are the file's, and its doc comments speak of
---   them before or after their declarations. Before a name's first
---   declaration, the first is the one a comment sees.
--- - Each name a nested block binds -- a local, a parameter, a loop's
---   variable -- where Lua has it in scope ([`scopes.in_scope`]): from
---   past the statement binding it (a function's or a type's from its
---   name), or from a parameter or loop variable itself, to the end of
---   its block. A doc comment (`---`) directly above a declaration sees
---   the scope that declaration is in and the names it declares; a
---   plain comment there sees only the scope. Neither sees the
---   declaration's parameters: those are its body's, and a comment
---   inside the body sees them. An inner binding shadows an outer one,
---   so a local of an alias's name ends the alias there.
--- - Each function by its name and its path (`grow`, `Box.grow`), and a
---   top-level record's, enum's or type's members spelled in full
---   (`Box.width`) and by their own names: a path names a field, which
---   no scope holds.
---
--- A function type's parameters (a record's field, a `.d.tl`
--- declaration) are no body's, so no comment sees them, as the one
--- above a function sees none of its own.
---
--- At the top level and nowhere else: a function, record, enum or type
--- declared at the start of a line (the layout `cosmic fix` writes puts
--- a top-level statement there, and a nested one past it), a top-level
--- record's members in full, and a type or function member by its own
--- name, when nothing else of the file declares the same name. Never a
--- value's local, which a plain name in a comment may mean as a
--- variable, nor a field by its own name.
---
--- It is read off the tokens, with the tree's top-level statements for
--- a record's members; the scopes are walked once, the first time a
--- comment asks, and each place's answer is kept.
function link_text.declarations(parsed: ast.Parsed): link_text.Declarations
  -- `names` holds what no scope does; `top` and `inner` say where each
  -- name is declared, for `module_level`.
  local names: {string: boolean} = {}
  local top: {string: boolean} = {}
  local inner: {string: boolean} = {}
  local function declare(name: string | nil, at_top: boolean, scoped: boolean)
    if name == nil or name == "" then return end
    if not scoped then names[name] = true end
    if at_top then top[name] = true else inner[name] = true end
  end
  local function declare_type(prefix: string, t: ast.TypeNode | nil, depth: integer)
    if t == nil or depth > 16 then return end
    local shape: ast.TypeNode = t.def or t
    local fields: {string: ast.TypeNode} = shape.fields or {}
    for field, field_type in pairs(fields) do
      declare(prefix .. "." .. field, true, false)
      declare(field, field_type.typename == "typedecl" or field_type.typename == "function", false)
      declare_type(prefix .. "." .. field, field_type, depth + 1)
    end
    local meta_fields: {string: ast.TypeNode} = shape.meta_fields or {}
    for field in pairs(meta_fields) do declare(prefix .. "." .. field, true, false) end
    local values: {string: boolean} = shape.enumset or {}
    for value in pairs(values) do declare(prefix .. "." .. value, true, false) end
  end
  for _, statement in ipairs(parsed.node) do
    local var, value = statement.var, statement.value
    if statement.kind == "local_type" and var ~= nil and var.tk ~= nil and value ~= nil and
        value.kind == "newtype" then
      declare_type(var.tk, value.newtype, 0)
    end
  end
  local tokens = parsed.tokens
  local function tk_at(at: integer): string
    local token = tokens[at]
    return token ~= nil and token.tk or ""
  end
  -- The token each comment's line stands before, and whether it is a
  -- doc comment's line.
  local before: {integer: compiler.Token} = {}
  local doc: {integer: boolean} = {}
  for at, token in ipairs(tokens) do
    local tk = token.tk
    local at_top = token.x == 1
    for _, comment in ipairs(token.comments or {}) do
      before[comment.y] = token
      doc[comment.y] = comment.text:match("^%-%-%-") ~= nil
    end
    if tk == "local" then
      local kind = tk_at(at + 1)
      if kind == "function" then
        declare(tk_at(at + 2), at_top, true)
      elseif kind == "record" or kind == "enum" or kind == "interface" or kind == "type" then
        local name = tk_at(at + 2)
        if is_name(name) then
          local alias = tk_at(at + 3) == "=" and tk_at(at + 4) == "require"
          declare(name, at_top and not alias, true)
        end
      else
        local j = at + 1
        while is_name(tk_at(j)) do
          declare(tk_at(j), false, true)
          j = j + 1
          if tk_at(j) == "<" then j = j + 3 end
          if tk_at(j) ~= "," then break end
          j = j + 1
        end
      end
    elseif tk == "function" then
      local before_tk = tk_at(at - 1)
      local j = at + 1
      if before_tk == "local" then
        j = at + 2
      elseif is_name(tk_at(j)) then
        local path = tk_at(j)
        j = j + 1
        while (tk_at(j) == "." or tk_at(j) == ":") and is_name(tk_at(j + 1)) do
          path = path .. "." .. tk_at(j + 1)
          j = j + 2
        end
        local named_top = at_top or before_tk == "global" and tokens[at - 1].x == 1
        declare(path, named_top, false)
        declare(path:match("([^.]+)$"), named_top, false)
      end
      if tk_at(j) == "<" then
        while tk_at(j) ~= ">" and tk_at(j) ~= "" do j = j + 1 end
        j = j + 1
      end
      if tk_at(j) == "(" then
        local depth = 1
        j = j + 1
        while tk_at(j) ~= "" and depth > 0 do
          local each = tk_at(j)
          if each == "(" or each == "{" or each == "[" then
            depth = depth + 1
          elseif each == ")" or each == "}" or each == "]" then
            depth = depth - 1
          elseif depth == 1 and is_name(each) and (tk_at(j + 1) == ":" or tk_at(j + 1) == "?") then
            declare(each, false, true)
          end
          j = j + 1
        end
      end
    elseif tk == "for" then
      local j = at + 1
      while is_name(tk_at(j)) do
        declare(tk_at(j), false, true)
        if tk_at(j + 1) ~= "," then break end
        j = j + 2
      end
    end
  end
  local module_level: {string: boolean} = {}
  for name in pairs(top) do
    if not inner[name] then module_level[name] = true end
  end
  local bindings: {scopes.Binding} | nil = nil
  -- What every comment sees: `names`, the top-level block's bindings,
  -- and its aliases, the first binding of each name deciding before a
  -- later one is in scope.
  local everywhere: {string: boolean} = {}
  local top_aliases: {string: string} = {}
  local function scoped(): {scopes.Binding}
    local found = bindings
    if found == nil then
      found = scopes.bindings_of(parsed)
      bindings = found
      for _, each in ipairs(found) do
        if each.top and not everywhere[each.name] then
          everywhere[each.name] = true
          top_aliases[each.name] = each.module ~= "" and each.module or nil
        end
      end
      for name in pairs(names) do everywhere[name] = true end
    end
    return found
  end
  local seen: {integer: link_text.Declared} = {}
  local function at(line: integer): link_text.Declared
    local token = before[line]
    local y, x = token ~= nil and token.y or line, token ~= nil and token.x or 0
    local doc_line = doc[line] == true
    local place = scopes.position(y, x) * 2 + (doc_line and 1 or 0)
    local known = seen[place]
    if known ~= nil then return known end
    local in_scope = scopes.in_scope(scoped(), y, x, doc_line)
    local here: {string: boolean} = setmetatable({}, { __index = everywhere })
    local aliases: {string: string} = {}
    for name, module in pairs(top_aliases) do aliases[name] = module end
    for name, module in pairs(in_scope) do
      here[name] = true
      aliases[name] = module ~= "" and module or nil
    end
    known = { names = here, aliases = aliases }
    seen[place] = known
    return known
  end
  return { at = at, module_level = module_level }
end

--- `text` as a reader is shown it: each shortcut link, and each
--- reference written as one (`` [`x`] `` with a definition), as its
--- code span alone, and the line of each definition whose label is a
--- code span left out, as the link it serves is.
function link_text.unlinked(text: string): string
  if not link_text.may_link(text) then
    return text
  end
  local starts: {integer} = { 1 }
  for at in text:gmatch("()\n") do
    starts[#starts + 1] = at + 1
  end
  local cut: {integer: boolean} = {}
  local dropped: {integer: boolean} = {}
  for _, link in ipairs(scan(visible_of(text))) do
    if link.form == "definition" then
      if link_text.shortcut_target(link.label or "") ~= nil then dropped[link.line] = true end
    elseif (link.form == "shortcut" or link.form == "reference") and
        link_text.shortcut_target(link.text) ~= nil then
      local open = starts[link.line] + link.column - 1
      local close = open + #link.text + 1
      local after = text:sub(close + 1, close + 1)
      if text:sub(close, close) == "]" and after ~= "(" and after ~= "[" then
        cut[open] = true
        cut[close] = true
      end
    end
  end
  local out: {string} = {}
  local number = 0
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if not dropped[number] then
      local start = starts[number]
      local kept: {string} = {}
      local from = 1
      for at = 1, #line do
        if cut[start + at - 1] then
          kept[#kept + 1] = line:sub(from, at - 1)
          from = at + 1
        end
      end
      kept[#kept + 1] = line:sub(from)
      out[#out + 1] = table.concat(kept)
    end
  end
  local shown = table.concat(out, "\n")
  if next(dropped) ~= nil then
    -- The blank line a block of definitions stood after.
    shown = shown:gsub("%s+$", "")
  end
  return shown
end

--- The links of Teal `source`'s comments, parsed to `root` and lexed
--- with `built` (which `name` is given to), as the build records
--- them: every link but a definition, whose target a reference link
--- carries.
function link_text.found(built: compiler, root: ast.Node, source: string,
                         name: string): {link_text.Found}
  local out: {link_text.Found} = {}
  if not link_text.may_link(source) then
    return out
  end
  local tokens, _ = built.lex(source, name)
  local comments = link_text.comments_of(tokens, source)
  local doc: {integer: boolean} = {}
  local column: {integer: integer} = {}
  for _, comment in ipairs(comments) do
    doc[comment.line] = comment.doc
    column[comment.line] = comment.column
  end
  local known: link_text.Declarations | nil = nil
  local function declared(line: integer): link_text.Declared
    local found: link_text.Declarations = known or link_text.declarations({ node = root, tokens = tokens })
    known = found
    return found.at(line)
  end
  for _, link in ipairs(link_text.in_blocks(link_text.blocks_of(comments))) do
    if link.form ~= "definition" then
      local own, alias = false, ""
      local named = link_text.name_of(link.target)
      if named ~= nil then
        local dotted = named:gsub(":", ".")
        local here = declared(link.line)
        own = here.names[dotted] == true
        local first = dotted:match("^([%a_][%w_]*)%.")
        if first ~= nil then
          alias = here.aliases[first] or ""
        end
      end
      -- The link's column in its file, not in its comment's text.
      link.column = link.column + (column[link.line] or 1) - 1
      out[#out + 1] = { link = link, doc = doc[link.line] == true, own = own, alias = alias }
    end
  end
  return out
end

return link_text
