--- `cosmic test --audit` run sandboxed, end to end: what a test reads
--- that its module does not declare is what its sandbox refused it
--- (build.refusals), named with the declaration that would hold it. It
--- declares `tool`, since it starts this program, and `nests`, since
--- the run it starts nests its workers' sandboxes in this one's: its
--- assertion is about them.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local confine = require("build.confine")
local this_program = require("build.this_program")
local Test = require("cosmic.test")

Test.needs{
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  tool = true,
  nests = true,
}

--- Runs `cosmic test --audit` on `root`, sandboxed where it can be,
--- answering whether it passed and what it printed.
local function audit(root: string, output: string): boolean, string
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_SANDBOX = nil
  local started = this_program.program({ "test", "--audit" }, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return result.ok, text
end

--- Whether the run `text` says was unsandboxed, as it is where the
--- kernel refuses a sandbox this deep -- which only a run not held to
--- sandboxing may be.
local function unsandboxed(text: string): boolean
  if not text:find("no worker can be sandboxed here", 1, true) then return false end
  assert(not confine.held_to_sandbox(),
    "the run is held to sandboxing, but the run it started was not:\n" .. text)
  return true
end

--- A project whose test reads its helper's source, which its import
--- closure holds; a file of the tree and a variable, each declared or
--- not, as `declared` says, taking whatever it finds; a database its
--- module's top level opens, and one a statement attaches, which only
--- SQLite reads; a file that is not there, which no sandbox would show
--- it either; and the worker's own /proc, which every worker is given.
local function project(root: string, declared: boolean)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/data"))
  assert(Fs.write(root .. "/data/extra.txt", "extra\n"))
  assert(Fs.write(root .. "/data/top.db", ""))
  assert(Fs.write(root .. "/data/other.db", ""))
  assert(Fs.write(root .. "/suite/helper.tl", "return { answer = 42 }\n"))
  assert(Fs.write(root .. "/suite/reads_test.tl", table.concat({
    'local Env = require("cosmic.env")',
    'local Fs = require("cosmic.fs")',
    'local Sqlite = require("cosmic.sqlite")',
    'local sys = require("cosmic.sys")',
    'local helper = require("suite.helper")',
    declared and 'local Test = require("cosmic.test")' or "",
    declared and 'Test.needs { reads = { "data/extra.txt", "data/other.db", "data/top.db" }, ' ..
      'env = { "REFUSALS_ASKED" } }' or "",
    'local top, _ = Sqlite.open("data/top.db")',
    "if top ~= nil then top:close() end",
    "local function test_reads()",
    "  assert(helper.answer == 42)",
    '  local _ = Fs.read("data/extra.txt")',
    '  assert(Fs.read("data/missing.txt") == nil)',
    '  local _ = Env.get("REFUSALS_ASKED")',
    "end",
    "local function test_attach()",
    "  local db = assert(Sqlite.memory())",
    '  local _, _ = Sqlite.run(db, "ATTACH DATABASE \'data/other.db\' AS other")',
    "  db:close()",
    "end",
    "local function test_own_proc()",
    '  assert(Fs.list("/proc/" .. tostring(sys.getpid()) .. "/fd") ~= nil)',
    "end",
  }, "\n") .. "\n"))
end

--- A project whose test starts a process in a root of its own, which
--- its worker, held by a Landlock ruleset for not declaring `nests`,
--- is refused.
local function nesting_project(root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.write(root .. "/bin/probe", "#!/bin/sh\nexit 0\n"))
  assert(Fs.write(root .. "/suite/held_test.tl", table.concat({
    'local Child = require("cosmic.child")',
    'local Test = require("cosmic.test")',
    'Test.needs { reads = { "bin/probe" } }',
    "local record Confine",
    "  confine: function(declared: {string:{string}} | nil)",
    "end",
    "-- The worker's own, which a suite outside the tree cannot require.",
    'local confine = package.loaded["build.confine"] as Confine',
    "local function test_confined()",
    '  confine.confine({ reads = { "bin/probe" } })',
    '  local _, _ = Child.run({ "bin/probe" })',
    "  confine.confine(nil)",
    "end",
  }, "\n") .. "\n"))
end

--- Sandboxed, a test that reads a file and a variable it does not
--- declare is refused both, and passes, taking what it found; so is a
--- database its module's top level opens and one it attaches. The
--- audit names each from what the sandbox refused, and nothing the
--- host does not have either, nor what every worker is given -- its own
--- /proc, which a read of it notes and a refusal does not -- and passes
--- once they are declared.
local function test_the_audit_names_what_the_sandbox_refused(tmp: string)
  local root = tmp .. "/project"
  project(root, false)
  local ok, text = audit(root, tmp .. "/first.out")
  if unsandboxed(text) then return end
  assert(text:find("; sandboxed)", 1, true), text)
  assert(not ok, text)
  assert(text:find("audit: suite.reads_test (suite/reads_test.tl): 3 of 3 tests read " ..
    "what they do not declare\n", 1, true), text)
  assert(text:find("  test_reads:\n    reads        data/extra.txt\n" ..
    "    env          REFUSALS_ASKED\n", 1, true), text)
  assert(text:find("    reads        data/top.db\n", 1, true), text)
  assert(text:find("  test_attach:\n    reads        data/other.db\n", 1, true), text)
  assert(not text:find("helper.tl", 1, true) and not text:find("missing", 1, true), text)
  assert(not text:find("/proc", 1, true), text)
  assert(text:find("test: PASS", 1, true), text)
  project(root, true)
  ok, text = audit(root, tmp .. "/second.out")
  assert(ok, text)
  assert(text:find("audit: 3 tests read only their inputs\n", 1, true), text)
end

--- Sandboxed, a start refused a root of its own, which a worker held by
--- a Landlock ruleset cannot make, fails its test, and the audit names
--- `nests` from the refusal.
local function test_the_audit_names_a_root_of_its_own_refused(tmp: string)
  local root = tmp .. "/nesting"
  nesting_project(root)
  local ok, text = audit(root, tmp .. "/nesting.out")
  if unsandboxed(text) then return end
  assert(not ok, text)
  assert(text:find("    nests        bin/probe\n", 1, true), text)
  assert(text:find('  declare: Test.needs { reads = { "bin/probe" }, nests = true }', 1, true),
    text)
end
