--- What `cosmic lsp` ([`build.lsp.session`]) shows of the symbol under the
--- cursor: its docs, from the binary's own and the project's last build,
--- as `cosmic docs` finds them. A name whose first part is a local bound
--- to a `require` is looked up in the module required: [`Fs.read`], with
--- `local Fs = require("cosmic.fs")`, is [`cosmic.fs.read`].
---
--- The project's build is the one the stage found ([`source.View`]'s
--- `where`), so a hover looks at none of the project's own paths.

local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local docs = require("build.docs")
local protocol = require("build.lsp.protocol")
local source = require("build.lsp.source")

local record hover
  --- The docs one session reads.
  record Docs
    root: string
    --- The databases docs are read from: [`Store.databases()`] when nil.
    store: {Sqlite.Handle} | nil
    --- Where complaints go, without their newline.
    err: function(line: string)
    --- The tree's view of the working database, whose stage found what
    --- the root is.
    tree: source.View
    --- The docs databases, once read.
    sources: docs.Sources | nil
    view: docs.View | nil
    --- Why the docs could not be read, once they were tried.
    view_trouble: string | nil
  end
end

local type Docs = hover.Docs

--- The docs of the tree `tree` holds, at `root`, read from `store` when
--- given.
function hover.new(root: string, tree: source.View, store: {Sqlite.Handle} | nil,
                   err: function(line: string)): Docs
  return { root = root, store = store, err = err, tree = tree, sources = nil, view = nil,
    view_trouble = nil }
end

--- The docs databases, opened once.
function hover.sources(d: Docs): docs.Sources
  local sources = d.sources
  if sources == nil then
    local where = d.tree.where
    local known: docs.Known | nil = nil
    if where ~= nil then known = { directory = where.directory, own_tree = where.own_tree } end
    sources = docs.databases(d.store or Store.databases(), d.root, known)
    d.sources = sources
  end
  return sources
end

--- The docs view, read once.
local function view_of(d: Docs): docs.View | nil
  if d.view ~= nil or d.view_trouble ~= nil then return d.view end
  local sources = hover.sources(d)
  local view, trouble = docs.view(sources.handles, sources.public)
  d.view = view
  d.view_trouble = trouble
  if view == nil then d.err("cosmic: lsp: no docs: " .. trouble) end
  return view
end

--- The dotted name under byte `x` of `line`, up to the end of the word
--- the cursor is in: [`Fs.read`] with the cursor anywhere in `Fs`'s `read`.
local function name_at(line: string, x: integer): string | nil
  local first = x
  while first > 1 do
    if line:sub(first - 1, first - 1):match("[%w_%.]") == nil then break end
    first = first - 1
  end
  local last = x
  while last <= #line do
    if line:sub(last, last):match("[%w_]") == nil then break end
    last = last + 1
  end
  local name = line:sub(first, last - 1):gsub("^%.+", "")
  if name:match("^[%a_]") == nil then return nil end
  return name
end

--- `name` with its first part read as the module a `require` in `text`
--- bound to it: [`Fs.read`] as [`cosmic.fs.read`]. Nil when no `require` did.
local function resolved(text: string, name: string): string | nil
  local head, rest = name:match("^([%a_][%w_]*)(.*)$")
  for alias, module in text:gmatch("local%s+([%a_][%w_]*)%s*=%s*require%s*%(?%s*[\"']([%w_%.]+)[\"']") do
    if alias == head then return module .. rest end
  end
  return nil
end

--- The hover of `text` at `where`, its character counted in
--- `encoding`'s units, or nil when nothing is documented there.
function hover.at(d: Docs, text: string, where: protocol.Position, encoding: string): protocol.Hover | nil
  local line = protocol.lines_of(text).texts[where.line + 1] or ""
  local name = name_at(line, protocol.byte_of(line, where.character, encoding))
  if name == nil then return nil end
  local view = view_of(d)
  if view == nil then return nil end
  local queries: {string} = {}
  local through = resolved(text, name)
  if through ~= nil then queries[#queries + 1] = through end
  queries[#queries + 1] = name
  for _, query in ipairs(queries) do
    local found, _ = docs.exact(view, query)
    local entry: docs.Entry | nil = nil
    if found ~= nil then entry = found[1] end
    if entry ~= nil then
      local title = entry.module
      if entry.symbol ~= "" then title = title .. "." .. entry.symbol end
      local parts: {string} = { "**" .. title .. "**" }
      if entry.signature ~= "" then
        parts[#parts + 1] = "```teal\n" .. entry.signature .. "\n```"
      end
      if entry.text ~= "" then parts[#parts + 1] = entry.text end
      return { contents = { kind = "markdown", value = table.concat(parts, "\n\n") } }
    end
  end
  return nil
end

--- Lets go of the databases the docs opened, which are opened again when
--- next read.
function hover.close(d: Docs)
  local sources = d.sources
  if sources ~= nil then
    for _, db in ipairs(sources.opened) do
      local _, _ = db:close()
    end
  end
  d.sources, d.view, d.view_trouble = nil, nil, nil
end

return hover
