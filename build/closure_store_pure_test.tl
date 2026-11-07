--- Tests for the pure closure store ([`build.closure_store`]'s `write` with
--- `own`): the store of a test's import closure that holds nothing a
--- comment, a blank line or a moved line moves, so a test that is given it
--- stands when a module it imports is edited in one of those ways and runs
--- again when the edit changes what the module does.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Sqlite = require("cosmic.sqlite")
local closure_store = require("build.closure_store")
local importer = require("build.importer")
local lua_tail = require("build.lua_tail")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local stub = require("build.syntax_stub")
local symbols = require("build.symbols")
local errors = require("cosmic.errors")
local work = require("build.work")
local writer = require("build.writer")
local support = require("build.test_support_fixture")

-- A fixture below names [`cosmic.zip`] and [`cosmic.tar`], which the checker types from the store's text.
local type _zip = require("cosmic.zip")
local type _tar = require("cosmic.tar")

-- Compiling a project reads the text of the checker's own modules, and the subject is the text of a store.
Test.policy{ store_text = true }

--- The module `greet`, which `body` is the code of, with `note` above it.
local function greet(root: string, note: string, body: string)
  assert(Fs.write(root .. "/greet.tl", table.concat({
    "local record greet",
    "end",
    note,
    "function greet.hello(): string",
    "  " .. body,
    "end",
    "return greet",
    "",
  }, "\n")))
end

--- Compiles the project at `root`, `greet_test` the test of `greet`, and
--- writes its projection to `out`.
local function project(root: string, out: string, header?: string)
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    header or "-- the test",
    'local greet = require("greet")',
    "local function test_hello()",
    '  assert(greet.hello() ~= "")',
    "end",
    "",
  }, "\n")))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "closure-store-pure-test"))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
end

local names <const> = { "greet", "greet_test" }

--- The pure address and the plain one of the closure of `greet_test`, and
--- its pure store's bytes, for the project at `root` as it is.
local function made(root: string, tmp: string, name: string, header?: string): string, string, string
  project(root, tmp .. "/whole.db", header)
  local basis = assert(closure_store.basis(tmp .. "/whole.db", true))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/" .. name .. ".db", names, basis, nil, "greet_test"))
  local bytes = assert(Fs.read(tmp .. "/" .. name .. ".db"))
  return closure_store.address(basis, names, "salt", "greet_test"), closure_store.address(basis, names, "salt"), bytes
end

--- A comment, a blank line or a moved line in an imported module leaves the
--- pure address and the pure store's bytes as they were, which the plain
--- address does not; an edit to what it does moves both, and so does an
--- edit to the test's own module, whose bytecode keeps its debug
--- information.
local function test_a_pure_store_moves_with_what_a_module_does_and_not_with_its_text(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  greet(root, "", 'local said = "hello"\n  return said')
  local pure, plain, bytes = made(root, tmp, "first")
  greet(root, "-- Greets.\n\n-- Said twice.", 'local said = "hello"\n  return said')
  local noted, plain_noted, noted_bytes = made(root, tmp, "noted")
  assert(plain_noted ~= plain, "the plain address did not move with a comment, so this shows nothing " .. plain .. " " .. assert(Fs.read(root .. "/greet.tl")))
  assert(noted == pure, "a comment and blank lines in an imported module moved the pure address")
  assert(noted_bytes == bytes, "a comment and blank lines in an imported module moved the pure store")
  greet(root, "", 'local spoken = "hello"\n  return spoken')
  local renamed = made(root, tmp, "renamed")
  assert(renamed == pure, "renaming a local moved the pure address")
  greet(root, "", 'local said = "hello, world"\n  return said')
  local changed, _, changed_bytes = made(root, tmp, "changed")
  assert(changed ~= pure, "a constant of an imported module did not move the pure address")
  assert(changed_bytes ~= bytes)
  greet(root, "", 'local said = "hello"\n  return said')
  local again = made(root, tmp, "again")
  assert(again == pure)
  local own, _, own_bytes = made(root, tmp, "own", "-- the test\n-- said otherwise")
  assert(own ~= pure and own_bytes ~= bytes,
    "a comment in the test's own module, whose debug information its store keeps, moved nothing")
end

--- The pure store holds none of the text-derived rows: a module's source
--- and source hash are empty, the tables the docs, uses, links, examples,
--- catalog, stubs and places come from hold no row, a test that reads one
--- finds none and fails rather than stands on it, an imported module's
--- bytecode is stripped and numbered by instruction ([`lua_tail.numbered`]), and the test's own is as the build
--- made it.
local function test_a_pure_store_holds_no_text(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  greet(root, "--- Greets.", 'return "hello"')
  project(root, tmp .. "/whole.db")
  local whole = assert(Sqlite.open(tmp .. "/whole.db", { writable = true }))
  assert(whole:exec("INSERT INTO docs (module, symbol, source_symbol, exported, kind, " ..
      "signature, text, file, line) VALUES ('greet', 'greet.wave', 'greet.wave', 1, " ..
      "'function', 'function(): string', 'Waves at the world.', 'greet.tl', 2); " ..
      "INSERT INTO uses (module, symbol, from_module, from_file, line) VALUES " ..
      "('greet', 'hello', 'greet_test', 'greet_test.tl', 99); " ..
      "INSERT INTO catalog (kind, module, symbol, message, text, file, line) VALUES " ..
      "('error', 'greet', 'greet.hello', 'no world', 'Raised.', 'greet.tl', 4); " ..
      "INSERT INTO examples (module, name, text, file, line, source) VALUES " ..
      "('greet', 'hello', 'Greets.', 'greet.tl', 5, 'print(greet.hello())')"))
  assert(whole:close())
  local basis = assert(closure_store.basis(tmp .. "/whole.db", true))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/pure.db", names, basis, nil, "greet_test"))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/full.db", names, basis))
  local function count(db: Sqlite.Handle, query: string): string
    return support.nth(assert(Sqlite.text_rows(db, query)), 1):text(1)
  end
  local full = assert(Sqlite.open(tmp .. "/full.db"))
  assert(count(full, "SELECT count(*) FROM docs") ~= "0", "the plain store has no docs, so this shows nothing")
  assert(count(full, "SELECT count(*) FROM modules WHERE length(source) > 0") == "2")
  local pure = assert(Sqlite.open(tmp .. "/pure.db"))
  for _, table_name in ipairs({ "docs", "uses", "links", "examples", "catalog", "places", "docs_fts", "examples_fts",
      "catalog_fts" }) do
    local rows, why = Sqlite.text_rows(pure, "SELECT count(*) FROM " .. table_name)
    assert(rows == nil and why:find("no such table", 1, true) ~= nil,
      table_name .. " is in the pure store, where a query of it answers nothing and does not fail")
  end
  assert(count(pure, "SELECT count(*) FROM stubs") == "0", "the stubs a test names are the only ones kept")
  assert(count(pure, "SELECT count(*) FROM meta WHERE key = 'pure_store'") == "1", "the store does not say it is pure")
  assert(count(pure, "SELECT count(*) FROM modules WHERE length(source) > 0 OR length(source_hash) > 0") == "0",
    "the pure store holds a module's source")
  assert(count(pure, "SELECT count(*) FROM modules") == "2")
  assert(count(pure, "SELECT count(*) FROM imports") == "1", "the edges a require follows are kept")
  local function bytecode(db: Sqlite.Handle, path: string): string
    local rows = assert(Sqlite.rows(db, "SELECT inflate(bytecode) FROM modules WHERE path = ?1", { { text = path } }))
    return support.nth(rows, 1):blob(1)
  end
  local imported = bytecode(full, "greet")
  assert(bytecode(pure, "greet") == assert(lua_tail.numbered(imported, "greet")),
    "an imported module's bytecode is not stripped of its debug information and numbered by instruction")
  assert(bytecode(pure, "greet") ~= imported, "the build's bytecode carried no debug information, so this shows nothing")
  assert(bytecode(pure, "greet_test") == bytecode(full, "greet_test"), "the test's own bytecode was stripped")
  -- A hint asked of the pure store raises, and of the full one answers: no match is not an answer of a store without the table.
  local ok, why = pcall(symbols.named, { pure }, { false }, "wave")
  assert(not ok and tostring(why):find("withheld", 1, true) ~= nil, "a hint of a pure store was answered with no match")
  local no_example, no_example_why = pcall(symbols.has_example_query, { pure }, { false }, "hello")
  assert(not no_example and tostring(no_example_why):find("withheld", 1, true) ~= nil,
    "an example query of a pure store was answered with no example")
  local no_guidance, no_guidance_why = pcall(errors.guidance_in, pure, "the file could not be opened for reading here")
  assert(not no_guidance and tostring(no_guidance_why):find("withheld", 1, true) ~= nil,
    "a lookup of guidance in a pure store was answered with none")
  -- The full store answers (with no guidance, or some) and does not raise.
  local _ = errors.guidance_in(full, "the file could not be opened for reading here")
  local found = symbols.named({ full }, { false }, "wave")
  assert(#found == 1 and found[1] == "greet.wave", "the full store answered " .. table.concat(found, " "))
  assert(full:close())
  assert(pure:close())
end

--- How the project of `texted` differs from its default: a comment `lined[name]` on a line of its own above the
--- module, one `trailed[name]` at the end of its first line, and the type `declared[name]` its function returns.
local record Edits
  lined: {string:string}
  trailed: {string:string}
  declared: {string:string}
end

--- A project of a test, `greet_test`, that requires `greet` and `other`, `greet` requiring `leaf`, and the projection of it at `out`, in which each module has the stub the build makes of a module of
--- the standard library ([`build.syntax_stub`]'s `made`), which keeps every token where its source has it.
local function texted(root: string, out: string, edits: Edits)
  assert(Fs.mkdirs(root))
  local stubs: mut {string:string} = {}
  local function module(name: string, requires: string, record_body: string, result: string, value: string)
    local file = name .. ".tl"
    local declared = edits.declared[name] or result
    local lines: mut {string} = {}
    local note = edits.lined[name]
    if note ~= nil then lines[1] = note end
    for _, line in ipairs({
        "local record " .. name .. (edits.trailed[name] or ""),
        record_body,
        "end",
        requires,
        "function " .. name .. ".value(): " .. declared,
        "  return " .. (if declared == "integer" then "1" else value end),
        "end",
        "return " .. name,
        "",
    }) do lines[#lines + 1] = line end
    local text = table.concat(lines, "\n")
    assert(Fs.write(root .. "/" .. file, text))
    local parsed = Parser.parse(Lexer.lex(text, file), file, "tl")
    assert(#parsed.errors == 0)
    stubs[name] = stub.made(parsed.chunk).text
  end
  module("leaf", "", "  record Box\n    n: integer\n  end", "string", '"leaf"')
  module("greet", 'local leaf = require("leaf")', "", "leaf.Box", "{ n = 1 }")
  module("other", "", "", "string", '"other"')
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    'local other = require("other")',
    "local function test_hello()",
    "  assert(greet.value() ~= nil and other.value() ~= \"\")",
    "end",
    "",
  }, "\n")))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "closure-store-pure-test"))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
  local whole = assert(Sqlite.open(out, { writable = true }))
  for name, text in pairs(stubs) do
    assert(Sqlite.run(whole, "INSERT OR REPLACE INTO stubs (path, source) VALUES (?1, deflate(?2))",
      { { text = name }, { text = text } }))
  end
  assert(whole:close())
end

local texted_names <const> = { "greet", "leaf", "other", "greet_test" }

--- The pure address and the pure store's path for `texted_names` of the project at `root` as `edits` leave it,
--- where the test names `greet` as it would a module of the standard library it type-checks if `named`.
local function texted_store(root: string, tmp: string, name: string, edits: Edits, named: boolean): string, string
  texted(root, tmp .. "/" .. name .. ".whole.db", edits)
  local basis = assert(closure_store.basis(tmp .. "/" .. name .. ".whole.db", true))
  -- A project holds no `cosmic.*` module (the directory is reserved to the tool's own tree), so what a test names
  -- with a `local type _ = require("cosmic.x")` is set as the scan of its source ([`closure_store.basis`]) would.
  basis.type_requires["greet_test"] = if named then { "greet" } else {} end
  assert(closure_store.write(tmp .. "/" .. name .. ".whole.db", tmp .. "/" .. name .. ".db", texted_names, basis, nil, "greet_test"))
  return closure_store.address(basis, texted_names, "salt", "greet_test"), tmp .. "/" .. name .. ".db"
end

local none: Edits = { lined = {}, trailed = {}, declared = {} }

--- The pure store keeps the stub of a module its test names, and of those that stub requires, and no source,
--- source hash or other text of any module.
local function test_a_pure_store_keeps_the_stubs_of_the_modules_its_test_names(tmp: string)
  local _, path = texted_store(tmp .. "/a", tmp, "kept", none, true)
  local db = assert(Sqlite.open(path))
  local function count(query: string): string
    return support.nth(assert(Sqlite.text_rows(db, query)), 1):text(1)
  end
  assert(count("SELECT group_concat(path, ' ') FROM (SELECT path FROM stubs ORDER BY path)") == "greet leaf",
    "the stubs kept were not the named module's and the one it requires")
  assert(count("SELECT count(*) FROM modules WHERE length(source) > 0 OR length(source_hash) > 0") == "0",
    "the pure store holds a module's source")
  for _, table_name in ipairs({ "docs", "uses", "links", "examples", "catalog", "places" }) do
    local rows, why = Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name)
    assert(rows == nil and why:find("no such table", 1, true) ~= nil, table_name .. " is in the pure store")
  end
  assert(db:close())
  local _, bare = texted_store(tmp .. "/b", tmp, "bare", none, false)
  local unnamed = assert(Sqlite.open(bare))
  local rows = assert(Sqlite.text_rows(unnamed, "SELECT count(*) FROM stubs"))
  assert(support.nth(rows, 1):text(1) == "0", "a test that names no module kept a stub")
  assert(unnamed:close())
end

--- The key follows the kept stubs, which keep every token where the source has it: a change to a kept module's
--- declared types, a line added above it, or one added to a module its stub requires moves the address and the
--- bytes; a comment at the end of a line it already has, or any change to a stub no kept stub requires, does not.
local function test_a_pure_store_moves_with_the_stubs_it_keeps_and_not_with_others(tmp: string)
  local address, path = texted_store(tmp .. "/a", tmp, "first", none, true)
  local bytes = assert(Fs.read(path))
  local function same(name: string, edits: Edits, named: boolean, why: string)
    local moved, moved_path = texted_store(tmp .. "/" .. name, tmp, name, edits, named)
    assert(moved == address and assert(Fs.read(moved_path)) == bytes, why)
  end
  local function moves(name: string, edits: Edits, why: string)
    local moved, moved_path = texted_store(tmp .. "/" .. name, tmp, name, edits, true)
    assert(moved ~= address, why .. " (the address)")
    assert(assert(Fs.read(moved_path)) ~= bytes, why .. " (the store)")
  end
  same("trailing", { lined = {}, trailed = { ["greet"] = " -- noted" }, declared = {} }, true,
    "a comment at the end of a line of a kept module moved the pure store")
  same("elsewhere", { lined = { ["other"] = "-- noted" }, trailed = {}, declared = {} }, true,
    "a line added to an imported module no kept stub requires moved the pure store")
  moves("lined", { lined = { ["greet"] = "-- noted" }, trailed = {}, declared = {} },
    "a line added above a kept module, which shifts its stub's tokens, did not move the pure store")
  moves("followed", { lined = { ["leaf"] = "-- noted" }, trailed = {}, declared = {} },
    "a line added to a module a kept stub requires did not move the pure store")
  moves("changed", { lined = {}, trailed = {}, declared = { ["greet"] = "integer" } },
    "a change to a kept module's declared types did not move the pure store")
  -- Naming no module keeps no stub, so a line added above one moves nothing.
  local bare, bare_path = texted_store(tmp .. "/bare", tmp, "bare", none, false)
  local bare_lined, bare_lined_path = texted_store(tmp .. "/bare_lined", tmp, "bare_lined",
    { lined = { ["greet"] = "-- noted" }, trailed = {}, declared = {} }, false)
  assert(bare_lined == bare and assert(Fs.read(bare_lined_path)) == assert(Fs.read(bare_path)),
    "a line added above a module moved the store of a test that names none")
end

--- A test names the standard-library modules a snippet it type-checks requires with a top-level
--- `local type _ = require(...)`, a `<const>` after the name allowed; a `require` it runs by value, a statement
--- in a comment or a long string, which a snippet it checks is, and one of another module of the tree are none of them.
local function test_the_modules_a_test_names_for_its_snippets_are_its_top_level_local_type_requires(tmp: string)
  assert(Fs.mkdirs(tmp .. "/a"))
  assert(Fs.write(tmp .. "/a/greet.tl", "local record greet\nend\nreturn greet\n"))
  assert(Fs.write(tmp .. "/a/greet_test.tl", table.concat({
    '-- local type _comment = require("cosmic.json")',
    'local Fs = require("cosmic.fs")',
    'local type _zip = require("cosmic.zip")',
    "local type _tar <const> = require('cosmic.tar')",
    'local type _ours = require("greet")',
    '-- local type _hidden = require("cosmic.http")',
    "local function test_x()",
    "  local used = Fs.stdout",
    "  local snippet = [[",
    'local type _s = require("cosmic.stream")',
    "]]",
    "  local second = [=[",
    'local type _t = require("cosmic.clock")',
    "]=]",
    '  assert(used >= 0 and snippet ~= second)',
    "end",
    "",
  }, "\n")))
  local handle = assert(work.open(tmp .. "/a"))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "closure-store-pure-test"))
  assert(writer.write_result(handle, tmp .. "/whole.db", result))
  assert(work.close(handle))
  local basis = assert(closure_store.basis(tmp .. "/whole.db", true))
  local named = table.concat(basis.type_requires["greet_test"] or {}, " ")
  assert(named == "cosmic.zip cosmic.tar", named)
end

--- The project of a test, `walk_test`, that requires [`build.pipeline`] and [`build.paths`], and the projection of it at
--- `out`. [`build.pipeline`] requires `build.helper` and declares it reads the walk of the checker's readers
--- ([`build.reads.pipeline`]), so those and the declaration are the walk; [`build.paths`] is an import outside it. `edits`
--- gives a line a module opens with.
local function walked(root: string, out: string, edits: {string:string})
  assert(Fs.mkdirs(root .. "/build/reads"))
  local function put(path: string, body: string)
    assert(Fs.write(root .. "/" .. path .. ".tl", (edits[path] or "-- as written") .. "\n" .. body))
  end
  put("build/reads/pipeline", "--- @public\nlocal record reads\n  reads: string\nend\nlocal declared: reads = { reads = \"pipeline\" }\nreturn declared\n")
  put("build/helper", "local record helper\nend\nfunction helper.name(): string\n  return \"helper\"\nend\nreturn helper\n")
  put("build/paths", "local record paths\nend\nfunction paths.name(): string\n  return \"paths\"\nend\nreturn paths\n")
  put("build/typed", "local record typed\nend\nreturn typed\n")
  put("build/pipeline", table.concat({
    'local helper = require("build.helper")',
    'local type typed = require("build.typed")',
    'local _ = require("build.reads.pipeline")',
    "local record pipeline",
    "end",
    "function pipeline.name(): string",
    "  local _: typed? = nil",
    "  return helper.name()",
    "end",
    "return pipeline",
    "",
  }, "\n"))
  put("walk_test", table.concat({
    'local pipeline = require("build.pipeline")',
    'local paths = require("build.paths")',
    "local function test_names()",
    "  assert(pipeline.name() ~= paths.name())",
    "end",
    "",
  }, "\n"))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "closure-store-pure-test"))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
end

local walk_names <const> = { "build.helper", "build.paths", "build.pipeline", "build.reads.pipeline", "walk_test" }

--- The pure address of the closure of `walk_test` in the project `walked` writes, with `edits`, and its store.
local function walk_store(root: string, tmp: string, name: string, edits: {string:string}): string, Sqlite.Handle
  walked(root, tmp .. "/" .. name .. "-whole.db", edits)
  local basis = assert(closure_store.basis(tmp .. "/" .. name .. "-whole.db", true))
  assert(closure_store.write(tmp .. "/" .. name .. "-whole.db", tmp .. "/" .. name .. ".db", walk_names, basis, nil,
    "walk_test"))
  local opened = assert(Sqlite.open(tmp .. "/" .. name .. ".db"))
  return closure_store.address(basis, walk_names, "salt", "walk_test"), opened
end

--- A module that declares it reads a walk of the code that reads text (requires [`build.reads.pipeline`]) has the walk's
--- sources kept in the pure store of a test that imports it, and its address holds them: a comment in a module of the
--- walk moves the address, and one in an import outside it does not.
local function test_a_pure_store_keeps_the_sources_of_the_walks_its_closure_declares(tmp: string)
  local plain, store = walk_store(tmp .. "/a", tmp, "plain", {})
  local function sourced(db: Sqlite.Handle, path: string): boolean
    local rows = assert(Sqlite.text_rows(db, "SELECT length(source) FROM modules WHERE path = ?1", { { text = path } }))
    return support.nth(rows, 1):text(1) ~= "0"
  end
  assert(sourced(store, "build.pipeline") and sourced(store, "build.helper"), "the walk's sources are kept")
  assert(not sourced(store, "build.paths"), "an import outside the walk keeps no source")
  -- A module the walk reaches by a type alone is no part of the closure: its source is kept, its code is not, so
  -- requiring it finds a chunk that does not load and not a module that runs.
  assert(sourced(store, "build.typed"), "a module the walk reaches by a type alone keeps no source")
  local code = assert(Sqlite.text_rows(store, "SELECT length(bytecode) FROM modules WHERE path = 'build.typed'"))
  assert(support.nth(code, 1):text(1) == "0", "a module outside the closure keeps its code")
  assert(not sourced(store, "walk_test"), "the test's own source is not kept")
  assert(store:close())
  local outside, outside_store = walk_store(tmp .. "/b", tmp, "outside", { ["build/paths"] = "-- a comment" })
  assert(outside == plain, "a comment in an import outside the walk moved the address")
  assert(outside_store:close())
  local inside, inside_store = walk_store(tmp .. "/c", tmp, "inside", { ["build/helper"] = "-- a comment" })
  assert(inside ~= plain, "a comment in a module of the walk left the address as it was")
  assert(inside_store:close())
  local typed, typed_store = walk_store(tmp .. "/e", tmp, "typed", { ["build/typed"] = "-- a comment" })
  assert(typed ~= plain, "a comment in a module the walk reaches by a type alone left the address as it was")
  assert(typed_store:close())
  local root, root_store = walk_store(tmp .. "/d", tmp, "root", { ["build/pipeline"] = "-- a comment" })
  assert(root ~= plain and root ~= inside, "a comment in the walk's root left the address as it was")
  assert(root_store:close())
end

--- A closure that declares no read keeps no source: the same project with the declaration left out holds no source
--- and its address ignores a comment in [`build.pipeline`].
local function test_a_closure_that_declares_no_read_keeps_no_source(tmp: string)
  local undeclared: {string} = { "build.helper", "build.paths", "build.pipeline", "walk_test" }
  local function address(root: string, name: string, edits: {string:string}): string
    walked(root, tmp .. "/" .. name .. ".db", edits)
    local basis = assert(closure_store.basis(tmp .. "/" .. name .. ".db", true))
    return closure_store.address(basis, undeclared, "salt", "walk_test")
  end
  assert(address(tmp .. "/a", "a", {}) == address(tmp .. "/b", "b", { ["build/pipeline"] = "-- a comment" }))
end
