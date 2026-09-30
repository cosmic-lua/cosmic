--- The files whose links `cosmic fix` checks beside Teal's -- Markdown,
--- Zig and, in cosmic's own tree, C -- and what their text says of
--- links: the comment blocks a link is read from and the names a file
--- declares, read off the text alone as [`build.link_text`] reads Teal's.
---
--- `cosmic fix` walks a tree for them by `skip` and `checked` and checks
--- each ([`build.links`]); the build's stage walks the same files and
--- keeps what `found` reads of each, keyed by its text's hash
--- ([`build.work`]), so the projection indexes their links as it does a
--- module's ([`build.link_index`]).

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local ast = require("build.ast")
local c_tokens = require("build.c_tokens")
local link_text = require("build.link_text")

local record link_files
end

--- The kind of file `path` is by its name, as far as links go:
--- "teal", "c", "zig" or "markdown"; nil for any other.
function link_files.kind_of(path: string): string | nil
  if String.ends_with(path, ".tl") or String.ends_with(path, ".lua") then return "teal" end
  if String.ends_with(path, ".c") or String.ends_with(path, ".h") then return "c" end
  if String.ends_with(path, ".zig") then return "zig" end
  if String.ends_with(path, ".md") then return "markdown" end
  return nil
end

--- What a walk for files whose links are checked passes over, `entry`
--- from the directory walked: the build's output, the upstream sources
--- and the records that patch them, the shell scripts under `bin/`, and
--- anything hidden but `.claude/`, whose skills are Markdown.
function link_files.skip(entry: string): boolean
  local first = entry:match("^([^/]+)") or entry
  if first == "o" or first == "vendor" or first == "patch" or first == "bin" then
    return true
  end
  if entry == ".claude" then
    return false
  end
  return Fs.basename(entry):sub(1, 1) == "."
end

--- Every file under `dir` a walk by [`link_files.skip`] finds, relative
--- to it and sorted.
function link_files.walk(dir: string): {string} | nil, string
  local files, trouble = Fs.walk(dir, link_files.skip)
  if files == nil then return nil, trouble end
  table.sort(files)
  return files
end

--- The kind of `file`, a path from the root of a tree `own` says is or
--- is not cosmic's, when its links are checked as a file's that is not
--- Teal: Markdown or Zig anywhere, and C in cosmic's own tree but in
--- `.claude/`. Nil for any other file.
function link_files.checked(file: string, own: boolean): string | nil
  local kind = link_files.kind_of(file)
  if kind == "markdown" or kind == "zig" then
    return kind
  end
  if kind == "c" and own and file:sub(1, 8) ~= ".claude/" then
    return kind
  end
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
--- `/* */` with each line's leading `*` taken off; and the byte of
--- `text` each line begins at. A line with no `*` is taken past the
--- whitespace that sets it under the first line's text, which starts
--- past `/*` at byte `column` of its line, so that its indent is read
--- against the first line's rather than the file's.
local function slash_comment(text: string, column: integer): {string}, {integer}
  if text:sub(1, 2) == "/*" then
    local body = text:sub(3):gsub("%*/$", "")
    local raw = split_lines(body)
    local out: {string} = { raw[1] }
    local starts: {integer} = { 3 }
    local at = 3
    for index = 2, #raw do
      at = at + #raw[index - 1] + 1
      local marker = raw[index]:match("^[ \t]*%*") or
        raw[index]:match("^" .. ("[ \t]?"):rep(column + 1)) or ""
      out[index] = raw[index]:sub(#marker + 1)
      starts[index] = at + #marker
    end
    return out, starts
  end
  local marker = text:match("^//[/!]?")
  return { text:sub(#marker + 1) }, { #marker + 1 }
end

--- `comment` placed in the file: each line's `starts` counted from the
--- byte of the file its text (`raw`, the comment as written) begins at.
local function placed(comment: link_text.Comment, raw_at: integer, at: {integer}): link_text.Comment
  local starts: {integer} = {}
  for index, offset in ipairs(at) do
    starts[index] = raw_at > 0 and raw_at + offset - 1 or 0
  end
  comment.starts = starts
  return comment
end

--- Every `//` comment of Zig source `source`, with its line: past a
--- string or character literal, and never in a multiline string's
--- line (what follows `\`).
local function zig_comments(source: string): {link_text.Comment}
  local out: {link_text.Comment} = {}
  local number = 0
  local line_start = 1
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    number = number + 1
    local this_start = line_start
    line_start = line_start + #line + 1
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
          local lines, at = slash_comment(line:sub(j), j)
          out[#out + 1] = placed({ line = number, lines = lines, doc = false }, this_start + j - 1, at)
        end
        break
      else
        j = j + 1
      end
    end
  end
  return out
end

--- The comment text of `source`, a Markdown, C or Zig file of `kind`
--- ([`link_files.kind_of`]), in blocks; a Markdown file is one block of
--- the whole.
function link_files.blocks(kind: string, source: string): {link_text.Block}
  if kind == "markdown" then
    return { { line = 1, text = source, starts = ast.line_starts(source) } }
  end
  local comments: {link_text.Comment} = {}
  if kind == "c" then
    local line_starts = ast.line_starts(source)
    for _, comment in ipairs(c_tokens.comments(source)) do
      local line_start = line_starts[comment.line] or 1
      local raw_at = source:find(comment.text, line_start, true) or 0
      local lines, at = slash_comment(comment.text, raw_at > 0 and raw_at - line_start + 1 or 1)
      comments[#comments + 1] = placed({ line = comment.line, lines = lines, doc = false }, raw_at, at)
    end
  elseif kind == "zig" then
    comments = zig_comments(source)
  end
  return link_text.blocks_of(comments)
end

--- What C source declares at file scope, read off its lines: each
--- function defined or declared (`name (`, as [`build.c.layout`] writes
--- one), each macro, and each struct, union, enum and typedef name.
-- TODO: resolve a C name through what the file includes too, and by
-- its declarations rather than its lines, once build.c.tree's
-- declarations can be had without compiling the file ([`c.check`]
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

--- The names Zig source declares at its top level (a `fn`, `const` or
--- `var` at the start of a line, `pub` or `export` before it) and not
--- also in a block.
local function module_level_zig(source: string): {string: boolean}
  local top: {string: boolean} = {}
  local inner: {string: boolean} = {}
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    for _, word in ipairs({ "fn", "const", "var" }) do
      local declared = line:match("^[%a ]-%f[%w_]" .. word .. "%s+([%a_][%w_]*)")
      if declared ~= nil then
        if line:match("^%s") ~= nil then inner[declared] = true else top[declared] = true end
      end
    end
  end
  local out: {string: boolean} = {}
  for name in pairs(top) do
    if not inner[name] then out[name] = true end
  end
  return out
end

--- What `source`, a Markdown, C or Zig file of `kind`, declares: the
--- first step of resolution. A Markdown file declares nothing. C is
--- read at file scope alone, so all it declares is its top level.
function link_files.declarations(kind: string, source: string): link_text.Declarations
  if kind == "c" then
    local declared = declared_c(source)
    return { declared = declared, module_level = declared.names }
  end
  if kind == "zig" then
    return { declared = declared_zig(source), module_level = module_level_zig(source) }
  end
  return { declared = { names = {}, aliases = {} }, module_level = {} }
end

--- The links of `source`, a Markdown, C or Zig file of `kind`, as the
--- build records a module's ([`link_text.found`]): every link but a
--- definition, whose target a reference link carries, each at the
--- column of its file its `[` is at. A name no file declares a first
--- part of is no alias here: only Teal requires a module.
function link_files.found(kind: string, source: string): {link_text.Found}
  local out: {link_text.Found} = {}
  if not link_text.may_link(source) then
    return out
  end
  local names: {string: boolean} | nil = nil
  local line_starts = ast.line_starts(source)
  for _, block in ipairs(link_files.blocks(kind, source)) do
    local starts = block.starts or {}
    for _, link in ipairs(link_text.parse(block.text)) do
      if link.form ~= "definition" then
        local line = block.line + link.line - 1
        -- A line of the block that is not one stretch of the file keeps
        -- the column of its text.
        local start = starts[link.line] or 0
        if start > 0 and line_starts[line] ~= nil then
          link.column = start - line_starts[line] + link.column
        end
        link.line = line
        local own = false
        local named = link_text.name_of(link.target)
        if named ~= nil then
          local declared = names or link_files.declarations(kind, source).declared.names
          names = declared
          own = declared[(named:gsub(":", "."))] == true
        end
        out[#out + 1] = { link = link, doc = false, own = own, alias = "" }
      end
    end
  end
  return out
end

return link_files
