--- What the end-to-end tests of [`confine.must_confine`] share (build/must_confine_test.tl and
--- build/must_confine_sandboxed_test.tl): a stand-in program for a child to start, and a run of one of the children of
--- build/must_confine_children_test.tl in this program. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local stand_in = require("build.stand_in")
local test_child = require("build.test_child")
local this_program = require("build.this_program")

local record must_confine_fixture
  --- What a child ended with and printed.
  record Said
    code: integer
    text: string
  end

  --- A stand-in program built under `tmp` (build/stand_in.tl), which a child confined to itself alone can start.
  probe: function(tmp: string): string

  --- Runs the child `name` of build/must_confine_children_test.tl in this program with `args`, in `tmp`, with `set` added
  --- to its environment and COSMIC_SANDBOX otherwise unset, and answers what it ended with and printed.
  run: function(tmp: string, name: string, args: {string}, set?: {string:string}): must_confine_fixture.Said

  --- What the line `name=` of `said` holds. Raises where the child printed none.
  field: function(said: must_confine_fixture.Said, name: string): string
end

function must_confine_fixture.probe(tmp: string): string
  return (assert(stand_in.build(tmp .. "/stand-in")))
end

function must_confine_fixture.run(tmp: string, name: string, args: {string}, set?: {string:string}): must_confine_fixture.Said
  local env = this_program.environment()
  env["COSMIC_SANDBOX"] = nil
  for key, value in pairs(set or {}) do env[key] = value end
  local started = this_program.program(test_child.words(tmp, "build.must_confine_children_test", name, args),
    { env = env, cwd = tmp, stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60) })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code or -1, text = result.stdout or "" }
end

function must_confine_fixture.field(said: must_confine_fixture.Said, name: string): string
  local value = ("\n" .. said.text):match("\n" .. name .. "=([^\n]*)")
  assert(value ~= nil, name .. " is not among what the child printed: " .. said.text)
  return value
end

return must_confine_fixture
