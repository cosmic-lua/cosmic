--- The links of a projection's modules, each resolved to what it names
--- and written to its `links` table ([the schema](schema.tl)) as the
--- projection is written (`build.writer`).
---
--- A parse records each link as written ([`link_text.found`]), keyed by
--- its source's hash like every other row a parse keeps. What a link
--- names cannot be known then: a symbol of another module is known
--- only once every module is parsed, and a parse sees one source. So
--- the link is resolved here, as the projection is written, by the rule
--- `cosmic fix` checks it by ([`link_resolve.resolve`]), against the
--- projection being written rather than a database the last build left:
--- its `docs` rows, which the plan's keys already sign, and the files
--- of the tree on disk, which nothing else in the projection reads.
---
--- So what the files said is part of the projection's signature
--- (`Pending.digest`): each link is resolved first with no symbols at
--- all, which asks after every file and heading any resolution of it
--- can, and each answer is kept. A link that also names a symbol fails
--- or stops before it reads more, so the resolution that writes the
--- rows reads only answers already kept. A file that appears, goes or
--- changes its headings moves the digest, and the next build writes the
--- projection again, rather than keeping a row about a file that is not
--- there.
---
--- A project's links are resolved against its own projection alone:
--- one to the standard library, which only the binary's database knows,
--- is not kept.
-- TODO: keep a project's links to the standard library too, once the
-- projection's signature holds the binary's docs it would resolve them
-- against (a stale tool's are not the ones a boot's would be).
-- TODO: index the links of Markdown, C and Zig files too, as `cosmic
-- fix` checks them: no parse keeps them, since none is a module. Read
-- them here, each file's text in `Pending.digest`, once the stage
-- walks every file `fix --check .` does (it leaves out doc/ but its
-- guides); their rows have no `from_module`, so `build.docs` would
-- answer them by the database rather than by the module's owner.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")
local link_resolve = require("build.link_resolve")
local link_text = require("build.link_text")
local symbol_index = require("build.symbol_index")

local record link_index
  --- One link as a parse recorded it, with the module and file it is in.
  record Raw
    from_module: string
    from_file: string
    line: integer
    column: integer
    form: string
    doc: boolean
    text: string
    target: string
    own: boolean
    alias: string
  end

  --- What the disk answered, by absolute path: a kind as
  --- `Context.kind` answers it (`""` for nothing there), and a text or
  --- a real path, each in a table of its own so that none is kept as an
  --- answer too.
  record Memo
    kinds: {string: string}
    reads: {string: {string}}
    reals: {string: {string}}
  end

  --- One row of the projection's `links` (`build.schema`).
  record Row
    module: string
    symbol: string
    path: string
    anchor: string
    from_file: string
    line: integer
    column: integer
    from_module: string
    kind: string
    form: string
    source: string
    text: string
  end

  --- A projection's links, read and their files looked up, waiting for
  --- its symbols.
  record Pending
    root: string
    rows: {Raw}
    memo: Memo
    --- A hash of every answer in `memo`, from the root down: what
    --- the rows are a function of beside the projection's own.
    digest: string
  end
end

local text = bind.text

--- Every link the parse recorded in a planned module or a declaration
--- -- the sources whose docs a projection holds (`build.writer`'s
--- `insert_docs`), each under the module its docs name -- in file and
--- line order. A source under o/, the build's output (the compiler a
--- boot puts in), is the tree's by no link.
local raw_links =
  "SELECT m.path, i.file, l.line, l.column, l.form, l.doc, l.text, l.target, l.own, l.alias " ..
  "FROM (SELECT path FROM plan UNION SELECT path FROM inputs WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path AND i.file NOT GLOB 'o/*' " ..
  "JOIN links l ON l.source_hash = i.source_hash ORDER BY i.file, l.line, l.column"

--- A context over the tree at `root` on disk that keeps each answer in
--- `memo`, and gives one already kept without asking again; its
--- symbols are `symbols` and `member`'s.
local function remembering(root: string, memo: link_index.Memo,
                           symbols_of: function(string): {link_resolve.Symbol} | nil, string,
                           member_of: function(string, string): {link_resolve.Symbol} | nil, string):
                           link_resolve.Context
  local disk = link_resolve.on_disk(root, symbols_of, member_of,
    function(): string | nil return nil end)
  local context: link_resolve.Context = {
    root = root,
    kind = function(path: string): string | nil
      if memo.kinds[path] == nil then
        memo.kinds[path] = disk.kind(path) or ""
      end
      local kind = memo.kinds[path]
      return kind ~= "" and kind or nil
    end,
    read = function(path: string): string | nil
      if memo.reads[path] == nil then
        memo.reads[path] = { disk.read(path) }
      end
      return memo.reads[path][1]
    end,
    real = function(path: string): string | nil
      if memo.reals[path] == nil then
        memo.reals[path] = { disk.real(path) }
      end
      return memo.reals[path][1]
    end,
    unbuilt = disk.unbuilt,
    symbols = symbols_of,
    member = member_of,
  }
  return context
end

--- Nothing, for a name whose declaration in its file the parse did not
--- record: a reference's label.
local function nothing_declared(): link_text.Declared
  return { names = {}, aliases = {} }
end

--- What the file a link is in declares, as far as its target goes: the
--- name, when the file declares it, and the alias its first part is.
local function declared_for(raw: link_index.Raw): function(): link_text.Declared
  return function(): link_text.Declared
    local out: link_text.Declared = { names = {}, aliases = {} }
    local name = link_text.name_of(raw.target)
    if name ~= nil then
      local dotted = name:gsub(":", ".")
      if raw.own then
        out.names[dotted] = true
      end
      local first = dotted:match("^([%a_][%w_]*)%.")
      if first ~= nil and raw.alias ~= "" then
        out.aliases[first] = raw.alias
      end
    end
    return out
  end
end

--- The name a reference's code-span label gives (`` [`x`] `` with a
--- definition of `` `x` ``), which decides what it names as a
--- shortcut's would; nil for any other link.
local function label_of(raw: link_index.Raw): string | nil
  if raw.form ~= "reference" or raw.target:match("^%a[%w+.-]*:") ~= nil then
    return nil
  end
  return link_text.shortcut_target(raw.text)
end

--- `memo`'s answers as one hash, each path from `root`, so the same
--- tree gives the same digest wherever it is checked out.
local function digest_of(root: string, memo: link_index.Memo): string
  local function from_root(path: string): string
    if path == root then return "." end
    if path:sub(1, #root + 1) == root .. "/" then return path:sub(#root + 2) end
    return path
  end
  local real_root = memo.reals[root] ~= nil and memo.reals[root][1] or root
  local lines: {string} = {}
  for path, kind in pairs(memo.kinds) do
    lines[#lines + 1] = "kind " .. from_root(path) .. " " .. kind
  end
  for path, answer in pairs(memo.reals) do
    local real = answer[1]
    -- Only whether a path stays inside the root decides a link.
    local inside = real ~= nil and (real == real_root or real:sub(1, #real_root + 1) == real_root .. "/")
    lines[#lines + 1] = "real " .. from_root(path) .. " " .. (inside and "in" or "out")
  end
  for path, answer in pairs(memo.reads) do
    local read = answer[1]
    lines[#lines + 1] = "read " .. from_root(path) .. " " .. (read ~= nil and Hash.hex_sha256(read) or "-")
  end
  table.sort(lines)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- The links the parse recorded in `db`'s planned modules, resolved
--- as far as the tree at `root` goes, with a digest of what it said.
function link_index.pending(db: Sqlite.Handle, root: string): link_index.Pending | nil, string
  local absolute, _ = Fs.absolute(root)
  root = absolute or root
  local found, trouble = Sqlite.text_rows(db, raw_links)
  if found == nil then
    return nil, trouble
  end
  local rows: {link_index.Raw} = {}
  for _, row in ipairs(found) do
    rows[#rows + 1] = {
      from_module = row[1], from_file = row[2],
      line = math.tointeger(tonumber(row[3])) or 0, column = math.tointeger(tonumber(row[4])) or 0,
      form = row[5], doc = row[6] == "1", text = row[7], target = row[8],
      own = row[9] == "1", alias = row[10],
    }
  end
  local memo: link_index.Memo = { kinds = {}, reads = {}, reals = {} }
  -- No symbol is known yet: every name reads as naming none.
  local unknown = "no symbols until the projection's docs are in"
  local function none(_: string): {link_resolve.Symbol} | nil, string return nil, unknown end
  local function no_member(_: string, _: string): {link_resolve.Symbol} | nil, string
    return nil, unknown
  end
  local resolver = link_resolve.resolver(remembering(root, memo, none, no_member))
  for _, raw in ipairs(rows) do
    local from = root .. "/" .. raw.from_file
    local _, _ = link_resolve.resolve(resolver, from, raw.target, declared_for(raw), raw.form ~= "shortcut")
    local label = label_of(raw)
    if label ~= nil then
      local _, _ = link_resolve.resolve(resolver, from, label, nothing_declared, false)
    end
  end
  return { root = root, rows = rows, memo = memo, digest = digest_of(root, memo) }
end

--- The `docs` of the projection under `qualifier`, held in memory.
local function index_of(db: Sqlite.Handle, qualifier: string): symbol_index.Index | nil, string
  local out = symbol_index.new()
  local modules, modules_trouble = Sqlite.text_rows(db,
    "SELECT path FROM " .. qualifier .. "modules UNION SELECT path FROM " .. qualifier .. "decls")
  if modules == nil then
    return nil, modules_trouble
  end
  for _, row in ipairs(modules) do symbol_index.module(out, row[1]) end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT module, symbol, source_symbol, file FROM " .. qualifier .. "docs " ..
    "ORDER BY module, exported DESC, id")
  if rows == nil then
    return nil, trouble
  end
  for _, row in ipairs(rows) do
    symbol_index.add(out, row[1], row[2], row[3], row[4])
  end
  return out, ""
end

--- Resolves `pending`'s links against the `docs` of the projection
--- under `qualifier` (`"out."`) and writes those that name one thing to
--- its `links`, in key order.
function link_index.fill(db: Sqlite.Handle, pending: link_index.Pending,
                         qualifier: string): boolean, string
  local indexed, index_trouble = index_of(db, qualifier)
  if indexed == nil then
    return false, index_trouble
  end
  local index: symbol_index.Index = indexed
  local function member_of(module: string, name: string): {link_resolve.Symbol} | nil, string
    return symbol_index.member(index, module, name), ""
  end
  -- TODO: resolve a member of a type an alias stands for
  -- (`Sqlite.Handle.close`), as `docs.exact` does through
  -- `through_alias`, once that lookup is split from build.docs, which
  -- build.writer cannot require (build.docs requires build.rebuild,
  -- which requires build.writer).
  local function symbols_of(query: string): {link_resolve.Symbol} | nil, string
    return symbol_index.named(index, query), ""
  end
  local root = pending.root
  local resolver = link_resolve.resolver(remembering(root, pending.memo, symbols_of, member_of))
  local rows: {link_index.Row} = {}
  for _, raw in ipairs(pending.rows) do
    local from = root .. "/" .. raw.from_file
    local target, _ = link_resolve.resolve(resolver, from, raw.target, declared_for(raw),
      raw.form ~= "shortcut")
    -- A code-span label names its symbol when the definition names the
    -- file that declares it, as `build.links` checks.
    local label = label_of(raw)
    if label ~= nil and target ~= nil and target.kind == "file" then
      local named, _ = link_resolve.resolve(resolver, from, label, nothing_declared, false)
      if named ~= nil and named.kind == "symbol" and named.file == target.path then
        target = named
      end
    end
    if target ~= nil then
      local kind, module, symbol = target.kind, target.module, target.symbol
      if kind == "declared" then
        -- A name the file declares is a symbol of its own module when
        -- that module documents it (a parameter or a block's local is not).
        local own, trouble = member_of(raw.from_module, target.name)
        if own == nil then
          return false, trouble
        end
        if #own == 1 then
          kind, module, symbol = "symbol", own[1].module, own[1].symbol
        end
      end
      if kind == "symbol" or kind == "file" or kind == "anchor" then
        rows[#rows + 1] = {
          module = module, symbol = symbol, path = target.path, anchor = target.anchor,
          from_file = raw.from_file, line = raw.line, column = raw.column,
          from_module = raw.from_module, kind = kind, form = raw.form,
          source = raw.doc and "doc" or "comment", text = raw.text,
        }
      end
    end
  end
  if resolver.trouble ~= nil then
    return false, resolver.trouble
  end
  table.sort(rows, function(a: link_index.Row, b: link_index.Row): boolean
    if a.module ~= b.module then return a.module < b.module end
    if a.symbol ~= b.symbol then return a.symbol < b.symbol end
    if a.path ~= b.path then return a.path < b.path end
    if a.anchor ~= b.anchor then return a.anchor < b.anchor end
    if a.from_file ~= b.from_file then return a.from_file < b.from_file end
    if a.line ~= b.line then return a.line < b.line end
    return a.column < b.column
  end)
  for _, row in ipairs(rows) do
    local ok, trouble = Sqlite.run(db,
      "INSERT INTO " .. qualifier .. "links (module, symbol, path, anchor, from_file, line, " ..
      "column, from_module, kind, form, source, text) " ..
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
      { text(row.module), text(row.symbol), text(row.path), text(row.anchor),
        text(row.from_file), { integer = row.line }, { integer = row.column },
        text(row.from_module), text(row.kind), text(row.form), text(row.source),
        text(row.text) })
    if not ok then
      return false, trouble
    end
  end
  return true, ""
end

return link_index
