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
--- bytecode is stripped, and the test's own is as the build made it.
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
  for _, table_name in ipairs({ "docs", "uses", "links", "examples", "catalog", "stubs", "places" }) do
    assert(count(pure, "SELECT count(*) FROM " .. table_name) == "0", table_name .. " holds rows in the pure store")
  end
  assert(count(pure, "SELECT count(*) FROM modules WHERE length(source) > 0 OR length(source_hash) > 0") == "0",
    "the pure store holds a module's source")
  assert(count(pure, "SELECT count(*) FROM modules") == "2")
  assert(count(pure, "SELECT count(*) FROM imports") == "1", "the edges a require follows are kept")
  local function bytecode(db: Sqlite.Handle, path: string): string
    local rows = assert(Sqlite.rows(db, "SELECT inflate(bytecode) FROM modules WHERE path = ?1", { { text = path } }))
    return support.nth(rows, 1):blob(1)
  end
  local imported = bytecode(full, "greet")
  assert(bytecode(pure, "greet") == assert(lua_tail.stripped(imported, "greet")),
    "an imported module's bytecode is not stripped of its debug information")
  assert(bytecode(pure, "greet") ~= imported, "the build's bytecode carried no debug information, so this shows nothing")
  assert(bytecode(pure, "greet_test") == bytecode(full, "greet_test"), "the test's own bytecode was stripped")
  assert(full:close())
  assert(pure:close())
end

--- A project of a test, `greet_test`, that requires `greet` and `other`, `greet` requiring `leaf`, and
--- the projection of it at `out`, in which each module has a stub, as a module of the standard library does.
--- `edited` names the comment at the head of a module's source, `declared` the type its stub declares for its function (a stub
--- is the module's declared types, with no comment; the source is as it was, so the bytecode is).
local function texted(root: string, out: string, edited: {string:string}, declared: {string:string})
  assert(Fs.mkdirs(root))
  local stubs: mut {string:string} = {}
  local function module(name: string, requires: string)
    local result_type = declared[name] or "string"
    assert(Fs.write(root .. "/" .. name .. ".tl", table.concat({
      edited[name] or "",
      "local record " .. name,
      "end",
      requires,
      "function " .. name .. ".value(): string",
      '  return "' .. name .. '"',
      "end",
      "return " .. name,
      "",
    }, "\n")))
    stubs[name] = table.concat({
      requires,
      "local record " .. name,
      "  value: function(): " .. result_type,
      "end",
      "return " .. name,
      "",
    }, "\n")
  end
  module("leaf", "")
  module("greet", 'local _leaf = require("leaf")')
  module("other", "")
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    'local other = require("other")',
    "local function test_hello()",
    "  assert(greet.value() ~= other.value())",
    "end",
    "",
  }, "\n")))
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "closure-store-pure-test"))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
  local whole = assert(Sqlite.open(out, { writable = true }))
  for name, stub in pairs(stubs) do
    assert(Sqlite.run(whole, "INSERT OR REPLACE INTO stubs (path, source) VALUES (?1, deflate(?2))",
      { { text = name }, { text = stub } }))
  end
  assert(whole:close())
end

local texted_names <const> = { "greet", "greet_test", "leaf", "other" }

--- The pure address and the pure store's path for `texted_names` of the project at `root` with `edited`
--- comments and `declared` types, where the test names `kept` as it would the modules of the standard library it
--- type-checks.
local function texted_store(root: string, tmp: string, name: string, edited: {string:string},
                            declared: {string:string}, kept: {string}): string, string
  texted(root, tmp .. "/" .. name .. ".whole.db", edited, declared)
  local basis = assert(closure_store.basis(tmp .. "/" .. name .. ".whole.db", true))
  -- What the test names with `local type` is a standard-library module's, which the project here has none of.
  basis.type_requires["greet_test"] = kept
  assert(closure_store.write(tmp .. "/" .. name .. ".whole.db", tmp .. "/" .. name .. ".db", texted_names, basis, nil, "greet_test"))
  return closure_store.address(basis, texted_names, "salt", "greet_test"), tmp .. "/" .. name .. ".db"
end

--- The pure store keeps the stub of a module its test names, and of those that stub requires, and no source,
--- source hash or other text of any module.
local function test_a_pure_store_keeps_the_stubs_of_the_modules_its_test_names(tmp: string)
  local _, path = texted_store(tmp .. "/a", tmp, "kept", {}, {}, { "greet" })
  local db = assert(Sqlite.open(path))
  local function count(query: string): string
    return support.nth(assert(Sqlite.text_rows(db, query)), 1):text(1)
  end
  assert(count("SELECT group_concat(path, ' ') FROM (SELECT path FROM stubs ORDER BY path)") == "greet leaf",
    "the stubs kept were not the named module's and the one it requires")
  assert(count("SELECT count(*) FROM modules WHERE length(source) > 0 OR length(source_hash) > 0") == "0",
    "the pure store holds a module's source")
  for _, table_name in ipairs({ "docs", "uses", "links", "examples", "catalog", "places" }) do
    assert(count("SELECT count(*) FROM " .. table_name) == "0", table_name .. " holds rows in the pure store")
  end
  assert(db:close())
  local _, bare = texted_store(tmp .. "/b", tmp, "bare", {}, {}, {})
  local none = assert(Sqlite.open(bare))
  local rows = assert(Sqlite.text_rows(none, "SELECT count(*) FROM stubs"))
  assert(support.nth(rows, 1):text(1) == "0", "a test that names no module kept a stub")
  assert(none:close())
end

--- The key follows the kept stubs: a change to a kept module's declared types moves the address and the bytes,
--- as does one to a module its stub requires; a comment in a kept module, which its stub drops, a change to
--- a module the test imports and no kept stub requires, and a change to a stub of a store that names none,
--- leave both as they were.
local function test_a_pure_store_moves_with_the_declared_types_of_a_kept_module_and_not_with_others(tmp: string)
  local address, path = texted_store(tmp .. "/a", tmp, "first", {}, {}, { "greet" })
  local bytes = assert(Fs.read(path))
  local noted, noted_path = texted_store(tmp .. "/b", tmp, "noted", { greet = "-- noted\n\n-- again" }, {}, { "greet" })
  assert(noted == address, "a comment in a kept module, which its stub drops, moved the pure address")
  assert(assert(Fs.read(noted_path)) == bytes, "a comment in a kept module moved the pure store")
  local other, other_path = texted_store(tmp .. "/c", tmp, "other", {}, { other = "integer" }, { "greet" })
  assert(other == address and assert(Fs.read(other_path)) == bytes,
    "a change to an imported module no kept stub requires moved the pure store")
  local changed, changed_path = texted_store(tmp .. "/d", tmp, "changed", {}, { greet = "integer" }, { "greet" })
  assert(changed ~= address, "a change to a kept module's declared types did not move the pure address")
  assert(assert(Fs.read(changed_path)) ~= bytes, "a change to a kept module's declared types did not move the pure store")
  local followed, followed_path = texted_store(tmp .. "/e", tmp, "followed", {}, { leaf = "integer" }, { "greet" })
  assert(followed ~= address, "a change to a module a kept stub requires did not move the pure address")
  assert(assert(Fs.read(followed_path)) ~= bytes)
  -- Naming no module keeps no stub, so the same change moves nothing but the bytecode it changes.
  local bare_from, bare_from_path = texted_store(tmp .. "/f", tmp, "bare_from", {}, {}, {})
  assert(bare_from ~= address, "the stubs kept moved nothing, so this shows nothing")
  local bare_noted = texted_store(tmp .. "/g", tmp, "bare_noted", { greet = "-- noted" }, {}, {})
  assert(bare_noted == bare_from and assert(Fs.read(tmp .. "/bare_noted.db")) == assert(Fs.read(bare_from_path)))
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
