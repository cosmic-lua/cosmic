--- What build/test_sandbox_tool_test.tl and build/test_sandbox_run_tool_test.tl
--- share: a `cosmic test` run on a suite of their own, and a suite of one
--- module that grants a `host` path, and a run of this program in a project (build/boundary_hook_tool_test.tl and
--- build/fact_hook_tool_test.tl). Test support.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local stand_in = require("build.stand_in")
local this_program = require("build.this_program")

local record test_sandbox_fixture
  --- What a run printed and whether it passed.
  record Run
    text: string
    ok: boolean
  end

  --- A run of [`test_sandbox_fixture.run_words`].
  record Words
    ok: boolean
    stdout: string
    stderr: string
  end

  --- A finished run of [`test_sandbox_fixture.invoke`] and what it said.
  record Invoked
    result: Child.Result
    --- Its stdout and stderr, in the order they were written.
    text: string
  end

  --- What a run with the sandbox off printed and how it ended.
  record Unsandboxed
    --- Its stdout and then its stderr.
    text: string
    code: integer?
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

--- Runs `cosmic test` on `root` with the sandbox off (`COSMIC_TEST_SANDBOX=0`) and the environment this program has
--- besides what `extra` sets, answering what it printed and its exit status.
--- @param root the suite's tree, which the run starts in
--- @param extra variables to set on top of the environment
function test_sandbox_fixture.unsandboxed(root: string, extra: {string:string}): test_sandbox_fixture.Unsandboxed
  local env = this_program.environment()
  env["COSMIC_TEST_SANDBOX"] = "0"
  env["COSMIC_SANDBOX"] = nil
  env["COSMIC_CI_REQUIRE_SANDBOX"] = nil
  for name, value in pairs(extra) do env[name] = value end
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { text = (result.stdout or "") .. (result.stderr or ""), code = result.code }
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

--- Makes `root`, a tree for a suite, with a stand-in program
--- (build/stand_in.tl) at bin/probe for its tests to start, which
--- declare it -- not this program, which would take `tool` -- in the
--- tree, since a sandboxed worker has a /tmp of its own over this
--- test's.
--- @param tmp the test's directory, where the stand-in is built
--- @param root the suite's tree
function test_sandbox_fixture.suite_tree(tmp: string, root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), root .. "/bin/probe"))
end

--- Makes `root` as [`suite_tree`] does, with `hidden`, a directory outside it,
--- and a suite of one test that declares a file of the tree and the stand-in
--- and fails with what it and a process it starts see, `seen|<cwd>|<tmp>|
--- <data>|<secret>|<hidden exists>|<declared var>|<undeclared var>|<child>|end`.
--- @param tmp the test's directory
--- @param root the suite's tree
--- @param hidden a directory outside the tree
function test_sandbox_fixture.view_suite(tmp: string, root: string, hidden: string)
  test_sandbox_fixture.suite_tree(tmp, root)
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(root .. "/suite/data.txt", "declared"))
  assert(Fs.write(root .. "/suite/secret.txt", "undeclared"))
  assert(Fs.write(root .. "/suite/view_test.tl", string.format([[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.policy {
  grants = {
    { path = "suite/data.txt", letters = "r" },
    { path = "bin/probe", letters = "r" },
  },
  env = { "DECLARED_VAR" },
}

local function test_view(tmp: string)
  local here = assert(sys.getcwd())
  -- What a process it starts sees, with the worker's environment.
  local child = assert(Child.run({ "bin/probe",
    "cat-quiet suite/data.txt; cat-quiet suite/secret.txt; print /$DECLARED_VAR/$UNDECLARED_VAR" },
    { stdout = "capture" }))
  error(table.concat({ "seen", here, tmp,
    tostring((Fs.read(here .. "/suite/data.txt"))),
    tostring((Fs.read(here .. "/suite/secret.txt"))),
    tostring(sys.stat(%q) ~= nil), tostring(sys.getenv("DECLARED_VAR")),
    tostring(sys.getenv("UNDECLARED_VAR")), (tostring(child.stdout):gsub("\n", "")), "end" }, "|"))
end
]], hidden)))
end

--- Runs the program with `words` in `root`, unsandboxed (a sandbox nested in a test's own may be refused where the host
--- nests only two deep), compiling with the new checker, and answers what it said.
--- @param root the project the run starts in
--- @param tmp a directory for its output and its TMPDIR
--- @param words the program's arguments
function test_sandbox_fixture.invoke(root: string, tmp: string, words: {string}): test_sandbox_fixture.Invoked
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

--- The descriptors [`this_program.program`] hands its child, as
--- [`process.spawn`] takes them: each a descriptor of this process, as
--- the relaunch's are, and none "capture", which only [`cosmic.child`]
--- reads.
function test_sandbox_fixture.spawn_fds(started: this_program.Program): {integer:integer}
  local fds: mut {integer:integer} = {}
  for number, fd in pairs(started.options.fds or {}) do
    if fd is integer then
      fds[number] = fd
    else
      error("descriptor " .. tostring(number) .. " is " .. fd .. ", which spawn cannot hand on")
    end
  end
  return fds
end

--- Runs `words` after this program, past its launcher, and answers whether it exited 0, and what it wrote to stdout and
--- stderr.
--- @param words the program's arguments
function test_sandbox_fixture.run_words(words: {string}): test_sandbox_fixture.Words
  local started = this_program.program(words, { stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(30) })
  local result = assert(Child.run(started.argv, started.options))
  return { ok = result.ok, stdout = result.stdout or "", stderr = result.stderr or "" }
end

return test_sandbox_fixture
