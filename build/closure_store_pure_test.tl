--- Tests for the pure closure store ([`build.closure_store`]'s `write` with
--- `own`): the store of a test's import closure that holds nothing a
--- comment, a blank line or a moved line moves, so a test that is given it
--- stands when a module it imports is edited in one of those ways and runs
--- again when the edit changes what the module does.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local closure_store = require("build.closure_store")
local importer = require("build.importer")
local lua_tail = require("build.lua_tail")
local work = require("build.work")
local writer = require("build.writer")
local support = require("build.test_support_fixture")

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
  local basis = assert(closure_store.basis(tmp .. "/whole.db"))
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
  local basis = assert(closure_store.basis(tmp .. "/whole.db"))
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
