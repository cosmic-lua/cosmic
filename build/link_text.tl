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
  --- line of the file it starts on.
  record Block
    line: integer
    text: string
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
  --- (`column`), counted from 1.
  record Comment
    line: integer
    lines: {string}
    doc: boolean
    column: integer
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
local function label_key(label: string): string
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
local function shortcut_target(inner: string): string | nil
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
--- line each is on; a pure function of the text. Fenced code blocks
--- are passed over, and so is every form but the three a link takes.
function link_text.parse(text: string): {link_text.Link}
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
      local key = label_key(label)
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
      local target = defined[label_key(label)]
      if target == nil then
        return nil
      end
      out[#out + 1] = { line = line, column = column, form = "reference", text = inner,
        target = target, label = label }
      return stop + 1
    end
    local found = defined[label_key(inner)]
    if found ~= nil then
      out[#out + 1] = { line = line, column = column, form = "reference", text = inner, target = found,
        label = inner }
      return close + 1
    end
    local target = shortcut_target(inner)
    if target ~= nil then
      out[#out + 1] = { line = line, column = column, form = "shortcut", text = inner, target = target }
      return close + 1
    end
    return nil
  end

  local at = 1
  while at <= #text do
    local c = text:sub(at, at)
    if definition_lines[line_of(at)] then
      local next_line = text:find("\n", at, true)
      at = next_line ~= nil and next_line + 1 or #text + 1
    elseif c == "\\" then
      at = at + 2
    elseif c == "`" then
      at = past_code_span(text, at)
    elseif c == "[" then
      at = link_at(at) or at + 1
    else
      at = at + 1
    end
  end
  table.sort(out, function(a: link_text.Link, b: link_text.Link): boolean
    return a.line < b.line or a.line == b.line and a.column < b.column
  end)
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
  local first, next_line = 0, -1
  local function flush()
    if #current > 0 then
      out[#out + 1] = { line = first, text = table.concat(current, "\n") }
    end
    current = {}
  end
  for _, comment in ipairs(comments) do
    local lines = comment.lines
    if #current > 0 and comment.line == next_line - 1 then
      -- A second comment on the line the one before it ended on.
      current[#current] = current[#current] .. " " .. lines[1]
      for index = 2, #lines do current[#current + 1] = lines[index] end
    else
      if comment.line ~= next_line then
        flush()
        first = comment.line
      end
      for _, line in ipairs(lines) do current[#current + 1] = line end
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

--- The line comments of Teal `source`, lexed with `built` (which
--- `name` is given to), in the order of their lines.
function link_text.teal_comments(built: compiler, source: string, name: string): {link_text.Comment}
  local comments: {link_text.Comment} = {}
  local tokens, _ = built.lex(source, name)
  for _, token in ipairs(tokens) do
    for _, comment in ipairs(token.comments or {}) do
      local lines = teal_comment(comment.text)
      if lines ~= nil then
        comments[#comments + 1] = { line = comment.y, lines = lines,
          doc = comment.text:match("^%-%-%-") ~= nil,
          column = comment.x + #comment.text - #lines[1] }
      end
    end
  end
  table.sort(comments, function(a: link_text.Comment, b: link_text.Comment): boolean
    return a.line < b.line
  end)
  return comments
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

--- A `record_function`'s owner spelled in full (`Thing`, `Thing.Box`).
local function owner_name(owner: ast.Node | nil): string
  if owner == nil then
    return ""
  end
  if owner.tk ~= nil then
    return owner.tk
  end
  local member = owner.e2
  if owner.kind == "op" and owner.op ~= nil and owner.op.op == "." and member ~= nil and
      member.tk ~= nil then
    return owner_name(owner.e1) .. "." .. member.tk
  end
  return ""
end

--- The module `node` requires when it is `require("<module>")`.
local function required(node: ast.Node | nil): string | nil
  if node == nil or node.kind ~= "op" then
    return nil
  end
  local op = node.op
  if op == nil or op.op ~= "@funcall" then
    return nil
  end
  local callee, args = node.e1, node.e2
  if callee == nil or callee.tk ~= "require" or args == nil or #args ~= 1 or
      args[1].kind ~= "string" then
    return nil
  end
  return args[1].conststr
end

--- What the Teal source parsed to `root` declares, file-wide.
-- TODO: resolve a name by the scope at the link's line rather than
-- file-wide, once build.analyzer exposes the names in scope at a line
-- (its `uses_of` and `references_of` walk the scopes, then drop them).
function link_text.declared(root: ast.Node): link_text.Declared
  local out: link_text.Declared = { names = {}, aliases = {} }
  local function add(declared: string | nil)
    if declared ~= nil and declared ~= "" then out.names[declared] = true end
  end
  local function declare_type(prefix: string, t: ast.TypeNode | nil, depth: integer)
    if t == nil or depth > 16 then return end
    local shape: ast.TypeNode = t.def or t
    local fields: {string: ast.TypeNode} = shape.fields or {}
    for field, field_type in pairs(fields) do
      add(prefix .. "." .. field)
      add(field)
      declare_type(prefix .. "." .. field, field_type, depth + 1)
    end
    local meta_fields: {string: ast.TypeNode} = shape.meta_fields or {}
    for field in pairs(meta_fields) do
      add(prefix .. "." .. field)
    end
    local values: {string: boolean} = shape.enumset or {}
    for value in pairs(values) do
      add(prefix .. "." .. value)
    end
  end
  local function arguments(n: ast.Node)
    for _, argument in ipairs(n.args or {}) do add(argument.tk) end
  end
  ast.walk(root, function(n: ast.Node)
    local kind = n.kind
    if kind == "local_declaration" then
      for index, var in ipairs(n.vars or {}) do
        add(var.tk)
        local exps = n.exps
        local module = required(exps ~= nil and exps[index] or nil)
        if module ~= nil and var.tk ~= nil then out.aliases[var.tk] = module end
      end
    elseif kind == "local_type" then
      local var = n.var
      if var ~= nil and var.tk ~= nil then
        add(var.tk)
        local value = n.value
        if value ~= nil and value.kind == "newtype" then
          declare_type(var.tk, value.newtype, 0)
        elseif required(value) ~= nil then
          out.aliases[var.tk] = required(value)
        end
      end
    elseif kind == "local_function" then
      add(n.name ~= nil and n.name.tk or nil)
      arguments(n)
    elseif kind == "record_function" or kind == "global_function" then
      local fn_name = n.name ~= nil and n.name.tk or nil
      add(fn_name)
      local owner = owner_name(n.fn_owner)
      if owner ~= "" and fn_name ~= nil then add(owner .. "." .. fn_name) end
      arguments(n)
    elseif kind == "function" then
      arguments(n)
    elseif kind == "forin" then
      for _, var in ipairs(n.vars or {}) do add(var.tk) end
    elseif kind == "fornum" then
      add(n.var ~= nil and n.var.tk or nil)
    end
  end)
  return out
end

--- What C source declares at file scope, read off its lines: each

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
  local comments = link_text.teal_comments(built, source, name)
  local doc: {integer: boolean} = {}
  local column: {integer: integer} = {}
  for _, comment in ipairs(comments) do
    doc[comment.line] = comment.doc
    column[comment.line] = comment.column
  end
  local known: link_text.Declared | nil = nil
  local function declared(): link_text.Declared
    if known == nil then
      known = link_text.declared(root)
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
