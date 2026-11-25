local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.policy{ profiles = { "cosmic" } }

--- An empty or relative TMPDIR is unset: [`Fs.temp_dir`] is /tmp, and
--- mkdtemp makes (or tries to make) its directory there. The child prints the temp directory and the path
--- mkdtemp made, or the template it was refused, since the sandbox may not
--- grant /tmp.
local function test_an_empty_or_relative_tmpdir_is_tmp(tmp: string)
  local script = [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local made, why = Fs.mkdtemp("cosmic-empty-tmpdir-")
assert(sys.write(1, Fs.temp_dir() .. "\n" .. (made or tostring(why.path)) .. "\n"))
if made ~= nil then assert(Fs.remove_tree(made)) end
]]
  for _, given in ipairs({ "", "relative" }) do
    local env = this_program.environment()
    env["TMPDIR"] = given
    local started = this_program.program({ "-e", script },
      { env = env, cwd = tmp, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) })
    local result = assert(Child.run(started.argv, started.options))
    assert(result.code == 0, tostring(result.stderr))
    local out = assert(result.stdout)
    assert(out:find("^/tmp\n/tmp/cosmic%-empty%-tmpdir%-") ~= nil, given .. ": " .. out)
  end
end
