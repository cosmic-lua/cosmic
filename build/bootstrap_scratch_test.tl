--- Standalone cache scratch ownership across independent processes.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Patch = require("build.patch")
local ZigFetch = require("build.zig_fetch")
local this_program = require("build.this_program")

Test.policy{ cpu_features = true, profiles = { "cosmic" } }

local function holder(path: string): Child.Handle
  local script = [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local fd = assert(sys.open(%q, sys.O_RDWR | sys.O_CREAT, 0x180))
assert(sys.flock(fd, "exclusive", 0))
print("held")
Fs.take(Fs.stdin, 1)
]]
  local command = this_program.program({ "-e", script:format(path) },
    { stdin = "stream", stdout = "stream", stderr = "capture" })
  local child = assert(Child.start(command.argv, command.options))
  assert(Stream.lines(assert(child.stdout_stream)):read() == "held")
  return child
end

--- How long a wait for a child to end is given: a guard against a hang
--- alone, generous for a slow host.
local finish_ns <const> = Clock.seconds(20)

local function release(child: Child.Handle)
  assert(assert(child.stdin_stream):close())
  assert(assert(child:wait(finish_ns)).ok)
end

local function prepare(root: string, cache: string, patch: boolean)
  if patch then
    assert(Patch.prepare(root, "lib", cache))
  else
    local result, trouble = ZigFetch.install(cache, cache .. "/install", "v", "host", nil)
    assert(result == nil and trouble:find("sha256", 1, true) ~= nil, trouble)
  end
end

local function source(root: string)
  assert(Fs.mkdirs(root .. "/vendor/lib"))
  assert(Fs.write(root .. "/vendor/lib/PIN", "url https://invalid.example/lib\n"))
  assert(Fs.write(root .. "/vendor/lib/file", "whole"))
end

local function test_sweeps_preserve_live_owners_and_reap_killed_ones(tmp: string)
  for _, patch in ipairs({ false, true }) do
    local root = tmp .. "/" .. tostring(patch)
    source(root)
    local cache = root .. "/cache"
    local wrapper = cache .. "/.scratch.live"
    assert(Fs.mkdirs(wrapper .. "/payload"))
    local missing = cache .. "/.scratch.missing"
    local legacy = cache .. "/lib.work.2147483646"
    assert(Fs.mkdirs(missing))
    assert(Fs.mkdirs(legacy))
    local child = holder(wrapper .. "/owner")
    prepare(root, cache, patch)
    assert(Fs.exists(wrapper), "a live owner's payload was swept")
    assert(sys.kill(child.pid, sys.SIGKILL))
    local _ = assert(child:wait(Clock.seconds(5)))
    -- Move the patched content so the second prepare is also a cache miss.
    assert(Fs.write(root .. "/vendor/lib/file", "next"))
    prepare(root, cache, patch)
    assert(Fs.exists(wrapper) == false, "a dead owner's payload was retained")
    assert(Fs.exists(missing), "missing ownership metadata was treated as dead")
    assert(Fs.exists(legacy), "a legacy PID was treated as proof of death")
  end
end

local function test_gate_holds_creation_until_an_owner_can_be_established(tmp: string)
  for _, patch in ipairs({ false, true }) do
    local root = tmp .. "/" .. tostring(patch)
    source(root)
    local cache = root .. "/cache"
    assert(Fs.mkdirs(cache))
    local gate = holder(cache .. "/.scratch-gate")
    local script = if patch then [[
assert(require("build.patch").prepare(%q, "lib", %q))
]] else [[
local cache = %q
require("build.zig_fetch").install(cache, cache .. "/install", "v", "host", nil)
]] end
    local body = patch and script:format(root, cache) or script:format(cache)
    body = 'print("started")\n' .. body .. '\nprint("finished")'
    local command = this_program.program({ "-e", body }, { stdout = "stream", stderr = "capture" })
    local child = assert(Child.start(command.argv, command.options))
    local lines = Stream.lines(assert(child.stdout_stream))
    assert(lines:read() == "started")
    local result, _ = Child.wait_any({ child }, Clock.ms(100))
    assert(result == nil, "creation bypassed the held gate")
    assert(table.concat(assert(Fs.list(cache)), " ") == ".scratch-gate")
    release(gate)
    assert(lines:read() == "finished")
    assert(assert(child:wait(finish_ns)).ok)
    for _, name in ipairs((assert(Fs.list(cache)))) do
      assert(not name:match("^%.scratch%."), "a completed install retained scratch")
    end
  end
end

-- TODO: test that creating the scratch directory and taking its owner are one gated operation, as a pause between
-- [`Fs.scratch`]'s `mkdtemp` and its `owner` open once did by replacing [`sys.mkdtemp`] in a child, once a test can hold a
-- process between two calls of the library without replacing a field of its table: a checked chunk cannot assign one.
local function test_concurrent_patch_installs_publish_only_whole_payloads(tmp: string)
  source(tmp)
  local cache = tmp .. "/cache"
  local script = [[
local Fs = require("cosmic.fs")
local path = assert(require("build.patch").prepare(%q, "lib", %q))
assert(Fs.read(path .. "/file") == "whole")
assert(Fs.exists(path .. "/owner") == false)
print(path)
]]
  local children: mut {Child.Handle} = {}
  for _ = 1, 4 do
    local command = this_program.program({ "-e", script:format(tmp, cache) },
      { stdout = "capture", stderr = "capture" })
    children[#children + 1] = assert(Child.start(command.argv, command.options))
  end
  local published = ""
  for _, child in ipairs(children) do
    local result = assert(child:wait(finish_ns))
    assert(result.ok, result.stderr)
    if published == "" then published = result.stdout or "" end
    assert(result.stdout == published)
  end
  for _, name in ipairs((assert(Fs.list(cache)))) do
    assert(not name:match("^%.scratch%."), "an installer retained its wrapper")
  end
end
