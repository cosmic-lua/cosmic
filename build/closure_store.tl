--- Writing the store of a test module's import closure: what a
--- sandboxed worker of a test whose module does not declare `store` is
--- given at o/cosmic.db in the projection's place ([`build.test_sandbox`]),
--- derived from the projection [`build.writer`] writes and kept by
--- `cosmic test` under the build directory's stores/ by its address ([`build.test`]), so an
--- edit to a module outside the closure leaves the store as it was. A
--- test's key holds the store by the digest of its bytes
--- ([`build.declared_key`]'s `store_digest`), not by its address: the
--- address says only where a store is and whether it must be written, so
--- an edit to the code that writes it that leaves its bytes as they were
--- moves no key.
---
--- It is apart from the projection's writer because its code salts
--- every store's address ([`build.test`]'s `store_writer`), and that
--- writer's need not. What the writer writes reaches a store only
--- through rows and orderings the address digests
--- ([`closure_store.basis`]): each module's columns, the stored (deflated)
--- source's bytes among them, and each module's own imports, the
--- edges the checker follows from it, names bound, docs, uses, catalog,
--- examples and links in the order the store takes them. The order across
--- modules is this module's (`closed`). So an edit to the writer -- a
--- query of the projection, a table only the projection fills -- moves
--- only the addresses of the stores whose rows it moves.

local Clock = require("cosmic.clock")
local CodeWalk = require("build.code_walk")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local lua_tail = require("build.lua_tail")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")
local Sqlite = require("cosmic.sqlite")
local schema = require("build.schema")
local String = require("cosmic.string")

local record closure_store
  --- What every closure store a projection yields is a function of,
  --- read once from the projection ([`closure_store.basis`]).
  ---
  --- Each module is a line naming its path, kind, file, source hash and
  --- tests, then the digests of its bytecode (inflated, so the compressor
  --- moves none), of its source as stored
  --- (deflated, by [`build.writer`]), and of the rows a store carries of
  --- it: its imports, the edges the checker follows from it
  --- (`decl_imports`), the names it binds, its docs, uses, catalog,
  --- examples and links (those it makes), each in the order the store
  --- takes them within the module (or file). Each declaration is a line
  --- naming its path and the digests of its source as stored, of its
  --- docs, of its links, of the names it binds and of its edges, and it
  --- records the declarations it requires. A digest covers what
  --- every store holds alike: the `meta` rows it keeps (`closure_meta`).
  ---
  --- What the compiler made of a module is held by what it made, not by
  --- the compiler's identity ([`build.identity`]'s `Identities`). That moves
  --- with every edit to any module a compile or a parse runs, most of
  --- which change nothing it makes. An edit to the compiler that leaves
  --- every row of a closure as it was leaves its store and its address
  --- too.
  record Basis
    modules: mut {string:string}
    shared: string
    --- Each module's kind, by path.
    kinds: mut {string:string}
    --- The modules an example can be paired with -- neither tests nor
    --- examples -- sorted (see [`build.writer`]'s `insert_examples`).
    pairable: mut {string}
    --- Each declaration's line, by path.
    decls: mut {string:string}
    --- The declarations each declaration requires, by path
    --- ([`required_by`]).
    decl_requires: mut {string:{string}}
    --- The pure store's ([`closure_store.write`]'s `own`) line of each module,
    --- by path: what it holds of a module but its bytecode -- the kind, file,
    --- tests, and the imports, declaration imports and bound names, each by a
    --- digest. Nothing text-derived: no source, source hash, doc, use, link,
    --- example, catalog row, place or stub.
    pure: mut {string:string}
    --- The digest of each module's bytecode with the debug information
    --- stripped ([`lua_tail.stripped`]), by path: what the pure store holds
    --- of every module but its test's own.
    stripped: mut {string:string}
    --- The digest of each module's whole bytecode, debug information
    --- included (inflated, so the compressor moves none), by path: what the
    --- pure store holds of its test's own module.
    bytecode: mut {string:string}
    --- A declaration's line in the pure store: its source (a declaration is
    --- types, with no bytecode to say what it does), the names it binds and
    --- the edges the checker follows from it; not its docs or links.
    pure_decls: mut {string:string}
    --- What the pure store holds of a module its test names with `local type` ([`type_requires`]),
    --- by path: the digest of its stub, inflated so the compressor moves none; none for a module with no stub.
    --- Empty unless the run holds the pure store.
    texts: mut {string:string}
    --- The standard-library modules (`cosmic.*`) each test and example module names with a top-level
    --- `local type _ = require("cosmic.x")`, by path ([`type_requires`]): what its pure
    --- store keeps the text of.
    type_requires: mut {string:{string}}
    --- The names each module's stub requires, by path ([`required_by`]): the checker types a stub
    --- from the stubs of those, so a module a kept stub requires is kept too.
    text_edges: mut {string:{string}}
    --- The digest of each module's source (inflated, so the compressor moves none), by path: what the pure store
    --- holds of a module whose source it keeps ([`source_kept`]). Empty unless the run holds the pure store.
    sources: mut {string:string}
    --- The modules each module requires, by path (the `imports` rows), which [`source_kept`] walks from a
    --- walk's roots. Empty unless the run holds the pure store.
    edges: mut {string:{string}}
  end
end

--- `value`, bound as TEXT: [`build.bind`]'s `text`, restated rather than
--- required so that what salts a store's address is this module and the
--- schema alone ([`build.test`]'s `store_writer`), and an edit to the
--- binds the rest of the build shares moves no address.
local function text(value: string): Sqlite.Value
  return { text = value }
end

--- The `meta` rows of a projection a closure store keeps: none that
--- moves with a module outside the closure. `boot_hash` hashes every
--- file of the tree and `projected` signs every module; `writer` and
--- `written_by` name the projection's writer ([`build.work`]'s
--- `writer_modules`), which holds much of the standard library
--- (cosmic.json among it); `compiler` and `compiled_by` name the
--- importer's. Each left out is answered by the tool's own `meta`, the
--- next database [`Store.meta`] searches; what writes a closure store is
--- named in its address instead ([`closure_store.address`]'s `salt`), and
--- a test whose closure reads the compiler's identity is keyed by the
--- tool's ([`build.declared_key`]'s `compiler_readers`).
local closure_meta <const> = "('image_hash', 'main', 'runtime_basis')"

--- The names `source`, a declaration's, requires: each literal name
--- handed to `require` -- `local type t = require("name")`, as a
--- declaration requires another's types -- spelled `require("name")`,
--- `require "name"`, with single quotes, or as a long string
--- (`require [[name]]`). It reads more than a parse would: a name
--- written so in a comment is among them, which only makes a store
--- carry, and its address hold, one declaration more. A declaration
--- cannot require a computed name, since the checker types only a
--- literal one. A spelling it misses fails closed: a store, given a
--- worker in the projection's place, holds only the declarations it
--- carries, so one this leaves out is one no test can read, and a test
--- that types it fails rather than standing. Scanned here rather than taken from the
--- importer's parse, which the projection does not keep of a
--- declaration: a require of [`build.syntax_analyzer`] would salt every store's
--- address with it ([`build.test`]'s `store_writer`). [`build.tree_checks`]
--- holds the tree to declarations that require only declarations
--- (`declared`).
function closure_store.required_by(source: string): {string}
  local out: mut {string} = {}
  for _, pattern in ipairs({ "require%s*%(?%s*[\"']([%w_%.]+)[\"']",
      "require%s*%(?%s*%[(=*)%[([%w_%.]+)%]%1%]" }) do
    for first, second in source:gmatch(pattern) do
      out[#out + 1] = second or first
    end
  end
  return out
end

--- `source` less its comments and its long strings, each long string replaced by `""` (the grammar has no
--- long comment), so that what a
--- test spells inside a snippet it checks is no statement of its own. Quoted strings stay, since a
--- `require` names its module in one.
local function without_long_text(source: string): string
  local out: mut {string} = {}
  local size = #source
  local at = 1
  while at <= size do
    local next_at = source:find("[%-%[\"']", at)
    if next_at == nil then
      out[#out + 1] = source:sub(at)
      break
    end
    out[#out + 1] = source:sub(at, next_at - 1)
    at = next_at
    local here = source:sub(at, at)
    if here == "-" and source:sub(at + 1, at + 1) == "-" then
      at = source:find("\n", at, true) or (size + 1)
    elseif here == "[" then
      local _, open_stop, level = source:find("^%[(=*)%[", at)
      if open_stop ~= nil and level ~= nil then
        local _, close_stop = source:find("]" .. level .. "]", open_stop + 1, true)
        at = (close_stop or size) + 1
        out[#out + 1] = '""'
      else
        out[#out + 1] = here
        at = at + 1
      end
    elseif here == "-" then
      out[#out + 1] = here
      at = at + 1
    else
      local finish = at + 1
      while finish <= size do
        local char = source:sub(finish, finish)
        if char == "\\" then
          finish = finish + 2
        elseif char == here or char == "\n" then
          break
        else
          finish = finish + 1
        end
      end
      out[#out + 1] = source:sub(at, finish)
      at = finish + 1
    end
  end
  return table.concat(out)
end

--- The standard-library modules (`cosmic.*`) that the test or example `source` names with a top-level
--- `local type _ = require("cosmic.x")` (a `<const>` after the name is allowed), in the order written:
--- the spelling [`cosmic.test`]'s `store` documents for a module a snippet the test type-checks requires.
--- Only those, and not every `require`: a test requires [`cosmic.test`] and the modules it runs by value,
--- which a comment in would run it again for nothing. A statement inside a comment or a long string, such
--- as a snippet the test checks, is none. A `require` after other code on its line is missed, and the test
--- fails naming the module whose stub is withheld.
local function type_requires(source: string): {string}
  local out: mut {string} = {}
  for name in ("\n" .. without_long_text(source)):gmatch("\nlocal type [%w_]+[%s<%w>]-=%s*require%s*%(?%s*[\"']([%w_%.]+)[\"']") do
    if name:sub(1, 7) == "cosmic." then out[#out + 1] = name end
  end
  return out
end

--- One call of [`grouped`], as `read` lists them: the column `owner` names
--- the rows' group, the `columns` (a space-separated list) are digested,
--- `from` is the table (or table and condition) and `order` the ordering.
local record Group
  owner: string
  columns: string
  from: string
  order: string
end

--- The digest of the rows of `from`, the table of a projection `db`
--- holds, by each value of its column `of`: of each row's `columns`,
--- each quoted (`quote`) so no two rows spell one line, in `order`. A
--- text is quoted as a blob of its bytes, since quote() ends a text at
--- its first NUL, which a blob's hex does not (as [`build.declared_key`]'s
--- `carried_digest` quotes it).
local function grouped(db: Sqlite.Handle, of: string, columns: {string}, from: string,
                       order: string): {string:string}?, string
  local quoted: mut {string} = {}
  for i, column in ipairs(columns) do
    quoted[i] = "typeof(" .. column .. ") || ':' || quote(CASE WHEN typeof(" .. column ..
      ") = 'text' THEN CAST(" .. column .. " AS BLOB) ELSE " .. column .. " END)"
  end
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT " .. of .. ", lower(hex(sha256(group_concat(" ..
      table.concat(quoted, " || ',' || ") .. ", char(10) ORDER BY " .. order .. ")))) " ..
      "FROM " .. from .. " GROUP BY " .. of)
  if rows == nil then return nil, trouble end
  local out: mut {string:string} = {}
  for _, row in ipairs(rows) do out[row:text(1)] = row:text(2) end
  return out, ""
end

--- Where the basis of the projection at `whole` is kept: beside it.
local function memo_path(whole: string): string
  return whole .. ".basis"
end

--- What says the projection at `whole` is the file a kept basis was made
--- of, and this code the code that made it: the file's size, inode,
--- modification and change times, and the digest of this module's
--- bytecode. Nil where there is nothing to say it by, and nil too while
--- the file is younger than two seconds: a write inside the tick of the
--- clock that stamped it would leave all of these as they were, so a
--- basis is kept only of a file already older than that.
local function memo_token(whole: string, pure?: boolean): string?
  local st, _ = sys.stat(whole)
  if st == nil then return nil end
  local written = st.mtime * 1000000000 + st.mtime_ns
  local changed = st.ctime * 1000000000 + st.ctime_ns
  if Clock.now_ns() - math.max(written, changed) < 2000000000 then return nil end
  local code, _ = Store.bytecode("build.closure_store")
  if code == nil then return nil end
  return table.concat({ if pure == true then "basis-memo-3-pure" else "basis-memo-3" end, Hash.hex_sha256(code), st.size, st.ino, st.dev, written, changed }, " ")
end

--- Where a read of a kept basis is, and the basis it made.
local record Reading
  mut at: integer
  mut basis: closure_store.Basis?
end

--- The basis kept beside `whole` under `token`, or nil where none is, or
--- it is of another file or another code, or it is not whole.
local function remembered(whole: string, token: string): closure_store.Basis?
  local bytes, _ = Fs.read(memo_path(whole))
  if bytes == nil then return nil end
  local data: string = bytes
  local reading: Reading = { at = 1, basis = nil }
  local function next_string(): string
    local value: string
    value, reading.at = string.unpack("<s4", data, reading.at)
    return value
  end
  local function next_count(): integer
    local value: integer
    value, reading.at = string.unpack("<I4", data, reading.at)
    return value
  end
  -- The reading raises on a truncated file; `pcall`'s own results are all
  -- that is taken of it, and the basis leaves by `reading`.
  pcall(function()
    if next_string() ~= token then return end
    local out: closure_store.Basis = {
      modules = {}, shared = next_string(), kinds = {}, pairable = {}, decls = {}, decl_requires = {},
      pure = {}, stripped = {}, bytecode = {}, pure_decls = {}, texts = {}, text_edges = {}, type_requires = {}, sources = {}, edges = {},
    }
    for _ = 1, next_count() do
      local path = next_string()
      out.modules[path] = next_string()
      out.kinds[path] = next_string()
      out.pure[path] = next_string()
      out.stripped[path] = next_string()
      out.bytecode[path] = next_string()
      out.texts[path] = next_string()
    end
    for _ = 1, next_count() do
      local path = next_string()
      local required: mut {string} = {}
      for i = 1, next_count() do required[i] = next_string() end
      out.text_edges[path] = required
    end
    for _ = 1, next_count() do
      local path = next_string()
      local required: mut {string} = {}
      for i = 1, next_count() do required[i] = next_string() end
      out.type_requires[path] = required
    end
    for _ = 1, next_count() do
      local name = next_string()
      out.pairable[#out.pairable + 1] = name
    end
    for _ = 1, next_count() do
      local path = next_string()
      out.decls[path] = next_string()
      local required: mut {string} = {}
      for i = 1, next_count() do required[i] = next_string() end
      out.decl_requires[path] = required
      out.pure_decls[path] = next_string()
    end
    for _ = 1, next_count() do
      local path = next_string()
      out.sources[path] = next_string()
    end
    for _ = 1, next_count() do
      local path = next_string()
      local required: mut {string} = {}
      for i = 1, next_count() do required[i] = next_string() end
      out.edges[path] = required
    end
    if reading.at ~= #data + 1 then return end
    reading.basis = out
  end)
  return reading.basis
end

--- Keeps `basis` beside `whole` under `token`, written aside and moved into
--- place so that what is there is whole. A failure costs the next run
--- the work it would have saved, and nothing else.
local function remember(whole: string, token: string, basis: closure_store.Basis)
  local parts: mut {string} = {}
  local function put_string(value: string) table.insert(parts, string.pack("<s4", value)) end
  local function put_count(value: integer) table.insert(parts, string.pack("<I4", value)) end
  put_string(token)
  put_string(basis.shared)
  -- In the order `pairs` has them: a reader takes them by name.
  local modules = 0
  for _ in pairs(basis.modules) do modules = modules + 1 end
  put_count(modules)
  for path, line in pairs(basis.modules) do
    put_string(path)
    put_string(line)
    put_string(basis.kinds[path] or "")
    put_string(basis.pure[path] or "")
    put_string(basis.stripped[path] or "")
    put_string(basis.bytecode[path] or "")
    put_string(basis.texts[path] or "")
  end
  local edged = 0
  for _ in pairs(basis.text_edges) do edged = edged + 1 end
  put_count(edged)
  for path, required in pairs(basis.text_edges) do
    put_string(path)
    put_count(#required)
    for _, name in ipairs(required) do put_string(name) end
  end
  local typed = 0
  for _ in pairs(basis.type_requires) do typed = typed + 1 end
  put_count(typed)
  for path, required in pairs(basis.type_requires) do
    put_string(path)
    put_count(#required)
    for _, name in ipairs(required) do put_string(name) end
  end
  put_count(#basis.pairable)
  for _, path in ipairs(basis.pairable) do put_string(path) end
  local declared = 0
  for _ in pairs(basis.decls) do declared = declared + 1 end
  put_count(declared)
  for path, line in pairs(basis.decls) do
    put_string(path)
    put_string(line)
    local required = basis.decl_requires[path] or {}
    put_count(#required)
    for _, name in ipairs(required) do put_string(name) end
    put_string(basis.pure_decls[path] or "")
  end
  local sourced = 0
  for _ in pairs(basis.sources) do sourced = sourced + 1 end
  put_count(sourced)
  for path, digest in pairs(basis.sources) do
    put_string(path)
    put_string(digest)
  end
  local listed = 0
  for _ in pairs(basis.edges) do listed = listed + 1 end
  put_count(listed)
  for path, required in pairs(basis.edges) do
    put_string(path)
    put_count(#required)
    for _, name in ipairs(required) do put_string(name) end
  end
  local aside = memo_path(whole) .. "." .. tostring(Proc.pid()) .. ".building"
  local written, _ = Fs.write(aside, table.concat(parts))
  if written then
    local moved, _ = Fs.rename(aside, memo_path(whole))
    if moved then return end
  end
  local _, _ = Fs.remove(aside)
end

--- The basis of the closure stores of the projection at `whole`, read from
--- every row of it.
local function read_basis(whole: string, pure?: boolean): closure_store.Basis?, string
  local opened, trouble = Sqlite.open(whole)
  if opened == nil then return nil, whole .. ": " .. trouble end
  local db: Sqlite.Handle = opened
  local function read(): closure_store.Basis?, string
    local rows, rows_trouble = Sqlite.text_rows(db,
      "SELECT path, path || char(9) || kind || char(9) || file || char(9) || " ..
        "lower(hex(source_hash)) || char(9) || lower(hex(sha256(inflate(bytecode)))) || char(9) || " ..
        "lower(hex(sha256(tests))) || char(9) || lower(hex(sha256(source))), file " ..
        "FROM modules ORDER BY path")
    if rows == nil then return nil, rows_trouble end
    -- The rows `closed` carries of each module, as it carries them: by
    -- its path, or, for its examples, by its file.
    local carried: mut {{string:string}} = {}
    local by_file: mut {boolean} = {}
    -- The links', the names' and the edges' digests, which a
    -- declaration's line takes too.
    local linked: {string:string} = {}
    local bound: {string:string} = {}
    local edges: {string:string} = {}
    local groups: {Group} = {
      { owner = "path", columns = "requires", from = "imports", order = "requires" },
      { owner = "path", columns = "requires", from = "decl_imports", order = "requires" },
      { owner = "path", columns = "name requires", from = "bound", order = "name" },
      { owner = "module", columns = "symbol source_symbol exported kind signature text file line", from = "docs", order = "id" },
      { owner = "from_module", columns = "module symbol from_file line", from = "uses", order = "module, symbol, line" },
      { owner = "module", columns = "kind symbol message text file line", from = "catalog", order = "id" },
      { owner = "file", columns = "module name text line source", from = "examples", order = "id" },
      { owner = "from_module", columns = "module symbol path anchor from_file line column kind form source text", from = "links", order = "module, symbol, path, anchor, from_file, line, column" },
      { owner = "path", columns = "source", from = "stubs", order = "path" },
      { owner = "module", columns = "ordinal symbol kind line column length plain", from = "places", order = "ordinal" },
    }
    for _, group in ipairs(groups) do
      local columns: mut {string} = {}
      for column in group.columns:gmatch("%S+") do columns[#columns + 1] = column end
      local digests, group_trouble = grouped(db, group.owner, columns, group.from, group.order)
      if digests == nil then return nil, group_trouble end
      carried[#carried + 1] = digests
      if group.from == "links" then linked = digests end
      if group.from == "bound" then bound = digests end
      if group.from == "decl_imports" then edges = digests end
      by_file[#by_file + 1] = group.owner == "file"
    end
    local shared, shared_trouble = Sqlite.text_rows(db,
      "SELECT coalesce((SELECT group_concat(key || ' ' || lower(hex(value)), char(10) " ..
        "ORDER BY key) FROM meta WHERE key IN " .. closure_meta .. "), '')")
    if shared == nil then return nil, shared_trouble end
    local shared_row = assert(shared[1], "the shared meta query answers one row")
    local decl_rows, decl_trouble = Sqlite.text_rows(db,
      "SELECT path, lower(hex(sha256(source))), CAST(inflate(source) AS TEXT) FROM decls " ..
        "ORDER BY path")
    if decl_rows == nil then return nil, decl_trouble end
    local declared, declared_trouble = grouped(db, "module",
      { "symbol", "source_symbol", "exported", "kind", "signature", "text", "file", "line" },
      "docs WHERE module IN (SELECT path FROM decls)", "id")
    if declared == nil then return nil, declared_trouble end
    local names, names_trouble = Sqlite.text_rows(db,
      "SELECT path FROM modules WHERE kind NOT IN ('test', 'example') ORDER BY path")
    if names == nil then return nil, names_trouble end
    local basis: closure_store.Basis = {
      modules = {}, shared = Hash.hex_sha256("closure-store-8\n" .. shared_row:text(1)),
      kinds = {}, pairable = {}, decls = {}, decl_requires = {},
      pure = {}, stripped = {}, bytecode = {}, pure_decls = {}, texts = {}, text_edges = {}, type_requires = {}, sources = {}, edges = {},
    }
    for _, row in ipairs(rows) do
      local line: mut {string} = { row:text(2) }
      for i, digests in ipairs(carried) do
        line[#line + 1] = digests[by_file[i] and row:text(3) or row:text(1)] or "" -- checked: condition_type
      end
      basis.modules[row:text(1)] = table.concat(line, "\t")
      local kind = row:text(2):match("^[^\t]*\t([^\t]*)")
      assert(kind ~= nil, "the second column of a module's row holds its kind")
      basis.kinds[row:text(1)] = kind
    end
    for _, row in ipairs(names) do
      local name = row:text(1)
      basis.pairable[#basis.pairable + 1] = name
    end
    -- The first three groups are the imports, the declaration imports and the bound names.
    local kept: mut {{string:string}} = {}
    for i = 1, 3 do kept[i] = assert(carried[i], "the first three groups are read") end
    -- Only for a run that holds the pure store: stripping every chunk is for it alone, and a chunk it refuses
    -- would otherwise stop a run that never reads the result.
    local pure_rows: {Sqlite.Row} = {}
    if pure == true then
      local found, pure_trouble = Sqlite.rows(db,
        "SELECT path, kind, file, lower(hex(sha256(tests))), inflate(bytecode) FROM modules ORDER BY path")
      if found == nil then return nil, pure_trouble end
      pure_rows = found
      -- What the checker reads of a standard-library module is its stub ([`build.standard_text`]); the
      -- stub keeps no comment but keeps every token at its source line and column ([`build.syntax_stub`]),
      -- so these digests move with a module's declared types and with a line added or removed above them.
      local stubbed, stubbed_trouble = Sqlite.text_rows(db,
        "SELECT path, lower(hex(sha256(inflate(source)))), CAST(inflate(source) AS TEXT) FROM stubs ORDER BY path")
      if stubbed == nil then return nil, stubbed_trouble end
      for _, row in ipairs(stubbed) do
        basis.texts[row:text(1)] = row:text(2)
        basis.text_edges[row:text(1)] = closure_store.required_by(row:text(3))
      end
      local sourced, sourced_trouble = Sqlite.text_rows(db,
        "SELECT path, CAST(inflate(source) AS TEXT) FROM modules WHERE kind IN ('test', 'example') ORDER BY path")
      if sourced == nil then return nil, sourced_trouble end
      for _, row in ipairs(sourced) do
        basis.type_requires[row:text(1)] = type_requires(row:text(2))
      end
      -- What a walk of the code that reads module text ([`build.code_walk`]) is hashed from.
      local hashed, hashed_trouble = Sqlite.text_rows(db,
        "SELECT path, lower(hex(sha256(inflate(source)))) FROM modules WHERE kind NOT IN ('test', 'example') " ..
          "AND length(source) > 0 ORDER BY path")
      if hashed == nil then return nil, hashed_trouble end
      for _, row in ipairs(hashed) do basis.sources[row:text(1)] = row:text(2) end
      local imported, imported_trouble = Sqlite.text_rows(db, "SELECT path, requires FROM imports ORDER BY path, requires")
      if imported == nil then return nil, imported_trouble end
      local lists: mut {string:mut {string}} = {}
      for _, row in ipairs(imported) do
        local list: mut {string} = lists[row:text(1)] or {}
        lists[row:text(1)] = list
        table.insert(list, row:text(2))
      end
      for path, list in pairs(lists) do basis.edges[path] = list end
    end
    for _, row in ipairs(pure_rows) do
      local path = row:text(1)
      local line: mut {string} = { path, row:text(2), row:text(3), row:text(4) }
      for _, digests in ipairs(kept) do line[#line + 1] = digests[path] or "" end
      basis.pure[path] = table.concat(line, "\t")
      local code = row:blob(5)
      basis.bytecode[path] = Hash.hex_sha256(code)
      local stripped, why = lua_tail.stripped(code, path)
      if stripped == nil then return nil, why end
      basis.stripped[path] = Hash.hex_sha256(stripped)
    end
    for _, row in ipairs(decl_rows) do
      basis.decls[row:text(1)] = "decl " .. row:text(1) .. " " .. row:text(2) .. " " .. (declared[row:text(1)] or "") ..
        " " .. (linked[row:text(1)] or "") .. " " .. (bound[row:text(1)] or "") .. " " ..
        (edges[row:text(1)] or "")
      basis.decl_requires[row:text(1)] = closure_store.required_by(row:text(3))
      basis.pure_decls[row:text(1)] = "decl " .. row:text(1) .. " " .. row:text(2) .. " " ..
        (bound[row:text(1)] or "") .. " " .. (edges[row:text(1)] or "")
    end
    return basis, ""
  end
  local basis, read_trouble = read()
  local _, _ = db:close()
  if basis == nil then return nil, whole .. ": " .. read_trouble end
  return basis, ""
end

--- The basis of the closure stores of the projection at `whole`: read
--- from the file beside it where an earlier run kept one of this very
--- file ([`memo_token`]), which saves hashing every row of the
--- projection, some half a second for cosmic's own tree.
---
--- `pure` makes it also what [`closure_store.address`] and [`closure_store.write`] take for
--- the pure store (`pure`, `stripped`, `bytecode`, `pure_decls`); without it those are empty.
function closure_store.basis(whole: string, pure?: boolean): closure_store.Basis?, string
  local token = memo_token(whole, pure)
  if token ~= nil then
    local kept = remembered(whole, token)
    if kept ~= nil then return kept, "" end
  end
  local made, made_trouble = read_basis(whole, pure)
  if made == nil then return nil, made_trouble end
  if token ~= nil then remember(whole, token, made) end
  return made, ""
end

--- Declarations a module reads by other means than `require`, which a closure store carries beside it: the new
--- checker's declarations of the globals and of the standard library, which [`build.checker_declarations`]'s `carried`
--- reads by name ([`Store.source`]) for any compile of a project, such as a test's.
local declared_beside: {string:{string}} = {
  ["build.checker_declarations"] = { "lang.prelude", "lang.stdlib" },
}

--- The modules of `basis` a closure store for `names` -- an import
--- closure's module names ([`test_inputs.modules`]) -- holds, sorted: each
--- that the projection holds. A name only a declaration answers for is none:
--- `declared` answers those.
local function stored(basis: closure_store.Basis, names: {string}): {string}
  local seen: mut {string:boolean} = {}
  local out: mut {string} = {}
  local function add(name: string)
    if seen[name] == true or basis.modules[name] == nil then return end
    seen[name] = true
    out[#out + 1] = name
  end
  for _, name in ipairs(names) do
    add(name)
  end
  table.sort(out)
  return out
end

--- The declarations of `basis` a closure store for `names` holds,
--- sorted: each that `names` holds -- an import closure holds each
--- declaration a module of it requires by value, and each a test module
--- of it requires by `require` or by `local type ... = require`; a
--- non-test module's type-only edges are not followed
--- ([`test_inputs.modules`]) -- and each that one of
--- them requires, directly or not, so a declaration the checker reads
--- to type another's is carried beside it and its edit moves the
--- address too. The core's raw modules (`cosmic.internal.*`) and
--- [`cosmic.sys`] are so carried only by the closures whose wrappers
--- require them, and an edit to one moves only those stores.
---
--- What it carries beyond the closure's names over-approximates the
--- address: an edit to a declaration carried only this way moves an
--- address no test's verdict need turn on, since what a test reads of a
--- store is what its key holds of it, so this walk keeps a store whole
--- for the checker.
--- It follows declarations alone: a module of the tree one required
--- would be neither carried nor in the address, so [`build.tree_checks`]
--- (`declarations`) refuses a declaration that requires anything but
--- a declaration.
local function declared(basis: closure_store.Basis, names: {string}): {string}
  local seen: mut {string:boolean} = {}
  local out: mut {string} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(names) do
    stack[#stack + 1] = name
    for _, beside in ipairs(declared_beside[name] or {}) do stack[#stack + 1] = beside end
  end
  while #stack > 0 do
    local name = table.remove(stack)
    if name ~= nil and seen[name] ~= true and basis.decls[name] ~= nil then
      seen[name] = true
      out[#out + 1] = name
      local requires = assert(basis.decl_requires[name], "a declaration is stored with its requires")
      for _, required in ipairs(requires) do stack[#stack + 1] = required end
    end
  end
  table.sort(out)
  return out
end

--- The modules of `basis` whose stub the pure store for `names` keeps because its test names them: each of
--- `roots` ([`type_requires`]) that the store holds and has a stub of, and each of those that a kept stub
--- requires, sorted. What the checker reads to type a snippet that requires them
--- ([`build.standard_text`]), and no more: a module the test imports only otherwise keeps its
--- bytecode, stripped, and no text.
local function text_kept(basis: closure_store.Basis, names: {string}, roots: {string}): {string}
  -- TODO: keep these only for a closure that holds a module declaring `stubs` ([`build.code_walk`]'s `markers`), as the sources of
  -- a walk are kept, once every reader of a stub declares it and the tests of this module name the declaration.
  local held: mut {string:boolean} = {}
  for _, name in ipairs(stored(basis, names)) do held[name] = true end
  local seen: mut {string:boolean} = {}
  local out: mut {string} = {}
  local stack: mut {string} = {}
  for _, name in ipairs(roots) do stack[#stack + 1] = name end
  while #stack > 0 do
    local name = table.remove(stack)
    if name ~= nil and seen[name] ~= true and held[name] == true and basis.texts[name] ~= nil then
      seen[name] = true
      out[#out + 1] = name
      for _, required in ipairs(basis.text_edges[name] or {}) do stack[#stack + 1] = required end
    end
  end
  table.sort(out)
  return out
end

--- Whether the test or example whose closure is `names` imports a module that declares it reads `word`
--- ([`build.code_walk`]'s `markers`).
local function declares(names: {string}, word: string): boolean
  local present: mut {string:boolean} = {}
  for _, name in ipairs(names) do present[name] = true end
  for marker, spelled in pairs(CodeWalk.markers) do
    if spelled == word and present[marker] == true then return true end
  end
  return false
end

--- The modules whose source the pure store of the closure `names` keeps, sorted: those of each walk
--- ([`build.code_walk`]) that a module of `names` declares it reads, the walk taken over the whole projection's
--- imports as the identity takes it of the binary's, so a module a walk reaches by a type alone is kept though the
--- closure leaves it out. A module the walk reaches that the projection holds no source of is left out, as an absent
--- module is of the identity.
local function source_kept(basis: closure_store.Basis, names: {string}): {string}
  local seen: mut {string:boolean} = {}
  local out: mut {string} = {}
  for _, word in ipairs(CodeWalk.walks) do
    if declares(names, word) then
      local reached, _ = CodeWalk.reach(word, function(name: string): {string}?, string
        return basis.edges[name] or {}, ""
      end)
      for _, name in ipairs(reached or {}) do
        if seen[name] ~= true and (basis.sources[name] ~= nil or basis.decls[name] ~= nil) then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    end
  end
  table.sort(out)
  return out
end

--- The modules of `basis` the example module `name` could be paired
--- with by its name ([`build.writer`]'s `insert_examples`): each that it
--- is less `_example`, or that it starts with, followed by `_`. Which
--- of them is longest names the module its examples are about.
local function candidates(basis: closure_store.Basis, name: string): {string}
  local stem = name:sub(1, #name - #"_example")
  local out: mut {string} = {}
  for _, path in ipairs(basis.pairable) do
    if path == stem or String.starts_with(stem, path .. "_") then out[#out + 1] = path end
  end
  return out
end

--- Each line of a basis by its digest, kept for the life of the process: a
--- test and the examples share most of their modules with the others, and
--- an address digested the whole of each line it names, so the address
--- of every test module in the tree hashed each shared module again:
--- 0.12 s of a run's 0.27. A line's digest stands for it in an address, as
--- `basis.shared` stands for the meta rows: the address moves with any
--- byte of any line, and the memo is by the whole line.
local line_digests: mut {string:string} = {}

--- The hex SHA-256 of `line`, made once.
local function digest_of_line(line: string): string
  local digest = line_digests[line]
  if digest == nil then
    digest = Hash.hex_sha256(line)
    line_digests[line] = digest
  end
  return digest
end

--- The address of the closure store for `names` over `basis`: the
--- digest of everything its bytes follow from -- its modules' lines,
--- the modules each example module among them could be paired with
--- (`candidates`), its declarations' lines (`declared`), the basis's
--- shared digest, and `salt`, which names the code that writes it
--- ([`build.test`] passes a digest of this module's and build.schema's
--- sources and bytecode, and nothing of the projection's writer, whose
--- edits leave a store's bytes alone). An edit to a module or a
--- declaration outside the closure moves none of these, and neither
--- does adding or removing one, except a module an example of the
--- closure could be paired with. So neither the address nor the store
--- moves. The store holds no trace of its address (`write`), so two
--- addresses of the same rows -- an edit to the writer's comments, say
--- -- name stores of the same bytes, which a key holds alike.
---
--- With `own`, the address of the pure store ([`closure_store.write`]): the
--- digest of what that holds, which is each module's line of `basis.pure`
--- with its bytecode stripped of debug information -- `own`'s, the test's
--- module, with it -- and each declaration's, and the kept stubs. It moves
--- with a module's bytecode and what its rows say. A comment, blank line
--- or moved line moves it only in a module whose stub it keeps, as a
--- stub keeps each token at its line.
function closure_store.address(basis: closure_store.Basis, names: {string},
                               salt: string, own?: string): string
  if own ~= nil then
    local pure: mut {string} = { basis.shared, salt, "pure " .. own }
    for _, name in ipairs(text_kept(basis, names, basis.type_requires[own] or {})) do
      pure[#pure + 1] = digest_of_line("text " .. name .. " " .. assert(basis.texts[name], "a stored name has its text's digest"))
    end
    for _, name in ipairs(source_kept(basis, names)) do
      local held = basis.pure_decls[name] or assert(basis.sources[name], "a kept source has its digest")
      pure[#pure + 1] = digest_of_line("source " .. name .. " " .. held)
    end
    for _, name in ipairs(stored(basis, names)) do
      local held = if name == own then basis.bytecode[name] else basis.stripped[name] end
      pure[#pure + 1] = digest_of_line(assert(basis.pure[name], "a stored name has its pure line") ..
          "\t" .. assert(held, "a stored name has its bytecode's digest"))
    end
    for _, name in ipairs(declared(basis, names)) do
      pure[#pure + 1] = digest_of_line((assert(basis.pure_decls[name], "a declared name has its pure line")))
    end
    return Hash.hex_sha256(table.concat(pure, "\n"))
  end
  local lines: mut {string} = { basis.shared, salt }
  for _, name in ipairs(stored(basis, names)) do
    lines[#lines + 1] = digest_of_line((assert(basis.modules[name], "a stored name has its line")))
    if basis.kinds[name] == "example" then
      lines[#lines + 1] = "pairs " .. name .. " " .. table.concat(candidates(basis, name), " ")
    end
  end
  for _, name in ipairs(declared(basis, names)) do
    lines[#lines + 1] = digest_of_line((assert(basis.decls[name], "a declared name has its line")))
  end
  return Hash.hex_sha256(table.concat(lines, "\n"))
end

--- Fills a closure store's fresh schema from the projection attached
--- as `whole`, for the modules `temp.wanted` names: their rows, the
--- edges among them, the names they bind, their docs, uses and links
--- (those they make), catalog, stubs, and the examples of the example
--- files among them; the declarations `temp.declared` names
--- (`declared`), the names they bind, their docs and links; and of both,
--- every edge the checker follows (`decl_imports`), which
--- [`build.plans`] reads of a standard-library module on a sealed
--- database ([`build.test`]'s `sealed_fill`); and the `meta` rows `closure_meta` keeps. The zones, CA
--- roots, components and notices are left out: the core, [`cosmic.time`]
--- and [`build.bom`] read those from the tool's own database alone.
--- Each table's rows go in by what the address digests of them
--- ([`closure_store.basis`]): the docs, catalog and examples by module
--- (and file) first, then in the projection's order within one, which
--- the address digests; the projection's order across modules, which
--- the projection's writer decides and no digest holds, sets no id.
local function closed(uses_from: string): {string}
  return {
    "INSERT INTO main.meta SELECT * FROM whole.meta WHERE key IN " .. closure_meta ..
      " ORDER BY key",
    -- Every column but the key, which holds the compiler's identity: no
    -- worker reads a store's keys, and its address holds what the
    -- compiler made instead ([`Basis`]).
    "INSERT INTO main.modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
      "SELECT path, file, kind, source_hash, X'', bytecode, tests, source FROM whole.modules " ..
      "WHERE path IN temp.wanted ORDER BY path",
    "INSERT INTO main.imports SELECT * FROM whole.imports " ..
      "WHERE path IN temp.wanted AND requires IN temp.wanted ORDER BY path, requires",
    "INSERT INTO main.decl_imports SELECT * FROM whole.decl_imports " ..
      "WHERE path IN temp.wanted OR path IN temp.declared ORDER BY path, requires",
    "INSERT INTO main.bound SELECT * FROM whole.bound " ..
      "WHERE path IN temp.wanted OR path IN temp.declared ORDER BY path, name",
    "INSERT INTO main.decls SELECT * FROM whole.decls WHERE path IN temp.declared " ..
      "ORDER BY path",
    -- The stubs (build.stub) of its standard-library modules, which a
    -- checker run in the worker (teal.standard_text) reads as a
    -- project's does.
    "INSERT INTO main.stubs SELECT * FROM whole.stubs WHERE path IN temp.wanted ORDER BY path",
    -- Where its modules declare their types and members (`cosmic lsp` reads
    -- them of a sealed database too).
    "INSERT INTO main.places SELECT * FROM whole.places WHERE module IN temp.wanted " ..
      "ORDER BY module, ordinal",
    "INSERT INTO main.docs (module, symbol, source_symbol, exported, kind, signature, " ..
      "text, file, line) SELECT module, symbol, source_symbol, exported, kind, signature, " ..
      "text, file, line FROM whole.docs WHERE module IN temp.wanted " ..
      "OR module IN temp.declared ORDER BY module, id",
    -- `uses_from` names the table the rows come from: the projection's
    -- own, keyed by the referenced symbol first, or [`closure_store.extract`]'s,
    -- which a closure finds by source module without scanning the rest.
    "INSERT INTO main.uses SELECT * FROM " .. uses_from .. " WHERE from_module IN temp.wanted " ..
      "ORDER BY module, symbol, from_module, line",
    -- The links its modules and declarations make, as the uses: one from
    -- a Markdown, C or Zig file (from_module "") is no module's, so no
    -- closure's.
    "INSERT INTO main.links SELECT * FROM whole.links WHERE from_module IN temp.wanted " ..
      "OR from_module IN temp.declared " ..
      "ORDER BY module, symbol, path, anchor, from_file, line, column",
    "INSERT INTO main.examples (module, name, text, file, line, source) " ..
      "SELECT module, name, text, file, line, source FROM whole.examples " ..
      "WHERE file IN (SELECT file FROM whole.modules WHERE path IN temp.wanted) " ..
      "ORDER BY module, file, id",
    "INSERT INTO main.catalog (kind, module, symbol, message, text, file, line) " ..
      "SELECT kind, module, symbol, message, text, file, line FROM whole.catalog " ..
      "WHERE module IN temp.wanted ORDER BY module, id",
  }
end

--- What [`closed`] copies, less everything text-derived: a module's source
--- and source hash are left empty, and no doc, use, link, example, catalog
--- row, place or stub goes in, but for the stub of the modules in `temp.kept` ([`text_kept`]). The bytecode of the modules goes in as the
--- projection has it; [`closure_store.write`] strips the debug information
--- of all but the test's own.
local function closed_pure(): {string}
  return {
    "INSERT INTO main.meta SELECT * FROM whole.meta WHERE key IN " .. closure_meta ..
      " ORDER BY key",
    "INSERT INTO main.modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
      "SELECT path, file, kind, X'', X'', bytecode, tests, X'' FROM whole.modules " ..
      "WHERE path IN temp.wanted ORDER BY path",
    -- What the checker reads of a standard-library module ([`build.standard_text`]).
    "INSERT INTO main.stubs SELECT * FROM whole.stubs WHERE path IN temp.kept ORDER BY path",
    -- The modules whose source it keeps ([`source_kept`]) beside the closure's, with no bytecode where the closure
    -- leaves them out, so that requiring one finds a chunk that does not load and not a module that runs.
    "INSERT INTO main.modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
      "SELECT path, file, kind, source_hash, X'', X'', tests, source FROM whole.modules " ..
      "WHERE path IN temp.sourced AND path NOT IN temp.wanted ORDER BY path",
    "UPDATE main.modules SET source_hash = (SELECT w.source_hash FROM whole.modules w WHERE w.path = main.modules.path), " ..
      "source = (SELECT w.source FROM whole.modules w WHERE w.path = main.modules.path) " ..
      "WHERE path IN temp.sourced AND path IN temp.wanted",
    "INSERT INTO main.imports SELECT * FROM whole.imports " ..
      "WHERE (path IN temp.wanted OR path IN temp.sourced) AND (requires IN temp.wanted OR requires IN temp.sourced) " ..
      "ORDER BY path, requires",
    "INSERT INTO main.decl_imports SELECT * FROM whole.decl_imports " ..
      "WHERE path IN temp.wanted OR path IN temp.declared ORDER BY path, requires",
    "INSERT INTO main.bound SELECT * FROM whole.bound " ..
      "WHERE path IN temp.wanted OR path IN temp.declared ORDER BY path, name",
    "INSERT INTO main.decls SELECT * FROM whole.decls WHERE path IN temp.declared " ..
      "ORDER BY path",
    "INSERT OR IGNORE INTO main.decls SELECT * FROM whole.decls WHERE path IN temp.sourced ORDER BY path",
  }
end

--- Writes at `path` a database holding the projection's `uses` rows
--- keyed by the module that makes them, for [`closure_store.write`] to
--- find a closure's by that module: the projection's own table is keyed by
--- the symbol referred to, so each closure's selection scans every row.
--- It is an auxiliary of one run's extraction and not a store, so the
--- index costs no store or shipped database any bytes. A function of the
--- projection's rows alone; replaces a file already at `path`.
function closure_store.extract(whole: string, path: string): boolean, string
  local _, _ = Fs.remove(path)
  local opened, open_trouble = Sqlite.open(path, { writable = true, create = true })
  if opened == nil then return false, open_trouble end
  local db: Sqlite.Handle = opened
  local function fill(handle: Sqlite.Handle): boolean, string
    local attached, attach_trouble = Sqlite.run(handle, "ATTACH DATABASE ?1 AS whole",
      { text(whole) })
    if not attached then return false, attach_trouble end
    local statements = {
      "PRAGMA journal_mode = OFF",
      "PRAGMA synchronous = OFF",
      "CREATE TABLE main.uses (module TEXT NOT NULL, symbol TEXT NOT NULL, " ..
        "from_module TEXT NOT NULL, from_file TEXT NOT NULL, line INTEGER NOT NULL, " ..
        "PRIMARY KEY (from_module, module, symbol, line)) WITHOUT ROWID",
      "INSERT INTO main.uses (module, symbol, from_module, from_file, line) " ..
        "SELECT module, symbol, from_module, from_file, line FROM whole.uses",
      "DETACH whole",
    }
    for _, statement in ipairs(statements) do
      local ok, failure = handle:exec(statement)
      if not ok then return false, failure end
    end
    return true, ""
  end
  local ok, trouble = fill(db)
  local _, _ = db:close()
  if not ok then
    local _, _ = Fs.remove(path)
    return false, trouble
  end
  return true, ""
end

--- Flushes the file at `path` to the disk: `VACUUM INTO` leaves its
--- output unsynced, and a store cut short by a crash after its rename
--- would stand at its address for good.
local function sync(path: string): boolean, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then return false, path .. ": " .. trouble end
  local synced, sync_trouble = sys.fsync(fd)
  local _, _ = sys.close(fd)
  if not synced then return false, path .. ": " .. sync_trouble end
  return true, ""
end

--- Writes at `out` the closure store for `names` (see
--- [`closure_store.address`]) of the projection at `whole`, whose basis
--- is `basis`: what a sandboxed worker of a test whose module's import
--- closure `names` holds is given at o/cosmic.db in the projection's
--- place ([`build.test_sandbox`]), so an edit outside the closure leaves
--- it as it was. Like the projection, a function of its rows alone: a
--- fresh schema, filled in one order, vacuumed, naming neither its
--- address nor the code that wrote it, so a key holds it by its bytes
--- (build/closure_store_test.tl holds two writes of the same rows to
--- the same bytes); and synced before it is moved into place, since a
--- store is written once and read as it is from then on.
---
--- With `own`, the name of the test module the store is for, it is the
--- pure store instead: nothing in it moves with a comment, a blank line
--- or a moved line but the stubs it keeps, which keep each token at its
--- line. The modules' source and source hash are empty, the
--- stubs, places, docs, uses, links, examples and catalog tables hold no
--- rows, but for the stubs of the standard-library modules the test module names with
--- a top-level `local type _ = require(...)` ([`type_requires`]) and those their stubs require
--- ([`text_kept`]), which the address digests, and every module's bytecode but `own`'s is stripped of its debug
--- information, so a test that reads such a row finds none and fails, and
--- the store's bytes follow from [`closure_store.address`]'s pure address.
function closure_store.write(whole: string, out: string, names: {string},
                             basis: closure_store.Basis, extraction?: string,
                             own?: string): boolean, string
  local function fill(db: Sqlite.Handle): boolean, string
    local statements: mut {string} = {}
    for _, statement in ipairs(schema.settings("")) do statements[#statements + 1] = statement end
    for _, statement in ipairs(schema.create("")) do statements[#statements + 1] = statement end
    statements[#statements + 1] = "CREATE TEMP TABLE wanted (path TEXT PRIMARY KEY)"
    statements[#statements + 1] = "CREATE TEMP TABLE declared (path TEXT PRIMARY KEY)"
    statements[#statements + 1] = "CREATE TEMP TABLE kept (path TEXT PRIMARY KEY)"
    statements[#statements + 1] = "CREATE TEMP TABLE sourced (path TEXT PRIMARY KEY)"
    for _, statement in ipairs(statements) do
      local ok, failure = db:exec(statement)
      if not ok then return false, failure end
    end
    for _, name in ipairs(stored(basis, names)) do
      local ok, failure = Sqlite.run(db, "INSERT INTO temp.wanted (path) VALUES (?1)",
        { text(name) })
      if not ok then return false, failure end
    end
    for _, name in ipairs(declared(basis, names)) do
      local ok, failure = Sqlite.run(db, "INSERT INTO temp.declared (path) VALUES (?1)",
        { text(name) })
      if not ok then return false, failure end
    end
    if own ~= nil then
      for _, name in ipairs(text_kept(basis, names, basis.type_requires[own] or {})) do
        local ok, failure = Sqlite.run(db, "INSERT INTO temp.kept (path) VALUES (?1)", { text(name) })
        if not ok then return false, failure end
      end
      for _, name in ipairs(source_kept(basis, names)) do
        local ok, failure = Sqlite.run(db, "INSERT INTO temp.sourced (path) VALUES (?1)", { text(name) })
        if not ok then return false, failure end
      end
    end
    local attached, attach_trouble = Sqlite.run(db, "ATTACH DATABASE ?1 AS whole",
      { text(whole) })
    if not attached then return false, attach_trouble end
    local uses_from = "whole.uses"
    if extraction ~= nil and own == nil then
      local extracted, extract_trouble = Sqlite.run(db, "ATTACH DATABASE ?1 AS extracted",
        { text(extraction) })
      if not extracted then
        local _, _ = db:exec("DETACH whole")
        return false, extract_trouble
      end
      uses_from = "extracted.uses"
    end
    local made, refused = Sqlite.transact(db, function(): boolean, string
      for _, statement in ipairs(if own ~= nil then closed_pure() else closed(uses_from) end) do
        local ok, failure = db:exec(statement)
        if not ok then return false, failure end
      end
      for _, statement in ipairs(schema.rebuild("main.")) do
        local ok, failure = db:exec(statement)
        if not ok then return false, failure end
      end
      if own ~= nil then
        local held, held_trouble = Sqlite.rows(db,
          "SELECT path, inflate(bytecode) FROM main.modules WHERE path <> ?1 AND path IN temp.wanted", { text(own) })
        if held == nil then return false, held_trouble end
        for _, row in ipairs(held) do
          local stripped, why = lua_tail.stripped(row:blob(2), row:text(1))
          if stripped == nil then return false, why end
          local ok, failure = Sqlite.run(db, "UPDATE main.modules SET bytecode = deflate(?1) WHERE path = ?2",
            { { blob = stripped }, text(row:text(1)) })
          if not ok then return false, failure end
        end
      end
      return true, ""
    end)
    local _, _ = db:exec("DETACH whole")
    if extraction ~= nil and own == nil then local _, _ = db:exec("DETACH extracted") end
    if not made then return false, refused end
    -- Written aside under `out`'s one fixed `.building` name, which no
    -- other run writes or sweeps meanwhile: only `cosmic test` writes a
    -- checkout's stores, and one run of it at a time holds the
    -- checkout's rebuild lock (build.rebuild_lock), so a `.building`
    -- that build.test's `sweep_stores` finds is one cut short.
    local _, _ = Fs.remove(out .. ".building")
    local vacuumed, vacuum_trouble = Sqlite.run(db, "VACUUM INTO ?1", { text(out .. ".building") })
    if not vacuumed then return false, vacuum_trouble end
    local synced, sync_trouble = sync(out .. ".building")
    if not synced then return false, sync_trouble end
    return Fs.rename(out .. ".building", out)
  end
  local db, open_trouble = Sqlite.memory()
  if db == nil then return false, open_trouble end
  local ok, trouble = fill(db)
  local _, _ = db:close()
  if not ok then return false, trouble end
  return true, ""
end

return closure_store
