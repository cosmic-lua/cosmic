--- Tests of [`build.writer`]: `write_result` must trust only the projection
--- already sitting at `out`, never a record kept somewhere else. The
--- working database's own `meta` table can drift from the file on disk:
--- [`build/boot.tl`] reuses one working database across several output
--- paths, and a snapshot of `o/build.db` restored after `o/cosmic.db`
--- moved on both leave a row that no longer describes the file.

local Compress = require("cosmic.compress")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local importer = require("build.importer")
local schema = require("build.schema")
local work = require("build.work")
local writer = require("build.writer")
local fixture = require("build.docs_fixture")

--- The element of `list` at `index`, which the case knows is there.
local function nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

--- Writes a minimal one-module project at `root`, greeting `whom`, so
--- two projects built from a different `whom` compile to different
--- module keys and so a different signature.
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

--- Compiles the project at `root` and writes it to `out`, returning the
--- open working handle and its compiled result so the caller can write
--- again against it.
local function build_and_write(root: string, whom: string, out: string,
                               tool?: string): work.Handle, importer.Result
  write_project(root, whom)
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, tool or "writer-test"))
  assert(writer.write_result(handle, out, result))
  return handle, result
end

--- The signature a projection at `path` carries in its own `meta`
--- table, or "" when it has none.
local function projected(path: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'projected'"))
  assert(db:close())
  if #rows == 0 then
    return ""
  end
  return rows[1]:text(1)
end

--- A file at `out` that some other write replaced -- a different
--- tree's projection entirely, standing in for a restored working
--- database or a stray copy -- is never mistaken for the current
--- signature just because a working database still agrees with it:
--- write_result must render and write a fresh file.
local function test_a_drifted_file_is_rewritten(tmp: string)
  local handle, result = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  local original = projected(tmp .. "/out.db")
  assert(original ~= "", "the file must carry its own signature")

  -- A second, different tree's projection lands at the same path,
  -- behind the first handle's back -- the drift itself.
  local other_handle = build_and_write(tmp .. "/b", "moon", tmp .. "/out.db")
  assert(work.close(other_handle))
  local drifted = projected(tmp .. "/out.db")
  assert(drifted ~= original, "the fixture must actually differ")

  -- The original handle still names the original signature; the file
  -- now holds a different one. write_result must not trust that they
  -- once agreed and must write the current projection back.
  assert(writer.write_result(handle, tmp .. "/out.db", result))
  assert(work.close(handle))
  assert(projected(tmp .. "/out.db") == original,
    "a drifted file must be rewritten back to the current projection")
end

--- Once the file at `out` already is the current projection, a second
--- `write_result` call for the same inputs leaves it untouched.
local function test_an_unchanged_file_is_not_rewritten(tmp: string)
  local handle, result = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  local before = assert(Fs.stat(tmp .. "/out.db"))

  assert(writer.write_result(handle, tmp .. "/out.db", result))
  assert(work.close(handle))
  local after = assert(Fs.stat(tmp .. "/out.db"))
  assert(before.mtime_ns == after.mtime_ns and before.size == after.size,
    "an unchanged projection must not be rewritten")
end

--- A projection a different binary wrote -- a stale tool rebuilding
--- itself writes `o/cosmic.db` with its own, older writer before the
--- new tool re-enters -- is not this binary's projection, even of the
--- same tree: write_result must write it again.
local function test_a_file_another_binary_wrote_is_rewritten(tmp: string)
  local handle, result = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  local older = assert(writer.signature(handle, result, "an older binary"))
  assert(older ~= projected(tmp .. "/out.db"), "the binary must be part of the signature")

  local db = assert(Sqlite.open(tmp .. "/out.db", { writable = true }))
  assert(Sqlite.run(db, "UPDATE meta SET value = ?1 WHERE key = 'projected'",
    { { text = older } }))
  assert(db:exec("INSERT INTO meta (key, value) VALUES ('older', 'x')"))
  assert(db:close())

  assert(writer.write_result(handle, tmp .. "/out.db", result))
  assert(work.close(handle))
  local out = assert(Sqlite.open(tmp .. "/out.db"))
  local rows = assert(Sqlite.text_rows(out, "SELECT key FROM meta WHERE key = 'older'"))
  assert(out:close())
  assert(#rows == 0, "a file another binary wrote must be rewritten")
end

--- A project's own declaration ships its documentation alongside its
--- modules', so `cosmic docs` answers for a module the project only
--- declares.
local function test_a_declaration_ships_its_docs(tmp: string)
  assert(Fs.mkdirs(tmp .. "/a"))
  assert(Fs.write(tmp .. "/a/clock.d.tl", table.concat({
    "local record clock",
    "  --- Seconds since the epoch.",
    "  now: function(): integer",
    "end",
    "return clock",
    "",
  }, "\n")))
  local handle = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  assert(work.close(handle))
  local out = assert(Sqlite.open(tmp .. "/out.db"))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT text, file, line FROM docs WHERE module = 'clock' AND symbol = 'now'"))
  assert(out:close())
  assert(#rows == 1, tostring(#rows))
  assert(nth(rows, 1):text(1) == "Seconds since the epoch." and nth(rows, 1):text(2) == "clock.d.tl" and
      nth(rows, 1):text(3) == "3", table.concat(nth(rows, 1):texts(), " "))
end

--- What the tool carries is the projection without the tree's own
--- tests and examples, and without a row about one -- but with a test
--- or example file a carried module requires, which the tool could not
--- load without -- written the same bytes every time.
local function test_the_carried_database_leaves_the_tree_s_tests_out(tmp: string)
  local root = tmp .. "/a"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/greet_test.tl", table.concat({
    'local greet = require("greet")',
    "local function greeting(): string?, string",
    '  if greet.hello() ~= "hello, world" then',
    '    return nil, "greet_test: the greeting changed"',
    "  end",
    '  return greet.hello(), ""',
    "end",
    "--- Checks the greeting.",
    "local function test_hello()",
    "  assert(greeting())",
    "end",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/greet_example.tl", table.concat({
    'local greet = require("greet")',
    "local record Example",
    "end",
    "--- Greets.",
    "function Example.hello()",
    '  assert(greet.hello() == "hello, world")',
    "end",
    "return Example",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/shared.tl", table.concat({
    'local fixture = require("fixture_test")',
    "local record shared",
    "end",
    "function shared.name(): string",
    "  return fixture.name",
    "end",
    "return shared",
    "",
  }, "\n")))
  assert(Fs.write(root .. "/fixture_test.tl", 'local record Fixture\n  name: string\nend\nlocal fixture: Fixture = { name = "x" }\nreturn fixture\n'))
  local handle = build_and_write(root, "world", tmp .. "/whole.db")
  assert(work.close(handle))
  -- A bill of materials, as cosmic's own tree's projection holds one.
  local whole_db = assert(Sqlite.open(tmp .. "/whole.db", { writable = true }))
  assert(whole_db:exec("INSERT INTO components VALUES ('zlib', 'library', '1.3', 'Zlib', " ..
      "'https://zlib.net/z.tar.gz', '', '', ''); INSERT INTO notices VALUES ('zlib', 1, " ..
      "'LICENSE', '(C) 1995 Jean-loup Gailly and Mark Adler' || char(10)); " ..
      "INSERT INTO ca_roots VALUES (sha256(x'0506'), 'A Root', x'0506', '')"))
  assert(whole_db:close())
  assert(writer.carried(tmp .. "/whole.db", tmp .. "/carried.db"))
  assert(writer.carried(tmp .. "/whole.db", tmp .. "/again.db"))
  assert(Fs.read(tmp .. "/carried.db") == Fs.read(tmp .. "/again.db"),
    "the carried database is a function of the projection")

  local function rows(path: string, sql: string): Sqlite.Rows
    local db = assert(Sqlite.open(path))
    local found = assert(Sqlite.text_rows(db, sql))
    assert(db:close())
    return found
  end
  local whole = rows(tmp .. "/whole.db",
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM modules ORDER BY path)")
  assert(nth(whole, 1):text(1) ==
      "cmd.hello.main fixture_test greet greet_example greet_test shared",
    nth(whole, 1):text(1))
  local carried = rows(tmp .. "/carried.db",
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM modules ORDER BY path)")
  assert(nth(carried, 1):text(1) == "cmd.hello.main fixture_test greet shared", nth(carried, 1):text(1))
  local about_dropped = rows(tmp .. "/carried.db",
    "SELECT (SELECT count(*) FROM docs WHERE module IN ('greet_test', 'greet_example')) " ..
      "+ (SELECT count(*) FROM uses WHERE from_module IN ('greet_test', 'greet_example')) " ..
      "+ (SELECT count(*) FROM imports WHERE path IN ('greet_test', 'greet_example') " ..
      "OR requires IN ('greet_test', 'greet_example')) " ..
      "+ (SELECT count(*) FROM catalog WHERE module IN ('greet_test', 'greet_example'))")
  local in_whole = rows(tmp .. "/whole.db",
    "SELECT count(*) FROM catalog WHERE module = 'greet_test'")
  assert(nth(in_whole, 1):text(1) == "1", "the projection holds the test's catalog row")
  assert(nth(about_dropped, 1):text(1) == "0", "a row about a dropped module is carried")
  -- `greet` is no public standard-library module, so its docs and the
  -- example about it stay in the projection: `test_the_carried_docs_*`
  -- below covers which docs rows are carried.
  local kept = rows(tmp .. "/carried.db",
    "SELECT (SELECT count(*) FROM examples WHERE module = 'greet'), " ..
      "(SELECT count(*) FROM docs WHERE module = 'greet'), " ..
      "(SELECT value FROM meta WHERE key = 'main')")
  local documented = rows(tmp .. "/whole.db",
    "SELECT (SELECT count(*) FROM examples WHERE module = 'greet'), " ..
      "(SELECT count(*) FROM docs WHERE module = 'greet')")
  assert(nth(documented, 1):text(1) == "1" and assert(tonumber(nth(documented, 1):text(2)), "the docs count is a number") > 0,
    "the projection documents greet")
  assert(nth(kept, 1):text(1) == "0" and nth(kept, 1):text(2) == "0", "greet's docs stay in the projection")
  assert(nth(kept, 1):text(3) == "cmd.hello.main", "meta is carried")
  local materials = rows(tmp .. "/carried.db",
    "SELECT c.name, c.license, n.text FROM components c JOIN notices n ON n.component = c.name")
  assert(#materials == 1 and materials[1]:text(1) == "zlib" and nth(materials, 1):text(2) == "Zlib" and
      nth(materials, 1):text(3) == "(C) 1995 Jean-loup Gailly and Mark Adler\n",
    "the tool carries the projection's bill of materials")
  local trusted = rows(tmp .. "/carried.db", "SELECT label, hex(der) FROM ca_roots")
  assert(#trusted == 1 and trusted[1]:text(1) == "A Root" and nth(trusted, 1):text(2) == "0506",
    "the tool carries the projection's CA roots")
end

--- An edit to a test moves the projection and its signature, but not
--- the database the tool carries, which leaves the test out: it carries
--- none of the projection's `projected` row, so a tool built from the
--- tree before the edit and one built after are the same bytes, and so
--- is what a verdict keyed by them (CI's fixtures) turns on.
local function test_an_edit_to_a_test_moves_nothing_the_tool_carries(tmp: string)
  local root = tmp .. "/a"
  local function edit(body: string)
    assert(Fs.mkdirs(root))
    assert(Fs.write(root .. "/greet_test.tl", table.concat({
      'local greet = require("greet")',
      "-- " .. body,
      "local function test_hello()",
      '  assert(greet.hello() == "hello, world")',
      "end",
      "",
    }, "\n")))
  end
  edit("before")
  local handle = build_and_write(root, "world", tmp .. "/before.db")
  assert(work.close(handle))
  edit("after")
  handle = build_and_write(root, "world", tmp .. "/after.db")
  assert(work.close(handle))
  local signed = projected(tmp .. "/before.db")
  assert(signed ~= "" and projected(tmp .. "/after.db") ~= signed,
    "the edit to the test must move the projection's signature")
  assert(writer.carried(tmp .. "/before.db", tmp .. "/carried_before.db"))
  assert(writer.carried(tmp .. "/after.db", tmp .. "/carried_after.db"))
  assert(projected(tmp .. "/carried_before.db") == "",
    "the tool carries the projection's signature")
  assert(Fs.read(tmp .. "/carried_before.db") == Fs.read(tmp .. "/carried_after.db"),
    "an edit to a test moved the database the tool carries")
end

--- A projection ships what a reader of it loads -- each module's
--- bytecode and its Teal source, deflated -- and not the Lua tl
--- generated on the way, which only the working database's `compiled`
--- needs.
local function test_a_module_ships_its_bytecode_and_not_its_lua(tmp: string)
  local handle = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  assert(work.close(handle))
  local out = assert(Sqlite.open(tmp .. "/out.db"))
  local columns = assert(Sqlite.text_rows(out,
    "SELECT name FROM pragma_table_info('modules') WHERE name = 'lua'"))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT length(bytecode) > 0, " ..
      "instr(CAST(inflate(source) AS TEXT), 'hello, world') > 0, " ..
      "instr(CAST(source AS TEXT), 'function greet.hello') = 0 " ..
      "FROM modules WHERE path = 'greet'"))
  assert(out:close())
  assert(#columns == 0, "the shipped modules table carries generated Lua")
  assert(#rows == 1 and rows[1]:text(1) == "1" and nth(rows, 1):text(2) == "1",
    tostring(#rows))
  assert(nth(rows, 1):text(3) == "1", "the source is stored deflated")
end

--- The zones the working database holds ship in the projection, and are
--- part of what it is a function of: new zones write it again.
local function test_the_zones_ship_and_sign_the_projection(tmp: string)
  local out = tmp .. "/out.db"
  local handle, result = build_and_write(tmp .. "/a", "world", out)
  local before = projected(out)
  assert(work.put_zoneinfo(handle, { ["Test/Zone"] = "TZif\0test", ["A/Zone"] = "TZif a" }))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
  assert(projected(out) ~= before, "new zones sign a new projection")
  local db = assert(Sqlite.open(out))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT group_concat(name || ' ' || typeof(data) || ' ' || length(data), ',' ORDER BY rowid) " ..
      "FROM zoneinfo"))
  assert(db:close())
  assert(nth(rows, 1):text(1) == "A/Zone blob 6,Test/Zone blob 9", nth(rows, 1):text(1))
  -- And the tool built from the projection carries them too.
  assert(writer.carried(out, tmp .. "/carried.db"))
  local carried = assert(Sqlite.open(tmp .. "/carried.db"))
  local kept = assert(Sqlite.text_rows(carried,
    "SELECT group_concat(name || ' ' || typeof(data), ',' ORDER BY rowid) FROM zoneinfo"))
  assert(carried:close())
  assert(nth(kept, 1):text(1) == "A/Zone blob,Test/Zone blob", nth(kept, 1):text(1))
end

--- The web assets the working database holds ship in the projection and
--- the tool built from it, and are part of what it is a function of.
local function test_the_web_assets_ship_and_sign_the_projection(tmp: string)
  local out = tmp .. "/out.db"
  local handle, result = build_and_write(tmp .. "/a", "world", out)
  local before = projected(out)
  assert(work.put_web_assets(handle, {
    { name = "b.js", data = "bee\0", sha256 = "s2", sha384 = "t2", version = "2" },
    { name = "a.js", data = "ay", sha256 = "s1", sha384 = "t1", version = "1" } }))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
  assert(projected(out) ~= before, "new web assets sign a new projection")
  local function listed(path: string): string
    local db = assert(Sqlite.open(path))
    local rows = assert(Sqlite.text_rows(db,
      "SELECT group_concat(name || ' ' || typeof(data) || ' ' || length(data) || ' ' || " ..
        "sha256 || ' ' || sha384 || ' ' || version, ',' ORDER BY name) FROM web_assets"))
    assert(db:close())
    return nth(rows, 1):text(1)
  end
  local expected = "a.js blob 2 s1 t1 1,b.js blob 4 s2 t2 2"
  assert(listed(out) == expected, listed(out))
  assert(writer.carried(out, tmp .. "/carried.db"))
  assert(listed(tmp .. "/carried.db") == expected, listed(tmp .. "/carried.db"))
end

--- Of a projection's docs, uses and examples, the tool carries what a
--- reader asks it for outside cosmic's own tree -- the public standard
--- library's -- and, of every other doc row, the internal type a
--- public alias names through the module it binds. A dropped module's
--- rows go even so.
local function test_the_carried_docs_are_the_public_standard_library_s(tmp: string)
  local whole = tmp .. "/whole.db"
  local db = assert(Sqlite.open(whole, { writable = true }))
  for _, statement in ipairs(schema.settings("")) do assert(db:exec(statement)) end
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  for _, statement in ipairs({
      "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
        "VALUES ('cosmic.fs', 'cosmic/fs.tl', 'module', '', '', '', '', ''), " ..
        "('cosmic.fs_example', 'cosmic/fs_example.tl', 'example', '', '', '', '', ''), " ..
        "('build.work', 'build/work.tl', 'module', '', '', '', '', ''), " ..
        "('build.tree', 'build/tree.tl', 'module', '', '', '', '', '')",
      "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, " ..
        "text, file, line) VALUES " ..
        "('cosmic.fs', 'Fs.read', 'Fs.read', 1, 'function', '', 'Reads a file.', 'f', 1), " ..
        "('cosmic.internal.fs', 'raw', 'raw', 1, 'function', '', 'Raw.', 'f', 1), " ..
        "('cosmic.internal.fs', 'Stat', 'raw.Stat', 1, 'record', '', 'A stat.', 'f', 1), " ..
        "('cosmic.internal.fs', 'Stat.size', 'raw.Stat.size', 1, 'field', '', 'Its size.', 'f', 1), " ..
        "('cosmic.internal.fs', 'open', 'raw.open', 1, 'field', '', 'Opens.', 'f', 1), " ..
        "('cosmic.internal.fs', 'Other', 'raw.Other', 1, 'record', '', 'Unreached.', 'f', 1), " ..
        "('cosmic.internal.fs', 'Other.n', 'raw.Other.n', 1, 'field', '', 'Unreached.', 'f', 1), " ..
        "('cosmic.fs', 'Fs.Stat', 'Fs.Stat', 1, 'field', 'type Stat = Native.Stat', 'A stat.', " ..
        "'f', 1), " ..
        "('cosmic.fs_example', 'Example.read', 'Example.read', 1, 'function', '', " ..
        "'Shows it.', 'f', 1), " ..
        "('build.work', 'work.open', 'work.open', 1, 'function', '', " ..
        "'Opens the working database.', 'f', 1), " ..
        "('build.tree', 'tree.standing', 'tree.standing', 1, 'function', '', " ..
        "'Whether a tree is cosmic.', 'f', 1)",
      -- The name cosmic.fs binds the internal module to is no spelling of
      -- the module's own.
      "INSERT INTO bound (path, name, requires) VALUES " ..
        "('cosmic.fs', 'Native', 'cosmic.internal.fs'), " ..
        "('cosmic.fs_example', 'Fs', 'cosmic.fs')",
      "INSERT INTO catalog (kind, module, symbol, message, text, file, line) " ..
        "VALUES ('error', 'build.work', 'work.open', 'cannot open', NULL, 'f', 1)",
      "INSERT INTO uses (module, symbol, from_module, from_file, line) VALUES " ..
        "('cosmic.fs', 'read', 'cosmic.fs', 'f', 1), " ..
        "('cosmic.fs', 'read', 'build.work', 'f', 2), " ..
        "('build.tree', 'standing', 'build.work', 'f', 3), " ..
        "('cosmic.fs', 'read', 'cosmic.fs_example', 'f', 4)",
      "INSERT INTO examples (module, name, text, file, line, source) VALUES " ..
        "('cosmic.fs', 'read', 'Reads.', 'f', 1, 'Fs.read(p)'), " ..
        "('build.tree', 'own', 'Owns.', 'f', 1, 'tree.standing(r)')",
      "INSERT INTO links (module, symbol, path, anchor, from_file, line, column, from_module, " ..
        "kind, form, source, text) VALUES " ..
        "('cosmic.fs', 'read', '', '', 'f', 5, 1, 'cosmic.fs', 'symbol', 'shortcut', 'doc', 'r'), " ..
        "('cosmic.fs', 'read', '', '', 'f', 6, 1, 'build.work', 'symbol', 'shortcut', 'doc', 'r'), " ..
        "('', '', 'doc/a.md', '', 'f', 7, 1, 'cosmic.fs', 'file', 'inline', 'doc', 'a'), " ..
        "('cosmic.fs', 'read', '', '', 'f', 8, 1, 'cosmic.fs_example', 'symbol', 'shortcut', " ..
        "'doc', 'r')",
  }) do
    assert(db:exec(statement))
  end
  assert(db:close())
  assert(writer.carried(whole, tmp .. "/carried.db"))
  local out = assert(Sqlite.open(tmp .. "/carried.db"))
  local function column(sql: string): string
    local found = assert(Sqlite.text_rows(out,
      "SELECT coalesce(group_concat(v, ' '), '') FROM (" .. sql .. ")"))
    return nth(found, 1):text(1)
  end
  local docs = column("SELECT module AS v FROM docs ORDER BY id")
  local uses = column("SELECT from_module || '>' || module AS v FROM uses " ..
      "ORDER BY module, symbol, from_module, line")
  local examples = column("SELECT module AS v FROM examples ORDER BY id")
  local bound = column("SELECT path || ':' || name AS v FROM bound ORDER BY path")
  local linked = column("SELECT from_module || ':' || line || '>' || module || path AS v " ..
      "FROM links ORDER BY from_file, line")
  local indexed = column("SELECT d.module AS v FROM docs_fts JOIN docs d " ..
      "ON d.id = docs_fts.rowid WHERE docs_fts MATCH 'opens OR reads' ORDER BY d.id")
  assert(out:close())
  -- The internal rows carried are the nested type and its member, which a
  -- public alias's page lists, not the module's own function or field.
  assert(docs == "cosmic.fs cosmic.internal.fs cosmic.internal.fs cosmic.fs",
    "the docs carried: " .. docs)
  assert(uses == "cosmic.fs>cosmic.fs", "the uses carried: " .. uses)
  assert(examples == "cosmic.fs", "the examples carried: " .. examples)
  assert(bound == "cosmic.fs:Native", "the names bound carried: " .. bound)
  -- A link to a file names one of the tree's own, which a project lacks.
  assert(linked == "cosmic.fs:5>cosmic.fs", "the links carried: " .. linked)
  assert(indexed == "cosmic.fs", "the docs index: " .. indexed)
end

--- An internal type is carried when a public declaration names it through
--- the name its own module binds: as an alias's whole target, or as one of
--- the bases a record or interface lists, and so is each of its members.
--- A name that only ends in the bound one, a
--- binding to another internal module, and a declaration outside the
--- public standard library reach nothing, however many internal rows there
--- are to ask about.
local function test_the_carried_internal_types_are_the_ones_a_public_signature_names(tmp: string)
  local whole = tmp .. "/whole.db"
  local db = assert(Sqlite.open(whole, { writable = true }))
  for _, statement in ipairs(schema.settings("")) do assert(db:exec(statement)) end
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  local function internal(module: string, type_name: string): string
    return "('" .. module .. "', '" .. type_name .. "', 'raw." .. type_name ..
      "', 1, 'record', '', 'A type.', 'f', 1)"
  end
  for _, statement in ipairs({
      "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, " ..
        "text, file, line) VALUES " ..
        internal("cosmic.internal.net", "Alias") .. ", " ..
        internal("cosmic.internal.net", "First") .. ", " ..
        internal("cosmic.internal.net", "Second") .. ", " ..
        internal("cosmic.internal.net", "Suffixed") .. ", " ..
        internal("cosmic.internal.other", "Elsewhere") .. ", " ..
        internal("cosmic.internal.net", "Hidden") .. ", " ..
        internal("cosmic.internal.net", "Base") .. ", " ..
        "('cosmic.internal.net', 'Alias.size', 'raw.Alias.size', 1, 'field', '', " ..
        "'A member.', 'f', 1), " ..
        "('cosmic.internal.net', 'Hidden.size', 'raw.Hidden.size', 1, 'field', '', " ..
        "'Not reached.', 'f', 1), " ..
        "('cosmic.net', 'Net.Alias', 'Net.Alias', 1, 'field', 'type Alias = Native.Alias', " ..
        "'An alias.', 'f', 1), " ..
        "('cosmic.net', 'Net.Options', 'Net.Options', 1, 'record', " ..
        "'record Options is Native.First, Native.Second', 'Options.', 'f', 1), " ..
        "('cosmic.net', 'Net.Suffixed', 'Net.Suffixed', 1, 'field', " ..
        "'type Suffixed = NotNative.Suffixed', 'Not it.', 'f', 1), " ..
        "('cosmic.net', 'Net.Elsewhere', 'Net.Elsewhere', 1, 'field', " ..
        "'type Elsewhere = Native.Elsewhere', 'Not it.', 'f', 1), " ..
        "('build.net', 'net.Hidden', 'net.Hidden', 1, 'field', " ..
        "'type Hidden = Native.Hidden', 'Not public.', 'f', 1), " ..
        "('cosmic.net', 'Net.Shape', 'Net.Shape', 1, 'interface', " ..
        "'interface Shape is Native.Base', 'A shape.', 'f', 1)",
      "INSERT INTO bound (path, name, requires) VALUES " ..
        "('cosmic.net', 'Native', 'cosmic.internal.net'), " ..
        "('build.net', 'Native', 'cosmic.internal.net')",
  }) do
    assert(db:exec(statement))
  end
  assert(db:close())
  assert(writer.carried(whole, tmp .. "/carried.db"))
  local out = assert(Sqlite.open(tmp .. "/carried.db"))
  local found = assert(Sqlite.text_rows(out,
    "SELECT coalesce(group_concat(symbol, ' '), '') FROM (SELECT symbol FROM docs " ..
      "WHERE module LIKE 'cosmic.internal.%' ORDER BY id)"))
  assert(out:close())
  assert(nth(found, 1):text(1) == "Alias First Second Base Alias.size", "the internal types carried: " .. nth(found, 1):text(1))
end

--- A user guide is a generated test module, which the tool does not
--- carry, but its prose is what `cosmic docs quickstart` answers with:
--- its own doc row is carried, not the helpers its module declares, and
--- a guide about the runtime's own construction is left to the tree.
local function test_the_carried_docs_hold_the_user_guides_prose(tmp: string)
  local whole = tmp .. "/whole.db"
  local db = assert(Sqlite.open(whole, { writable = true }))
  for _, statement in ipairs(schema.settings("")) do assert(db:exec(statement)) end
  for _, statement in ipairs(schema.create("")) do assert(db:exec(statement)) end
  for _, statement in ipairs({
      "INSERT INTO modules (path, file, kind, source_hash, key, bytecode, tests, source) " ..
        "VALUES ('doc.guides.quickstart', 'doc/guides/quickstart.md', 'test', '', '', '', '', ''), " ..
        "('doc.guides.portable-runtime', 'doc/guides/portable-runtime.md', 'test', '', '', '', '', '')",
      "INSERT INTO docs (module, symbol, source_symbol, exported, kind, signature, " ..
        "text, file, line) VALUES " ..
        "('doc.guides.quickstart', '', '', 1, 'module', '', 'A tour.', 'f', 1), " ..
        "('doc.guides.quickstart', '__doctest_write', '__doctest_write', 0, 'function', '', " ..
        "'A helper.', 'f', 1), " ..
        "('doc.guides.portable-runtime', '', '', 1, 'module', '', 'How it is built.', 'f', 1)",
  }) do
    assert(db:exec(statement))
  end
  assert(db:close())
  assert(writer.carried(whole, tmp .. "/carried.db"))
  local out = assert(Sqlite.open(tmp .. "/carried.db"))
  local found = assert(Sqlite.text_rows(out,
    "SELECT coalesce(group_concat(module || '|' || text, ' '), '') FROM docs"))
  assert(out:close())
  assert(nth(found, 1):text(1) == "doc.guides.quickstart|A tour.", nth(found, 1):text(1))
end

--- Rebuilding the projection from the same source assigns the same
--- rowids regardless of the output path or the working database.
local function test_a_project_is_reproducible(tmp: string)
  assert(work.close((build_and_write(tmp .. "/one", "world", tmp .. "/one.db"))))
  assert(work.close((build_and_write(tmp .. "/two", "world", tmp .. "/two.db"))))
  assert(Fs.read(tmp .. "/one.db") == Fs.read(tmp .. "/two.db"),
    "equivalent projects produced different projections")
end

--- The compressed sources a projection ships are kept in the working
--- database by source, so an edit compresses only what it changed: a
--- projection written again after one is the very bytes a fresh working
--- database writes, carries the edited text and not the old, and the
--- cache holds no source the tree no longer has.
local function test_an_edited_source_is_not_served_from_the_deflate_cache(tmp: string)
  local handle = build_and_write(tmp .. "/a", "world", tmp .. "/first.db")
  local before = assert(Sqlite.text_rows(handle.db, "SELECT count(*) FROM deflated"))
  assert(assert(before[1]):text(1) ~= "0", "writing a projection fills the cache")

  write_project(tmp .. "/a", "moon")
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "writer-test"))
  assert(writer.write_result(handle, tmp .. "/second.db", result))
  local stale = assert(Sqlite.text_rows(handle.db,
    "SELECT count(*) FROM deflated WHERE source_hash NOT IN (SELECT source_hash FROM inputs)"))
  assert(assert(stale[1]):text(1) == "0", "the cache holds a source no input has")
  assert(work.close(handle))

  assert(work.close((build_and_write(tmp .. "/b", "moon", tmp .. "/fresh.db"))))
  assert(Fs.read(tmp .. "/second.db") == Fs.read(tmp .. "/fresh.db"),
    "a projection served from the cache differs from a fresh one")
  local out = assert(Sqlite.open(tmp .. "/second.db"))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT instr(CAST(inflate(source) AS TEXT), 'hello, moon') > 0, " ..
      "instr(CAST(inflate(source) AS TEXT), 'hello, world') > 0 " ..
      "FROM modules WHERE path = 'greet'"))
  assert(out:close())
  local shipped = assert(rows[1])
  assert(shipped:text(1) == "1" and shipped:text(2) == "0", "the edited source was not shipped")
end

--- A compressed source is kept for the core that compressed it: a
--- projection written by a core of another image never ships bytes the
--- first made, and the cache drops what that core made.
local function test_a_source_is_deflated_again_by_a_core_of_another_image(tmp: string)
  local handle = build_and_write(tmp .. "/a", "world", tmp .. "/first.db")
  assert(handle.db:exec("UPDATE deflated SET data = x'00'"))
  assert(handle.db:exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('image_hash', 'other-core')"))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "writer-test"))
  assert(writer.write_result(handle, tmp .. "/second.db", result))
  local cores = assert(Sqlite.text_rows(handle.db, "SELECT DISTINCT core FROM deflated"))
  assert(#cores == 1 and assert(cores[1]):text(1) == "6f746865722d636f7265",
    "the cache holds a core's bytes that is not the writing core's")
  assert(work.close(handle))
  local out = assert(Sqlite.open(tmp .. "/second.db"))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT instr(CAST(inflate(source) AS TEXT), 'hello, world') > 0 FROM modules WHERE path = 'greet'"))
  assert(out:close())
  assert(assert(rows[1]):text(1) == "1", "another core's compressed source was shipped")
end

--- A paired declaration describes the interface; only its implementation
--- contributes executable rows and runtime dependencies.
local function test_paired_declaration_projects_each_source_in_its_role(tmp: string)
  local db = fixture.database(tmp, {
    ["decl_dep.tl"] = "local record Dep\n  declared: integer\nend\nreturn Dep\n",
    ["impl_dep.tl"] = "local record Dep\n  executed: integer\nend\nreturn Dep\n",
    ["foo.d.tl"] = 'local Dep = require("decl_dep")\n' ..
      "--- Public interface.\n--- See [`Dep.declared`].\nlocal record Foo\n  answer: integer\n" ..
      "  fail: function(): nil, string\nend\nreturn Foo\n",
    ["foo.tl"] = 'local Dep = require("impl_dep")\n' ..
      "--- Private implementation.\n--- See [`Dep.executed`].\nlocal record Foo\n  answer: integer\nend\n" ..
      'local x = Dep.executed\nfunction Foo.fail(): nil, string\n' ..
      '  return nil, "implementation error"\nend\nlocal value: Foo = { answer = 42 }\nreturn value\n',
    ["only.d.tl"] = "--- Declaration alone.\nlocal record Only\nend\nreturn Only\n",
  })
  local function rows(sql: string): Sqlite.Rows
    return (assert(Sqlite.text_rows(db, sql)))
  end
  local module = rows("SELECT file, kind, inflate(source) FROM modules WHERE path = 'foo'")
  assert(#module == 1 and module[1]:text(1) == "foo.tl" and nth(module, 1):text(2) ~= "decl")
  assert(nth(module, 1):text(3):find("answer = 42", 1, true), nth(module, 1):text(3))
  assert(nth(rows("SELECT count(*) FROM decls WHERE path IN ('foo', 'only')"), 1):text(1) == "2")
  assert(nth(rows("SELECT count(*) FROM modules WHERE path = 'only'"), 1):text(1) == "0")
  local imports = rows("SELECT requires FROM imports WHERE path = 'foo'")
  assert(#imports == 1 and imports[1]:text(1) == "impl_dep")
  local bound = rows("SELECT requires FROM bound WHERE path = 'foo' AND name = 'Dep'")
  assert(#bound == 1 and bound[1]:text(1) == "decl_dep")
  local docs = rows("SELECT file, text FROM docs WHERE module = 'foo' AND symbol = 'Foo'")
  assert(#docs == 1 and docs[1]:text(1) == "foo.d.tl" and nth(docs, 1):text(2):find("Public interface.", 1, true) ~= nil)
  local uses = rows("SELECT module, symbol, from_file FROM uses WHERE from_module = 'foo'")
  assert(#uses == 1 and uses[1]:text(1) == "impl_dep" and nth(uses, 1):text(2) == "executed" and
      nth(uses, 1):text(3) == "foo.tl")
  local catalog = rows("SELECT message, file FROM catalog WHERE module = 'foo'")
  assert(#catalog == 1 and catalog[1]:text(1) == "implementation error" and nth(catalog, 1):text(2) == "foo.tl")
  local links = rows("SELECT module, symbol, from_file FROM links WHERE from_module = 'foo'")
  assert(#links == 1 and links[1]:text(1) == "decl_dep" and nth(links, 1):text(2) == "declared" and
      nth(links, 1):text(3) == "foo.d.tl")
  assert(nth(rows("SELECT count(*) FROM docs WHERE module = 'only'"), 1):text(1) ~= "0")
  assert(db:close())
end

--- A module's edge to a name the plan does not ship, a declaration with
--- no implementation, is kept for the checker in `decl_imports` and
--- left out of `imports`, which the program's closures are made of.
local function test_an_edge_to_a_declaration_is_kept_beside_the_runtime_edges(tmp: string)
  local db = fixture.database(tmp, {
    ["only.d.tl"] = "local record Only\n  n: integer\nend\nreturn Only\n",
    ["dep.tl"] = "local record Dep\nend\nreturn Dep\n",
    ["paired.d.tl"] = 'local type Dep = require("dep")\nlocal record Paired\n  dep: Dep\nend\nreturn Paired\n',
    ["paired.tl"] = "local record Paired\nend\nreturn Paired\n",
    ["foo.tl"] = 'local type Only = require("only")\nlocal Dep = require("dep")\n' ..
      "local record Foo\n  only: Only\nend\nreturn Foo\n",
  })
  local function names(table_name: string): string
    local rows = assert(Sqlite.text_rows(db,
      "SELECT requires FROM " .. table_name .. " WHERE path = 'foo' AND requires <> '' " ..
        "ORDER BY requires"))
    local out: mut {string} = {}
    for index, row in ipairs(rows) do out[index] = row:text(1) end
    return table.concat(out, ",")
  end
  assert(names("imports") == "dep", names("imports"))
  assert(names("decl_imports") == "dep,only", names("decl_imports"))
  local paired = assert(Sqlite.text_rows(db,
    "SELECT requires FROM decl_imports WHERE path = 'paired' AND requires <> ''"))
  assert(#paired == 1 and paired[1]:text(1) == "dep", "a pair keeps its declaration's edges")
  local leaf = assert(Sqlite.text_rows(db,
    "SELECT requires FROM decl_imports WHERE path = 'dep'"))
  assert(#leaf == 1 and leaf[1]:text(1) == "", "a module with no edge has the empty row")
  assert(db:close())
end

--- A projection failure rolls back the working transaction and discards
--- the attached snapshot, so the same handle can stage and publish again.
local function test_a_failed_projection_can_be_retried(tmp: string)
  write_project(tmp, "retry")
  local handle = assert(work.open(tmp))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "writer-test"))
  assert(handle.db:exec("DROP TABLE compiled"))
  local out = tmp .. "/out.db"
  local written, trouble = writer.write_result(handle, out, result)
  assert(not written and trouble:find("compiled", 1, true) ~= nil, trouble)
  assert(not handle.inside, "the failed projection left its transaction open")
  assert(Fs.stat(out) == nil, "the failed projection published a file")
  assert(handle.db:exec("ATTACH ':memory:' AS out"), "the failed snapshot stayed attached")
  assert(handle.db:exec("DETACH out"))
  assert(work.begin(handle))
  assert(work.stage(handle, { own = false }))
  local retried = assert(importer.compile(handle, "writer-test"))
  assert(writer.write_result(handle, out, retried))
  assert(work.close(handle))
  assert(projected(out) ~= "", "the retry did not publish a signed projection")
end

--- Writes the static files of the project at `root`: text worth gzipping,
--- an image, and Teal and a template that are assets, not modules.
local function write_static(root: string, css: string)
  assert(Fs.mkdirs(root .. "/static/css"))
  assert(Fs.mkdirs(root .. "/static/.hidden"))
  assert(Fs.write(root .. "/static/css/app.css", css))
  assert(Fs.write(root .. "/static/logo.png", "\137PNG\0\1\2"))
  assert(Fs.write(root .. "/static/notes.tl", "this is no Teal, and no module {{"))
  assert(Fs.write(root .. "/static/page.tmpl", "{{ this is no template"))
  assert(Fs.write(root .. "/static/.hidden/secret", "x"))
end

--- Compiles the project at `root` and writes its projection to `out`.
local function write_projection(root: string, out: string)
  local handle = assert(work.open(root))
  assert(work.stage(handle, { own = false }))
  local result = assert(importer.compile(handle, "writer-test"))
  assert(writer.write_result(handle, out, result))
  assert(work.close(handle))
end

--- The files under `static/` are the projection's `payload`, with the
--- hash, type and gzip a program serves them by; a `.tl` or `.tmpl`
--- under it is an asset and no module, and a hidden file is left out.
local function test_static_files_ship_as_payload_not_as_modules(tmp: string)
  local css = ("a { color: red }\n"):rep(200)
  write_project(tmp .. "/p", "world")
  write_static(tmp .. "/p", css)
  write_projection(tmp .. "/p", tmp .. "/p.db")
  local db = assert(Sqlite.open(tmp .. "/p.db"))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT path, sha256, type, gzip IS NOT NULL, length(data) FROM payload ORDER BY path"))
  assert(#rows == 4, tostring(#rows) .. " payload rows")
  assert(nth(rows, 1):text(1) == "css/app.css" and nth(rows, 1):text(2) == Hash.hex_sha256(css))
  assert(nth(rows, 1):text(3) == "text/css; charset=utf-8" and nth(rows, 1):text(4) == "1" and nth(rows, 1):text(5) == tostring(#css))
  assert(nth(rows, 2):text(1) == "logo.png" and nth(rows, 2):text(3) == "image/png" and nth(rows, 2):text(4) == "0")
  assert(nth(rows, 3):text(1) == "notes.tl" and nth(rows, 3):text(3) == "application/octet-stream")
  assert(nth(rows, 4):text(1) == "page.tmpl")
  local packed = assert(Sqlite.text_rows(db, "SELECT gzip FROM payload WHERE path = 'css/app.css'"))
  assert(Compress.inflate("gzip", nth(packed, 1):text(1)) == css)
  local bytes = assert(Sqlite.text_rows(db, "SELECT data FROM payload WHERE path = 'logo.png'"))
  assert(nth(bytes, 1):text(1) == "\137PNG\0\1\2", "binary bytes, a NUL among them, are kept")
  local modules = assert(Sqlite.text_rows(db,
    "SELECT count(*) FROM modules WHERE path LIKE 'static%' OR path LIKE '%notes%' OR path LIKE '%page%'"))
  assert(nth(modules, 1):text(1) == "0")
  assert(db:close())
end

--- Equal trees project equal bytes, and an edit to an asset moves the
--- projection although no module changed.
local function test_an_edit_to_an_asset_moves_the_projection(tmp: string)
  for _, name in ipairs({ "one", "two" }) do
    write_project(tmp .. "/" .. name, "world")
    write_static(tmp .. "/" .. name, "body {}")
    write_projection(tmp .. "/" .. name, tmp .. "/" .. name .. ".db")
  end
  assert(Fs.read(tmp .. "/one.db") == Fs.read(tmp .. "/two.db"), "equal trees, unequal projections")
  local before = projected(tmp .. "/one.db")
  assert(Fs.write(tmp .. "/one/static/css/app.css", "body { margin: 0 }"))
  write_projection(tmp .. "/one", tmp .. "/one.db")
  assert(projected(tmp .. "/one.db") ~= before)
  local db = assert(Sqlite.open(tmp .. "/one.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT data FROM payload WHERE path = 'css/app.css'"))
  assert(nth(rows, 1):text(1) == "body { margin: 0 }")
  assert(db:close())
end

--- The `type` and `gzip` of a payload row come from cosmic.mime, so an
--- edit to it moves the signature although no file did.
local function test_an_edit_to_cosmic_mime_moves_the_signature(tmp: string)
  local handle, result = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  local before = assert(writer.signature(handle, result, "binary"))
  local real = Store.bytecode
  Store.bytecode = function(name: string): string?, string
    if name == "cosmic.mime" then return "an edited cosmic.mime", "" end
    return real(name)
  end
  local after, trouble = writer.signature(handle, result, "binary")
  Store.bytecode = real
  assert(work.close(handle))
  assert(after ~= nil, trouble)
  assert(after ~= before, "cosmic.mime must be part of the signature")
end

--- A tree with no `static/` has an empty payload.
local function test_a_tree_without_static_has_no_payload(tmp: string)
  write_project(tmp .. "/p", "world")
  write_projection(tmp .. "/p", tmp .. "/p.db")
  local db = assert(Sqlite.open(tmp .. "/p.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT count(*) FROM payload"))
  assert(nth(rows, 1):text(1) == "0")
  assert(db:close())
end
