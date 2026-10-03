local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local type _ = require("cosmic.sys")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

Test.needs{ lua = true }

local function appender(tmp: string, name: string): Child.Handle
  local script = string.format("local name = %q\n", name) .. [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
assert(sys.write(1, "ready"))
assert(sys.read(0, 1) == "g")
for i = 1, 1000 do
  assert(Fs.append("log", string.format("%s:%04d\n", name, i)))
end
]]
  local started = this_program.program({ "-e", script }, {
    env = this_program.environment(), cwd = tmp,
    stdin = "stream", stdout = "stream", stderr = "capture",
  })
  return (assert(Child.start(started.argv, started.options)))
end

--- Both processes reach the gate before either appends. Each small record
--- fits one write; the API does not promise that larger records cannot mix.
local function test_append_concurrent_processes_preserve_both_ordered_streams(tmp: string)
  local first <close> = appender(tmp, "a")
  local second <close> = appender(tmp, "b")
  assert(assert(first.stdout_stream):read(5) == "ready")
  assert(assert(second.stdout_stream):read(5) == "ready")
  assert(assert(first.stdin_stream):write("g"))
  assert(assert(second.stdin_stream):write("g"))
  local a = assert(first:wait(Clock.seconds(10)))
  local b = assert(second:wait(Clock.seconds(10)))
  assert(a.ok, a.stderr)
  assert(b.ok, b.stderr)
  local next_index: {string:integer} = { a = 1, b = 1 }
  local data = assert(Fs.read(tmp .. "/log"))
  assert(#data == 14000)
  for name, index in data:gmatch("([ab]):(%d%d%d%d)\n") do
    assert(tonumber(index) == next_index[name])
    next_index[name] = next_index[name] + 1
  end
  assert(next_index.a == 1001 and next_index.b == 1001)
end
