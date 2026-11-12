--- The stamps the tool itself carries ([`build.stamps`]): each is there,
--- and is what the tool works out of its own database.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Test = require("cosmic.test")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Stamp = require("build.stamp")
local artifact = require("build.artifact")
local stamps = require("build.stamps")
local test_child = require("build.test_child")
local test_key = require("build.test_key")
local this_program = require("build.this_program")

--- The program itself, whose own database the stamps are in.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  timeout = 120,
}

local stamp_keys <const>: {string} = { "stamp_analyzer", "stamp_coded", "stamp_extras", "stamp_harness", "stamp_of" }

--- The stamps `db` holds, by key, "" for one it holds no row of.
local function held(db: Sqlite.Handle): {string:string}
  local out: mut {string:string} = {}
  for _, key in ipairs(stamp_keys) do
    local rows = assert(Sqlite.text_rows(db, "SELECT value FROM meta WHERE key = ?1", { { text = key } }))
    local row = rows[1]
    out[key] = if row ~= nil then row:text(1) else "" end
  end
  return out
end

--- What the child of the first test exits with where the program is no
--- portable artifact to take a copy of its database from.
local no_artifact <const> = 77

--- The child of the first test: in the program, each stamp its database
--- carries is bound to its rows, and a copy of the database stamped again
--- by the program's own code holds the same.
test_child.register("stamped again", function(args: {string}): integer
  local dir = assert(args[1])
  local databases = Store.databases()
  local binary = assert(databases[#databases], "the program has a database")
  local carried = held(binary)
  for _, key in ipairs(stamp_keys) do
    assert(carried[key] ~= "", "the program's database holds no " .. key)
    assert(Stamp.read(key) == carried[key], key .. " is not answered, though the database holds it")
  end
  local launched, _ = Proc.relaunch()
  local file = if launched ~= nil and launched.argv[2] == "--artifact" then launched.argv[3] else nil end
  if file == nil then return no_artifact end
  local bytes = assert(Fs.read(file))
  local parts = assert(artifact.split(bytes))
  local path = dir .. "/again.db"
  assert(Fs.write(path, parts.database))
  local copy = assert(Sqlite.open(path, { writable = true }))
  assert(copy:exec("DELETE FROM meta WHERE key LIKE 'stamp%'"))
  assert(stamps.fill(copy))
  local again = held(copy)
  assert(copy:close())
  for _, key in ipairs(stamp_keys) do
    assert(again[key] == carried[key], key .. " is not what the program works out of its own database")
  end
  return 0
end)

--- The child of the second test: the harness the program reads of its
--- stamp is the one it works out of its own database, part for part.
test_child.register("harness", function(_args: {string}): integer
  local databases = Store.databases()
  local binary = assert(databases[#databases], "the program has a database")
  assert(Stamp.read("stamp_harness") ~= nil, "the program's database holds no stamp of its harness")
  local read = assert(test_key.binary_harness())
  local worked = assert(test_key.harness(binary))
  assert(read.digest == worked.digest and read.store_salt == worked.store_salt)
  assert(table.concat(read.names, " ") == table.concat(worked.names, " "))
  assert(table.concat(read.runs, " ") == table.concat(worked.runs, " "))
  for name, digest in pairs(worked.modules) do
    assert(read.modules[name] == digest, name .. "'s digest")
  end
  for name in pairs(read.modules) do
    assert(worked.modules[name] ~= nil, name .. " is in the stamp alone")
  end
  for name in pairs(worked.carried) do
    assert(read.carried[name] == true, name .. " is carried, and the stamp's harness does not say so")
  end
  for name in pairs(read.carried) do
    assert(worked.carried[name] == true, name .. " is not carried")
  end
  return 0
end)

--- Runs the child `name` of this module in the program and answers its
--- exit status, which is 0 or `no_artifact`.
local function runs(tmp: string, name: string): integer
  local started = this_program.program(test_child.words(tmp, "build.stamps_tool_test", name, { tmp }),
    { cwd = tmp, stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(90) })
  local result = assert(Child.run(started.argv, started.options))
  local code = result.code
  assert(code == 0 or code == no_artifact, tostring(result.stdout))
  return code or no_artifact
end

--- A stamp that is not what the tool would work out keys a compile, a
--- parse or a verdict by another code's identity. Each is held here to
--- the value the tool's own code works out of the tool's own rows.
local function test_the_tool_carries_each_stamp_and_it_is_what_the_tool_works_out(tmp: string)
  if runs(tmp, "stamped again") == no_artifact then
    Test.skip("this program is no portable artifact to take a copy of its database from")
  end
end

local function test_the_harness_read_of_its_stamp_is_the_one_worked_out(tmp: string)
  assert(runs(tmp, "harness") == 0)
end
