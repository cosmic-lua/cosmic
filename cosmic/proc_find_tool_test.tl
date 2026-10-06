--- Executable lookup uses the child's actual PATH, including its absence.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local type _ = require("cosmic.proc")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- Only the default search's first candidate is needed; it is inspected,
--- not run. The child itself is this program running a chunk.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "/bin/sh", letters = "r" } },
}

local function lookup(dir: string, path: string | nil): string
  local env = this_program.environment()
  env.PATH = path
  local script = [[
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")
local result = Proc.find_result("sh")
local legacy, reason = Proc.find("sh")
assert(legacy == result.path and reason == result.reason)
print(Env.get("PATH") == nil and "unset" or "set", result.kind, result.path, result.reason)
]]
  local started = this_program.program({ "-e", script }, {
    env = env, cwd = dir, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(10),
  })
  local child = assert(Child.run(started.argv, started.options))
  assert(child.ok, child.stderr)
  return child.stdout or ""
end

--- Unset PATH uses the default list, not the working directory; an empty
--- PATH and empty components explicitly select the working directory.
local function test_find_result_distinguishes_unset_and_empty_path(dir: string)
  assert(Fs.write(dir .. "/sh", "", 0x1c0))
  assert(lookup(dir, nil) == "unset\tresolved\t/bin/sh\t\n")
  for _, path in ipairs({ "", ":", dir .. "/missing:", dir .. "/missing::" .. dir .. "/elsewhere" }) do
    assert(lookup(dir, path) == "set\tresolved\t./sh\t\n", path)
  end
  assert(lookup(dir, dir) == "set\tresolved\t" .. dir .. "/sh\t\n")
end
