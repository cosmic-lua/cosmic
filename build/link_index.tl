--- The links of a projection's modules, each resolved to what it names
--- and written to its `links` table ([the schema](schema.tl)) as the
--- projection is written ([`build.writer`]).
---
--- A parse records each link as written ([`link_text.found`]), keyed by
--- its source's hash like every other row a parse keeps; so does the
--- stage for each Markdown, C and Zig file `cosmic fix` checks the links
--- of ([`build.work`]'s `linked`), whose rows name no module. What a
--- link names cannot be known then: a symbol of another module is known
--- only once every module is parsed, and a parse sees one source. So
--- the link is resolved here, as the projection is written, by the rule
--- `cosmic fix` checks it by ([`link_resolve.resolve`]), against the
--- projection being written rather than a database the last build left:
--- its `docs` rows, which the plan's keys already sign, and the files
--- of the tree on disk, which nothing else in the projection reads.
---
--- So what the files said is part of the projection's signature
--- ([`Pending.digest`]): each link is resolved first with no symbols at
--- all, which asks after every file and heading any resolution of it
--- can, and each answer is kept. A link that also names a symbol fails
--- or stops before it reads more, so the resolution that writes the
--- rows reads only answers already kept. A file that appears, goes or
--- changes its headings moves the digest, and the next build writes the
--- projection again, rather than keeping a row about a file that is not
--- there.
---
--- A project's links are resolved against its own projection and the
--- standard library the running binary carries ([`Library`]), as
--- `cosmic fix` resolves them there, so one to [`cosmic.fs.read`] is
--- kept beside one to the project's own symbols. The binary's docs are
--- no part of the working database, so what determines them is signed
--- too, and a binary carrying other docs writes the projection again.
--- cosmic's own tree documents its standard library itself, and
--- resolves against its own projection alone.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local bind = require("build.bind")
local link_resolve = require("build.link_resolve")
local link_text = require("build.link_text")
local symbol_index = require("build.symbol_index")
local symbols = require("build.symbols")
local String = require("cosmic.string")

local record link_index
  --- One link as a parse or the stage recorded it, with the module
  --- and file it is in: `from_module` is "" for a file that is no
  --- module.
  record Raw
    from_module: string
    from_file: string
    line: integer
    column: integer
    form: string
    --- What the link is in, as a row of `links` says it.
    source: string
    text: string
    target: string
    own: boolean
    alias: string
  end

  --- What the disk answered, by absolute path: a kind as
  --- [`Context.kind`] answers it (`""` for nothing there), and a text or
  --- a real path, each in a table of its own so that none is kept as an
  --- answer too.
  record Memo
    kinds: {string: string}
    reads: {string: {string}}
    reals: {string: {string}}
  end

  --- One row of the projection's `links` ([`build.schema`]).
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

  --- The standard library a project's links may name besides its own
  --- symbols: the docs of `databases`, each answering for the modules
  --- no earlier one holds, as `cosmic docs` shows them to a project.
  record Library
    --- What determines those docs, signed into the projection
    --- ([`Pending.digest`]) in their place.
    identity: string
    --- The databases, opened only once a link asks for a symbol.
    databases: function(): {Sqlite.Handle} | nil, string
  end

  --- A projection's links, read and their files looked up, waiting for
  --- its symbols.
  record Pending
    root: string
    rows: {Raw}
    memo: Memo
    --- What the links may name besides the projection's own symbols:
    --- nil for cosmic's own tree, and where no link asks for a symbol.
    library: Library | nil
    --- A hash of every answer in `memo`, from the root down -- of a
    --- file read, the anchors it gives, which is all a link reads of it
    --- -- and of every link of a file that is no module, as the stage
    --- read it, and the library's identity once a link asks for a
    --- symbol: what the rows are a function of beside the projection's
    --- own. So an edit to a file that moves none of its links and none
    --- of the headings a link names leaves it as it was.
    digest: string
  end

  --- A library of nothing: links name the projection's own symbols alone.
  none: Library
end

link_index.none = {
  identity = "",
  databases = function(): {Sqlite.Handle} | nil, string return {} end,
}

--- The standard library of the binary running this build: its own
--- database, named by its `boot_hash`, which is over every file of the
--- tree it was built from ([`work.record_fingerprint`]), each source whose
--- docs it carries and the analyzer that read them included. A binary
--- with none carries no database, and no docs. What the store refuses
--- (a test that does not declare `store`) is said as the library's.
-- TODO: sign a digest of the docs the binary carries rather than its
-- boot_hash, once writer.carried records one in meta: a binary whose
-- docs did not change rewrites a project's projection once.
function link_index.running(): link_index.Library
  return {
    identity = "binary " .. (Store.meta("boot_hash") or ""),
    databases = function(): {Sqlite.Handle} | nil, string
      -- The binary's own is last, after any a process attached.
      local all: {Sqlite.Handle} = {}
      local ok, refused: boolean, any = pcall(function() all = Store.databases() end)
      if not ok then
        return nil, "the standard library a project's links name: " .. tostring(refused)
      end
      return { all[#all] }
    end,
  }
end

local text = bind.text

--- Every link the parse recorded in a planned module or a declaration
--- -- the sources whose docs a projection holds ([`build.writer`]'s
--- `insert_docs`), each under the module its docs name -- in file and
--- line order. A source under o/, the build's output (the compiler a
--- boot puts in), is the tree's by no link.
--- Then every link the stage read of a file that is no module (`linked`).
local raw_links =
  "SELECT m.path, i.file, l.line, l.column, l.form, " ..
  "CASE l.doc WHEN 1 THEN 'doc' ELSE 'comment' END, l.text, l.target, l.own, l.alias " ..
  "FROM (SELECT path FROM plan UNION SELECT path FROM inputs WHERE kind = 'decl') m " ..
  "JOIN inputs i ON i.path = m.path AND i.file NOT GLOB 'o/*' " ..
  "JOIN links l ON l.source_hash = i.source_hash " ..
  "UNION ALL SELECT '', f.path, l.line, l.column, l.form, " ..
  "CASE f.kind WHEN 'markdown' THEN 'text' ELSE 'comment' END, l.text, l.target, l.own, '' " ..
  "FROM linked f JOIN linked_found l ON l.sha256 = f.sha256 AND l.kind = f.kind " ..
  "ORDER BY 2, 3, 4"

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

--- `memo`'s answers and the links of `rows` in no module as one hash,
--- each path from `root`, so the same tree gives the same digest
--- wherever it is checked out.
local function digest_of(root: string, memo: link_index.Memo, rows: {link_index.Raw},
                         library: string | nil): string
  local function from_root(path: string): string
    if path == root then return "." end
    if String.starts_with(path, root .. "/") then return path:sub(#root + 2) end
    return path
  end
  local real_root = memo.reals[root] ~= nil and memo.reals[root][1] or root
  local lines: {string} = {}
  for _, raw in ipairs(rows) do
    if raw.from_module == "" then
      lines[#lines + 1] = table.concat({ "link", raw.from_file, tostring(raw.line),
        tostring(raw.column), raw.form, raw.source, raw.text, raw.target,
        raw.own and "own" or "-" }, " ")
    end
  end
  for path, kind in pairs(memo.kinds) do
    lines[#lines + 1] = "kind " .. from_root(path) .. " " .. kind
  end
  for path, answer in pairs(memo.reals) do
    local real = answer[1]
    -- Only whether a path stays inside the root decides a link.
    local inside = real ~= nil and (real == real_root or String.starts_with(real, real_root .. "/"))
    lines[#lines + 1] = "real " .. from_root(path) .. " " .. (inside and "in" or "out")
  end
  for path, answer in pairs(memo.reads) do
    local read = answer[1]
    local said = "-"
    if read ~= nil then
      local anchors: {string} = {}
      for anchor in pairs(link_resolve.anchors(read)) do anchors[#anchors + 1] = anchor end
      table.sort(anchors)
      said = Hash.hex_sha256(table.concat(anchors, "\n"))
    end
    lines[#lines + 1] = "read " .. from_root(path) .. " " .. said
  end
  if library ~= nil then
    lines[#lines + 1] = "library " .. library
  end
  table.sort(lines)
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- The links the parse recorded in `db`'s planned modules and the stage
--- in its files that are none, resolved as far as the tree at `root`
--- goes, with a digest of what it said; `library` is what they may name
--- beside `db`'s own symbols, nil for none.
function link_index.pending(db: Sqlite.Handle, root: string,
                            library: link_index.Library | nil): link_index.Pending | nil, string
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
      form = row[5], source = row[6], text = row[7], target = row[8],
      own = row[9] == "1", alias = row[10],
    }
  end
  local memo: link_index.Memo = { kinds = {}, reads = {}, reals = {} }
  -- No symbol is known yet: every name reads as naming none.
  local unknown = "no symbols until the projection's docs are in"
  -- A link that asks for none reads nothing of the library.
  local asked = false
  local function none(_: string): {link_resolve.Symbol} | nil, string
    asked = true
    return nil, unknown
  end
  local function no_member(_: string, _: string): {link_resolve.Symbol} | nil, string
    asked = true
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
  local signed = library ~= nil and asked and library.identity or nil
  return { root = root, rows = rows, memo = memo, library = asked and library or nil,
    digest = digest_of(root, memo, rows, signed) }
end

--- The `docs` of the projection under `qualifier`, held in memory, with
--- each module it answers for ([`symbols.owned_modules`]) set in `held`.
local function index_of(db: Sqlite.Handle, qualifier: string,
                        held: {string: boolean}): symbol_index.Index | nil, string
  local out = symbol_index.new()
  local modules, modules_trouble = Sqlite.text_rows(db, symbols.owned_modules(qualifier))
  if modules == nil then
    return nil, modules_trouble
  end
  for _, row in ipairs(modules) do
    symbol_index.module(out, row[1])
    held[row[1]] = true
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT module, symbol, source_symbol, file, kind, signature, exported, id FROM " ..
    qualifier .. "docs ORDER BY module, exported DESC, id")
  if rows == nil then
    return nil, trouble
  end
  for _, row in ipairs(rows) do
    symbol_index.add(out, { module = row[1], symbol = row[2], source_symbol = row[3],
      file = row[4], kind = row[5], signature = row[6], exported = row[7] == "1",
      shown = true, database = 1, id = math.tointeger(tonumber(row[8])) or 0 })
  end
  return out, ""
end

--- Adds to `index` the rows of `library`'s databases that `cosmic docs`
--- shows a project, each module answered by the first that holds it
--- and none the projection holds (`held`), as [`docs.view`] owns them
--- ([`symbols.owned_modules`]) and [`build.links`] reads them for
--- `cosmic fix`.
local function add_library(index: symbol_index.Index, held: {string: boolean},
                           library: link_index.Library): boolean, string
  local databases, trouble = library.databases()
  if databases == nil then
    return false, trouble
  end
  local owners: {string: integer} = {}
  for at, db in ipairs(databases) do
    local database = at + 1
    local modules, modules_trouble = Sqlite.text_rows(db, symbols.owned_modules(""))
    if modules == nil then
      return false, modules_trouble
    end
    for _, row in ipairs(modules) do
      if not held[row[1]] and owners[row[1]] == nil then
        owners[row[1]] = database
        symbol_index.module(index, row[1])
      end
    end
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT d.module, d.symbol, d.source_symbol, d.file, d.kind, d.signature, d.exported, " ..
      "d.id, " .. symbols.shown_docs("d", true) .. " FROM docs d ORDER BY d.module, d.id")
    if rows == nil then
      return false, rows_trouble
    end
    for _, row in ipairs(rows) do
      symbol_index.add(index, { module = row[1], symbol = row[2], source_symbol = row[3],
        file = row[4], kind = row[5], signature = row[6], exported = row[7] == "1",
        shown = row[9] == "1" and owners[row[1]] == database, database = database,
        id = math.tointeger(tonumber(row[8])) or 0 })
    end
  end
  return true, ""
end

--- Resolves `pending`'s links against the `docs` of the projection
--- under `qualifier` (`"out."`) and writes those that name one thing to
--- its `links`, in key order.
function link_index.fill(db: Sqlite.Handle, pending: link_index.Pending,
                         qualifier: string): boolean, string
  local held: {string: boolean} = {}
  local indexed, index_trouble = index_of(db, qualifier, held)
  if indexed == nil then
    return false, index_trouble
  end
  local index: symbol_index.Index = indexed
  -- The library is read the first time a link the projection's own
  -- symbols do not settle asks for one.
  local library = pending.library
  local function ready(): boolean, string
    if library == nil then
      return true, ""
    end
    local adding = library
    library = nil
    return add_library(index, held, adding)
  end
  -- A member of a module the projection holds is one of its own rows
  -- ([`symbol_index.member`] reads only the owner's), unless it is found
  -- through a type an alias stands for, which may be the library's: so
  -- only a member the projection alone does not find reads it.
  local function member_of(module: string, name: string): {link_resolve.Symbol} | nil, string
    if held[module] then
      local own = symbol_index.member(index, module, name)
      if #own > 0 then
        return own, ""
      end
    end
    local ok, trouble = ready()
    if not ok then
      return nil, trouble
    end
    return symbol_index.member(index, module, name), ""
  end
  -- A name in full that starts with a module the projection holds,
  -- and which names a symbol of the projection's, is taken as that:
  -- the library's modules are cosmic's, which no project holds, so
  -- only one of its symbols spelled with the same last names
  -- (`X.other.fn` beside the project's `other.fn`) could make it two,
  -- which `cosmic fix` would refuse and the index keeps as the
  -- project's.
  local function symbols_of(query: string): {link_resolve.Symbol} | nil, string
    local ours = false
    for at in query:gmatch("()[.:]") do
      ours = ours or held[query:sub(1, at - 1)] == true
    end
    if ours then
      local own = symbol_index.named(index, query)
      if #own > 0 then
        return own, ""
      end
    end
    local ok, trouble = ready()
    if not ok then
      return nil, trouble
    end
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
    -- file that declares it, as [`build.links`] checks.
    local label = label_of(raw)
    if label ~= nil and target ~= nil and target.kind == "file" then
      local named, _ = link_resolve.resolve(resolver, from, label, nothing_declared, false)
      if named ~= nil and named.kind == "symbol" and named.file == target.path then
        target = named
      end
    end
    if target ~= nil then
      local kind, module, symbol = target.kind, target.module, target.symbol
      if kind == "declared" and raw.from_module ~= "" then
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
          source = raw.source, text = raw.text,
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
