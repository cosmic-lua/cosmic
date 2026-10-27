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
    label?: string
  end

  --- A stretch of one file's comment text, markers taken off, and the
  --- line of the file it starts on. `starts`, when given, holds the byte
  --- of the file each of its lines begins at, 0 for a line whose text
  --- is not one stretch of the file (two comments joined on one line).
  record Block
    line: integer
    text: string
    starts: {integer}?
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
    --- Each name every comment of the file sees ([`Declared.names`] inherits them), which is filled once a line has been
    --- asked for: nil for a reader that does not keep them apart.
    everywhere?: {string: boolean}
  end

  --- What a file declares, for the first step of resolution.
  record Declared
    --- Each name, and each dotted path of a record's field or member:
    --- a set to look up, not to walk, since a Teal file's inherits what
    --- every comment of the file sees (`__index`).
    names: mut {string: boolean}
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
    column?: integer
    starts?: {integer}
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

--- The byte of `source` each of its lines starts at, counted from 1: a line
--- ends at "\n". The text files of [`build.link_files`] are read by it, as the
--- comments of a Teal source's tokens are by their own offsets.
function link_text.line_starts(source: string): {integer}
  local starts: mut {integer} = { 1 }
  local pos = 1
  while true do
    local nl = source:find("\n", pos, true)
    if nl == nil then
      break
    end
    starts[#starts + 1] = nl + 1
    pos = nl + 1
  end
  return starts
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
local function closing_bracket(text: string, at: integer, limit: integer): integer?
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
local function fence_opener(content: string): string?
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
  local starts: mut {integer} = { 1 }
  for at in text:gmatch("()\n") do
    starts[#starts + 1] = at + 1
  end
  local ends: mut {integer} = {}
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
  local pieces: mut {string} = {}
  local from = 1
  local at = text:find("[\\`<]", 1)
  while at ~= nil do
    local c = text:sub(at, at)
    if c == "\\" then
      at = at + 2
    elseif c == "`" then
      at = past_code_span(text, at, ends(at))
    elseif text:sub(at, at + 3) == "<!--" then
      local stop: integer?
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
  local lines: mut {string} = {}
  local least: integer? = nil
  for line in String.lines(text) do
    lines[#lines + 1] = line
    if line:find("%S") ~= nil then
      local column = indent_of(line)
      if least == nil or column < least then
        least = column
      end
    end
  end
  local out: mut {string} = {}
  -- The open fence's run, the column its container's content starts at
  -- and the quote it is in.
  local fence: string? = nil
  local fence_base, fence_depth = 0, 0
  -- Whether an HTML comment block is open, and its container's column
  -- and quote as a fence's.
  local in_comment = false
  local comment_base, comment_depth = 0, 0
  -- Each line that goes on with the paragraph of the line before it.
  local continues: mut {integer: boolean} = {}
  -- The column each open list item's content starts at, innermost last.
  local items: mut {integer} = {}
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
    out[number] = if hidden then "" else line end
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
function link_text.shortcut_target(inner: string): string?
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
local function destination(raw: string): string?
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
local function scan(text: string, continues: {integer: boolean}, spans?: mut {link_text.Span}): {link_text.Link}
  local ends = paragraph_ends(text, continues)
  local starts: mut {integer} = { 1 }
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

  local out: mut {link_text.Link} = {}
  local defined: mut {string: string} = {}
  local definition_lines: mut {integer: boolean} = {}
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
  local function link_at(at: integer): integer?
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
      at = if next_line ~= nil then next_line + 1 else #text + 1 end
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
  local lines: mut {string} = {}
  for line in String.lines(visible) do
    lines[#lines + 1] = line
  end
  local out: mut {link_text.Span} = {}
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

--- The block [`link_text.blocks_of`] is joining comments into.
local record Joining
  mut lines: mut {string}
  mut starts: mut {integer}
end

--- Comments on consecutive lines, joined into blocks: a definition
--- holds for the block it is in.
function link_text.blocks_of(comments: {link_text.Comment}): {link_text.Block}
  local out: mut {link_text.Block} = {}
  -- The block being joined: its lines, and where each starts.
  local open: Joining = { lines = {}, starts = {} }
  local first, next_line = 0, -1
  local function flush()
    if #open.lines > 0 then
      out[#out + 1] = { line = first, text = table.concat(open.lines, "\n"), starts = open.starts }
    end
    open.lines = {}
    open.starts = {}
  end
  for _, comment in ipairs(comments) do
    local lines = comment.lines
    local at = comment.starts or {}
    if #open.lines > 0 and comment.line == next_line - 1 then
      -- A second comment on the line the one before it ended on.
      open.lines[#open.lines] = open.lines[#open.lines] .. " " .. lines[1]
      open.starts[#open.lines] = 0
      for index = 2, #lines do
        open.lines[#open.lines + 1] = lines[index]
        open.starts[#open.lines] = at[index] or 0
      end
    else
      if comment.line ~= next_line then
        flush()
        first = comment.line
      end
      for index, line in ipairs(lines) do
        open.lines[#open.lines + 1] = line
        open.starts[#open.lines] = at[index] or 0
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
  local out: mut {link_text.Link} = {}
  for _, block in ipairs(blocks) do
    for _, link in ipairs(link_text.parse(block.text)) do
      link.line = link.line + block.line - 1
      out[#out + 1] = link
    end
  end
  return out
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
function link_text.name_of(target: string): string?
  if target:find("#", 1, true) ~= nil then
    return nil
  end
  local name = target:gsub("%(%)$", "")
  if name:match("^[%a_][%w_]*$") ~= nil or name:match("^[%a_][%w_]*[%.:][%a_][%w_%.:]*$") ~= nil then
    return name
  end
  return nil
end

--- `text` as a reader is shown it: each shortcut link, and each
--- reference written as one (`` [`x`] `` with a definition), as its
--- code span alone, and the line of each definition whose label is a
--- code span left out, as the link it serves is.
function link_text.unlinked(text: string): string
  if not link_text.may_link(text) then
    return text
  end
  local starts: mut {integer} = { 1 }
  for at in text:gmatch("()\n") do
    starts[#starts + 1] = at + 1
  end
  local cut: mut {integer: boolean} = {}
  local dropped: mut {integer: boolean} = {}
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
  local out: mut {string} = {}
  local number = 0
  for line in String.lines(text) do
    number = number + 1
    if not dropped[number] then
      local start = starts[number]
      local kept: mut {string} = {}
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

return link_text
