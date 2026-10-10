--- [`Store.closure`] and [`Store.seal`], over databases of the test's own
--- attached ahead of the binary's, and the binary's for what only it
--- carries. It reads the store's handles ([`Store.databases()`]), as
--- cosmic/store_handles_test.tl does.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local schema = require("build.schema")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")

--- `store`: both read every module's rows through [`Store.databases()`].
Test.policy{ grants = { { path = "o/cosmic.db", letters = "r" } } }

local function text(value: string): Sqlite.Value
  return { text = value }
end

--- A database of modules `fixture.*`: `app` requires `lib` by value and
--- `shapes` by type alone (its bytecode does not name it), `lib` requires
--- `leaf`, and `loop_a` and `loop_b` require each other. Attached ahead
--- of the binary's, once; a fixture module is never in the binary.
local attached = false
local function attach(tmp: string)
  if attached then
    return
  end
  local path = tmp .. "/fixture.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  for _, statement in ipairs({
      "CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID",
      [[CREATE TABLE modules (path TEXT PRIMARY KEY NOT NULL, file TEXT NOT NULL,
      kind TEXT NOT NULL, source_hash BLOB NOT NULL, key BLOB NOT NULL,
      bytecode BLOB NOT NULL, tests TEXT NOT NULL, source BLOB NOT NULL)]],
      [[CREATE TABLE imports (path TEXT NOT NULL, requires TEXT NOT NULL,
      PRIMARY KEY (path, requires)) WITHOUT ROWID]],
  }) do
    assert(db:exec(statement))
  end
  local function module(name: string, bytecode: string)
    assert(Sqlite.run(db, "INSERT INTO modules VALUES (?1, ?2, 'module', X'00', X'0102', ?3, '', X'')",
      { text(name), text(name .. ".tl"), { blob = bytecode } }))
  end
  local function requires(name: string, other: string)
    assert(Sqlite.run(db, "INSERT INTO imports VALUES (?1, ?2)", { text(name), text(other) }))
  end
  module("fixture.app", "calls fixture.lib")
  module("fixture.lib", "calls fixture.leaf")
  module("fixture.leaf", "nothing")
  module("fixture.shapes", "nothing")
  module("fixture.loop_a", "fixture.loop_b")
  module("fixture.loop_b", "fixture.loop_a")
  requires("fixture.app", "fixture.lib")
  requires("fixture.app", "fixture.shapes")
  requires("fixture.lib", "fixture.leaf")
  requires("fixture.loop_a", "fixture.loop_b")
  requires("fixture.loop_b", "fixture.loop_a")
  assert(db:close())
  assert(Store.attach(path))
  attached = true
end

local function raises(fn: function(): any, needle: string)
  local ok, trouble = pcall(fn)
  assert(not ok, "did not raise")
  assert(tostring(trouble):find(needle, 1, true), tostring(trouble))
end

--- With type-only edges followed, a closure is every module a root
--- requires, transitively, by the store's own `requires`, and sorted; a
--- cycle ends. Without them it is a subset of that.
local function test_closure_follows_requires_transitively(tmp: string)
  attach(tmp)
  assert(table.concat(Store.closure({ "fixture.lib" }), " ") == "fixture.leaf fixture.lib")
  assert(table.concat(Store.closure({ "fixture.loop_a" }), " ") ==
      "fixture.loop_a fixture.loop_b")
  local expected: {string:boolean} = {}
  local stack: {string} = { "cosmic.json" }
  while #stack > 0 do
    local name = table.remove(stack)
    if not expected[name] then
      expected[name] = true
      for _, required in ipairs((assert(Store.requires(name)))) do
        stack[#stack + 1] = required
      end
    end
  end
  local all = Store.closure({ "cosmic.json" }, { types = true })
  local count = 0
  for _, name in ipairs(all) do
    assert(expected[name], name .. " is not required, transitively, by cosmic.json")
    count = count + 1
  end
  local wanted = 0
  for _ in pairs(expected) do
    wanted = wanted + 1
  end
  assert(count == wanted, "a module cosmic.json requires is missing")
  local sorted = { table.unpack(all) }
  table.sort(sorted)
  assert(table.concat(sorted, " ") == table.concat(all, " "), "not sorted")
  local loaded = Store.closure({ "cosmic.json" })
  assert(#loaded < #all, "cosmic.json requires cosmic.stream only for its types")
  for _, name in ipairs(loaded) do
    assert(expected[name])
  end
end

--- An edge made by type alone, which the importer's bytecode shows by
--- not naming the module, is left out unless `types` asks for it.
local function test_closure_leaves_type_only_edges_out(tmp: string)
  attach(tmp)
  assert(table.concat(Store.closure({ "fixture.app" }), " ") ==
      "fixture.app fixture.leaf fixture.lib")
  assert(table.concat(Store.closure({ "fixture.app" }, { types = true }), " ") ==
      "fixture.app fixture.leaf fixture.lib fixture.shapes")
end

local function test_closure_of_a_missing_root_raises(tmp: string)
  attach(tmp)
  raises(function(): any return Store.closure({ "fixture.nowhere" }) end, "fixture.nowhere")
end

local function modules_of(path: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT path FROM modules ORDER BY path"))
  assert(db:close())
  local names: {string} = {}
  for _, row in ipairs(rows) do
    names[#names + 1] = row[1]
  end
  return table.concat(names, " ")
end

local function count_of(path: string, table_name: string): integer
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM " .. table_name))
  assert(db:close())
  return math.tointeger(rows[1][1]) as integer
end

--- Two seals of one set, even in another order or with a name twice,
--- are the same bytes, and the digest returned is theirs.
local function test_seal_is_deterministic(tmp: string)
  attach(tmp)
  local first = assert(Store.seal({ "fixture.lib", "fixture.leaf" }, tmp .. "/one.db"))
  local second = assert(Store.seal({ "fixture.leaf", "fixture.lib", "fixture.leaf" },
    tmp .. "/two.db"))
  local one, two = assert(Fs.read(tmp .. "/one.db")), assert(Fs.read(tmp .. "/two.db"))
  assert(one == two, "the files differ")
  assert(first == second and first == Hash.hex_sha256(one), "the digest is of the bytes")
end

--- The file holds the named modules and their imports, the runtime's
--- identity and the main asked for, and no module that was not named.
local function test_seal_holds_exactly_the_named_modules(tmp: string)
  attach(tmp)
  local path = tmp .. "/exact.db"
  assert(Store.seal({ "fixture.lib", "fixture.leaf" }, path, { main = "fixture.lib" }))
  assert(modules_of(path) == "fixture.leaf fixture.lib")
  assert(count_of(path, "imports") == 1)
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT key, value FROM meta ORDER BY key"))
  assert(db:close())
  local meta: {string:string} = {}
  for _, row in ipairs(rows) do
    meta[row[1]] = row[2]
  end
  assert(meta.main == "fixture.lib")
  assert(meta.runtime_basis ~= nil and meta.runtime_basis == Store.meta("runtime_basis"))
  assert(count_of(path, "zoneinfo") == 0 and count_of(path, "ca_roots") == 0)
  local keys = assert(Sqlite.text_rows(assert(Sqlite.open(path)), "SELECT hex(key) FROM modules"))
  assert(keys[1][1] == "", "a module's compile key is not carried")
end

--- The binary's modules are copied from the binary, not from an
--- attached database that holds a module of the same name.
local function test_seal_takes_a_reserved_name_from_the_binary(tmp: string)
  attach(tmp)
  local path = tmp .. "/binary.db"
  assert(Store.seal({ "cosmic.codec" }, path))
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT bytecode FROM modules"))
  assert(db:close())
  assert(rows[1][1] == assert(Store.bytecode("cosmic.codec")), "the binary's own bytecode")
end

--- The tz database goes only with cosmic.time, the CA roots only with
--- cosmic.http.
local function test_seal_carries_zones_and_roots_only_for_their_modules(tmp: string)
  local zoned = tmp .. "/zoned.db"
  assert(Store.seal({ "cosmic.time" }, zoned))
  assert(count_of(zoned, "zoneinfo") > 0 and count_of(zoned, "ca_roots") == 0)
  local trusting = tmp .. "/trusting.db"
  assert(Store.seal({ "cosmic.http" }, trusting))
  assert(count_of(trusting, "ca_roots") > 0 and count_of(trusting, "zoneinfo") == 0)
end

local function test_seal_refuses_what_it_cannot_carry(tmp: string)
  attach(tmp)
  raises(function(): any return (Store.seal({}, tmp .. "/none.db")) end, "non-empty")
  raises(function(): any return (Store.seal(nil as {string}, tmp .. "/nil.db")) end, "store:")
  raises(function(): any return Store.closure(nil as {string}) end, "store:")
  raises(function(): any return (Store.seal({ "fixture.nowhere" }, tmp .. "/gone.db")) end,
    "fixture.nowhere")
  raises(function(): any
    return (Store.seal({ "fixture.leaf" }, tmp .. "/main.db", { main = "fixture.app" }))
  end,
    "fixture.app")
  assert(Fs.exists(tmp .. "/gone.db") == false, "a failed seal leaves no file")
end

--- A seal replaces a file whole: a failure before the rename leaves the old
--- one, and no temporary file is left beside the result.
local function test_seal_writes_whole_or_leaves_the_old_file(tmp: string)
  attach(tmp)
  local dir = tmp .. "/out"
  assert(Fs.mkdirs(dir))
  assert(Fs.write(dir .. "/p.db", "old"))
  assert(Store.seal({ "fixture.leaf" }, dir .. "/p.db"))
  assert(modules_of(dir .. "/p.db") == "fixture.leaf")
  local listing = assert(Fs.list(dir))
  assert(#listing == 1 and listing[1] == "p.db", "only the result is left")
  assert(Fs.mkdirs(dir .. "/blocked"))
  local ok, why = Store.seal({ "fixture.leaf" }, dir .. "/blocked")
  assert(ok == nil and why ~= "", "a directory is no place for a database")
  assert(#assert(Fs.list(dir)) == 2)
end

--- A module the store does not hold goes in as the main, after the
--- others, with its edges to the sealed names; the same script seals the
--- same bytes, and a name already sealed or a main beside it is refused.
local function test_seal_carries_an_extra_module_as_the_main(tmp: string)
  attach(tmp)
  local extra: Store.Extra = { name = "main", bytecode = string.dump((assert(load("return 1")))),
    source = "return 1\n", requires = { "fixture.leaf", "fixture.nowhere" } }
  local path = tmp .. "/extra.db"
  local digest = assert(Store.seal({ "fixture.leaf" }, path, { extra = extra }))
  assert(modules_of(path) == "fixture.leaf main")
  assert(count_of(path, "imports") == 1, "its edge to a name left out is no row")
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT kind, bytecode = ?1, source FROM modules WHERE path = 'main' " ..
      "UNION ALL SELECT value, '', '' FROM meta WHERE key = 'main'", { { blob = extra.bytecode } }))
  assert(db:close())
  assert(rows[1][1] == "main" and rows[1][2] == "1" and rows[1][3] == "return 1\n")
  assert(rows[2][1] == "main", "the extra module is the database's main")
  assert(digest == (assert(Store.seal({ "fixture.leaf" }, tmp .. "/again.db", { extra = extra }))))
  -- A script that requires nothing is a program of no sealed names.
  assert(Store.seal({}, tmp .. "/alone.db", { extra = extra }))
  assert(modules_of(tmp .. "/alone.db") == "main")
  raises(function(): any
    return (Store.seal({ "fixture.leaf", "main" }, tmp .. "/x.db", { extra = extra }))
  end, "also one of the names")
  raises(function(): any
    return (Store.seal({ "fixture.leaf" }, tmp .. "/y.db", { extra = extra, main = "fixture.leaf" }))
  end, "both given")
  -- It may not shadow a module the store holds, or any of `cosmic.`.
  for _, name in ipairs({ "fixture.app", "cosmic.fs", "cosmic.nothing" }) do
    raises(function(): any
      return (Store.seal({ "fixture.leaf" }, tmp .. "/z.db", { extra = {
        name = name, bytecode = extra.bytecode, source = "", requires = {} } }))
    end, "must not shadow")
  end
end

--- The tests that name a module are not carried, so adding one moves no
--- digest; and an edge to a module left out of the set is not a row.
local function test_seal_digest_ignores_tests_and_drops_dangling_edges(tmp: string)
  attach(tmp)
  local set = { "fixture.app", "fixture.lib", "fixture.leaf" }
  local before = assert(Store.seal(set, tmp .. "/before.db"))
  assert(count_of(tmp .. "/before.db", "imports") == 2, "the edge to fixture.shapes dangles")
  local path = tmp .. "/tested.db"
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE meta (key TEXT PRIMARY KEY, value BLOB) WITHOUT ROWID"))
  assert(db:exec("CREATE TABLE modules (path TEXT PRIMARY KEY NOT NULL, file TEXT NOT NULL, " ..
      "kind TEXT NOT NULL, source_hash BLOB NOT NULL, key BLOB NOT NULL, " ..
      "bytecode BLOB NOT NULL, tests TEXT NOT NULL, source BLOB NOT NULL)"))
  assert(db:exec("CREATE TABLE imports (path TEXT NOT NULL, requires TEXT NOT NULL, " ..
      "PRIMARY KEY (path, requires)) WITHOUT ROWID"))
  assert(Sqlite.run(db, "INSERT INTO modules VALUES ('fixture.leaf', 'fixture.leaf.tl', " ..
      "'module', X'00', X'0102', CAST('nothing' AS BLOB), 'fixture/leaf_test.tl', X'')"))
  assert(db:close())
  assert(Store.attach(path))
  local after = assert(Store.seal(set, tmp .. "/after.db"))
  assert(before == after, "a test moved the digest")
end

--- A sealed module carries every edge the checker follows from it, as
--- the database it came from holds them, an edge to a name left out
--- among them: a compile of a project on the sealed database resolves
--- the standard library by them ([`build.compilation`]).
local function test_seal_carries_the_checkers_edges(tmp: string)
  local path = tmp .. "/edges.db"
  assert(Store.seal({ "cosmic.time" }, path))
  local query = "SELECT requires FROM decl_imports WHERE path = 'cosmic.time' ORDER BY requires"
  local databases = Store.databases()
  local want = assert(Sqlite.text_rows(databases[#databases], query))
  local sealed = assert(Sqlite.open(path))
  local got = assert(Sqlite.text_rows(sealed, query))
  assert(sealed:close())
  assert(#want > 1, "cosmic.time requires nothing")
  assert(#got == #want, "the sealed database holds " .. #got .. " edges, not " .. #want)
  for index, row in ipairs(want) do
    assert(got[index][1] == row[1], row[1])
  end
end

--- The tables the core reads, as the build's own schema makes them.
local function test_seal_schema_is_the_builds(tmp: string)
  local path = tmp .. "/schema.db"
  assert(Store.seal({ "cosmic.time", "cosmic.http" }, path))
  local reference = assert(Sqlite.memory())
  for _, statement in ipairs(schema.settings("")) do
    assert(reference:exec(statement))
  end
  for _, statement in ipairs(schema.create("")) do
    assert(reference:exec(statement))
  end
  local sealed = assert(Sqlite.open(path))
  for _, name in ipairs({ "meta", "modules", "imports", "decl_imports", "decls", "zoneinfo",
      "ca_roots" }) do
    local query = "SELECT name, type, \"notnull\", pk FROM pragma_table_info('" .. name .. "')"
    local want = assert(Sqlite.text_rows(reference, query))
    local got = assert(Sqlite.text_rows(sealed, query))
    assert(#want > 0, name .. " is not a table of the schema")
    assert(#want == #got, name .. ": columns differ")
    for index, row in ipairs(want) do
      assert(table.concat(row, " ") == table.concat(got[index], " "), name .. ": " .. row[1])
    end
  end
  for _, pragma in ipairs({ "page_size", "auto_vacuum" }) do
    assert(assert(Sqlite.text_rows(reference, "SELECT * FROM pragma_" .. pragma))[1][1] ==
        assert(Sqlite.text_rows(sealed, "SELECT * FROM pragma_" .. pragma))[1][1], pragma)
  end
  assert(sealed:close())
  assert(reference:close())
end
