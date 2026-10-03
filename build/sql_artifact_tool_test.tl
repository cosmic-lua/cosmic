--- The candidate command invokes new bindings; the pinned controller does not.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local Time = require("cosmic.time")
local fixture = require("build.sql_artifact_fixture")
local this_program = require("build.this_program")

Test.needs{ tool = true }

local function run(tmp: string, words: {string}): Child.Result
  local started = this_program.program(words, { cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = Time.seconds(30) })
  return (assert(Child.run(started.argv, started.options)))
end

local function test_artifact_cli_joins_named_attachments_without_building_an_ancestor(tmp: string)
  local a = fixture.write(tmp, "a", "one", true)
  local b = fixture.write(tmp, "b", "two")
  assert(Fs.write(tmp .. "/broken.tl", "this is deliberately not Teal"))
  assert(Fs.mkdirs(tmp .. "/child"))
  local result = run(tmp .. "/child", { "sql", "--artifact", a, "--attach-artifact", "b=" .. b,
    "SELECT a.source,b.source FROM main.modules a JOIN b.modules b USING(path)" })
  assert(result.ok, result.stderr)
  assert((result.stdout or ""):find("one\ttwo\n", 1, true), result.stdout)
  assert(not Fs.exists(tmp .. "/o"), "inspection built the ancestor")
  for _, words in ipairs({
      { "--attach-artifact", "b=" .. b },
      { "--artifact", a, "--db", a },
      { "--artifact", a, "--artifact", b },
      { "--artifact", a, "--attach-artifact", "main=" .. b },
      { "--artifact", a, "--attach-artifact", "bad-name=" .. b },
      { "--artifact", a, "--attach-artifact", "b=" .. b, "--attach-artifact", "B=" .. b },
      { "--artifact", a, "--from", a },
  } as {{string}}) do
    local argv = { "sql" }
    for _, word in ipairs(words) do argv[#argv + 1] = word end
    argv[#argv + 1] = "SELECT 1"
    assert(run(tmp, argv).code == 2, table.concat(words, " "))
  end
  assert(run(tmp, { "sql", "--artifact", a, "DELETE FROM modules" }).code == 1)
  assert(run(tmp, { "sql", "--artifact", tmp .. "/missing", "SELECT 1" }).code == 1)
end
