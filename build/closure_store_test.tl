--- Tests for [`build.closure_store`]: the store of a test module's import
--- closure holds that closure's rows alone, and its address moves with
--- what its bytes follow from and nothing else. Each writes a small
--- project's projection with [`build.writer`] and derives the store from
--- it.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local closure_store = require("build.closure_store")
local importer = require("build.importer")
local teal = require("build.teal")
local test_inputs = require("build.test_inputs")
local work = require("build.work")
local writer = require("build.writer")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Writes a minimal one-module project at `root`, greeting `whom`: the
--- one build/writer_test.tl projects, restated here since a test module
--- requires no other's.
local function write_project(root: string, whom: string)
  assert(Fs.mkdirs(root .. "/cmd/hello"))
  assert(Fs.write(root .. "/cmd/hello/main.tl", table.concat({
    'local greet = require("greet")',
    "return function(): integer",
    "  print(greet.hello())",
    "  return 0",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/greet.tl", table.concat({
    "local record greet",
    "end",
    "function greet.hello(): string",
    '  return "hello, ' .. whom .. '"',
    "end",
    "return greet",
    "",
  }, "\n")))
end

--- Compiles the project at `root` and writes its projection to `out`,
--- returning the open working handle; `tool` names the compiler.
local function build_and_write(root: string, whom: string, out: string,
                               tool?: string): work.Handle
  write_project(root, whom)
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, tool or "closure-store-test"))
  assert(writer.write_result(handle, out, result))
  return handle
end

--- The store of an import closure holds that closure's modules alone,
--- with the declarations it holds, and nothing that moves with a module
--- or a declaration outside it: an edit there, or a module or a
--- declaration added, leaves its address and its bytes as they were;
--- one inside moves both, and so do a declaration the closure holds, one
--- that declaration requires, and the code that writes it (the salt).
local function test_a_closure_store_moves_only_with_its_closure(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    "local function test_hello()",
    '  assert(greet.hello() ~= "")',
    "end",
    "",
  }, "\n")))
  local function other(body: string)
    assert(Fs.write(root .. "/other.tl", table.concat({
      "local record other",
      "end",
      "--- " .. body,
      "function other.name(): string",
      '  return "' .. body .. '"',
      "end",
      "return other",
      "",
    }, "\n")))
  end
  other("one")
  local names = { "greet", "greet_test" }
  local closure = names
  local function store(whom: string, out: string, salt?: string): string
    local handle = build_and_write(root, whom, tmp .. "/whole.db")
    assert(work.close(handle))
    local basis = assert(closure_store.basis(tmp .. "/whole.db"))
    local address = closure_store.address(basis, closure, salt or "salt")
    assert(closure_store.write(tmp .. "/whole.db", out, closure, basis, address))
    return address
  end
  local first = store("world", tmp .. "/first.db")
  local whole = assert(Fs.read(tmp .. "/whole.db"))
  other("two")
  local outside = store("world", tmp .. "/outside.db")
  assert(assert(Fs.read(tmp .. "/whole.db")) ~= whole, "the projection did not move")
  assert(outside == first, "an edit outside the closure moved its address")
  assert(Fs.read(tmp .. "/outside.db") == Fs.read(tmp .. "/first.db"),
    "an edit outside the closure moved its store")
  assert(Fs.write(root .. "/added.tl", "return {}\n"))
  local added = store("world", tmp .. "/added.db")
  assert(added == first, "a module added outside the closure moved its address")
  assert(Fs.read(tmp .. "/added.db") == Fs.read(tmp .. "/first.db"),
    "a module added outside the closure moved its store")
  assert(store("world", tmp .. "/salted.db", "another writer") ~= first,
    "the code that writes it left its address")
  local function extra(field: string)
    assert(Fs.write(root .. "/extra.d.tl", "local type base = require 'base'\n" ..
      "local record extra\n  " .. field .. ": base\nend\nreturn extra\n"))
  end
  local function base(field: string)
    assert(Fs.write(root .. "/base.d.tl", "local record base\n  " .. field ..
      ": integer\nend\nreturn base\n"))
  end
  base("x")
  extra("a")
  local declared = store("world", tmp .. "/declared.db")
  assert(declared == first, "a declaration outside the closure moved its address")
  assert(Fs.read(tmp .. "/declared.db") == Fs.read(tmp .. "/first.db"),
    "a declaration outside the closure moved its store")
  closure = { "extra", "greet", "greet_test" }
  local holding = store("world", tmp .. "/holding.db")
  assert(holding ~= first, "a declaration the closure holds left its address")
  extra("b")
  local edited = store("world", tmp .. "/edited.db")
  assert(edited ~= holding, "an edit to a declaration the closure holds left its address")
  base("y")
  local required = store("world", tmp .. "/required.db")
  assert(required ~= edited,
    "an edit to a declaration one the closure holds requires left its address")
  local held_db = assert(Sqlite.open(tmp .. "/required.db", false))
  local held_rows = assert(Sqlite.text_rows(held_db,
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM decls ORDER BY path)"))
  assert(held_db:close())
  assert(held_rows[1][1] == "base extra", held_rows[1][1])
  closure = names
  assert(store("world", tmp .. "/unheld.db") == first,
    "a declaration's edit moved the address of a closure that does not hold it")
  assert(Fs.remove(root .. "/extra.d.tl"))
  assert(Fs.remove(root .. "/base.d.tl"))
  local inside = store("there", tmp .. "/inside.db")
  assert(inside ~= first, "an edit inside the closure left its address")
  assert(Fs.read(tmp .. "/inside.db") ~= Fs.read(tmp .. "/first.db"),
    "an edit inside the closure left its store")

  local db = assert(Sqlite.open(tmp .. "/first.db", false))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT (SELECT group_concat(path, ' ') FROM (SELECT path FROM modules ORDER BY path)), " ..
    "(SELECT count(*) FROM docs WHERE module = 'other'), " ..
    "(SELECT count(*) FROM meta WHERE key IN ('boot_hash', 'projected', 'writer')), " ..
    "(SELECT value FROM meta WHERE key = 'closure'), (SELECT count(*) FROM decls)"))
  assert(db:close())
  local row = rows[1]
  assert(row[1] == "greet greet_test", row[1])
  assert(row[2] == "0", "a doc of a module outside the closure is in its store")
  assert(row[3] == "0", "a meta row that moves with the whole tree is in the store")
  assert(row[4] == first, row[4])
  assert(row[5] == "0", "a declaration outside the closure is in its store")
end

--- The store of an import closure holds what the compiler made of it,
--- not the compiler's identity: compiled again by a compiler of
--- another identity that makes the same bytecode and rows, it keeps
--- its address and its bytes, and a test given it keeps its key
--- ([`build.declared_key`]); a module's bytecode, or a row the store
--- carries of it, moves its address though its source stays.
local function test_a_closure_store_holds_what_the_compiler_made(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    "local function test_hello()",
    '  assert(greet.hello() ~= "")',
    "end",
    "",
  }, "\n")))
  local names = { "greet", "greet_test" }
  local function store(tool: string, out: string): string
    local handle = build_and_write(root, "world", tmp .. "/whole.db", tool)
    assert(work.close(handle))
    local basis = assert(closure_store.basis(tmp .. "/whole.db"))
    local address = closure_store.address(basis, names, "salt")
    assert(closure_store.write(tmp .. "/whole.db", out, names, basis, address))
    return address
  end
  local first = store("one compiler", tmp .. "/first.db")
  local whole = assert(Fs.read(tmp .. "/whole.db"))
  local again = store("another compiler", tmp .. "/again.db")
  assert(assert(Fs.read(tmp .. "/whole.db")) ~= whole,
    "the projection did not name the other compiler")
  assert(again == first, "a compiler of another identity moved the address")
  assert(Fs.read(tmp .. "/again.db") == Fs.read(tmp .. "/first.db"),
    "a compiler of another identity moved the store")

  -- Each statement against a projection written afresh -- not taken for
  -- the one its signature names -- after `setup`: whether the address
  -- before it and after differ, and whether the store's rows do (each
  -- written under one address, so its bytes differ only by its rows).
  local function change(statement: string, setup?: string): boolean, boolean
    assert(Fs.remove(tmp .. "/whole.db"))
    assert(store("one compiler", tmp .. "/first.db") == first)
    local function address(sql: string, out: string): string
      if sql ~= "" then
        local db = assert(Sqlite.open(tmp .. "/whole.db", true))
        assert(db:exec(sql))
        assert(db:close())
      end
      local basis = assert(closure_store.basis(tmp .. "/whole.db"))
      assert(closure_store.write(tmp .. "/whole.db", out, names, basis, "probe"))
      return closure_store.address(basis, names, "salt")
    end
    local before = address(setup or "", tmp .. "/before.db")
    local after = address(statement, tmp .. "/after.db")
    return after ~= before,
      assert(Fs.read(tmp .. "/after.db")) ~= assert(Fs.read(tmp .. "/before.db"))
  end
  -- The statement moves the store's rows, and so its address.
  local function moved(what: string, statement: string, setup?: string)
    local address, rows = change(statement, setup)
    assert(rows, what .. " left the store")
    assert(address, what .. " left the address")
  end
  -- The statement moves neither the store's rows nor its address.
  local function held(what: string, statement: string, setup?: string)
    local address, rows = change(statement, setup)
    assert(not rows, what .. " moved the store")
    assert(not address, what .. " moved the address")
  end
  local doc = "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, " ..
    "text, file, line) VALUES "
  moved("a module's bytecode", "UPDATE modules SET bytecode = bytecode || X'00' " ..
    "WHERE path = 'greet'")
  moved("a doc", doc .. "('greet', 'greet.x', 'greet.x', 1, 'function', '', 'X.', 'greet.tl', 1)")
  moved("a use", "INSERT INTO uses (module, symbol, from_module, from_file, line) " ..
    "VALUES ('greet', 'hello', 'greet', 'greet.tl', 99)")
  moved("a catalog row", "INSERT INTO catalog (kind, module, symbol, message, text, file, " ..
    "line) VALUES ('error', 'greet', 'greet.hello', 'no', NULL, 'greet.tl', 1)")
  moved("an import", "INSERT INTO imports (path, requires) VALUES ('greet', 'greet_test')")
  moved("an example", "INSERT INTO examples (module, name, text, file, line, source) " ..
    "VALUES ('greet', 'hello', 'Greets.', 'greet.tl', 1, 'greet.hello()')")
  -- What the projection's writer decides of a row and not the closure's
  -- code: the bytes a module's source is stored as, and the order of
  -- rows of several modules, which the store's ids would follow (each
  -- reordered here across modules, each module's own in its order).
  moved("a module's stored source", "UPDATE modules SET source = source || X'00' " ..
    "WHERE path = 'greet'")
  local function reordered(table_name: string, columns: string, rows: string): string, string
    return "INSERT INTO " .. table_name .. " (" .. columns .. ") VALUES " .. rows,
      "CREATE TEMP TABLE kept AS SELECT " .. columns .. " FROM " .. table_name ..
      " ORDER BY module DESC, id; DELETE FROM " .. table_name .. "; INSERT INTO " .. table_name ..
      " (" .. columns .. ") SELECT " .. columns .. " FROM temp.kept ORDER BY rowid"
  end
  local docs_rows, docs_again = reordered("docs",
    "module, symbol, source_symbol, exported, kind, signature, text, file, line",
    "('greet', 'greet.a', 'greet.a', 1, 'function', '', 'A.', 'greet.tl', 1), " ..
    "('greet_test', 'b', 'b', 1, 'function', '', 'B.', 'greet_test.tl', 1)")
  held("the docs' order across modules", docs_again, docs_rows)
  local catalog_rows, catalog_again = reordered("catalog",
    "kind, module, symbol, message, text, file, line",
    "('error', 'greet', 'greet.a', 'a', NULL, 'greet.tl', 1), " ..
    "('error', 'greet_test', 'b', 'b', NULL, 'greet_test.tl', 1)")
  held("the catalog's order across modules", catalog_again, catalog_rows)
  local examples_rows, examples_again = reordered("examples",
    "module, name, text, file, line, source",
    "('greet', 'a', 'A.', 'greet.tl', 1, 'a()'), " ..
    "('greet_test', 'b', 'B.', 'greet_test.tl', 1, 'b()')")
  held("the examples' order across modules", examples_again, examples_rows)
  local extra_doc = doc .. "('extra', 'extra.y', 'extra.y', 1, 'function', '', " ..
    "'Y.', 'extra.d.tl', 1)"
  local extra_decl = "INSERT INTO decls (path, source) VALUES ('extra', deflate('return {}'))"
  held("a doc of a declaration outside the closure", extra_doc, extra_decl)
  names = { "extra", "greet", "greet_test" }
  moved("a declaration's doc", extra_doc, extra_decl)
  names = { "greet", "greet_test" }
  -- SQLite's quote() ends a text at its first NUL: what follows it moves
  -- the address too.
  moved("a doc's text past a NUL", "UPDATE docs SET text = 'a' || char(0) || 'c' " ..
    "WHERE symbol = 'greet.z'", doc .. "('greet', 'greet.z', 'greet.z', 1, 'function', '', " ..
    "'a' || char(0) || 'b', 'greet.tl', 1)")
end

--- An edit to a declaration of one of the core's raw modules --
--- here `raw`, as cosmic.internal.store is to cosmic.store -- moves the
--- store, and so the key, of each test whose import closure holds the
--- wrapper that requires it ([`test_inputs.modules`]), and of no other.
local function test_a_declaration_moves_only_the_stores_that_hold_it(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  local function raw(parameter: string)
    assert(Fs.write(root .. "/raw.d.tl", table.concat({
      "local record raw",
      "  meta: function(" .. parameter .. ": string): string | nil",
      "end",
      "return raw",
      "",
    }, "\n")))
  end
  raw("key")
  assert(Fs.write(root .. "/wrap.tl", table.concat({
    'local type raw_store = require("raw")',
    "local record wrap",
    "  raw: raw_store",
    "end",
    "return wrap",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/wrap_test.tl", table.concat({
    'local wrap = require("wrap")',
    "local function test_wrap()",
    "  assert(wrap ~= nil)",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    "local function test_hello()",
    '  assert(greet.hello() ~= "")',
    "end",
    "",
  }, "\n")))
  local function addresses(): {string:string}
    write_project(root, "world")
    local handle = assert(work.open(root))
    assert(work.stage(handle, false))
    local result = assert(importer.compile(handle, built, "closure-store-test"))
    assert(writer.write_result(handle, tmp .. "/whole.db", result))
    local by_path: {string:importer.Module} = {}
    for _, m in ipairs(result.modules) do by_path[m.path] = m end
    local declarations: {string:string} = {}
    local rows = assert(Sqlite.text_rows(handle.db,
      "SELECT path, file FROM inputs WHERE kind = 'decl'"))
    for _, row in ipairs(rows) do
      declarations[row[1]] = row[2]
    end
    assert(work.close(handle))
    local basis = assert(closure_store.basis(tmp .. "/whole.db"))
    local out: {string:string} = {}
    for _, path in ipairs({ "wrap_test", "greet_test" }) do
      local names = test_inputs.modules(assert(by_path[path]), by_path, declarations)
      out[path] = closure_store.address(basis, names, "salt")
      out[path .. " names"] = table.concat(names, " ")
    end
    return out
  end
  local before = addresses()
  assert(before["wrap_test names"] == "raw wrap wrap_test", before["wrap_test names"])
  raw("name")
  local after = addresses()
  assert(after["wrap_test"] ~= before["wrap_test"],
    "an edit to a declaration left the store of a closure that holds it")
  assert(after["greet_test"] == before["greet_test"],
    "an edit to a declaration moved the store of a closure that does not hold it")
end
