--- Tests for [`build.closure_store`]: the store of a test module's import
--- closure holds that closure's rows alone, and its address moves with
--- what its bytes follow from and nothing else. Each writes a small
--- project's projection with [`build.writer`] and derives the store from
--- it.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local analysis_schema = require("build.analysis_schema")
local closure_store = require("build.closure_store")
local declared_key = require("build.declared_key")
local docs = require("build.docs")
local identity = require("build.identity")
local importer = require("build.importer")
local key_parts = require("build.key_parts")
local test_inputs = require("build.test_inputs")
local work = require("build.work")
local writer = require("build.writer")
local Clock = require("cosmic.clock")
local support = require("build.test_support_fixture")

--- Compiles the project at `root` and writes its projection to `out`,
--- returning the open working handle; `tool` names the compiler.
local function build_and_write(root: string, whom: string, out: string,
                               tool?: string): work.Handle
  support.write_project(root, whom)
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, tool or "closure-store-test"))
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
    assert(closure_store.write(tmp .. "/whole.db", out, closure, basis))
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
  assert(Fs.read(tmp .. "/salted.db") == Fs.read(tmp .. "/first.db"),
    "the code that writes it, writing the same rows, moved its bytes")
  local function extra(field: string)
    assert(Fs.write(root .. "/extra.d.tl", "--- @kind binding\nlocal type base = require 'base'\n" ..
        "local record extra\n  " .. field .. ": base\nend\nreturn extra\n"))
  end
  local function base(field: string)
    assert(Fs.write(root .. "/base.d.tl", "--- @kind binding\nlocal record base\n  " .. field ..
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
  local held_db = assert(Sqlite.open(tmp .. "/required.db"))
  local held_rows = assert(Sqlite.text_rows(held_db,
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM decls ORDER BY path)"))
  assert(held_db:close())
  assert(support.nth(held_rows, 1):text(1) == "base extra", support.nth(held_rows, 1):text(1))
  closure = names
  assert(store("world", tmp .. "/unheld.db") == first,
    "a declaration's edit moved the address of a closure that does not hold it")
  assert(Fs.remove(root .. "/extra.d.tl"))
  assert(Fs.remove(root .. "/base.d.tl"))
  local inside = store("there", tmp .. "/inside.db")
  assert(inside ~= first, "an edit inside the closure left its address")
  assert(Fs.read(tmp .. "/inside.db") ~= Fs.read(tmp .. "/first.db"),
    "an edit inside the closure left its store")

  local db = assert(Sqlite.open(tmp .. "/first.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT (SELECT group_concat(path, ' ') FROM (SELECT path FROM modules ORDER BY path)), " ..
      "(SELECT count(*) FROM docs WHERE module = 'other'), " ..
      "(SELECT count(*) FROM meta WHERE key IN ('boot_hash', 'projected', 'writer')), " ..
      "(SELECT count(*) FROM meta WHERE key = 'closure'), (SELECT count(*) FROM decls)"))
  assert(db:close())
  local row = support.nth(rows, 1)
  assert(row:text(1) == "greet greet_test", row:text(1))
  assert(row:text(2) == "0", "a doc of a module outside the closure is in its store")
  assert(row:text(3) == "0", "a meta row that moves with the whole tree is in the store")
  assert(row:text(4) == "0", "the store names its address, which a key would then hold")
  assert(row:text(5) == "0", "a declaration outside the closure is in its store")
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
    assert(closure_store.write(tmp .. "/whole.db", out, names, basis))
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
        local db = assert(Sqlite.open(tmp .. "/whole.db", { writable = true }))
        assert(db:exec(sql))
        assert(db:close())
      end
      local basis = assert(closure_store.basis(tmp .. "/whole.db"))
      assert(closure_store.write(tmp .. "/whole.db", out, names, basis))
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
  moved("a module's bytecode", "UPDATE modules SET bytecode = deflate(inflate(bytecode) || X'00') " ..
      "WHERE path = 'greet'")
  moved("a doc", doc .. "('greet', 'greet.x', 'greet.x', 1, 'function', '', 'X.', 'greet.tl', 1)")
  moved("a use", "INSERT INTO uses (module, symbol, from_module, from_file, line) " ..
      "VALUES ('greet', 'hello', 'greet', 'greet.tl', 99)")
  moved("a catalog row", "INSERT INTO catalog (kind, module, symbol, message, text, file, " ..
      "line) VALUES ('error', 'greet', 'greet.hello', 'no', NULL, 'greet.tl', 1)")
  moved("an import", "INSERT INTO imports (path, requires) VALUES ('greet', 'greet_test')")
  moved("a name bound", "INSERT INTO bound (path, name, requires) " ..
      "VALUES ('greet', 'Fs', 'cosmic.fs')")
  held("a name a module outside the closure binds", "INSERT INTO bound (path, name, requires) " ..
      "VALUES ('other', 'Fs', 'cosmic.fs')")
  moved("an edge the checker follows", "INSERT INTO decl_imports (path, requires) " ..
      "VALUES ('greet', 'cosmic.fs')")
  held("an edge of a module outside the closure", "INSERT INTO decl_imports (path, requires) " ..
      "VALUES ('other', 'cosmic.fs')")
  moved("a stub", "INSERT INTO stubs (path, source) VALUES ('greet', deflate('return {}'))")
  held("a stub of a module outside the closure", "INSERT INTO stubs (path, source) " ..
      "VALUES ('other', deflate('return {}'))")
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
  -- A link is its closure's where a module or a declaration of it makes
  -- it, whatever it names.
  local function link(from_module: string, from_file: string): string
    return "INSERT INTO links (module, symbol, path, anchor, from_file, line, column, " ..
      "from_module, kind, form, source, text) VALUES ('greet', 'greet.hello', '', '', '" ..
      from_file .. "', 1, 5, '" .. from_module .. "', 'symbol', 'shortcut', 'comment', " ..
      "'greet.hello')"
  end
  moved("a link", link("greet", "greet.tl"))
  held("a link from a module outside the closure", link("other", "other.tl"))
  held("a link from a file that is no module", link("", "notes.md"))
  local extra_doc = doc .. "('extra', 'extra.y', 'extra.y', 1, 'function', '', " ..
    "'Y.', 'extra.d.tl', 1)"
  local extra_decl = "INSERT INTO decls (path, source) VALUES ('extra', deflate('return {}'))"
  held("a doc of a declaration outside the closure", extra_doc, extra_decl)
  held("a link of a declaration outside the closure", link("extra", "extra.d.tl"), extra_decl)
  local extra_bound = "INSERT INTO bound (path, name, requires) VALUES ('extra', 'R', 'raw')"
  held("a name a declaration outside the closure binds", extra_bound, extra_decl)
  local extra_edge = "INSERT INTO decl_imports (path, requires) VALUES ('extra', 'raw')"
  held("an edge of a declaration outside the closure", extra_edge, extra_decl)
  names = { "extra", "greet", "greet_test" }
  moved("a declaration's doc", extra_doc, extra_decl)
  moved("a declaration's link", link("extra", "extra.d.tl"), extra_decl)
  moved("a name a declaration binds", extra_bound, extra_decl)
  moved("an edge of a declaration", extra_edge, extra_decl)
  names = { "greet", "greet_test" }
  -- SQLite's quote() ends a text at its first NUL: what follows it moves
  -- the address too.
  moved("a doc's text past a NUL", "UPDATE docs SET text = 'a' || char(0) || 'c' " ..
      "WHERE symbol = 'greet.z'", doc .. "('greet', 'greet.z', 'greet.z', 1, 'function', '', " ..
      "'a' || char(0) || 'b', 'greet.tl', 1)")
end

--- A lookup over a closure store -- `cosmic uses` or `cosmic docs` run
--- by a process a worker starts, whose o/cosmic.db it is -- finds the
--- links its closure's modules make, and none a module outside it makes.
local function test_a_closure_store_answers_for_its_closure_s_links(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    "-- Checks [`greet.hello`].",
    "local function test_hello()",
    '  assert(greet.hello() ~= "")',
    "end",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/other.tl", table.concat({
    'local greet = require("greet")',
    "-- Wraps [`greet.hello`].",
    "local other: function(): string = greet.hello",
    "return other",
    "",
  }, "\n")))
  local handle = build_and_write(root, "world", tmp .. "/whole.db")
  assert(work.close(handle))
  local names = { "greet", "greet_test" }
  local basis = assert(closure_store.basis(tmp .. "/whole.db"))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/store.db", names, basis))
  local db = assert(Sqlite.open(tmp .. "/store.db"))
  local view = assert(docs.view({ db }))
  local found = assert(docs.uses(view, "greet.hello"))
  assert(db:close())
  local links: mut {string} = {}
  for _, use in ipairs(found) do
    if use.link then links[#links + 1] = use.from_file .. ":" .. tostring(use.line) end
  end
  assert(table.concat(links, " ") == "greet_test.tl:2", table.concat(links, " "))
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
      "--- @kind binding",
      "local record raw",
      "  meta: function(" .. parameter .. ": string): string?",
      "end",
      "return raw",
      "",
    }, "\n")))
  end
  raw("key")
  assert(Fs.write(root .. "/wrap.tl", table.concat({
    'local raw_store = require("raw")',
    "local record wrap",
    "  raw: raw_store",
    "end",
    "return wrap",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/wrap_test.tl", table.concat({
    'local wrap = require("wrap")',
    "local function test_wrap()",
    "  assert(type(wrap) == \"table\")",
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
    support.write_project(root, "world")
    local handle = assert(work.open(root))
    assert(work.stage(handle, { own = false }))
    local result = assert(importer.compile(handle, "closure-store-test"))
    assert(writer.write_result(handle, tmp .. "/whole.db", result))
    local by_path: mut {string:importer.Module} = {}
    for _, m in ipairs(result.modules) do by_path[m.path] = m end
    local declarations: mut {string:string} = {}
    local rows = assert(Sqlite.text_rows(handle.db,
      "SELECT path, file FROM inputs WHERE " .. analysis_schema.declaration("kind")))
    for _, row in ipairs(rows) do
      declarations[row:text(1)] = row:text(2)
    end
    assert(work.close(handle))
    local basis = assert(closure_store.basis(tmp .. "/whole.db"))
    local out: mut {string:string} = {}
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

--- A closure store is a function of its rows alone: written twice from
--- one projection, and again from that projection written afresh, it is
--- the same bytes, wherever it is written -- which is what lets a key
--- hold it by its bytes ([`declared_key.store_digest`]).
local function test_a_closure_store_is_the_same_bytes_each_time_it_is_written(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", 'local greet = require("greet")\n' ..
      "local function test_hello()\n  assert(greet.hello() ~= \"\")\nend\n"))
  local names = { "greet", "greet_test" }
  -- The projection of the project, with a doc, a use, a catalog entry
  -- and an example of the closure beside what the build wrote, so the
  -- store carries rows of each table its full-text indexes are built
  -- from.
  local function projected()
    assert(work.close(build_and_write(root, "world", tmp .. "/whole.db")))
    local db = assert(Sqlite.open(tmp .. "/whole.db", { writable = true }))
    assert(db:exec("INSERT INTO docs (module, symbol, source_symbol, exported, kind, " ..
        "signature, text, file, line) VALUES ('greet', 'greet.wave', 'greet.wave', 1, " ..
        "'function', 'function(): string', 'Waves at the world.', 'greet.tl', 2); " ..
        "INSERT INTO uses (module, symbol, from_module, from_file, line) VALUES " ..
        "('greet', 'hello', 'greet_test', 'greet_test.tl', 99), " ..
        "('greet', 'hello', 'other_test', 'other_test.tl', 7); " ..
        "INSERT INTO catalog (kind, module, symbol, message, text, file, line) VALUES " ..
        "('error', 'greet', 'greet.hello', 'no world to greet', 'Raised with none.', " ..
        "'greet.tl', 4); " ..
        "INSERT INTO examples (module, name, text, file, line, source) VALUES " ..
        "('greet', 'hello', 'Greets the world.', 'greet.tl', 5, 'print(greet.hello())')"))
    assert(db:close())
  end
  projected()
  local basis = assert(closure_store.basis(tmp .. "/whole.db"))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/one.db", names, basis))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/elsewhere/two.db", names, basis))
  assert(Fs.remove(tmp .. "/whole.db"))
  projected()
  local again = assert(closure_store.basis(tmp .. "/whole.db"))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/three.db", names, again))
  local one = assert(Fs.read(tmp .. "/one.db"))
  assert(assert(Fs.read(tmp .. "/elsewhere/two.db")) == one,
    "a second write of the same rows moved the store's bytes")
  assert(assert(Fs.read(tmp .. "/three.db")) == one,
    "a write from the projection written afresh moved the store's bytes")
  -- Found by source module in the extraction, the closure's uses are
  -- the same rows in the same order, and a module outside it adds none.
  assert(closure_store.extract(tmp .. "/whole.db", tmp .. "/extraction.db"))
  assert(closure_store.write(tmp .. "/whole.db", tmp .. "/four.db", names, again,
    tmp .. "/extraction.db"))
  assert(assert(Fs.read(tmp .. "/four.db")) == one,
    "a write from the uses keyed by source module moved the store's bytes")
  local db = assert(Sqlite.open(tmp .. "/one.db"))
  local counts = assert(Sqlite.text_rows(db, "SELECT (SELECT count(*) FROM docs_fts " ..
      "WHERE docs_fts MATCH 'waves'), (SELECT count(*) FROM catalog_fts WHERE catalog_fts " ..
      "MATCH 'world'), (SELECT count(*) FROM examples_fts WHERE examples_fts MATCH 'greets'), " ..
      "(SELECT count(*) FROM uses)"))
  assert(db:close())
  assert(table.concat(support.nth(counts, 1):texts(), " ") == "1 1 1 2", table.concat(support.nth(counts, 1):texts(), " "))
end

--- The key of a test given a closure store holds the store by its bytes,
--- not its address: an edit to the code that writes it that writes the
--- same bytes (a comment in build/schema.tl, which salts the address)
--- moves the address and leaves the key; a change to the rows it
--- carries moves both.
local function test_a_key_holds_a_closure_store_by_its_bytes(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", 'local greet = require("greet")\n' ..
      "local function test_hello()\n  assert(greet.hello() ~= \"\")\nend\n"))
  local names = { "greet", "greet_test" }
  assert(work.close(build_and_write(root, "world", tmp .. "/whole.db")))
  local digests = declared_key.digests(tmp)
  --- The address of the store written under `salt` at `out`, and the
  --- key of a test given it.
  local function keyed(salt: string, out: string): string, string
    local basis = assert(closure_store.basis(tmp .. "/whole.db"))
    local address = closure_store.address(basis, names, salt)
    assert(closure_store.write(tmp .. "/whole.db", out, names, basis))
    local key, why = declared_key.compute(digests, {
      id = "greet_test test_hello", group = "greet_test", module_key = "module",
      runtime = "runtime", compiler = "", host = "host", epoch = "1-00000000",
      timeout_ns = Clock.seconds(30), declaration = "", environment = {},
      effective = { files = {}, reads = {}, host = {}, env = {}, network = {}, tool = false,
        store = false, caches = {}, cache_paths = {} },
      closure_store = declared_key.store_digest(digests, out),
    })
    assert(key ~= nil, why)
    return address, key
  end
  local address, key = keyed("the writer", tmp .. "/first.db")
  local commented, commented_key = keyed("the writer, commented", tmp .. "/commented.db")
  assert(commented ~= address, "the writer's edit left the address")
  assert(commented_key == key, "an edit to the writer that writes the same bytes moved the key")
  local db = assert(Sqlite.open(tmp .. "/whole.db", { writable = true }))
  assert(db:exec("UPDATE modules SET bytecode = deflate(inflate(bytecode) || X'00') WHERE path = 'greet'"))
  assert(db:close())
  local moved, moved_key = keyed("the writer", tmp .. "/moved.db")
  assert(moved ~= address, "a row of the closure left the address")
  assert(moved_key ~= key, "a change to the store's bytes left the key")
end

--- The basis of a projection is kept beside it once the file is older than
--- the clock's tick, and read back the same; a write to the file, even in
--- place, makes the next read come from its rows.
local function test_a_basis_is_kept_beside_a_projection_that_is_old_enough(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(work.close(build_and_write(root, "world", tmp .. "/whole.db")))
  local whole = tmp .. "/whole.db"
  local fresh = assert(closure_store.basis(whole))
  assert(Fs.exists(whole .. ".basis") ~= true, "a basis was kept of a file just written")
  -- Two seconds on, by a clock the test names, not one it waits on.
  local later = Clock.now_ns() + Clock.seconds(2) + Clock.ms(100)
  local made = assert(closure_store.basis(whole, nil, later))
  assert(Fs.exists(whole .. ".basis") == true, "no basis was kept of a file two seconds old")
  local kept = assert(closure_store.basis(whole, nil, later))
  for _, basis in ipairs({ made, kept }) do
    assert(basis.shared == fresh.shared, "the kept basis names other meta")
    assert(basis.image == fresh.image, "the kept basis names another image_hash")
    for path, line in pairs(fresh.modules) do
      assert(basis.modules[path] == line and basis.kinds[path] == fresh.kinds[path],
        path .. ": a kept basis holds another line")
    end
    assert(#basis.pairable == #fresh.pairable, "a kept basis pairs other modules")
  end
  local db = assert(Sqlite.open(whole, { writable = true }))
  assert(db:exec("UPDATE modules SET bytecode = deflate(inflate(bytecode) || X'00') WHERE path = 'greet'"))
  assert(db:close())
  local changed = assert(closure_store.basis(whole))
  assert(changed.modules["greet"] ~= fresh.modules["greet"],
    "a basis kept of the file before an edit in place answered after it")
  -- Once the edited file is older than the tick too, a basis is kept and
  -- looked for again: only its token says it is of the file before the edit.
  do
    local held_true, held_why = Fs.exists(whole .. ".basis")
    assert(held_true == true, held_why)
  end
  local old_token = assert(closure_store.basis(whole, nil, Clock.now_ns() + Clock.seconds(2) + Clock.ms(100)))
  assert(old_token.modules["greet"] == changed.modules["greet"],
    "a basis kept of the file before an edit in place answered after it, once the file was old")
  assert(old_token.modules["greet"] ~= fresh.modules["greet"], "the edit is not in the kept basis")
end

--- The first module the reader map names as a reader of `image_hash`.
local function image_reader(): string
  return support.nth(assert(key_parts.meta_group("image_hash")).readers, 1)
end

--- The `image_hash` row of the projection at `whole`, set to `value`.
local function set_image_hash(whole: string, value: string)
  local db = assert(Sqlite.open(whole, { writable = true }))
  assert(Sqlite.run(db, "INSERT OR REPLACE INTO meta (key, value) VALUES ('image_hash', ?1)",
    { { text = value } }))
  assert(db:close())
end

--- A project with two test modules: one whose closure holds a reader of
--- `image_hash` (the first the map names) and one that holds none.
local function image_project(root: string)
  local reader = image_reader()
  local path = reader:gsub("%.", "/") .. ".tl"
  assert(Fs.mkdirs(root .. "/" .. (path:match("^(.*)/[^/]*$") or ".")))
  assert(Fs.write(root .. "/" .. path, "local record reader\nend\nreturn reader\n"))
  assert(Fs.write(root .. "/reads_test.tl", 'local reader = require("' .. reader .. '")\n' ..
      "local function test_reads()\n  assert(reader ~= nil)\nend\n"))
  assert(Fs.write(root .. "/plain_test.tl", 'local greet = require("greet")\n' ..
      "local function test_hello()\n  assert(greet.hello() ~= \"\")\nend\n"))
end

--- The row `key` of the closure store at `path`, or nil.
local function meta_of(path: string, key: string): string?
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, "SELECT CAST(value AS TEXT) FROM meta WHERE key = ?1",
    { { text = key } }))
  assert(db:close())
  local row = rows[1]
  return if row ~= nil then row:text(1) else nil end
end

--- A closure store carries `image_hash` only where its closure holds a
--- reader of it: a store of a closure that holds none has no such row, so
--- a worker's [`Store.meta`] of that row answers nil there, and neither
--- its address nor its bytes move when the projection's row does; one
--- that holds a reader has the row, and both move. The base store (no
--- module) and the pure store follow the same rule.
local function test_a_closure_store_holds_the_image_hash_only_for_a_reader(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  image_project(root)
  local whole = tmp .. "/whole.db"
  assert(work.close(build_and_write(root, "world", whole)))
  local reader = image_reader()
  local read_closure = { reader, "reads_test" }
  local plain_closure = { "greet", "plain_test" }
  assert(key_parts.reads_meta(read_closure, "image_hash"))
  assert(not key_parts.reads_meta(plain_closure, "image_hash"))
  --- What the stores of both closures, and the base store, are written as for `image`.
  local function written(image: string, tag: string): {string:string}
    set_image_hash(whole, image)
    local basis = assert(closure_store.basis(whole))
    local out: mut {string:string} = {}
    local closures: {string:{string}} = { reader = read_closure, plain = plain_closure, base = {} }
    for name, closure in pairs(closures) do
      out[name .. " address"] = closure_store.address(basis, closure, "salt")
      assert(closure_store.write(whole, tmp .. "/" .. tag .. name .. ".db", closure, basis))
      out[name .. " bytes"] = assert(Fs.read(tmp .. "/" .. tag .. name .. ".db"))
      out[name .. " image"] = meta_of(tmp .. "/" .. tag .. name .. ".db", "image_hash") or "none"
      out[name .. " marker"] = meta_of(tmp .. "/" .. tag .. name .. ".db", "withheld_meta") or "none"
    end
    return out
  end
  local one = written("image one", "one-")
  local two = written("image two", "two-")
  assert(one["reader image"] == "image one" and two["reader image"] == "image two",
    "the store of a closure that reads image_hash does not carry it")
  assert(one["plain image"] == "none" and one["base image"] == "none",
    "a store of a closure that reads no image_hash carries it")
  assert(one["reader address"] ~= two["reader address"], "the reader's address did not follow image_hash")
  assert(one["reader bytes"] ~= two["reader bytes"], "the reader's store did not follow image_hash")
  for _, name in ipairs({ "plain", "base" }) do
    assert(one[name .. " address"] == two[name .. " address"], name .. ": image_hash moved the address")
    assert(one[name .. " bytes"] == two[name .. " bytes"], name .. ": image_hash moved the store's bytes")
  end
  -- In its place the same marker, whatever the row holds, so no edit moves a byte of it.
  assert(one["plain marker"] == "image_hash" and one["base marker"] == "image_hash",
    "a store that withholds image_hash does not say so")
  assert(one["reader marker"] == "none" and two["reader marker"] == "none",
    "a store that holds image_hash says it withholds it")
  assert(one["plain address"] ~= one["reader address"])
end

--- The key of a test given the store of its closure moves with
--- `image_hash` exactly where its closure holds a reader. The row is the
--- one a boot records over a tree whose seed files (build/seed.txt) one
--- comment edited ([`identity.record_fingerprint`]): the edit moves it,
--- and moves the key of the reader alone.
local function test_a_comment_in_a_seed_file_moves_the_key_of_a_reader_alone(tmp: string)
  local seed = tmp .. "/seed"
  for _, dir in ipairs({ "build", "core", "cosmic", "cmd/cosmic", "bin", "lang" }) do
    assert(Fs.mkdirs(seed .. "/" .. dir))
  end
  assert(Fs.write(seed .. "/build/seed.txt", "lang/truthy.tl\n"))
  assert(Fs.write(seed .. "/lang/truthy.tl", "local record truthy\nend\nreturn truthy\n"))
  --- The `image_hash` a boot records over the seed tree as it is.
  local function recorded(): string
    local handle = assert(work.open(seed))
    assert(work.stage(handle, { own = true }))
    local fingerprint = assert(identity.record_fingerprint(handle.db, handle.root))
    work.close(handle)
    return fingerprint.image
  end
  local before = recorded()
  assert(Fs.write(seed .. "/lang/truthy.tl", "local record truthy\nend\n-- a comment\nreturn truthy\n"))
  local after = recorded()
  assert(after ~= before, "a comment in a seed file did not move image_hash")

  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  image_project(root)
  local whole = tmp .. "/whole.db"
  assert(work.close(build_and_write(root, "world", whole)))
  local digests = declared_key.digests(tmp)
  local reader = image_reader()
  --- The key of a test whose module is `group`, given the store of `names` for the projection as `image` has it.
  local function keyed(group: string, names: {string}, image: string): string
    set_image_hash(whole, image)
    local basis = assert(closure_store.basis(whole))
    local out = tmp .. "/" .. group .. "-" .. image:sub(1, 8) .. ".db"
    assert(closure_store.write(whole, out, names, basis))
    local key, why = declared_key.compute(digests, {
      id = group .. " test", group = group, module_key = "module",
      runtime = "runtime", compiler = "", host = "host", epoch = "1-00000000",
      timeout_ns = Clock.seconds(30), declaration = "", environment = {},
      effective = { files = {}, reads = {}, host = {}, env = {}, network = {}, tool = false,
        store = false, caches = {}, cache_paths = {} },
      closure_store = declared_key.store_digest(digests, out),
    })
    assert(key ~= nil, why)
    return key
  end
  local plain_before = keyed("plain_test", { "greet", "plain_test" }, before)
  local plain_after = keyed("plain_test", { "greet", "plain_test" }, after)
  assert(plain_before == plain_after, "a comment in a seed file moved the key of a test that reads no image_hash")
  local read_before = keyed("reads_test", { reader, "reads_test" }, before)
  local read_after = keyed("reads_test", { reader, "reads_test" }, after)
  assert(read_before ~= read_after, "a comment in a seed file left the key of a test that reads image_hash")
end
