--- Regression test for `build.writer`: `write_result` must trust only
--- the projection already sitting at `out`, never a record kept
--- somewhere else. The working database's own `meta` table -- what
--- the fix in this file replaces -- can drift from the file on disk:
--- `build/boot.tl` reuses one working database across several output
--- paths, and a snapshot of `o/build.db` restored after `o/cosmic.db`
--- moved on both leave a row that no longer describes the file it
--- once did.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local importer = require("build.importer")
local teal = require("build.teal")
local work = require("build.work")
local writer = require("build.writer")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
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
local function build_and_write(root: string, whom: string, out: string): work.Handle, importer.Result
  write_project(root, whom)
  local handle = assert(work.open(root))
  assert(work.stage(handle, false))
  local result = assert(importer.compile(handle, built, "writer-test"))
  assert(writer.write_result(handle, out, result))
  return handle, result
end

--- The signature a projection at `path` carries in its own `meta`
--- table, or "" when it has none.
local function projected(path: string): string
  local db = assert(Sqlite.open(path, false))
  local rows = assert(Sqlite.text_rows(db,
    "SELECT value FROM meta WHERE key = 'projected'"))
  assert(db:close())
  if #rows == 0 then
    return ""
  end
  return rows[1][1]
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

  local db = assert(Sqlite.open(tmp .. "/out.db", true))
  assert(Sqlite.run(db, "UPDATE meta SET value = ?1 WHERE key = 'projected'",
    { { text = older } }))
  assert(db:exec("INSERT INTO meta (key, value) VALUES ('older', 'x')"))
  assert(db:close())

  assert(writer.write_result(handle, tmp .. "/out.db", result))
  assert(work.close(handle))
  local out = assert(Sqlite.open(tmp .. "/out.db", false))
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
  local out = assert(Sqlite.open(tmp .. "/out.db", false))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT text, file, line FROM docs WHERE module = 'clock' AND symbol = 'now'"))
  assert(out:close())
  assert(#rows == 1, tostring(#rows))
  assert(rows[1][1] == "Seconds since the epoch." and rows[1][2] == "clock.d.tl" and
    rows[1][3] == "3", table.concat(rows[1], " "))
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
    "local function greeting(): string | nil, string",
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
  assert(Fs.write(root .. "/fixture_test.tl", 'return { name = "x" }\n'))
  local handle = build_and_write(root, "world", tmp .. "/whole.db")
  assert(work.close(handle))
  assert(Fs.mkdirs(root .. "/vendor/zlib"))
  assert(Fs.mkdirs(root .. "/build/bom"))
  assert(Fs.write(root .. "/vendor/zlib/PIN",
    "version 1.3\nurl https://zlib.net/zlib-1.3.tar.gz\nlicense Zlib\nnotice LICENSE\n"))
  assert(Fs.write(root .. "/vendor/zlib/LICENSE", "(C) 1995 Jean-loup Gailly and Mark Adler\n"))
  assert(writer.carried(tmp .. "/whole.db", tmp .. "/carried.db", root))
  assert(writer.carried(tmp .. "/whole.db", tmp .. "/again.db", root))
  assert(Fs.read(tmp .. "/carried.db") == Fs.read(tmp .. "/again.db"),
    "the carried database is a function of the projection")

  local function rows(path: string, sql: string): {{string}}
    local db = assert(Sqlite.open(path, false))
    local found = assert(Sqlite.text_rows(db, sql))
    assert(db:close())
    return found
  end
  local whole = rows(tmp .. "/whole.db",
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM modules ORDER BY path)")
  assert(whole[1][1] ==
    "cmd.hello.main fixture_test greet greet_example greet_test shared",
    whole[1][1])
  local carried = rows(tmp .. "/carried.db",
    "SELECT group_concat(path, ' ') FROM (SELECT path FROM modules ORDER BY path)")
  assert(carried[1][1] == "cmd.hello.main fixture_test greet shared", carried[1][1])
  local about_dropped = rows(tmp .. "/carried.db",
    "SELECT (SELECT count(*) FROM docs WHERE module IN ('greet_test', 'greet_example')) " ..
    "+ (SELECT count(*) FROM uses WHERE from_module IN ('greet_test', 'greet_example')) " ..
    "+ (SELECT count(*) FROM imports WHERE path IN ('greet_test', 'greet_example') " ..
    "OR requires IN ('greet_test', 'greet_example')) " ..
    "+ (SELECT count(*) FROM catalog WHERE module IN ('greet_test', 'greet_example'))")
  local in_whole = rows(tmp .. "/whole.db",
    "SELECT count(*) FROM catalog WHERE module = 'greet_test'")
  assert(in_whole[1][1] == "1", "the projection holds the test's catalog row")
  assert(about_dropped[1][1] == "0", "a row about a dropped module is carried")
  local kept = rows(tmp .. "/carried.db",
    "SELECT (SELECT count(*) FROM examples WHERE module = 'greet'), " ..
    "(SELECT count(*) FROM docs_fts WHERE docs_fts MATCH 'hello'), " ..
    "(SELECT value FROM meta WHERE key = 'main')")
  assert(kept[1][1] == "1", "the example's documentation for greet is kept")
  assert(tonumber(kept[1][2]) > 0, "the docs index is rebuilt")
  assert(kept[1][3] == "cmd.hello.main", "meta is carried")
  local materials = rows(tmp .. "/carried.db",
    "SELECT c.name, c.license, n.text FROM components c JOIN notices n ON n.component = c.name")
  assert(#materials == 1 and materials[1][1] == "zlib" and materials[1][2] == "Zlib" and
    materials[1][3] == "(C) 1995 Jean-loup Gailly and Mark Adler\n",
    "the tool carries the tree's bill of materials")
end

--- A projection ships what a reader of it loads -- each module's
--- bytecode and its Teal source, deflated -- and not the Lua tl
--- generated on the way, which only the working database's `compiled`
--- needs.
local function test_a_module_ships_its_bytecode_and_not_its_lua(tmp: string)
  local handle = build_and_write(tmp .. "/a", "world", tmp .. "/out.db")
  assert(work.close(handle))
  local out = assert(Sqlite.open(tmp .. "/out.db", false))
  local columns = assert(Sqlite.text_rows(out,
    "SELECT name FROM pragma_table_info('modules') WHERE name = 'lua'"))
  local rows = assert(Sqlite.text_rows(out,
    "SELECT length(bytecode) > 0, " ..
    "instr(CAST(inflate(source) AS TEXT), 'hello, world') > 0, " ..
    "instr(CAST(source AS TEXT), 'function greet.hello') = 0 " ..
    "FROM modules WHERE path = 'greet'"))
  assert(out:close())
  assert(#columns == 0, "the shipped modules table carries generated Lua")
  assert(#rows == 1 and rows[1][1] == "1" and rows[1][2] == "1",
    tostring(#rows))
  assert(rows[1][3] == "1", "the source is stored deflated")
end
