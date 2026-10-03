--- End to end: a compile one checkout of a project made stands in
--- another checkout of the same content, at another path with its own
--- o/, through the cache `COSMIC_BUILD_CACHE` names, and lands there as
--- the compile would have; an edit compiles only what reaches it; a
--- compile that failed is not shared; and a cache turned off, broken, or
--- written by two builds at once never fails a build. These cases
--- declare `tool` because they start this program, a build of each
--- checkout; the cache's own cases, in-process, are in
--- build/shared_compiles_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local this_program = require("build.this_program")
local shared_compiles = require("build.shared_compiles")
local Test = require("cosmic.test")
local Time = require("cosmic.time")

--- The program itself, which its tests start.
Test.needs{ tool = true }

--- The project every case builds: `a` requires `b`, which requires `c`
--- and reads a field of a record `c` declares, so its compile finds a
--- record-field use (`typed_refs`).
local project: {string:string} = {
  ["c.tl"] = [[
local record c
  record Box
    value: integer
  end
end

function c.new(value: integer): c.Box
  return { value = value }
end

return c
]],
  ["b.tl"] = [[
local c = require("c")

local record b end

function b.twice(value: integer): integer
  local box = c.new(value)
  return box.value * 2
end

return b
]],
  ["a.tl"] = [[
local b = require("b")

local record a end

function a.four(): integer
  return b.twice(2)
end

return a
]],
}

--- A checkout of the project at `root`, with `changed` written over it
--- (a file to "" is left out).
local function checkout(root: string, changed?: {string:string})
  assert(Fs.mkdirs(root))
  local files: {string:string} = {}
  for name, source in pairs(project) do files[name] = source end
  for name, source in pairs(changed or {}) do files[name] = source end
  for name, source in pairs(files) do
    if source ~= "" then assert(Fs.write(root .. "/" .. name, source)) end
  end
end

--- Builds the checkout at `root` (`cosmic test`, which has nothing to
--- run), answering what it printed; it must pass unless `fails`.
local function build(root: string, env: {string:string}, fails?: boolean): string
  local output = root .. ".out"
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Time.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil and result.ok == not fails, tostring(trouble) .. text)
  return text
end

--- The environment the builds of a case run in, sharing through a
--- cache in `tmp`, and where that cache is.
local function environment(tmp: string): {string:string}, string
  local env = this_program.environment()
  local path = tmp .. "/cache/cache.db"
  env.COSMIC_BUILD_CACHE = path
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- It runs no test, so it sandboxes none: the same on every host.
  env.COSMIC_TEST_SANDBOX = "0"
  return env, path
end

--- Builds `root` and checks its build line says `wanted`.
local function built(root: string, env: {string:string}, wanted: string): string
  local text = build(root, env)
  assert(text:find(wanted, 1, true), wanted .. "\n" .. text)
  return text
end

--- Every row `sql` answers of the database at `path`, a line each.
local function dump(path: string, sql: string): string
  local db = assert(Sqlite.open(path))
  local rows = assert(Sqlite.text_rows(db, sql))
  assert(db:close())
  local lines: {string} = {}
  for _, row in ipairs(rows) do lines[#lines + 1] = table.concat(row, "\t") end
  return table.concat(lines, "\n")
end

--- How many compiles the cache at `path` holds.
local function rows_in(path: string): integer
  return math.tointeger(tonumber(dump(path, "SELECT COUNT(*) FROM compiled_v2"))) or -1
end

local function test_a_second_checkout_compiles_nothing_the_first_compiled(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  checkout(tmp .. "/first")
  built(tmp .. "/first", env, "(3 compiled, 0 cached;")
  checkout(tmp .. "/second")
  built(tmp .. "/second", env, "(0 compiled, 3 cached, 3 of them taken from another checkout;")
  -- What each checkout ships, and keeps, is what a compile makes: its
  -- bytecode, and the record-field use `b` makes of `c.Box` with it.
  local queries: {{string}} = {
    { "o/cosmic.db", "SELECT path, file, kind, hex(source_hash), hex(key), hex(bytecode), " ..
        "tests FROM modules ORDER BY path" },
    { "o/cosmic.db", "SELECT module, symbol, from_module, from_file, line FROM uses " ..
        "ORDER BY module, symbol, from_module, line" },
    { "o/build.db", "SELECT key, tool, lua, hex(bytecode), seen FROM compiled ORDER BY key" },
    { "o/build.db", "SELECT key, ordinal, module, member, line FROM typed_refs " ..
        "ORDER BY key, ordinal" },
  }
  for _, query in ipairs(queries) do
    local first = dump(tmp .. "/first/" .. query[1], query[2])
    local second = dump(tmp .. "/second/" .. query[1], query[2])
    assert(first ~= "" and first == second, query[2] .. "\n" .. first .. "\n--\n" .. second)
  end
  local uses = dump(tmp .. "/second/o/cosmic.db", "SELECT symbol FROM uses WHERE module = 'c'")
  assert(uses:find("Box.value", 1, true), uses)
  -- Its own now: a build again takes nothing from the cache.
  local again = built(tmp .. "/second", env, "(0 compiled, 3 cached;")
  assert(not again:find("another checkout", 1, true), again)
end

local function test_an_edit_compiles_only_what_it_reaches(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  local alone = "local record d end\nreturn d\n"
  checkout(tmp .. "/first", { ["d.tl"] = alone })
  built(tmp .. "/first", env, "(4 compiled, 0 cached;")
  -- `c` edited: `a`, `b` and `c` reach it, `d` does not.
  checkout(tmp .. "/edited_c", { ["d.tl"] = alone,
    ["c.tl"] = project["c.tl"] .. "-- edited\n" })
  built(tmp .. "/edited_c", env, "(3 compiled, 1 cached, 1 of them taken from another checkout;")
  -- `d` edited: only `d`.
  checkout(tmp .. "/edited_d", { ["d.tl"] = alone .. "-- edited\n" })
  built(tmp .. "/edited_d", env, "(1 compiled, 3 cached, 3 of them taken from another checkout;")
end

local function test_a_failed_compile_is_not_shared(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  -- `z` sorts last, so everything else compiles before it fails.
  checkout(tmp .. "/first", { ["z.tl"] = "local z: integer = \"not a number\"\nreturn z\n" })
  local failed = build(tmp .. "/first", env, true)
  assert(failed:find("z.tl", 1, true), failed)
  assert(rows_in(path) == 3, dump(path, "SELECT key FROM compiled_v2"))
  checkout(tmp .. "/fixed", { ["z.tl"] = "local z: integer = 1\nreturn z\n" })
  built(tmp .. "/fixed", env, "(1 compiled, 3 cached, 3 of them taken from another checkout;")
end

local function test_the_cache_turned_off_writes_nothing(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  env.COSMIC_BUILD_CACHE = "0"
  checkout(tmp .. "/first")
  built(tmp .. "/first", env, "(3 compiled, 0 cached;")
  checkout(tmp .. "/second")
  built(tmp .. "/second", env, "(3 compiled, 0 cached;")
  assert(Fs.stat(tmp .. "/cache") == nil, "a cache turned off was written")
end

local function test_a_broken_cache_never_fails_a_build(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  assert(Fs.mkdirs(tmp .. "/cache"))
  assert(Fs.write(path, string.rep("not a database\n", 512)))
  assert(Fs.chmod(path, 0x180))
  local before = assert(Fs.stat(path))
  local bytes = assert(Fs.read(path))
  local sibling = path .. ".corrupt-older"
  assert(Fs.write(sibling, "earlier evidence"))
  for _, name in ipairs({ "first", "second" }) do
    checkout(tmp .. "/" .. name)
    local output = built(tmp .. "/" .. name, env, "(3 compiled, 0 cached;")
    local _, complaints = output:gsub("shared compiles: ", "")
    assert(complaints == 1 and output:find("building without them", 1, true), output)
    assert(not output:find("moved aside", 1, true), output)
    local after = assert(Fs.stat(path))
    assert(after.ino == before.ino and after.dev == before.dev)
    assert(Fs.read(path) == bytes and Fs.read(sibling) == "earlier evidence")
    assert(#assert(Fs.list(Fs.dirname(path))) == 2, "a cache was renamed or replaced")
  end
end

--- A row that does not decode to what its digest says is a miss: the
--- module compiles, the rest are still shared, and the row is replaced
--- with the compile made, the cache kept on throughout.
local function test_a_damaged_row_is_compiled_again_and_replaced(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  checkout(tmp .. "/first")
  built(tmp .. "/first", env, "(3 compiled, 0 cached;")
  local keys: {string:string} = {}
  local db = assert(Sqlite.open(tmp .. "/first/o/cosmic.db"))
  local rows = assert(Sqlite.text_rows(db, "SELECT path, CAST(key AS TEXT) FROM modules"))
  for _, row in ipairs(rows) do
    keys[row[1]] = shared_compiles.key(row[2], false, false)
  end
  assert(db:close())
  local cache = assert(Sqlite.open(path, { writable = true }))
  -- `b`'s Lua becomes no stream at all, and `c`'s becomes `a`'s.
  assert(Sqlite.run(cache, "UPDATE compiled_v2 SET lua = x'deadbeef' WHERE key = ?1",
    { { text = keys.b } }))
  assert(Sqlite.run(cache, "UPDATE compiled_v2 SET lua = (SELECT lua FROM compiled_v2 " ..
      "WHERE key = ?2) WHERE key = ?1", { { text = keys.c }, { text = keys.a } }))
  assert(cache:close())
  checkout(tmp .. "/second")
  local second = built(tmp .. "/second", env,
    "(2 compiled, 1 cached, 1 of them taken from another checkout;")
  assert(not second:find("shared compiles: ", 1, true), second)
  local opened = assert(shared_compiles.open(path))
  for _, name in ipairs({ "b", "c" }) do
    local found, trouble = shared_compiles.look(opened, keys[name])
    assert(found ~= nil, name .. " was not replaced: " .. trouble)
  end
  shared_compiles.close(opened)
  checkout(tmp .. "/third")
  built(tmp .. "/third", env, "(0 compiled, 3 cached, 3 of them taken from another checkout;")
end

--- A cache whose directory others can write is refused, since a row's
--- bytecode runs, and the build goes on without it.
local function test_a_cache_others_can_write_is_refused(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env = environment(tmp)
  assert(Fs.mkdirs(tmp .. "/open"))
  assert(Fs.chmod(tmp .. "/open", 0x1ff))
  env.COSMIC_BUILD_CACHE = tmp .. "/open/cache.db"
  checkout(tmp .. "/first")
  local first = built(tmp .. "/first", env, "(3 compiled, 0 cached;")
  assert(first:find("writable by its group or others", 1, true), first)
  assert(Fs.stat(tmp .. "/open/cache.db") == nil, "a cache others can write was written")
end

--- A file holding an earlier format's table is taken up, not refused:
--- the table goes, and this format's is made and written.
local function test_an_earlier_formats_table_is_dropped(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  assert(Fs.mkdirs(tmp .. "/cache"))
  assert(Fs.chmod(tmp .. "/cache", 0x1c0))
  local db = assert(Sqlite.open(path, { writable = true }))
  assert(db:exec("CREATE TABLE compiled_v1 (key TEXT PRIMARY KEY, lua BLOB NOT NULL, " ..
      "bytecode BLOB NOT NULL, refs BLOB NOT NULL, size INTEGER NOT NULL, used_ns INTEGER NOT NULL)"))
  assert(db:close())
  assert(Fs.chmod(path, 0x180))
  checkout(tmp .. "/first")
  local first = built(tmp .. "/first", env, "(3 compiled, 0 cached;")
  assert(not first:find("shared compiles: ", 1, true), first)
  assert(rows_in(path) == 3)
  local tables = dump(path, "SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
  assert(tables == "compiled_v2\nparsed_v1", tables)
end

--- A cache file that is a link is refused: SQLite would write its log
--- beside where it leads, a directory no check saw.
local function test_a_cache_file_that_is_a_link_is_refused(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  assert(Fs.mkdirs(tmp .. "/cache"))
  assert(Fs.chmod(tmp .. "/cache", 0x1c0))
  assert(Fs.symlink(tmp .. "/elsewhere.db", path))
  checkout(tmp .. "/first")
  local first = built(tmp .. "/first", env, "(3 compiled, 0 cached;")
  assert(first:find("a symbolic link", 1, true), first)
  assert(Fs.stat(tmp .. "/elsewhere.db") == nil, "the link was followed")
end

local function test_two_builds_writing_at_once_keep_both(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local env, path = environment(tmp)
  -- Content of their own, so each writes three compiles.
  checkout(tmp .. "/one", { ["c.tl"] = project["c.tl"] .. "-- one\n" })
  checkout(tmp .. "/two", { ["c.tl"] = project["c.tl"] .. "-- two\n" })
  local handles: {Child.Handle} = {}
  local outputs: {integer} = {}
  for index, name in ipairs({ "one", "two" }) do
    local fd = assert(Fs.open_write(tmp .. "/" .. name .. ".out"))
    outputs[index] = fd
    local started = this_program.program({ "test" }, {
      cwd = tmp .. "/" .. name, env = env, stdout = fd, stderr = fd, process_group = true,
    })
    handles[index] = assert(Child.start(started.argv, started.options))
  end
  for index, handle in ipairs(handles) do
    local result, trouble = handle:wait(Time.seconds(60))
    assert(Fs.close(outputs[index]))
    local text = assert(Fs.read(tmp .. "/" .. (index == 1 and "one" or "two") .. ".out"))
    assert(result ~= nil and result.ok, tostring(trouble) .. text)
    assert(text:find("(3 compiled, 0 cached;", 1, true), text)
    assert(not text:find("shared compiles: ", 1, true), text)
  end
  assert(dump(path, "PRAGMA integrity_check") == "ok")
  -- `a` and `b` reach `c`, so no key of one is the other's.
  assert(rows_in(path) == 6, dump(path, "SELECT key FROM compiled_v2"))
  for _, name in ipairs({ "one", "two" }) do
    checkout(tmp .. "/" .. name .. "_again", { ["c.tl"] = project["c.tl"] .. "-- " .. name .. "\n" })
    built(tmp .. "/" .. name .. "_again", env,
      "(0 compiled, 3 cached, 3 of them taken from another checkout;")
  end
end

--- Two builds meeting a fresh cache at once: the second's switch to
--- write-ahead mode finds the first holding the file's write lock, and
--- SQLite answers "database is locked" at once, calling no busy handler
--- (the switch reads the header in one transaction, then writes it);
--- the open tries again rather than leaving that build without the cache.
local function test_a_cache_another_build_is_making_is_opened(tmp: string)
  tmp = assert(Fs.absolute(tmp))
  local _, path = environment(tmp)
  assert(Fs.mkdirs(Fs.dirname(path)))
  assert(Fs.chmod(Fs.dirname(path), 0x1c0))
  local held = tmp .. "/held"
  -- Another build, as far as the file is concerned: it holds the write
  -- lock of the fresh, rollback-mode file for half a second.
  local chunk = string.format([[
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Time = require("cosmic.time")
local db = assert(Sqlite.open(%q, { writable = true }))
assert(db:exec("BEGIN IMMEDIATE"))
assert(Fs.write(%q, ""))
assert(Time.sleep_ns(500 * 1000000))
assert(db:exec("COMMIT"))
assert(db:close())
return 0
]], path, held)
  local started = this_program.program({ "-e", chunk }, { process_group = true })
  local handle = assert(Child.start(started.argv, started.options))
  local waited = 0
  while Fs.exists(held) ~= true do
    assert(waited < 10000, "the holder never took the lock")
    assert(Time.sleep_ns(Time.ms(10)))
    waited = waited + 10
  end
  local cache, trouble = shared_compiles.open(path)
  assert(cache ~= nil, trouble)
  local rows = assert(Sqlite.text_rows(cache.db, "PRAGMA journal_mode"))
  assert(rows[1][1] == "wal", rows[1][1])
  shared_compiles.close(cache)
  local result, wait_trouble = handle:wait(Time.seconds(10))
  assert(result ~= nil and result.ok, tostring(wait_trouble))
end
