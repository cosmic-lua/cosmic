--- The cases of cosmic.child whose child is sandboxed (`sandbox` with
--- `unveil`): this program again, past its launcher, in a root of its own.
--- They need a sandbox the host gives (`requires`), so where the platform
--- has none they are not applicable, and where this host's kernel refuses
--- one the test skips (Test.skip). What a platform with no sandbox does
--- is in cosmic/child_tool_test.tl.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local this_program = require("build.this_program")
local child_tool_fixture = require("build.child_tool_fixture")

--- The same as cosmic/child_tool_test.tl reads: the program itself
--- (`tool`), started past its launcher, `/proc`, and `nests`, for a child
--- sandboxed in a root of its own.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" }, { path = "/proc", letters = "r" } },
  promises = { "nest" },
  requires = { "sandbox" },
}

--- This program again, past its launcher ([`this_program.program`]),
--- running the Lua chunk `chunk` with `args` as its `...`: the child
--- each test starts, where a shell would need the system's. The argv
--- and options, for [`Child.run`] or [`Child.start`].
local function lua(chunk: string, args?: {string}, opts?: Child.Options): {string}, Child.Options
  local words: {string} = { "-e", chunk }
  for _, word in ipairs(args or {}) do words[#words + 1] = word end
  local started = this_program.program(words, opts)
  return started.argv, started.options
end

local sleeping, AGAIN = child_tool_fixture.sleeping, child_tool_fixture.AGAIN

--- Chunk prefixes: cosmic.fs as `Fs`, cosmic.sys as `sys`.
local FS <const> = 'local Fs = require("cosmic.fs") '
local SYS <const> = 'local sys = require("cosmic.sys") '

--- A child started in a sandbox of its own is ended by a timeout's SIGTERM,
--- not left for the SIGKILL after the grace period: it is its pid
--- namespace's pid 2, not the pid 1 that would pass over a signal it does
--- not catch from outside the namespace. Where the kernel will not sandbox
--- the child the test is skipped.
local function test_a_timeout_ends_a_sandboxed_child_that_catches_nothing(tmp: string)
  local reads = confine.itself()
  reads[#reads + 1] = "/proc"
  reads[#reads + 1] = "/dev/null"
  -- A directory it may start in: the worker's own, the tree's root, is
  -- none of what it unveils.
  reads[#reads + 1] = tmp
  local sandboxed, trouble = Child.run(lua(sleeping(100000), nil,
    { cwd = tmp, timeout_ns = Clock.ms(200), sandbox = { unveil = { reads = reads }, offline = true } }))
  if sandboxed == nil then
    Test.skip("no sandbox for the child: " .. tostring(trouble))
    return
  end
  assert(sandboxed.timed_out and sandboxed.signal == sys.SIGTERM,
    "sandboxed, ended by " .. tostring(sandboxed.signal))
end

--- A child started with a `sandbox` has only what it unveils, a path
--- at the name `at` gives it, and is held there with every process it
--- starts; a relative unveiled path is refused. Where the kernel will not
--- sandbox a child (no unprivileged user namespaces, say), the start fails
--- and the test is skipped.
local function test_a_sandboxed_child_has_only_what_it_unveils(tmp: string)
  local given, hidden = tmp .. "/given", tmp .. "/hidden"
  assert(Fs.mkdirs(given))
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(given .. "/f", "in"))
  local reads = confine.itself()
  reads[#reads + 1] = given
  reads[#reads + 1] = "/proc"
  reads[#reads + 1] = "/dev/null"
  local r, trouble = Child.run(lua(AGAIN .. FS .. SYS .. 'local hidden, given = ... ' ..
      'Fs.put(1, assert(Fs.read("f")) .. "\\n" .. assert(sys.getcwd()) .. "\\n" .. ' ..
      '(Fs.exists(hidden) == true and "hidden-seen" or "hidden-absent") .. "\\n") ' ..
      'local own = assert(again("return require(\'cosmic.fs\').exists(" .. ' ..
      'string.format("%q", given) .. ") == true and 0 or 1"):wait()) ' ..
      'Fs.put(1, (own.code == 0 and "own-name" or "no-own-name") .. "\\n")', { hidden, given },
    { cwd = "/given", stdout = "capture", stderr = "stdout",
      sandbox = { unveil = { reads = reads, at = { [given] = "/given" } }, offline = true } }))
  if r == nil then
    Test.skip("no sandbox for the child: " .. tostring(trouble))
    return
  end
  assert(r.ok and r.stdout == "in\n/given\nhidden-absent\nno-own-name\n", tostring(r.stdout))
  assert(not pcall(Child.start, { "/bin/sh" },
    { sandbox = { unveil = { reads = { "relative" } } } } as Child.Options))
end
