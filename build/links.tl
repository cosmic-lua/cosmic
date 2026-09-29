--- Links in comments and Markdown, and whether each one resolves:
--- what `cosmic fix` holds Teal, C, Zig and Markdown to, in any
--- project.
---
--- A link takes one of three forms, as Markdown and rustdoc write them:
---
--- - `` [`x`] ``, a shortcut, whose target is `x`;
--- - `[text][label]`, whose target a `[label]: target` line gives, in
---   the same comment block (a run of comments on consecutive lines) or,
---   in Markdown, anywhere in the file; `[label]` alone is one too when
---   such a line defines it;
--- - `[text](target)`, inline.
---
--- A name in backticks alone (`` `x` ``) is a literal and never a link.
--- So is anything else in brackets (`[options]`, `t[k]`, `%f[set]`), a
--- code span, a fenced block, and a long bracket (`--[[`). A `[` right
--- after a word, a `]`, a `)` or a `%` opens an index or a pattern,
--- never a link. A reference whose label nothing defines fails. A
--- target that is a URL (`http://`, `https://`, `mailto:`) is not
--- checked.
---
--- A target resolves, in order, to:
---
--- 1. a name the file itself declares: a local, a function, a
---    parameter, a record's field or member (`Rec.field`), an enum's
---    value; and `alias.member` where `local alias = require("m")`,
---    which is `m`'s member `member`;
--- 2. a symbol the project's databases know, by the rule `cosmic docs
---    <word>` answers an exact query with (`docs.exact`), or a module's
---    member written in full (`cosmic.fs.read`);
--- 3. a file or directory of the tree, relative to the linking file's
---    directory and then to the project's root, never under a
---    directory named `o` (the build's output), with an `#anchor` that
---    must name one of a Markdown file's headings (`#anchor` alone
---    names the linking file's own).
---
--- A name the file declares wins outright, so a local shadows a symbol
--- of the same name. Past that, a target must match exactly one symbol
--- or file: one that matches two symbols, or a symbol and a file, fails
--- and lists what it matched, each spelled in full, so the link can
--- name the one it means.

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local ast = require("build.ast")
local docs = require("build.docs")
local c_check = require("build.c")
local type compiler = require("build.compiler")

local record links
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
    --- Where it points; nil for a reference whose label nothing
    --- defines.
    target: string | nil
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

  --- What resolution reads beyond the file, so a test can hand it a
  --- world of its own.
  record Context
    --- The project's root, absolute.
    root: string
    --- "file" or "dir" for what is at the absolute `path`, or nil.
    kind: function(path: string): string | nil
    --- The text of the file at the absolute `path`, or nil.
    read: function(path: string): string | nil
    --- Each symbol `query` names (step 2), spelled in full: the
    --- module, then the symbol, joined by `.`. Nil and why when the
    --- databases cannot be read.
    symbols: function(query: string): {string} | nil, string
    --- The symbols of `module` whose name is `member`, spelled as
    --- `symbols` spells them.
    member: function(module: string, member: string): {string} | nil, string
  end

  --- Resolves links, remembering what it looked up.
  record Resolver
    context: Context
    kinds: {string: string}
    headings: {string: {string: boolean}}
    symbols: {string: {string}}
    members: {string: {string}}
    trouble: string | nil
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
local function without_fences(text: string): string
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
  while true do
    local s, e = text:find("`+", j)
    if s == nil then
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

--- Every link of `text` and every definition it holds, in order of the
--- line each is on; a pure function of the text. Fenced code blocks
--- are passed over, and so is every form but the three a link takes.
function links.parse(text: string): {links.Link}
  text = without_fences(text)
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

  local out: {links.Link} = {}
  local defined: {string: string} = {}
  local definition_lines: {integer: boolean} = {}
  for number, start in ipairs(starts) do
    local label, target = text:match("^[ \t]*%[([^%]\n]+)%]:[ \t]*(%S+)", start)
    if label ~= nil and target ~= nil then
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
    if close == nil then
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
      raw = String.trim(raw)
      local target = raw:match("^<([^>]*)>") or raw:match("^%S+")
      if target == nil or target == "" then
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
      out[#out + 1] = { line = line, column = column, form = "reference", text = inner,
        target = defined[label_key(label)], label = label }
      return stop + 1
    end
    local target = shortcut_target(inner)
    if target ~= nil then
      out[#out + 1] = { line = line, column = column, form = "shortcut", text = inner, target = target }
      return close + 1
    end
    local found = defined[label_key(inner)]
    if found ~= nil then
      out[#out + 1] = { line = line, column = column, form = "reference", text = inner, target = found,
        label = inner }
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
  table.sort(out, function(a: links.Link, b: links.Link): boolean
    return a.line < b.line or a.line == b.line and a.column < b.column
  end)
  return out
end

--- The kind of file `path` is by its name, as far as links go:
--- "teal", "c", "zig" or "markdown"; nil for any other.
function links.kind_of(path: string): string | nil
  if String.ends_with(path, ".tl") or String.ends_with(path, ".lua") then return "teal" end
  if String.ends_with(path, ".c") or String.ends_with(path, ".h") then return "c" end
  if String.ends_with(path, ".zig") then return "zig" end
  if String.ends_with(path, ".md") then return "markdown" end
  return nil
end

--- One comment's lines with its markers taken off.
local record Stripped
  line: integer
  lines: {string}
end

--- The lines of `body`, split at each line break.
local function split_lines(body: string): {string}
  local out: {string} = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

--- A Teal or Lua comment's lines: after `--` (and any more dashes), or
--- inside a long comment's brackets.
local function teal_comment(text: string): {string}
  local level = text:match("^%-%-%[(=*)%[")
  if level ~= nil then
    local body = text:sub(#level + 5)
    local close = "]" .. level .. "]"
    if body:sub(-#close) == close then
      body = body:sub(1, -#close - 1)
    end
    return split_lines(body)
  end
  return { (text:gsub("^%-%-+", "")) }
end

--- A C or Zig comment's lines: after `//` (and `/` or `!`), or inside
--- `/* */` with each line's leading `*` taken off.
local function slash_comment(text: string): {string}
  if text:sub(1, 2) == "/*" then
    local body = text:sub(3):gsub("%*/$", "")
    local out = split_lines(body)
    for index = 2, #out do
      out[index] = out[index]:gsub("^[ \t]*%*", "", 1)
    end
    return out
  end
  return { (text:gsub("^//[/!]?", "")) }
end

--- Every `//` comment of Zig source `source`, with its line: past a
--- string or character literal, and not in a multiline string (`\\`).
local function zig_comments(source: string): {Stripped}
  local out: {Stripped} = {}
  local number = 0
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    if line:match("^%s*\\\\") == nil then
      local j = 1
      while j <= #line do
        local c = line:sub(j, j)
        if c == "\"" or c == "'" then
          j = j + 1
          while j <= #line and line:sub(j, j) ~= c do
            j = j + (line:sub(j, j) == "\\" and 2 or 1)
          end
          j = j + 1
        elseif line:sub(j, j + 1) == "//" then
          out[#out + 1] = { line = number, lines = slash_comment(line:sub(j)) }
          break
        else
          j = j + 1
        end
      end
    end
  end
  return out
end

--- Comments on consecutive lines, joined into blocks: a definition
--- holds for the block it is in.
local function blocks_of(comments: {Stripped}): {links.Block}
  local out: {links.Block} = {}
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

--- The comment text of `source`, a file of `kind` (`kind_of`), in
--- blocks; a Markdown file is one block of the whole. Teal is lexed with
--- `built`, which `name` is given to.
local function comment_blocks(kind: string, source: string, built: compiler, name: string): {links.Block}
  if kind == "markdown" then
    return { { line = 1, text = source } }
  end
  local comments: {Stripped} = {}
  if kind == "teal" then
    local tokens, _ = built.lex(source, name)
    for _, token in ipairs(tokens) do
      for _, comment in ipairs(token.comments or {}) do
        comments[#comments + 1] = { line = comment.y, lines = teal_comment(comment.text) }
      end
    end
    table.sort(comments, function(a: Stripped, b: Stripped): boolean return a.line < b.line end)
  elseif kind == "c" then
    for _, comment in ipairs(c_check.comments(source)) do
      comments[#comments + 1] = { line = comment.line, lines = slash_comment(comment.text) }
    end
  elseif kind == "zig" then
    comments = zig_comments(source)
  end
  return blocks_of(comments)
end

--- Every link and definition in `source`, a file of `kind`, each on
--- the line of the file it is on.
local function links_of(kind: string, source: string, built: compiler, name: string): {links.Link}
  local out: {links.Link} = {}
  for _, block in ipairs(comment_blocks(kind, source, built, name)) do
    for _, link in ipairs(links.parse(block.text)) do
      link.line = link.line + block.line - 1
      out[#out + 1] = link
    end
  end
  return out
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

--- What Teal source declares, file-wide.
-- TODO: resolve a name by the scope at the link's line rather than
-- file-wide, once build.analyzer exposes the names in scope at a line
-- (its `uses_of` and `references_of` walk the scopes, then drop them).
local function declared_teal(built: compiler, source: string, name: string): links.Declared
  local out: links.Declared = { names = {}, aliases = {} }
  local parsed, _ = ast.parse(built, source, name)
  if parsed == nil then
    return out
  end
  local root: ast.Node = parsed.node
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
--- function defined or declared (`name (`, as `build.c.layout` writes
--- one), each macro, and each struct, union, enum and typedef name.
-- TODO: resolve a C name through what the file includes too, and by
-- its declarations rather than its lines, once build.c.tree's
-- declarations can be had without compiling the file (`c.check`
-- compiles only the checked files, and only in cosmic's own tree).
local function declared_c(source: string): links.Declared
  local out: links.Declared = { names = {}, aliases = {} }
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    local fn_name = line:match("^[%a_][%w_ %*]-([%a_][%w_]*) %(")
    if fn_name ~= nil then out.names[fn_name] = true end
    local macro = line:match("^%s*#%s*define%s+([%a_][%w_]*)")
    if macro ~= nil then out.names[macro] = true end
    for tag in line:gmatch("%f[%w_]struct%s+([%a_][%w_]*)") do out.names[tag] = true end
    for tag in line:gmatch("%f[%w_]union%s+([%a_][%w_]*)") do out.names[tag] = true end
    for tag in line:gmatch("%f[%w_]enum%s+([%a_][%w_]*)") do out.names[tag] = true end
    local typedef = line:match("^typedef%s.-([%a_][%w_]*)%s*;") or
      line:match("^}%s*([%a_][%w_]*)%s*;")
    if typedef ~= nil then out.names[typedef] = true end
  end
  return out
end

--- What Zig source declares, read off its lines: each `fn`, `const`
--- and `var`, at any depth.
local function declared_zig(source: string): links.Declared
  local out: links.Declared = { names = {}, aliases = {} }
  for _, word in ipairs({ "fn", "const", "var" }) do
    for declared in source:gmatch("%f[%w_]" .. word .. "%s+([%a_][%w_]*)") do
      out.names[declared] = true
    end
  end
  return out
end

--- What `source`, a file of `kind`, declares: the first step of
--- resolution. A Markdown file declares nothing.
local function declarations(kind: string, source: string, built: compiler, name: string): links.Declared
  if kind == "teal" then return declared_teal(built, source, name) end
  if kind == "c" then return declared_c(source) end
  if kind == "zig" then return declared_zig(source) end
  return { names = {}, aliases = {} }
end

--- A resolver over `context`.
function links.resolver(context: links.Context): links.Resolver
  return { context = context, kinds = {}, headings = {}, symbols = {}, members = {} }
end

--- What `resolver`'s context says is at `path`, asked once.
local function kind_at(resolver: links.Resolver, path: string): string | nil
  local cached = resolver.kinds[path]
  if cached == nil then
    cached = resolver.context.kind(path) or ""
    resolver.kinds[path] = cached
  end
  return cached ~= "" and cached or nil
end

--- A heading's anchor as GitHub makes it: lowercased, its punctuation
--- but `-` and `_` dropped, each space a `-`.
local function slug_of(heading: string): string
  local text = heading:gsub("%[([^%]]*)%]%b()", "%1")
  local out: {string} = {}
  for at = 1, #text do
    local c = text:sub(at, at)
    if c:byte() >= 128 or c:match("[%w_%-]") ~= nil then
      out[#out + 1] = c:lower()
    elseif c == " " then
      out[#out + 1] = "-"
    end
  end
  return table.concat(out)
end

--- Every anchor the headings of Markdown `text` give, GitHub's way: a
--- repeated heading's anchor takes `-1`, `-2` and so on.
local function anchors(text: string): {string: boolean}
  local out: {string: boolean} = {}
  local count: {string: integer} = {}
  for line in (without_fences(text) .. "\n"):gmatch("([^\n]*)\n") do
    local heading = line:match("^ ? ? ?#+%s+(.-)%s*$")
    if heading ~= nil then
      heading = heading:gsub("%s+#+$", "")
      local slug = slug_of(heading)
      local seen = count[slug]
      if seen == nil then
        count[slug] = 0
        out[slug] = true
      else
        count[slug] = seen + 1
        out[slug .. "-" .. (seen + 1)] = true
      end
    end
  end
  return out
end

--- Why `anchor` names nothing in the file at `path`, or nil when it
--- names a heading of it. A file other than Markdown takes only a line
--- anchor (`L12`, `L12-L20`).
local function anchor_problem(resolver: links.Resolver, path: string, anchor: string): string | nil
  if not String.ends_with(path, ".md") then
    if anchor:match("^L%d+$") ~= nil or anchor:match("^L%d+%-L%d+$") ~= nil then
      return nil
    end
    return "only a Markdown file's headings take an anchor"
  end
  local found = resolver.headings[path]
  if found == nil then
    local text = resolver.context.read(path)
    found = text ~= nil and anchors(text) or {}
    resolver.headings[path] = found
  end
  if found[anchor:lower()] then
    return nil
  end
  return "no heading of " .. Fs.basename(path) .. " has the anchor #" .. anchor
end

--- `path` with each `.` and `..` taken out, or nil when it climbs past
--- the top.
local function normalized(path: string): string | nil
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts == 0 then return nil end
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- The file or directory the path `target` names from the file at
--- `from`: relative to its directory, then to the root (and a path
--- that starts with `/` to the root alone). Nil and why when there is
--- none, or only one under a directory named `o`, or outside the root.
local function located(resolver: links.Resolver, from: string, target: string): string | nil, string
  local root = resolver.context.root
  local bases: {string} = { root }
  if target:sub(1, 1) ~= "/" then
    table.insert(bases, 1, Fs.dirname(from))
  end
  local why = "no declaration, symbol or file by that name"
  for _, base in ipairs(bases) do
    local path = normalized(base .. "/" .. target)
    if path ~= nil and kind_at(resolver, path) ~= nil then
      local inside = path == root or path:sub(1, #root + 1) == root .. "/"
      local relative = inside and path:sub(#root + 2) or ""
      if not inside then
        why = "it is outside the project"
      elseif ("/" .. relative .. "/"):find("/o/", 1, true) ~= nil then
        why = "it is under o/, the build's output"
      else
        return path, ""
      end
    end
  end
  return nil, why
end

--- `path` as the project's root sees it.
local function shown(resolver: links.Resolver, path: string): string
  local root = resolver.context.root
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

--- The symbols the context names `query` by, asked once.
local function symbols_named(resolver: links.Resolver, query: string): {string}
  local cached = resolver.symbols[query]
  if cached == nil then
    local found, trouble = resolver.context.symbols(query)
    if found == nil then
      resolver.trouble = trouble
      found = {}
    end
    cached = found
    resolver.symbols[query] = cached
  end
  return cached
end

--- The members of `module` named `member`, asked once.
local function members_named(resolver: links.Resolver, module: string, member: string): {string}
  local key = module .. "\n" .. member
  local cached = resolver.members[key]
  if cached == nil then
    local found, trouble = resolver.context.member(module, member)
    if found == nil then
      resolver.trouble = trouble
      found = {}
    end
    cached = found
    resolver.members[key] = cached
  end
  return cached
end

--- Why `found` is not one answer: none, or more than one.
local function one_of(found: {string}, none: string): string | nil
  if #found == 1 then
    return nil
  end
  if #found == 0 then
    return none
  end
  table.sort(found)
  return "it names " .. #found .. ": " .. table.concat(found, ", ", 1, math.min(#found, 5)) ..
    (#found > 5 and ", ..." or "") .. "; link the one meant in full"
end

--- Why `target`, linked from the file at the absolute path `from`,
--- resolves to nothing or to more than one thing; nil when it resolves
--- to one. `declared` gives what that file declares, asked only when
--- the target could be a name.
local function problem_of(resolver: links.Resolver, from: string, target: string,
                       declared: function(): links.Declared): string | nil
  if target:match("^https?://") ~= nil or target:match("^mailto:") ~= nil then
    return nil
  end
  local path, anchor = target:match("^([^#]*)#(.*)$")
  if path == nil then
    path = target
  end
  if path == "" then
    if anchor == nil or anchor == "" then
      return "it is empty"
    end
    return anchor_problem(resolver, from, anchor)
  end
  local found: {string} = {}
  local name = path:gsub("%(%)$", "")
  if anchor == nil and name:match("^[%a_][%w_]*$") ~= nil or
      anchor == nil and name:match("^[%a_][%w_]*[%.:][%a_][%w_%.:]*$") ~= nil then
    local dotted = name:gsub(":", ".")
    local own = declared()
    if own.names[dotted] then
      return nil
    end
    local first, rest = dotted:match("^([%a_][%w_]*)%.(.+)$")
    if first ~= nil and own.aliases[first] ~= nil then
      local module = own.aliases[first]
      return one_of(members_named(resolver, module, rest), module .. " has no " .. rest)
    end
    for _, symbol in ipairs(symbols_named(resolver, name)) do
      found[#found + 1] = symbol
    end
  end
  local file, why = located(resolver, from, path)
  if file ~= nil then
    found[#found + 1] = "the file " .. shown(resolver, file)
  end
  local problem = one_of(found, why)
  if problem ~= nil then
    return problem
  end
  if file ~= nil and #found == 1 and anchor ~= nil and anchor ~= "" then
    if kind_at(resolver, file) ~= "file" then
      return "a directory has no headings"
    end
    return anchor_problem(resolver, file, anchor)
  end
  return nil
end

--- What is wrong with the links of `source`, a file of `kind` at the
--- absolute path `absolute`, each as `file:line: link: ...` with `file`
--- as it was named. Nothing when it holds no link, or every link
--- resolves to one thing.
function links.check(resolver: links.Resolver, file: string, absolute: string, kind: string,
                     source: string, built: compiler): {string}
  local out: {string} = {}
  -- No link can be written without one of these.
  if source:find("[", 1, true) == nil or (source:find("`]", 1, true) == nil and
      source:find("](", 1, true) == nil and source:find("][", 1, true) == nil and
      source:find("]:", 1, true) == nil) then
    return out
  end
  if kind == "markdown" then
    resolver.headings[absolute] = anchors(source)
  end
  local own: links.Declared | nil = nil
  local function declared(): links.Declared
    if own == nil then
      own = declarations(kind, source, built, file)
    end
    return own
  end
  for _, link in ipairs(links_of(kind, source, built, file)) do
    local where = file .. ":" .. link.line .. ": link: "
    local target = link.target
    if target == nil then
      out[#out + 1] = where .. "[" .. tostring(link.label) ..
        "] does not resolve (no [" .. tostring(link.label) .. "]: line defines it" ..
        (kind == "markdown" and "" or " in its comment block") .. ")"
    elseif link.form ~= "reference" then
      local problem = problem_of(resolver, absolute, target, declared)
      if problem ~= nil then
        out[#out + 1] = where .. target .. " does not resolve (" .. problem .. ")"
      end
    end
  end
  return out
end

--- The symbols of `entries`, each spelled in full, once each.
local function spelled(entries: {docs.Entry}): {string}
  local out: {string} = {}
  local seen: {string: boolean} = {}
  for _, entry in ipairs(entries) do
    local symbol = entry.symbol:gsub(":", ".")
    local full = symbol ~= "" and entry.module .. "." .. symbol or entry.module
    if not seen[full] then
      seen[full] = true
      out[#out + 1] = full
    end
  end
  return out
end

--- A context over the project at `root` as it is on disk, with symbols
--- from the view `open` gives, opened the first time a link asks for
--- one: a file with no link to a symbol reads no database.
function links.context(root: string, open: function(): docs.View | nil, string): links.Context
  local view: docs.View | nil = nil
  local trouble: string | nil = nil
  local function ready(): docs.View | nil, string
    if view ~= nil then return view, "" end
    if trouble ~= nil then return nil, trouble end
    local opened, why = open()
    if opened == nil then
      trouble = why
      return nil, why
    end
    view = opened
    return opened, ""
  end
  local context: links.Context = {
    root = root,
    kind = function(path: string): string | nil
      local st, _ = Fs.stat(path)
      if st == nil then return nil end
      return st.kind == "dir" and "dir" or "file"
    end,
    read = function(path: string): string | nil
      local text, _ = Fs.read(path)
      return text
    end,
    symbols = function(query: string): {string} | nil, string
      local ready_view, why = ready()
      if ready_view == nil then return nil, why end
      local found, found_trouble = docs.exact(ready_view, query)
      if found == nil then return nil, found_trouble end
      local out = spelled(found)
      -- A module's member written in full: `cosmic.fs.read`.
      local at = 1
      while true do
        local dot = query:find(".", at, true)
        if dot == nil then break end
        local module = query:sub(1, dot - 1)
        if ready_view.owners[module] ~= nil then
          local members, member_trouble = docs.member(ready_view, module, query:sub(dot + 1))
          if members == nil then return nil, member_trouble end
          for _, full in ipairs(spelled(members)) do
            local known = false
            for _, have in ipairs(out) do
              if have == full then known = true end
            end
            if not known then out[#out + 1] = full end
          end
        end
        at = dot + 1
      end
      return out, ""
    end,
    member = function(module: string, member: string): {string} | nil, string
      local ready_view, why = ready()
      if ready_view == nil then return nil, why end
      local found, found_trouble = docs.member(ready_view, module, member)
      if found == nil then return nil, found_trouble end
      return spelled(found), ""
    end,
  }
  return context
end

return links
