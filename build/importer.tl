--- The staged tree, read by position into modules.
---
--- A source's path relative to the root is its import path, so nothing
--- lists what a module is: `cosmic/fs.tl` is `cosmic.fs`. A `*.d.tl`
--- declares a module the core provides and holds no code, so it is read
--- for its type and never stored.
---
--- Nothing here reads a path: `build.work` has already staged every
--- input into the working database, and the tree is the rows of its
--- `files` table. What a build derives from those rows -- the import
--- path and kind each file's position gives it, the test module a doc
--- guide extracts to, the declaration the syscall header generates
--- to, and what one parse of each source finds -- is written back as
--- rows too, each keyed so it is redone only when what it came from
--- changed, and the modules to compile are a query over them.
---
--- A module's key is the content hash of its source, the keys of
--- everything it imports, and the hash of the tool that compiled it. An
--- unchanged key is a stat; a changed one recompiles what depended on
--- it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local ast = require("build.ast")
local doctest = require("build.doctest")
local gen_syscalls = require("build.gen_syscalls")
local positions = require("build.positions")
local work = require("build.work")
local type compiler = require("build.compiler")

local type Module = positions.Module

local record importer
  Module: Module

  record Result
    modules: {Module}
    boot_hash: string
    main: string | nil
    -- One message per `kind = "test"` module refused compilation
    -- because it both defines its own tests and returns its own value;
    -- every module NOT in this list compiled and is in `modules`.
    refused: {string}
  end
end

--- Whether `root` is cosmic's own tree, structurally: `core/` and
--- `build/` both exist, and `build/` holds the importer itself rather
--- than just a directory of that name. `cosmic.*` is reserved to this
--- one tree; nothing else may claim it, by directory or by import path.
--- Exposed so a caller can gate other cosmic's-own-tree behavior on the
--- same test the importer itself uses.
function importer.is_own_tree(root: string): boolean
  return Fs.is_dir(root .. "/core") and Fs.is_dir(root .. "/build") and
    Fs.exists(root .. "/build/importer.tl") and
    not Fs.is_dir(root .. "/build/importer.tl")
end

--- The bytecode header every target must agree on. One column of
--- bytecode serves all three because they are all little-endian and
--- 64-bit; this is what says so out loud, so a target whose sizes or
--- byte order differ fails the build rather than a launch.
---
--- The bytes are the signature, the version and format, the data check,
--- and the size and value of an int, an instruction, an integer and a
--- number.
local bytecode_header =
  "\27LuaU\0\25\147\13\10\26\10" ..
  "\4\136\169\255\255" ..
  "\4\120\86\52\18" ..
  "\8\136\169\255\255\255\255\255\255" ..
  "\8\0\0\0\0\0\40\119\192"

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- A staged file's import path, as its position says: `cosmic/fs.tl`
--- is `cosmic.fs`, `build/ast/init.tl` is `build.ast`, and
--- `cosmic/internal/store.d.tl` is `cosmic.internal.store`.
local import_path_sql = [[
  replace(CASE WHEN path GLOB '*.d.tl' THEN substr(path, 1, length(path) - 5)
               WHEN path GLOB '*/init.tl' THEN substr(path, 1, length(path) - 8)
               ELSE substr(path, 1, length(path) - 3) END, '/', '.')]]

--- A staged file's kind, as its name says: a declaration holds no
--- code, `*_test.tl` is a test, `*_example.tl` an example, and
--- `cmd/<name>/main.tl` a binary's entry.
local kind_sql = [[
  CASE WHEN path GLOB '*.d.tl' THEN 'decl'
       WHEN path GLOB '*_test.tl' THEN 'test'
       WHEN path GLOB '*_example.tl' THEN 'example'
       WHEN path GLOB 'cmd/*/main.tl' AND path NOT GLOB 'cmd/*/*/*' THEN 'main'
       ELSE 'module' END]]

--- A doc guide's import path, the same dotted-name convention every
--- `.tl` file gets: `doc/guides/quickstart.md` compiles as
--- `doc.guides.quickstart`.
local function import_path_of_doc(file: string): string
  return (file:gsub("%.md$", ""):gsub("/", "."))
end

local insert_input =
  "INSERT INTO inputs (file, path, kind, origin, from_hash, source, " ..
  "source_hash) VALUES (?1, ?2, ?3, ?4, ?5, ?6, lower(hex(sha256(?6))))"

--- The doc guides with no current `inputs` row, each extracted into
--- the test module it is.
local function derive_doc_guides(db: Sqlite.Handle): boolean, string
  local guides, trouble = Sqlite.rows(db,
    "SELECT path, data, sha256 FROM files " ..
    "WHERE path GLOB 'doc/guides/*.md' AND path NOT GLOB 'doc/guides/*/*' " ..
    "AND path NOT IN (SELECT file FROM inputs) ORDER BY path")
  if guides == nil then
    return false, trouble
  end
  for _, row in ipairs(guides) do
    local file, doc_source, from_hash = row[1], row[2], row[3]
    local source, extract_trouble = doctest.extract(doc_source, file)
    if source == nil then
      return false, file .. ": " .. extract_trouble
    end
    local ok, insert_trouble = Sqlite.run(db, insert_input,
      { text(file), text(import_path_of_doc(file)), text("test"),
        text("doctest"), text(from_hash), text(source) })
    if not ok then
      return false, file .. ": " .. insert_trouble
    end
  end
  return true, ""
end

--- The syscall table's declaration, generated from its header when the
--- header has no current `inputs` row. Only cosmic's own tree has the
--- header; a project gets the declaration from the binary.
local function derive_syscalls(db: Sqlite.Handle): boolean, string
  local headers, trouble = Sqlite.rows(db,
    "SELECT data, sha256 FROM files WHERE path = 'core/syscalls.h' " ..
    "AND path NOT IN (SELECT file FROM inputs)")
  if headers == nil then
    return false, trouble
  end
  if #headers == 0 then
    return true, ""
  end
  local header, from_hash = headers[1][1], headers[1][2]
  local source, generate_trouble = gen_syscalls.declaration(header)
  if source == nil then
    return false, "core/syscalls.h: " .. generate_trouble
  end
  return Sqlite.run(db, insert_input,
    { text("core/syscalls.h"), text("cosmic.sys"), text("decl"),
      text("syscalls"), text(from_hash), text(source) })
end

--- Two files that would answer to one import path. The build refuses
--- rather than letting one shadow the other.
local function duplicate_import_paths(db: Sqlite.Handle): boolean, string
  local doubled, trouble = Sqlite.rows(db,
    "SELECT path, group_concat(file, ' and ') FROM inputs " ..
    "WHERE kind <> 'decl' GROUP BY path HAVING count(*) > 1 ORDER BY path")
  if doubled == nil then
    return false, trouble
  end
  if #doubled > 0 then
    return false, doubled[1][2] .. " both compile to import path '" ..
      doubled[1][1] .. "'; rename one"
  end
  return true, ""
end

--- One parse of every source no parse has seen: what it requires, in
--- order, the tests it defines, and whether it returns its own value.
--- Structural, over the real AST, never a regex over text: a
--- `require("cosmic.foo")` inside a string literal or a comment is not
--- an import. `all_requires`, not the narrower alias-resolving
--- `requires`, because a type-only `local type compiler =
--- require("build.compiler")` and a conditional re-assignment inside an
--- `if` are both real dependencies the build order must see.
local function parse_new(db: Sqlite.Handle, built: compiler): boolean, string
  local fresh, trouble = Sqlite.rows(db,
    "SELECT source_hash, min(file), source FROM inputs " ..
    "WHERE kind NOT IN ('decl', 'vendor') " ..
    "AND source_hash NOT IN (SELECT source_hash FROM parsed) " ..
    "GROUP BY source_hash ORDER BY source_hash")
  if fresh == nil then
    return false, trouble
  end
  for _, row in ipairs(fresh) do
    local source_hash, file, source = row[1], row[2], row[3]
    local parsed, parse_trouble = ast.parse(built, source, file)
    if parsed == nil then
      return false, file .. ": " .. parse_trouble
    end
    local requires, requires_trouble = ast.all_requires(built, parsed)
    if requires == nil then
      return false, file .. ": " .. requires_trouble
    end
    local found = positions.analysis_of(parsed)
    local ok, why = Sqlite.run(db,
      "INSERT INTO parsed (source_hash, has_return) VALUES (?1, ?2)",
      { text(source_hash), { integer = found.has_top_level_return and 1 or 0 } })
    if not ok then
      return false, file .. ": " .. why
    end
    for ordinal, name in ipairs(requires) do
      ok, why = Sqlite.run(db,
        "INSERT INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
        { text(source_hash), { integer = ordinal }, text(name) })
      if not ok then
        return false, file .. ": " .. why
      end
    end
    for ordinal, name in ipairs(found.tests) do
      ok, why = Sqlite.run(db,
        "INSERT INTO tests (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
        { text(source_hash), { integer = ordinal }, text(name) })
      if not ok then
        return false, file .. ": " .. why
      end
    end
  end
  return true, ""
end

--- Brings `inputs` and the parse tables up to the staged tree, in one
--- transaction: a row whose file changed or vanished goes, a file with
--- no row gets one, and only what is new is extracted, generated, or
--- parsed. The compiler's row has no file and is Lua, so it is neither
--- dropped nor parsed here; `build.writer` carries it. What no input refers to any more is dropped, so the tables
--- describe this tree and nothing older.
--- @param self_tree whether the tree is cosmic's own, where the
---   `cosmic.` namespace is not reserved against the tree itself
--- @param built the compiler, loaded and ready
local function derive(handle: work.Handle, self_tree: boolean,
                      built: compiler): boolean, string
  local db = handle.db
  if not self_tree then
    if Fs.is_dir(handle.root .. "/cosmic") then
      return false, "cosmic: the 'cosmic' directory is reserved to cosmic's own tree"
    end
    local claimed, trouble = Sqlite.rows(db,
      "SELECT path FROM files WHERE path GLOB 'cosmic/*' ORDER BY path LIMIT 1")
    if claimed == nil then
      return false, trouble
    end
    if #claimed > 0 then
      return false, claimed[1][1] .. ": the 'cosmic' directory is reserved to " ..
        "cosmic's own tree"
    end
  end

  return Sqlite.transact(db, function(): boolean, string
    local statements: {string} = {
      "DELETE FROM inputs WHERE origin <> 'vendor' AND NOT EXISTS " ..
      "(SELECT 1 FROM files f WHERE f.path = inputs.file " ..
      "AND f.sha256 = inputs.from_hash)",
      "INSERT INTO inputs (file, path, kind, origin, from_hash, source, " ..
      "source_hash) SELECT path, " .. import_path_sql .. ", " .. kind_sql ..
      ", 'tree', sha256, CAST(data AS TEXT), sha256 FROM files " ..
      "WHERE path GLOB '*.tl' AND path NOT IN (SELECT file FROM inputs)",
    }
    for _, statement in ipairs(statements) do
      local ok, trouble = db:exec(statement)
      if not ok then
        return false, trouble
      end
    end
    local steps = { derive_doc_guides, derive_syscalls, duplicate_import_paths }
    for _, step in ipairs(steps) do
      local ok, trouble = step(db)
      if not ok then
        return false, trouble
      end
    end
    local parsed, parse_trouble = parse_new(db, built)
    if not parsed then
      return false, parse_trouble
    end
    for _, table_name in ipairs({ "parsed", "requires", "tests" }) do
      local ok, trouble = db:exec("DELETE FROM " .. table_name ..
        " WHERE source_hash NOT IN (SELECT source_hash FROM inputs)")
      if not ok then
        return false, trouble
      end
    end
    return true, ""
  end)
end

--- Every name a table keyed by source hash lists, in order, by hash.
local function names_by_hash(db: Sqlite.Handle,
                             table_name: string): {string:{string}} | nil, string
  local rows, trouble = Sqlite.rows(db,
    "SELECT source_hash, name FROM " .. table_name ..
    " ORDER BY source_hash, ordinal")
  if rows == nil then
    return nil, trouble
  end
  local out: {string:{string}} = {}
  for _, row in ipairs(rows) do
    local list = out[row[1]]
    if list == nil then
      list = {}
      out[row[1]] = list
    end
    list[#list + 1] = row[2]
  end
  return out
end

--- Every module the derived tree holds, with what its parse found.
local function collect(handle: work.Handle, self_tree: boolean,
                       built: compiler): {Module} | nil, string
  local derived, derive_trouble = derive(handle, self_tree, built)
  if not derived then
    return nil, derive_trouble
  end
  local db = handle.db
  local rows, trouble = Sqlite.rows(db,
    "SELECT i.path, i.file, i.kind, i.origin, i.source, i.source_hash, " ..
    "p.has_return FROM inputs i JOIN parsed p ON p.source_hash = i.source_hash " ..
    "WHERE i.kind NOT IN ('decl', 'vendor') ORDER BY i.path")
  if rows == nil then
    return nil, trouble
  end
  local requires, requires_trouble = names_by_hash(db, "requires")
  if requires == nil then
    return nil, requires_trouble
  end
  local tests, tests_trouble = names_by_hash(db, "tests")
  if tests == nil then
    return nil, tests_trouble
  end
  local out: {Module} = {}
  for _, row in ipairs(rows) do
    local path, file, kind, origin = row[1], row[2], row[3], row[4]
    local source, source_hash, has_return = row[5], row[6], row[7]
    out[#out + 1] = {
      path = path,
      file = file,
      kind = kind,
      source = source,
      source_hash = source_hash,
      requires = requires[source_hash] or {},
      tests = kind == "test" and (tests[source_hash] or {}) or {},
      has_top_level_return = has_return == "1",
      generated = origin == "doctest",
      key = "",
      lua = "",
      bytecode = "",
    }
  end
  return out
end

--- The modules in an order where nothing is compiled before what it
--- imports. A cycle is reported rather than looped on.
local function ordered(modules: {Module}): {Module} | nil, string
  local by_path: {string:Module} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
  end

  local out: {Module} = {}
  local state: {string:string} = {}

  local visit: function(Module): boolean, string
  visit = function(m: Module): boolean, string
    if state[m.path] == "done" then
      return true, ""
    end
    if state[m.path] == "visiting" then
      return false, "a cycle of imports reaches " .. m.path
    end
    state[m.path] = "visiting"
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local ok, trouble = visit(other)
        if not ok then
          return false, trouble
        end
      end
    end
    state[m.path] = "done"
    out[#out + 1] = m
    return true, ""
  end

  for _, m in ipairs(modules) do
    local ok, trouble = visit(m)
    if not ok then
      return nil, trouble
    end
  end
  return out
end

--- Appends a generated `return` to compiled Lua for a test module, so a
--- `local function test_*` -- otherwise unreachable from outside the
--- file it is declared in -- comes back on the table `require` gives
--- the runner. The Teal source the test's author wrote is never
--- touched; only the compiled Lua this module already owns is.
local function with_test_tail(code: string, tests: {string}): string
  if #tests == 0 then
    return code
  end
  local fields: {string} = {}
  for _, name in ipairs(tests) do
    fields[#fields + 1] = name .. " = " .. name
  end
  return code .. "\nreturn { " .. table.concat(fields, ", ") .. " }\n"
end

--- A `local function test_*` at a test module's top level is only ever
--- called by the runner, from outside the file, so the checker's
--- "unused function" warning about it is a false positive: it is
--- narrow enough to name the exact function discovery already found,
--- rather than turning the warning off for the whole file.
local function discount_test_warnings(result: compiler.Result,
                                      tests: {string}): compiler.Result
  local names: {string:boolean} = {}
  for _, name in ipairs(tests) do
    names[name] = true
  end
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    local unused = w.msg:match("^unused function ([%w_]+):")
    if unused == nil or not names[unused] then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- The one warning tl's checker always raises over a `build.doctest`
--- generated module: a generated example that declares an `output`
--- block shadows the global `print` with a local of the same name, on
--- purpose, so a doc's own verbatim `print(...)` calls run against the
--- capturing one instead -- print is declared `<const>` in tl's own
--- prelude, so reassigning the global outright is a hard type error,
--- and a local is the only way left to intercept a call the doc's own
--- source spells as a bare, unqualified `print`. This is narrower than
--- `discount_test_warnings` above in what it drops, but wider in who it
--- applies to: any module `m.generated` marks, not only the specific
--- function names a scan of `m` already found.
local function discount_doctest_shadow_warnings(result: compiler.Result): compiler.Result
  local kept: {compiler.Error} = {}
  for _, w in ipairs(result.warnings) do
    if w.msg ~= "variable shadows previous declaration of 'print'" then
      kept[#kept + 1] = w
    end
  end
  result.warnings = kept
  return result
end

--- Whether `m`'s own source both defines tests of its own and returns
--- its own value at the top level. `with_test_tail` appends a generated
--- `return` after the module's compiled Lua, and Lua allows only one
--- `return` as a block's last statement, so the two together always
--- produce a parse error the moment both are true. `collect` already
--- read both facts off one parse of `m.source`, so this only reads
--- what `m` itself carries -- never a second parse of the same source.
local function collides_with_test_tail(m: Module): boolean
  return #m.tests > 0 and m.has_top_level_return
end

local function complain(file: string, result: compiler.Result): string
  local lines: {string} = {}
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group or {}) do
      local where = e.filename ~= "" and e.filename or file
      lines[#lines + 1] = where .. ":" .. e.y .. ":" .. e.x .. ": " .. e.msg
    end
  end
  return table.concat(lines, "\n")
end

--- Compiles every module, in import order, into Lua and bytecode.
--- @param handle the working database the tree is staged in
--- @param built the compiler, loaded and ready
--- @param env the checker's environment, already pointed at the tree
--- @param boot_hash what the tool doing the compiling hashes to
function importer.compile(handle: work.Handle, built: compiler,
                          env: compiler.Env,
                          boot_hash: string): importer.Result | nil, string
  local modules, trouble =
    collect(handle, importer.is_own_tree(handle.root), built)
  if modules == nil then
    return nil, trouble
  end
  local positioned, position_trouble = positions.check(modules)
  if not positioned then
    return nil, position_trouble
  end
  local order, why = ordered(modules)
  if order == nil then
    return nil, why
  end
  local keys: {string:string} = {}
  local main: string | nil = nil
  local compiled: {Module} = {}
  local refused: {string} = {}

  for _, m in ipairs(order) do
    local closure: {string} = {}
    for _, name in ipairs(m.requires) do
      if keys[name] ~= nil then
        closure[#closure + 1] = name .. " " .. keys[name]
      end
    end
    table.sort(closure)
    m.key = Hash.hex_sha256(
      m.source_hash .. "\n" .. table.concat(closure, "\n") .. "\n" .. boot_hash)
    keys[m.path] = m.key

    local colliding = m.kind == "test" and collides_with_test_tail(m)
    if colliding then
      -- Refused on its own, narrowly: every other module still
      -- compiles below, unaffected. Compiling this one anyway would
      -- only surface as `<eof> expected near 'return'` once
      -- `with_test_tail` appends its own generated return after this
      -- file's, a Lua parse error naming neither the file nor the
      -- cause.
      refused[#refused + 1] = m.file .. ": a test file may not both " ..
        "define test_* functions and return its own value; remove the " ..
        "top-level return so the generated tail can hand the runner " ..
        "its tests"
    else
      local code, result = built.gen(m.source, env, nil, "tl")
      if m.kind == "test" and result ~= nil then
        result = discount_test_warnings(result, m.tests)
      end
      if m.generated and result ~= nil then
        result = discount_doctest_shadow_warnings(result)
      end
      local complaint = result ~= nil and complain(m.file, result) or ""
      if code == nil or complaint ~= "" then
        return nil, m.file .. ": the compiler refused it\n" .. complaint
      end
      -- The checker has just seen this module whole; a module compiled
      -- after it that requires it is checked against that, rather than
      -- against a second read and check of the same source.
      env.modules[m.path] = result.type
      env.module_filenames[m.path] = handle.root .. "/" .. m.file
      if m.kind == "test" then
        code = with_test_tail(code, m.tests)
      end
      m.lua = code

      local chunk, load_trouble = load(code, "@" .. m.path, "t")
      if chunk == nil then
        return nil, m.file .. ": " .. tostring(load_trouble)
      end
      m.bytecode = string.dump(chunk, false)
      if m.bytecode:sub(1, #bytecode_header) ~= bytecode_header then
        return nil, m.file .. ": this host dumps bytecode the three " ..
          "targets do not share"
      end

      if m.kind == "main" then
        main = m.path
      end
      compiled[#compiled + 1] = m
    end
  end

  return { modules = compiled, boot_hash = boot_hash, main = main,
           refused = refused }
end

return importer
