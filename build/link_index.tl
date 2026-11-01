--- The links of a projection's modules, each resolved to what it names
--- and written to its `links` table ([the schema](schema.tl)) as the
--- projection is written ([`build.writer`]).
---
--- A parse records each link as written (`link_text.found`), keyed by
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
local AnalysisSchema = require("build.analysis_schema")
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
    kinds: mut {string: string}
    reads: {string: {string}}
    reals: mut {string: {string}}
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
    --- The databases, opened only once a link asks for a symbol: nil and why where they cannot be. A library that
    --- carries none has no such function.
    databases?: function(): {Sqlite.Handle}?, string
  end

  --- A projection's links, read and their files looked up, waiting for
  --- its symbols.
  record Pending
    root: string
    rows: {Raw}
    memo: Memo
    --- What the links may name besides the projection's own symbols:
    --- nil for cosmic's own tree, and where no link asks for a symbol.
    library: Library?
    --- A hash of every answer in `memo`, from the root down -- of a
    --- file read, the anchors it gives, which is all a link reads of it
    --- -- and of every link of a file that is no module, as the stage
    --- read it, and the library's identity once a link asks for a
    --- symbol: what the rows are a function of beside the projection's
    --- own. So an edit to a file that moves none of its links and none
    --- of the headings a link names leaves it as it was.
    digest: string
    --- Whether `memo` is one an earlier call kept, which every answer of
    --- it was asked of the disk again and found the same.
    remembered: boolean
    --- What the links of `rows` are resolved from, beside the disk's
    --- answers and the projection's symbols: their rows, the root and
    --- the code that resolves them. Nil where the caller named no code.
    fingerprint: string?
  end

  --- A library of nothing: links name the projection's own symbols alone.
  none: Library
end

link_index.none = {
  identity = "",
}

--- The standard library of the binary running this build: its own
--- database, named by its `boot_hash`, which is over every file of the
--- tree it was built from ([`build.identity.record_fingerprint`]), each
--- source whose docs it carries and the analyzer that read them
--- included. A binary with none carries no database, and no docs. What
--- the store refuses (a test that does not declare `store`) is said as
--- the library's.
-- TODO: sign a digest of the docs the binary carries rather than its
-- boot_hash, once writer.carried records one in meta: a binary whose
-- docs did not change rewrites a project's projection once.
function link_index.running(): link_index.Library
  return {
    identity = "binary " .. (Store.meta("boot_hash") or ""),
    databases = function(): {Sqlite.Handle}?, string
      -- The binary's own is last, after any a process attached.
      local ok, all = pcall(Store.databases)
      if not ok then
        return nil, "the standard library a project's links name: " .. tostring(all)
      end
      return { all[#all] }, ""
    end,
  }
end

local text = bind.text

--- Every link the parse recorded in a planned module or a declaration,
--- each under the module its docs name, in file and line order. The compiler a boot puts in, which [`build.derivation`] names
--- `lang/`, is the tree's by no link: it is that tree's Lua.
--- Then every link the stage read of a file that is no module (`linked`).
local raw_links =
  "SELECT m.path, i.file, l.line, l.column, l.form, " ..
  "CASE l.doc WHEN 1 THEN 'doc' ELSE 'comment' END, l.text, l.target, l.own, l.alias " ..
  "FROM (SELECT path FROM plan UNION SELECT path FROM inputs WHERE " .. AnalysisSchema.declaration("kind") .. ") m " ..
  "JOIN inputs i ON i.path = m.path AND i.origin <> 'vendor' " ..
  "JOIN links l ON l.source_hash = i.source_hash " ..
  "UNION ALL SELECT '', f.path, l.line, l.column, l.form, " ..
  "CASE f.kind WHEN 'markdown' THEN 'text' ELSE 'comment' END, l.text, l.target, l.own, '' " ..
  "FROM linked f JOIN linked_found l ON l.sha256 = f.sha256 AND l.kind = f.kind " ..
  "ORDER BY 2, 3, 4"

--- A context over the tree at `root` on disk that keeps each answer in
--- `memo`, and gives one already kept without asking again; its
--- symbols are `symbols` and `member`'s.
local function remembering(root: string, memo: link_index.Memo,
                           symbols_of: function(string): {link_resolve.Symbol}?, string,
                           member_of: function(string, string): {link_resolve.Symbol}?, string):
    link_resolve.Context
  local disk = link_resolve.on_disk(root, symbols_of, member_of,
    function(): string? return nil end)
  local context: link_resolve.Context = {
    root = root,
    kind = function(path: string): string?
      if memo.kinds[path] == nil then
        memo.kinds[path] = disk.kind(path) or ""
      end
      local kind = memo.kinds[path]
      return kind ~= "" and kind or nil
    end,
    read = function(path: string): string?
      local kept = memo.reads[path]
      if kept ~= nil then return kept[1] end
      local contents = disk.read(path)
      memo.reads[path] = if contents ~= nil then { contents } else {} end
      return contents
    end,
    real = function(path: string): string?
      local kept = memo.reals[path]
      if kept ~= nil then return kept[1] end
      local resolved = disk.real(path)
      memo.reals[path] = if resolved ~= nil then { resolved } else {} end
      return resolved
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
local function label_of(raw: link_index.Raw): string?
  if raw.form ~= "reference" or raw.target:match("^%a[%w+.-]*:") ~= nil then
    return nil
  end
  return link_text.shortcut_target(raw.text)
end

--- `memo`'s answers and the links of `rows` in no module as one hash,
--- each path from `root`, so the same tree gives the same digest
--- wherever it is checked out.
local function digest_of(root: string, memo: link_index.Memo, rows: {link_index.Raw},
                         library: string?): string
  local function from_root(path: string): string
    if path == root then return "." end
    if String.starts_with(path, root .. "/") then return path:sub(#root + 2) end
    return path
  end
  local real_root = root
  local kept_root = memo.reals[root]
  if kept_root ~= nil then real_root = kept_root[1] or root end
  local lines: mut {string} = {}
  for _, raw in ipairs(rows) do
    if raw.from_module == "" then
      lines[#lines + 1] = table.concat({ "link", raw.from_file, tostring(raw.line),
        tostring(raw.column), raw.form, raw.source, raw.text, raw.target,
        if raw.own then "own" else "-" end }, " ")
    end
  end
  for path, kind in pairs(memo.kinds) do
    lines[#lines + 1] = "kind " .. from_root(path) .. " " .. kind
  end
  for path, answer in pairs(memo.reals) do
    local real = answer[1]
    -- Only whether a path stays inside the root decides a link.
    local inside = real ~= nil and (real == real_root or String.starts_with(real, real_root .. "/"))
    lines[#lines + 1] = "real " .. from_root(path) .. " " .. (if inside then "in" else "out" end)
  end
  for path, answer in pairs(memo.reads) do
    local read = answer[1]
    local said = "-"
    if read ~= nil then
      local anchors: mut {string} = {}
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

--- What a resolution of `rows` under the code `code` is a function of beside
--- the disk's answers: the rows themselves, the root they are resolved
--- from, and the code that resolves them.
local function memo_fingerprint(code: string, root: string, rows: {link_index.Raw}): string
  local parts: mut {string} = { "link-memo-1", code, root }
  for _, raw in ipairs(rows) do
    parts[#parts + 1] = table.concat({ raw.from_module, raw.from_file, tostring(raw.line),
      tostring(raw.column), raw.form, raw.source, raw.text, raw.target,
      if raw.own then "1" else "0" end, raw.alias }, "\0")
  end
  return Hash.hex_sha256(table.concat(parts, "\n"))
end

--- What a row of `link_answers` says the disk answered: `value` where it
--- answered, nil where it did not.
local function kept_answer(found: boolean, value: string): string?
  if found then return value end
  return nil
end

--- The memo an earlier [`link_index.pending`] kept under `fingerprint`, and
--- whether a link asked for a symbol, when the disk still answers each
--- question it holds as it did: a path's kind, a path's real path, a
--- file's text, each asked again. The resolution is a function of the rows
--- and these answers alone, so one that is given the same answers to the
--- same questions asks the same ones in turn and makes the same memo:
--- nothing a file's mtime or size could miss is trusted. Nil where none
--- is kept, it is another's, or the disk answers any question differently.
--- With them, the digest of those answers and the links ([`digest_of`])
--- the call that kept them made, and what it signed in ([`link_index.Pending`]'s
--- `digest`): it is a function of the rows, the answers and that, which is
--- all `recalled` has found the same.
local function recalled(db: Sqlite.Handle, fingerprint: string): link_index.Memo?, boolean, string?, string
  local kept, _ = Sqlite.text_rows(db,
    "SELECT kind, path, value, found FROM link_answers ORDER BY kind, path")
  if kept == nil then return nil, false, nil, "" end
  local memo: link_index.Memo = { kinds = {}, reads = {}, reals = {} }
  local matched, asked = false, false
  local kept_digest: string? = nil
  local kept_signed = ""
  for _, row in ipairs(kept) do
    local what, path, value, found = row:text(1), row:text(2), row:text(3), row:text(4) == "1"
    if what == "fingerprint" then
      if value ~= fingerprint then return nil, false, nil, "" end
      matched = true
    elseif what == "asked" then
      asked = value == "1"
    elseif what == "digest" then
      kept_signed, kept_digest = path, value
    elseif what == "kind" then
      local st, _ = Fs.stat(path)
      if (if st == nil then "" else (if st.kind == "dir" then "dir" else "file" end) end) ~= value then
        return nil, false, nil, ""
      end
      memo.kinds[path] = value
    elseif what == "real" then
      local now, _ = Fs.absolute(path)
      if now ~= kept_answer(found, value) then return nil, false, nil, "" end
      memo.reals[path] = if found then { value } else {} end
    elseif what == "read" then
      local now, _ = Fs.read(path)
      if now ~= kept_answer(found, value) then return nil, false, nil, "" end
      memo.reads[path] = if found then { value } else {} end
    else
      return nil, false, nil, ""
    end
  end
  if not matched then return nil, false, nil, "" end
  return memo, asked, kept_digest, kept_signed
end

--- Keeps `memo` under `fingerprint` for [`recalled`], in the working
--- transaction, replacing any other. A failure to keep it costs a later
--- call its resolution and nothing else.
local function remember(db: Sqlite.Handle, fingerprint: string, memo: link_index.Memo, asked: boolean,
                        signed: string, digest: string)
  local prepared, _ = db:prepare(
    "INSERT INTO link_answers (kind, path, value, found) VALUES (?1, ?2, ?3, ?4)")
  if prepared == nil then return end
  local put: Sqlite.Statement = prepared
  local function add(what: string, path: string, value: string?)
    local ok, _ = put:bind_text(1, what)
    if ok then ok, _ = put:bind_text(2, path) end
    if ok then ok, _ = put:bind_text(3, value or "") end
    if ok then ok, _ = put:bind_integer(4, if value ~= nil then 1 else 0 end) end
    if ok then ok, _ = bind.once(put) end
  end
  local cleared, _ = db:exec("DELETE FROM link_answers")
  if cleared then
    add("fingerprint", "", fingerprint)
    add("asked", "", if asked then "1" else "0" end)
    add("digest", signed, digest)
    for path, kind in pairs(memo.kinds) do add("kind", path, kind) end
    for path, answer in pairs(memo.reals) do add("real", path, answer[1]) end
    for path, answer in pairs(memo.reads) do add("read", path, answer[1]) end
  end
  put:finalize()
end

--- The links the parse recorded in `db`'s planned modules and the stage
--- in its files that are none, resolved as far as the tree at `root`
--- goes, with a digest of what it said; `library` is what they may name
--- beside `db`'s own symbols, nil for none. `code` names the code that
--- resolves them, the writer's identity ([`build.identity`]): given, the
--- disk's answers are kept in `link_answers` and, where the disk still gives
--- every one, not worked out again ([`recalled`]).
function link_index.pending(db: Sqlite.Handle, root: string,
                            library: link_index.Library?, code?: string): link_index.Pending?, string
  local absolute, _ = Fs.absolute(root)
  root = absolute or root
  local found, trouble = Sqlite.text_rows(db, raw_links)
  if found == nil then
    return nil, trouble
  end
  local rows: mut {link_index.Raw} = {}
  for _, row in ipairs(found) do
    rows[#rows + 1] = {
      from_module = row:text(1), from_file = row:text(2),
      line = math.tointeger(tonumber(row:text(3))) or 0, column = math.tointeger(tonumber(row:text(4))) or 0,
      form = row:text(5), source = row:text(6), text = row:text(7), target = row:text(8),
      own = row:text(9) == "1", alias = row:text(10),
    }
  end
  local fingerprint: string? = nil
  if code ~= nil then fingerprint = memo_fingerprint(code, root, rows) end
  local recalled_memo: link_index.Memo? = nil
  local recalled_asked = false
  local kept_digest: string? = nil
  local kept_signed = ""
  if fingerprint ~= nil then
    recalled_memo, recalled_asked, kept_digest, kept_signed = recalled(db, fingerprint)
  end
  local memo: link_index.Memo = recalled_memo or { kinds = {}, reads = {}, reals = {} }
  -- No symbol is known yet: every name reads as naming none.
  local unknown = "no symbols until the projection's docs are in"
  -- A link that asks for none reads nothing of the library.
  local library_asked: boolean = recalled_asked
  local function none(_: string): {link_resolve.Symbol}?, string
    library_asked = true
    return nil, unknown
  end
  local function no_member(_: string, _: string): {link_resolve.Symbol}?, string
    library_asked = true
    return nil, unknown
  end
  if recalled_memo == nil then
    local resolver = link_resolve.resolver(remembering(root, memo, none, no_member))
    for _, raw in ipairs(rows) do
      local from = root .. "/" .. raw.from_file
      local _, _ = link_resolve.resolve(resolver, from, raw.target, declared_for(raw), raw.form ~= "shortcut")
      local label = label_of(raw)
      if label ~= nil then
        local _, _ = link_resolve.resolve(resolver, from, label, nothing_declared, false)
      end
    end
  end
  local signed = if library ~= nil and library_asked then library.identity else nil end
  local digest: string
  if recalled_memo ~= nil and kept_digest ~= nil and kept_signed == (signed or "") then
    digest = kept_digest
  else
    digest = digest_of(root, memo, rows, signed)
    if fingerprint ~= nil then
      if recalled_memo == nil then
        remember(db, fingerprint, memo, library_asked, signed or "", digest)
      else
        -- Answers kept before the digest was, or by a call that signed another library in.
        local _, _ = Sqlite.run(db, "DELETE FROM link_answers WHERE kind = 'digest'")
        local _, _ = Sqlite.run(db, "INSERT INTO link_answers (kind, path, value, found) VALUES ('digest', ?1, ?2, 1)",
          { text(signed or ""), text(digest) })
      end
    end
  end
  return { root = root, rows = rows, memo = memo, library = if library_asked then library else nil end,
    digest = digest, remembered = recalled_memo ~= nil, fingerprint = fingerprint }, ""
end

--- The `docs` of the projection under `qualifier`, held in memory, with
--- each module it answers for ([`symbols.owned_modules`]) set in `held`.
local function index_of(db: Sqlite.Handle, qualifier: string,
                        held: mut {string: boolean}): symbol_index.Index?, string
  local out = symbol_index.new()
  local modules, modules_trouble = Sqlite.text_rows(db, symbols.owned_modules(qualifier))
  if modules == nil then
    return nil, modules_trouble
  end
  for _, row in ipairs(modules) do
    symbol_index.module(out, row:text(1))
    held[row:text(1)] = true
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT module, symbol, source_symbol, file, kind, signature, exported, id FROM " ..
      qualifier .. "docs ORDER BY module, exported DESC, id")
  if rows == nil then
    return nil, trouble
  end
  for _, row in ipairs(rows) do
    symbol_index.add(out, { module = row:text(1), symbol = row:text(2), source_symbol = row:text(3),
      file = row:text(4), kind = row:text(5), signature = row:text(6), exported = row:text(7) == "1",
      shown = true, database = 1, id = math.tointeger(tonumber(row:text(8))) or 0 })
  end
  local bound, bound_trouble = symbol_index.add_bound(out, db, qualifier)
  if not bound then
    return nil, bound_trouble
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
  local open = library.databases
  local databases: {Sqlite.Handle}? = {}
  local trouble = ""
  if open ~= nil then databases, trouble = open() end
  if databases == nil then
    return false, trouble
  end
  local owners: mut {string: integer} = {}
  for at, db in ipairs(databases) do
    local database = at + 1
    local modules, modules_trouble = Sqlite.text_rows(db, symbols.owned_modules(""))
    if modules == nil then
      return false, modules_trouble
    end
    for _, row in ipairs(modules) do
      if held[row:text(1)] ~= true and owners[row:text(1)] == nil then
        owners[row:text(1)] = database
        symbol_index.module(index, row:text(1))
      end
    end
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT d.module, d.symbol, d.source_symbol, d.file, d.kind, d.signature, d.exported, " ..
        "d.id, " .. symbols.shown_docs("d", true) .. " FROM docs d ORDER BY d.module, d.id")
    if rows == nil then
      return false, rows_trouble
    end
    for _, row in ipairs(rows) do
      symbol_index.add(index, { module = row:text(1), symbol = row:text(2), source_symbol = row:text(3),
        file = row:text(4), kind = row:text(5), signature = row:text(6), exported = row:text(7) == "1",
        shown = row:text(9) == "1" and owners[row:text(1)] == database, database = database,
        id = math.tointeger(tonumber(row:text(8))) or 0 })
    end
    local bound, bound_trouble = symbol_index.add_bound(index, db, "")
    if not bound then
      return false, bound_trouble
    end
  end
  return true, ""
end

--- Resolves `pending`'s links against the `docs` of the projection
--- under `qualifier` and writes those that name one thing to its `links`:
--- [`link_index.fill`] without the memory of its last answer.
local function resolve_and_write(db: Sqlite.Handle, pending: link_index.Pending,
                                 qualifier: string): boolean, string
  local held: mut {string: boolean} = {}
  local indexed, index_trouble = index_of(db, qualifier, held)
  if indexed == nil then
    return false, index_trouble
  end
  local index: symbol_index.Index = indexed
  -- The library is read the first time a link the projection's own
  -- symbols do not settle asks for one.
  local waiting: mut {link_index.Library} = {}
  local library = pending.library
  if library ~= nil then waiting[1] = library end
  local function ready(): boolean, string
    local adding = table.remove(waiting)
    if adding == nil then
      return true, ""
    end
    return add_library(index, held, adding)
  end
  -- A member of a module the projection holds is one of its own rows
  -- ([`symbol_index.member`] reads only the owner's), unless it is found
  -- through a type an alias stands for, which may be the library's: so
  -- only a member the projection alone does not find reads it.
  local function member_of(module: string, name: string): {link_resolve.Symbol}?, string
    if held[module] == true then
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
  local function symbols_of(query: string): {link_resolve.Symbol}?, string
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
  local rows: mut {link_index.Row} = {}
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
  local resolver_trouble = resolver.trouble
  if resolver_trouble ~= nil then
    return false, resolver_trouble
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

--- The columns of a `links` row, in the order [`resolve_and_write`] and the
--- copy kept of its rows name them.
local link_columns <const> =
  "module, symbol, path, anchor, from_file, line, column, from_module, kind, form, source, text"

--- One digest of everything [`resolve_and_write`] reads of the projection
--- under `qualifier` to know which symbols there are: the modules and
--- declarations that answer for a name, each doc row's names, kind and
--- signature (not its text or line, which no link reads), and the names
--- each module binds. Quoted by type as [`build.closure_store`] quotes a row, so
--- no two rows spell one line.
local function symbols_digest(db: Sqlite.Handle, qualifier: string): string?
  local function quoted(columns: {string}): string
    local out: mut {string} = {}
    for i, column in ipairs(columns) do
      out[i] = "typeof(" .. column .. ") || ':' || quote(CASE WHEN typeof(" .. column ..
        ") = 'text' THEN CAST(" .. column .. " AS BLOB) ELSE " .. column .. " END)"
    end
    return table.concat(out, " || ',' || ")
  end
  local function digest(columns: {string}, from: string, order: string): string
    return "coalesce((SELECT lower(hex(sha256(group_concat(" .. quoted(columns) ..
      ", char(10) ORDER BY " .. order .. ")))) FROM " .. qualifier .. from .. "), '')"
  end
  local rows, _ = Sqlite.text_rows(db, "SELECT " .. table.concat({
    digest({ "path" }, "modules", "path"),
    digest({ "path" }, "decls", "path"),
    digest({ "module", "symbol", "source_symbol", "file", "kind", "signature", "exported", "id" },
      "docs", "id"),
    digest({ "path", "name", "requires" }, "bound", "path, name"),
  }, ", "))
  local row: Sqlite.Row? = nil
  if rows ~= nil then row = rows[1] end
  if row == nil then return nil end
  return Hash.hex_sha256(table.concat({ "link-fill-1", row:text(1), row:text(2),
    row:text(3), row:text(4) }, "\n"))
end

--- How many answers `memo` holds, which only grows.
local function answers(memo: link_index.Memo): integer
  local n = 0
  for _ in pairs(memo.kinds) do n = n + 1 end
  for _ in pairs(memo.reads) do n = n + 1 end
  for _ in pairs(memo.reals) do n = n + 1 end
  return n
end

--- Resolves `pending`'s links against the `docs` of the projection
--- under `qualifier` (`"out."`) and writes those that name one thing to
--- its `links`, in key order.
---
--- What it writes is a function of the links, the code and the disk's
--- answers `pending` holds, of the library's docs, and of the symbols the
--- projection documents ([`symbols_digest`]) alone, so the rows it wrote
--- last are kept in the working database under a fingerprint of those and
--- copied where they are the same: an edit that adds, drops or renames no
--- symbol and moves no link writes the same rows. Rows are kept only of a
--- resolution that asked the disk nothing `pending` had not.
function link_index.fill(db: Sqlite.Handle, pending: link_index.Pending,
                         qualifier: string): boolean, string
  local fingerprint: string? = nil
  local symbols_key: string? = nil
  local pended = pending.fingerprint
  if pended ~= nil then symbols_key = symbols_digest(db, qualifier) end
  local library = pending.library
  local library_named = "-"
  if library ~= nil then library_named = library.identity end
  if pended ~= nil and symbols_key ~= nil then
    fingerprint = Hash.hex_sha256(table.concat({ "link-fill-key-1", pended,
      pending.digest, symbols_key, library_named }, "\n"))
  end
  if fingerprint ~= nil then
    local kept, _ = Sqlite.text_rows(db, "SELECT 1 FROM link_fill WHERE fingerprint = ?1",
      { text(fingerprint) })
    if kept ~= nil and kept[1] ~= nil then
      return Sqlite.run(db, "INSERT INTO " .. qualifier .. "links (" .. link_columns .. ") " ..
          "SELECT " .. link_columns .. " FROM link_fill_rows")
    end
  end
  local before = answers(pending.memo)
  local ok, trouble = resolve_and_write(db, pending, qualifier)
  if not ok then return false, trouble end
  if fingerprint ~= nil and answers(pending.memo) == before then
    local _, _ = db:exec("DELETE FROM link_fill")
    local _, _ = db:exec("DELETE FROM link_fill_rows")
    local _, _ = Sqlite.run(db, "INSERT INTO link_fill_rows (" .. link_columns .. ") SELECT " ..
        link_columns .. " FROM " .. qualifier .. "links")
    local _, _ = Sqlite.run(db, "INSERT INTO link_fill (fingerprint) VALUES (?1)", { text(fingerprint) })
  end
  return true, ""
end

return link_index
