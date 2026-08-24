--- Examples for querying and editing a cosmic artifact with SQL.
--- A cosmic executable is a zip, and sqlite's `zipfile` virtual table
--- reads one directly, so `cosmic.sqlite` inspects an artifact with no
--- extraction step. See `cosmic --docs guide.artifacts` for the prose.

-- Example_inspect_members enumerates what an artifact carries. The
-- artifact here is the running cosmic binary itself, reached through
-- proc.interpreter() -- arg[0] is /zip/main.lua, a member rather than
-- the file.
local function Example_inspect_members()
  local check = require("cosmic.check")
  local proc = require("cosmic.proc")
  local sqlite = require("cosmic.sqlite")

  local exe = check.must(proc.interpreter())
  local db = check.must(sqlite.open(":memory:"))
  local row = check.must(db:query_one(
      "SELECT count(*) AS members," ..
      " sum(name LIKE 'cosmic/%') AS modules FROM zipfile(?)", {exe}))
  print(tonumber(row.members) > 0, tonumber(row.modules) > 0)

  -- Members are named by their path inside the zip, and the zip root
  -- is the module root: require("cosmic.fs") loads /zip/cosmic/fs.lua.
  local named = check.must(db:query_one(
      "SELECT name FROM zipfile(?) WHERE name = 'cosmic/fs.lua'", {exe}))
  print(named.name)
  assert(db:close())
  -- Output:
  -- true	true
  -- cosmic/fs.lua
end

-- Example_extract_member reads a member out as text, and shows the one
-- member class that does not come out readable.
local function Example_extract_member()
  local check = require("cosmic.check")
  local proc = require("cosmic.proc")
  local sqlite = require("cosmic.sqlite")

  local exe = check.must(proc.interpreter())
  local db = check.must(sqlite.open(":memory:"))

  -- cosmic.mk is the make ruleset the binary ships at /zip/cosmic.mk.
  local mk = check.must(db:query_one(
      "SELECT CAST(data AS TEXT) AS text FROM zipfile(?)" ..
      " WHERE name = 'cosmic.mk'", {exe}))
  print((tostring(mk.text):gsub("\n.*", "")))

  -- A module is precompiled bytecode, not source: its first bytes are
  -- a Lua chunk header. Read a module with `cosmic --docs`, not SQL.
  local mod = check.must(db:query_one(
      "SELECT CAST(data AS TEXT) AS text FROM zipfile(?)" ..
      " WHERE name = 'cosmic/json.lua'", {exe}))
  print(tostring(mod.text):sub(2, 4))
  assert(db:close())
  -- Output:
  -- # cosmic.mk — the rules for `cosmic --make`.
  -- Lua
end

-- Example_add_member writes a member into an artifact and runs the
-- result. The copy matters: a program that rewrites the zip it is
-- executing from is asking for the failure it will get.
local function Example_add_member()
  local check = require("cosmic.check")
  local child = require("cosmic.child")
  local fs = require("cosmic.fs")
  local proc = require("cosmic.proc")
  local sqlite = require("cosmic.sqlite")

  local exe = check.must(proc.interpreter())
  local dir = check.must(fs.temp_dir())
  local copy = fs.join(dir, "artifact")
  -- fs.copy carries the mode across, so the copy stays executable.
  check.must(fs.copy(exe, copy))

  local db = check.must(sqlite.open(":memory:"))
  check.must(db:exec("CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
  check.must(db:exec(
      "INSERT INTO z(name, data) VALUES ('hello.txt', 'hi from sql')"))
  assert(db:close())

  -- The edited binary still runs, and serves the member through /zip.
  local ran = check.must(child.run({copy, "-e",
        "local f = assert(io.open('/zip/hello.txt')) io.write(f:read('a')) f:close()"}))
  print(ran.stdout)
  check.must(fs.remove_all(dir))
  -- Output:
  -- hi from sql
end

-- Example_remove_member deletes a member, and shows what that costs:
-- zipfile appends a fresh central directory rather than rewriting the
-- archive, so the file grows and nothing is reclaimed.
local function Example_remove_member()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")
  local proc = require("cosmic.proc")
  local sqlite = require("cosmic.sqlite")

  local exe = check.must(proc.interpreter())
  local dir = check.must(fs.temp_dir())
  local copy = fs.join(dir, "artifact")
  -- fs.copy carries the mode across, so the copy stays executable.
  check.must(fs.copy(exe, copy))
  local before = check.must(fs.stat(copy)):size()

  local db = check.must(sqlite.open(":memory:"))
  check.must(db:exec("CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
  check.must(db:exec("DELETE FROM z WHERE name LIKE '.docs/%'"))
  assert(db:close())

  local after = check.must(fs.stat(copy)):size()

  local reread = check.must(sqlite.open(":memory:"))
  local left = check.must(reread:query_one(
      "SELECT count(*) AS n FROM zipfile(?) WHERE name LIKE '.docs/%'",
      {copy}))
  assert(reread:close())
  print("members left: " .. tostring(tonumber(left.n)))
  print("file smaller: " .. tostring(after < before))
  check.must(fs.remove_all(dir))
  -- Output:
  -- members left: 0
  -- file smaller: false
end

-- Suppress unused warnings for examples
local _ = {
  Example_inspect_members,
  Example_extract_member,
  Example_add_member,
  Example_remove_member,
}
