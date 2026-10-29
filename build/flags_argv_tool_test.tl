--- [`Flags.dispatch`] in a program run as this one runs a script: the words it
--- is handed are the script's own, `argv[0]` being the script's path, and the
--- name in its usage is the one it is told. These start this program, so they
--- need `tool`; the unit cases of `dispatch` are in [`cosmic/flags_test.tl`], which
--- cannot hold a name in slot 0 of a typed array.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function test_the_usage_names_the_program_it_is_told_and_not_the_path_of_the_script(tmp: string)
  local script = tmp .. "/flags_fixture.tl"
  assert(Fs.write(script, [[
local Flags = require("cosmic.flags")

local commands: {string:Flags.Command} = {
  build = {
    about = "Builds the target.",
    run = function(_: Flags.Parsed): integer error("help runs nothing") end,
  },
}

return function(argv: {string}): integer
  -- The script's own path is in slot 0, as it is for every program run this way.
  local own = assert(argv[0])
  assert(own:find("flags_fixture.tl", 1, true) ~= nil, own)
  local done, why = Flags.dispatch(argv, 1, commands, "prog")
  if done == nil then
    print(why)
    return 2
  end
  print(done.help)
  return 0
end
]]))
  local started = this_program.program({ script, "--help" }, {
    cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  local out = result.stdout or ""
  assert(result.code == 0, tostring(result.stderr) .. out)
  assert(out:sub(1, 11) == "usage: prog", out)
  assert(out:find("flags_fixture", 1, true) == nil, out)
end
