--- core/main.c's `--database` start, as core/database_start_test.tl holds
--- it, for the program that confines a child of its own: the child is this
--- same core, which runs on the database of its parent. It needs a
--- sandbox, which no platform but Linux has: where the platform lacks one
--- it is not applicable, and where this host's kernel refuses the child its
--- own, skipped (`requires`, and Test.skip for what only the start can tell).

local Test = require("cosmic.test")
local database_start_fixture = require("build.database_start_fixture")

--- The core is started past its launcher, as core/database_start_test.tl
--- does, and `/proc` is what the sandboxed child reads of its own descriptors.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/proc", letters = "r" } },
  requires = { "sandbox" },
}

local core_path = database_start_fixture.core_path
local run = database_start_fixture.run
local fields = database_start_fixture.fields
local info_database = database_start_fixture.info_database

--- A child a policy confines is this same program, which its profile
--- grants the core of: it runs on the same database, which the start
--- grants it to read.
local function test_a_sandboxed_child_stays_on_the_database(tmp: string)
  local core = core_path()
  if core == nil then return end
  local path = info_database(tmp)
  local r = run({ core, "--database", path, "sandboxed" })
  assert(r.ok, "exit " .. tostring(r.code) .. ": " .. tostring(r.stderr))
  local out = fields(assert(r.stdout))
  if out.sandbox_refused ~= nil then
    -- A kernel that gives no sandbox here has nothing to check, which only
    -- the start can tell.
    for _, word in ipairs({ "Landlock", "seccomp", "not implemented", "namespace", "own /proc" }) do
      if out.sandbox_refused:find(word, 1, true) then Test.skip(out.sandbox_refused) end
    end
    error("the sandboxed start was refused: " .. out.sandbox_refused)
  end
  assert(out.child_code == "0", tostring(out.child_code) .. ": " .. tostring(out.child_stderr))
  assert(out.child_databases == "1", tostring(out.child_databases))
  assert(out.child_main == "probe.main", tostring(out.child_main))
  assert(out.child_args == "child|z", tostring(out.child_args))
end
