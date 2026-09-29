--- Links in comments and Markdown, and whether each one resolves:
--- what `cosmic fix` holds Teal, C, Zig and Markdown to, in any
--- project. A link is what CommonMark would show as one; anything else
--- is prose, and never fails.
---
--- A link takes one of three forms, as Markdown and rustdoc write them:
---
--- - `` [`x`] ``, a shortcut, whose target is `x`;
--- - `[text][label]` (or `[text][]`, or `[label]` alone), whose target
---   a `[label]: target` line gives, in the same comment block (a run
---   of comments on consecutive lines) or, in Markdown, anywhere in the
---   file. A label may be a code span, and then `` [`x`] `` is this
---   form, not a shortcut;
--- - `[text](target)`, inline, whose target is a URL or a path: no
---   space (but inside `<>`), none of `+*^$[]{}|\()`, and a `%` only in
---   a `%XX` escape, with at most a quoted title after it.
---
--- Prose, never checked: a name in backticks alone (`` `x` ``); a
--- reference whose label nothing defines (`[i][j]`, `[%a_][%w_]*`), as
--- CommonMark shows it as written; brackets in any other shape
--- (`[options]`); a footnote (`[^1]`); a code span (which ends with its
--- paragraph), a fenced block, and a Teal long comment (`--[[ ]]`,
--- code set aside). A `[` right after a word, a `]`, a `)` or a `%`
--- opens an index or a pattern, never a link. A URL (`http://`,
--- `https://`, `mailto:`) is not checked.
---
--- A shortcut's target resolves, in order, to:
---
--- 1. a name the file itself declares: a local, a function, a
---    parameter, a record's field or member (`Rec.field`), an enum's
---    value; and `alias.member` where `local alias = require("m")`,
---    which is `m`'s member `member`; or a value of the Lua standard
---    library this program carries (`string.format`, `print`; not
---    `io`, `os` or `debug`, which cosmic leaves out);
--- 2. a symbol the project's databases know, by the rule `cosmic docs
---    <word>` answers an exact query with (`docs.exact`, a type's
---    member through an alias included), or a module's member written
---    in full (`cosmic.fs.read`);
--- 3. a file or directory of the tree, relative to the linking file's
---    directory and then to the project's root (a leading `/`: the root
---    alone), inside the root once links are followed and not under
---    the root's `o/` (the build's output). An `#anchor` must name a
---    Markdown file's heading, `#` or underlined, or an `<a id>` or
---    `<a name>`, as GitHub makes anchors; `#anchor` alone names the
---    linking file's own. A `?query` is left off and `%XX` read.
---
--- A name the file declares wins outright, so a local shadows a symbol
--- of the same name. Past that, a shortcut must match exactly one
--- symbol or file: one that matches two symbols, or a symbol and a
--- file, fails and lists what it matched, each spelled in full (a file
--- as `./path`), so the link can name the one it means. An inline
--- link's or a definition's target is a path first, as in Markdown: a
--- file it names wins, and only a target that names no file is a name.
---
--- Where the project has no database of its own yet
--- (`Context.unbuilt`), a shortcut that resolves to nothing is counted
--- rather than failed: its symbol may be one the build would record.
---
--- The parse is `build.link_text`'s and the resolution
--- `build.link_resolve`'s, which the build shares to index each link
--- (`build.link_index`); this module reads C, Zig and Markdown as well,
--- and answers symbols from the project's databases.

local String = require("cosmic.string")
local ast = require("build.ast")
local docs = require("build.docs")
local c_check = require("build.c")
local link_resolve = require("build.link_resolve")
local link_text = require("build.link_text")
local type compiler = require("build.compiler")

local record links
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

--- The lines of `body`, split at each line break.
local function split_lines(body: string): {string}
  local out: {string} = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
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
--- string or character literal, and never in a multiline string's
--- line (what follows `\\`).
local function zig_comments(source: string): {link_text.Comment}
  local out: {link_text.Comment} = {}
  local number = 0
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    local j = 1
    while j <= #line do
      local c = line:sub(j, j)
      if c == "\"" or c == "'" then
        j = j + 1
        while j <= #line and line:sub(j, j) ~= c do
          j = j + (line:sub(j, j) == "\\" and 2 or 1)
        end
        j = j + 1
      elseif line:sub(j, j + 1) == "\\\\" or line:sub(j, j + 1) == "//" then
        if line:sub(j, j + 1) == "//" then
          out[#out + 1] = { line = number, lines = slash_comment(line:sub(j)), doc = false }
        end
        break
      else
        j = j + 1
      end
    end
  end
  return out
end

--- The comment text of `source`, a file of `kind` (`kind_of`), in
--- blocks; a Markdown file is one block of the whole. Teal is lexed with
--- `built`, which `name` is given to.
local function comment_blocks(kind: string, source: string, built: compiler, name: string): {link_text.Block}
  if kind == "markdown" then
    return { { line = 1, text = source } }
  end
  local comments: {link_text.Comment} = {}
  if kind == "teal" then
    comments = link_text.teal_comments(built, source, name)
  elseif kind == "c" then
    for _, comment in ipairs(c_check.comments(source)) do
      comments[#comments + 1] = { line = comment.line, lines = slash_comment(comment.text), doc = false }
    end
  elseif kind == "zig" then
    comments = zig_comments(source)
  end
  return link_text.blocks_of(comments)
end

--- What C source declares at file scope, read off its lines: each
--- function defined or declared (`name (`, as `build.c.layout` writes
--- one), each macro, and each struct, union, enum and typedef name.
-- TODO: resolve a C name through what the file includes too, and by
-- its declarations rather than its lines, once build.c.tree's
-- declarations can be had without compiling the file (`c.check`
-- compiles only the checked files, and only in cosmic's own tree).
local function declared_c(source: string): link_text.Declared
  local out: link_text.Declared = { names = {}, aliases = {} }
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
local function declared_zig(source: string): link_text.Declared
  local out: link_text.Declared = { names = {}, aliases = {} }
  for _, word in ipairs({ "fn", "const", "var" }) do
    for declared in source:gmatch("%f[%w_]" .. word .. "%s+([%a_][%w_]*)") do
      out.names[declared] = true
    end
  end
  return out
end

--- What `source`, a file of `kind`, declares: the first step of
--- resolution. A Markdown file declares nothing, nor does Teal that
--- does not parse.
local function declarations(kind: string, source: string, built: compiler, name: string): link_text.Declared
  if kind == "teal" then
    local parsed, _ = ast.parse(built, source, name)
    if parsed == nil then
      return { names = {}, aliases = {} }
    end
    return link_text.declared(parsed.node)
  end
  if kind == "c" then return declared_c(source) end
  if kind == "zig" then return declared_zig(source) end
  return { names = {}, aliases = {} }
end

--- What is wrong with the links of `source`, a file of `kind` at the
--- absolute path `absolute`, each as `file:line: link: ...` with `file`
--- as it was named. Nothing when it holds no link, or every link
--- resolves to one thing.
function links.check(resolver: link_resolve.Resolver, file: string, absolute: string, kind: string,
                     source: string, built: compiler): {string}
  local out: {string} = {}
  if not link_text.may_link(source) then
    return out
  end
  if kind == "markdown" then
    link_resolve.holds(resolver, absolute, source)
  end
  local own: link_text.Declared | nil = nil
  local function declared(): link_text.Declared
    if own == nil then
      own = declarations(kind, source, built, file)
    end
    return own
  end
  for _, link in ipairs(link_text.in_blocks(comment_blocks(kind, source, built, file))) do
    -- A reference's target is checked where its definition is.
    if link.form ~= "reference" then
      local target, problem = link_resolve.resolve(resolver, absolute, link.target, declared,
        link.form ~= "shortcut")
      -- No problem named: a symbol not checked (\`Context.unbuilt\`).
      if target == nil and problem ~= "" then
        out[#out + 1] = file .. ":" .. link.line .. ": link: " .. link.target ..
          " does not resolve (" .. problem .. ")"
      end
    end
  end
  return out
end

--- The symbols of \`entries\`, once each.
local function symbols_of(entries: {docs.Entry}): {link_resolve.Symbol}
  local out: {link_resolve.Symbol} = {}
  local seen: {string: boolean} = {}
  for _, entry in ipairs(entries) do
    local symbol: link_resolve.Symbol = { module = entry.module, symbol = entry.symbol }
    local full = link_resolve.spelled(symbol)
    if not seen[full] then
      seen[full] = true
      out[#out + 1] = symbol
    end
  end
  return out
end

--- A context over the project at `root` as it is on disk, with symbols
--- from the view `open` gives, opened the first time a link asks for
--- one: a file with no link to a symbol reads no database. `unbuilt`
--- says why the view lacks the project's own code, or nil.
function links.context(root: string, open: function(): docs.View | nil, string,
                       unbuilt: function(): string | nil): link_resolve.Context
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
  local function symbols(query: string): {link_resolve.Symbol} | nil, string
    local ready_view, why = ready()
    if ready_view == nil then return nil, why end
    local found, found_trouble = docs.exact(ready_view, query)
    if found == nil then return nil, found_trouble end
    -- A module's member written in full: \`cosmic.fs.read\`.
    local at = 1
    while true do
      local dot = query:find(".", at, true)
      if dot == nil then break end
      local module = query:sub(1, dot - 1)
      if ready_view.owners[module] ~= nil then
        local members, member_trouble = docs.member(ready_view, module, query:sub(dot + 1))
        if members == nil then return nil, member_trouble end
        for _, entry in ipairs(members) do found[#found + 1] = entry end
      end
      at = dot + 1
    end
    return symbols_of(found), ""
  end
  local function member(module: string, name: string): {link_resolve.Symbol} | nil, string
    local ready_view, why = ready()
    if ready_view == nil then return nil, why end
    local found, found_trouble = docs.member(ready_view, module, name)
    if found == nil then return nil, found_trouble end
    return symbols_of(found), ""
  end
  return link_resolve.on_disk(root, symbols, member, unbuilt)
end

return links
