--- The links a text holds, read off the text alone: what the build's
--- parse records of every Teal source (`build.importer`), keyed by the
--- source's hash, and what `cosmic fix` checks (`build.links`). Nothing
--- here reads a file, a database or the tree: a link's words, where
--- it is and what the file it is in declares are functions of the
--- source's bytes, which is what lets a parse keep them. What a link
--- resolves to is `build.link_resolve`'s.
---
--- See `build.links` for the forms a link takes and what is prose.

local String = require("cosmic.string")
local ast = require("build.ast")
local type compiler = require("build.compiler")

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

  --- A code span of a text that no link holds, as `plain_spans` finds
  --- it: the line it is on, counted from 1, the byte of that line its
  --- first backtick is, the span as written, backticks and all, and
  --- what it holds.
  record Span
    line: integer
    column: integer
    written: string
    content: string
  end

  --- What a Teal source declares (`declarations`): file-wide, and at
  --- its top level as far as a plain span may be linked to it.
  record Declarations
    declared: Declared
    --- Each module-level name, dotted as `Declared.names` holds it,
    --- that nothing else of the file declares.
    module_level: {string: boolean}
  end

  --- What a file declares, for the first step of resolution.
  record Declared
    --- Each name, and each dotted path of a record's field or member.
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
  --- (`build.link_resolve`): whether the file declares the name
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

--- `text` with every line of a fenced code block, fences and all, left
--- empty, so its lines keep their numbers.
-- TODO: pass over an indented code block and an HTML comment too, as
-- CommonMark does: a link-shaped bracket in either is checked as one.
function link_text.without_fences(text: string): string
  local out: {string} = {}
  local fence: string | nil = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local opener = line:match("^ ? ? ?(```+)") or line:match("^ ? ? ?(~~~+)")
    if fence == nil then
      if opener ~= nil then
        fence = opener
        out[#out + 1] = ""
      else
        out[#out + 1] = line
      end
    else
      if opener ~= nil and opener:sub(1, 1) == fence:sub(1, 1) and #opener >= #fence and
          line:match("^%s*[`~]+%s*$") ~= nil then
        fence = nil
      end
      out[#out + 1] = ""
    end
  end
  return table.concat(out, "\n")
end

--- Where to go on from the backtick at `at`: past the code span it
--- opens, or past its run of backticks when no run as long closes it
--- and they are plain text.
local function past_code_span(text: string, at: integer): integer
  local run = #text:match("^`+", at)
  local j = at + run
  -- A code span ends with its paragraph.
  local paragraph = text:find("\n[ \t]*\n", j) or #text + 1
  while true do
    local s, e = text:find("`+", j)
    if s == nil or s > paragraph then
      return at + run
    end
    if e - s + 1 == run then
      return e + 1
    end
    j = e + 1
  end
end

--- The `]` that closes the `[` at `at`, brackets nested, code spans and
--- escapes passed over; nil when a blank line or the end comes first.
local function closing_bracket(text: string, at: integer): integer | nil
  local depth = 1
  local j = at + 1
  while j <= #text do
    local c = text:sub(j, j)
    if c == "\\" then
      j = j + 2
    elseif c == "`" then
      j = past_code_span(text, j)
    elseif c == "[" then
      depth = depth + 1
      j = j + 1
    elseif c == "]" then
      depth = depth - 1
      if depth == 0 then
        return j
      end
      j = j + 1
    elseif c == "\n" and text:match("^\n[ \t]*\n", j) ~= nil then
      return nil
    else
      j = j + 1
    end
  end
  return nil
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

--- Every link of `text` and every definition it holds, in order of the
--- line each is on, and each code span no link holds, added to `spans`
--- when it is given. Fenced code blocks are passed over, and so is
--- every form but the three a link takes.
local function scan(text: string, spans?: {link_text.Span}): {link_text.Link}
  text = link_text.without_fences(text)
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
    local close = closing_bracket(text, at)
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
      local past = past_code_span(text, at)
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
  return scan(text)
end

--- Whether each line of `text` is in an indented code block: indented
--- four columns past the text's least indented line, after a blank line
--- or another such line. A list item's indented paragraph reads as one
--- too, which only leaves a span in it unlinked.
local function indented_code(text: string): {integer: boolean}
  local lines: {string} = {}
  local least: integer | nil = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
    if line:match("%S") ~= nil then
      local indent = #line:match("^ *")
      if least == nil or indent < least then least = indent end
    end
  end
  local out: {integer: boolean} = {}
  local previous_blank = true
  for number, line in ipairs(lines) do
    local blank = line:match("%S") == nil
    if not blank and #line:match("^ *") >= (least or 0) + 4 and
        (previous_blank or out[number - 1]) then
      out[number] = true
    end
    previous_blank = blank
  end
  return out
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
  -- An HTML comment is blanked byte for byte, so the lines and columns
  -- of what is left stay where they were.
  local visible = text:gsub("<!%-%-.-%-%->", function(comment: string): string
    return (comment:gsub("[^\n]", " "))
  end)
  local found: {link_text.Span} = {}
  scan(visible, found)
  local lines: {string} = {}
  for line in (visible .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local code = indented_code(visible)
  local out: {link_text.Span} = {}
  for _, span in ipairs(found) do
    local line = lines[span.line] or ""
    local before = line:sub(1, span.column - 1)
    local after = line:sub(span.column + #span.written, span.column + #span.written)
    local kept = span.content ~= "" and span.content == String.trim(span.content) and
      not code[span.line] and line:match("^%s*#+%s") == nil and
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
--- (`read`, `Fs.read`, `Box:grow`), a call's `()` left off; nil
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

--- What the Teal source `parsed` declares, file-wide, and what it
--- declares at its top level and nowhere else.
---
--- Declared: each local, whatever its depth; each function, by its
--- name and its path (`grow`, `Box.grow`); each record, enum and type,
--- and a top-level one's members spelled in full (`Box.width`) and by
--- their own names; each loop's variable; each parameter a signature
--- names with a type (`n: integer`), a function type's included -- a
--- record's field or a `.d.tl` declaration, whose names the parser's
--- tree keeps nowhere -- and each `local alias = require("m")`.
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
--- a record's members: a walk of every node would cost each file of a
--- run many times more.
-- TODO: resolve a name by the scope at the link's line rather than
-- file-wide, once build.analyzer exposes the names in scope at a line
-- (its `uses_of` and `references_of` walk the scopes, then drop them).
function link_text.declarations(parsed: ast.Parsed): link_text.Declarations
  local names: {string: boolean} = {}
  local aliases: {string: string} = {}
  local top: {string: boolean} = {}
  local inner: {string: boolean} = {}
  local function declare(name: string | nil, at_top: boolean)
    if name == nil or name == "" then return end
    names[name] = true
    if at_top then top[name] = true else inner[name] = true end
  end
  local function declare_type(prefix: string, t: ast.TypeNode | nil, depth: integer)
    if t == nil or depth > 16 then return end
    local shape: ast.TypeNode = t.def or t
    local fields: {string: ast.TypeNode} = shape.fields or {}
    for field, field_type in pairs(fields) do
      declare(prefix .. "." .. field, true)
      declare(field, field_type.typename == "typedecl" or field_type.typename == "function")
      declare_type(prefix .. "." .. field, field_type, depth + 1)
    end
    local meta_fields: {string: ast.TypeNode} = shape.meta_fields or {}
    for field in pairs(meta_fields) do declare(prefix .. "." .. field, true) end
    local values: {string: boolean} = shape.enumset or {}
    for value in pairs(values) do declare(prefix .. "." .. value, true) end
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
  --- The module a `require("m")` at `at` names, or nil.
  local function required_at(at: integer): string | nil
    if tk_at(at) ~= "require" or tk_at(at + 1) ~= "(" or tk_at(at + 3) ~= ")" then return nil end
    return tk_at(at + 2):match("^[\"'](.*)[\"']$")
  end
  for at, token in ipairs(tokens) do
    local tk = token.tk
    local at_top = token.x == 1
    if tk == "local" then
      local kind = tk_at(at + 1)
      if kind == "function" then
        declare(tk_at(at + 2), at_top)
      elseif kind == "record" or kind == "enum" or kind == "interface" or kind == "type" then
        local name = tk_at(at + 2)
        if is_name(name) then
          local module = tk_at(at + 3) == "=" and required_at(at + 4) or nil
          if module ~= nil then
            aliases[name] = module
            declare(name, false)
          else
            declare(name, at_top)
          end
        end
      else
        local j = at + 1
        local bound: {string} = {}
        while is_name(tk_at(j)) do
          bound[#bound + 1] = tk_at(j)
          declare(tk_at(j), false)
          j = j + 1
          if tk_at(j) == "<" then j = j + 3 end
          if tk_at(j) ~= "," then break end
          j = j + 1
        end
        while tk_at(j) ~= "=" and tk_at(j) ~= "" and tokens[j].y == token.y do j = j + 1 end
        local module = #bound == 1 and tk_at(j) == "=" and required_at(j + 1) or nil
        if module ~= nil then aliases[bound[1]] = module end
      end
    elseif tk == "function" then
      local before = tk_at(at - 1)
      local j = at + 1
      if before == "local" then
        j = at + 2
      elseif is_name(tk_at(j)) then
        local path = tk_at(j)
        j = j + 1
        while (tk_at(j) == "." or tk_at(j) == ":") and is_name(tk_at(j + 1)) do
          path = path .. "." .. tk_at(j + 1)
          j = j + 2
        end
        local named_top = at_top or before == "global" and tokens[at - 1].x == 1
        declare(path, named_top)
        declare(path:match("([^.]+)$"), named_top)
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
            declare(each, false)
          end
          j = j + 1
        end
      end
    elseif tk == "for" then
      local j = at + 1
      while is_name(tk_at(j)) do
        declare(tk_at(j), false)
        if tk_at(j + 1) ~= "," then break end
        j = j + 2
      end
    end
  end
  local module_level: {string: boolean} = {}
  for name in pairs(top) do
    if not inner[name] then module_level[name] = true end
  end
  return { declared = { names = names, aliases = aliases }, module_level = module_level }
end

--- What the Teal source parsed to `root`, whose tokens are `tokens`,
--- declares, file-wide: the first step of resolution.
local function declared_in(root: ast.Node, tokens: {compiler.Token}): link_text.Declared
  return link_text.declarations({ node = root, tokens = tokens }).declared
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
  for _, link in ipairs(scan(text)) do
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
  local known: link_text.Declared | nil = nil
  local function declared(): link_text.Declared
    if known == nil then
      known = declared_in(root, tokens)
    end
    return known
  end
  for _, link in ipairs(link_text.in_blocks(link_text.blocks_of(comments))) do
    if link.form ~= "definition" then
      local own, alias = false, ""
      local named = link_text.name_of(link.target)
      if named ~= nil then
        local dotted = named:gsub(":", ".")
        own = declared().names[dotted] == true
        local first = dotted:match("^([%a_][%w_]*)%.")
        if first ~= nil then
          alias = declared().aliases[first] or ""
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
