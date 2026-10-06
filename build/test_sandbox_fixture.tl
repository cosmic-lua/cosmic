--- What build/test_sandbox_tool_test.tl and build/test_sandbox_run_tool_test.tl
--- share: a `cosmic test` run on a suite of their own, and a suite of one
--- module that grants a `host` path. Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")

local record test_sandbox_fixture
  --- What a run printed and whether it passed.
  record Run
    text: string
    ok: boolean
  end
end

--- Runs `cosmic test --all` on `root` with `env`, answering what it
--- printed and whether it passed.
--- @param root the suite's tree, which the run starts in
--- @param output the file the run's output is written to
--- @param env the run's environment
function test_sandbox_fixture.run(root: string, output: string, env: {string:string}): test_sandbox_fixture.Run
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test", "--all" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return { text = text, ok = result.ok }
end

--- Writes `root`/suite/host_test.tl, whose one test grants the host path
--- `path` to read and fails with what it read of `product`/given.txt and
--- `product`/sibling.txt, `read|<given>|<sibling>|end`.
--- @param root the suite's tree
--- @param product the host directory the test reads two files of
--- @param path the path its policy grants
function test_sandbox_fixture.host_test(root: string, product: string, path: string)
  assert(Fs.write(root .. "/suite/host_test.tl", [[
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy { grants = { { path = "]] .. path .. [[", letters = "r" } } }

local function test_read()
  error("read|" .. tostring((Fs.read("]] .. product .. [[/given.txt"))) .. "|" ..
    tostring((Fs.read("]] .. product .. [[/sibling.txt"))) .. "|end")
end
]]))
end

return test_sandbox_fixture
