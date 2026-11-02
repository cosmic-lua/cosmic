--- What build/boundary_hook_tool_test.tl and build/fact_hook_tool_test.tl share: a run of this program in a project,
--- unsandboxed and compiling with the new checker. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")

local record hook_tool_fixture
  --- A finished run and what it said.
  record Run
    result: Child.Result
    --- Its stdout and stderr, in the order they were written.
    text: string
  end
end

--- Runs the program with `words` in `root`, unsandboxed (a sandbox nested in a test's own may be refused where the host
--- nests only two deep), compiling with the new checker, and answers what it said.
--- @param root the project the run starts in
--- @param tmp a directory for its output and its TMPDIR
--- @param words the program's arguments
function hook_tool_fixture.invoke(root: string, tmp: string, words: {string}): hook_tool_fixture.Run
  local output = tmp .. "/out." .. tostring(Clock.monotonic_ns())
  local fd = assert(Fs.open_write(output))
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["TMPDIR"] = tmp
  env["COSMIC_GRAMMAR"] = "new"
  local started = this_program.program(words, {
    cwd = root, env = env, stdout = fd, stderr = fd,
    process_group = true, timeout_ns = Clock.seconds(120),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  return { result = assert(result, trouble), text = (assert(Fs.read(output))) }
end

return hook_tool_fixture
