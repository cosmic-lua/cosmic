local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local type _ = require("cosmic.sys")
local Clock = require("cosmic.clock")
local Test = require("cosmic.test")
local this_program = require("build.this_program")
local type Stream = require("cosmic.stream")

--- The next chunk of `reader`: raises where it ended or failed.
local function chunk_of(reader: Stream.Reader, max_bytes?: integer): string
  local chunk, why = reader:read(max_bytes)
  if chunk == nil then error(tostring(why), 2) end
  if chunk == false then error("the stream ended", 2) end
  return chunk
end

Test.policy{ profiles = { "cosmic" } }

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
  local started = this_program.program({ "-e", script }, { timeout_ns = Child.FOREVER,
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
  assert(chunk_of(assert(first.stdout_stream), 5) == "ready")
  assert(chunk_of(assert(second.stdout_stream), 5) == "ready")
  assert(assert(first.stdin_stream):write("g"))
  assert(assert(second.stdin_stream):write("g"))
  local a = assert(first:wait(Clock.seconds(10)))
  local b = assert(second:wait(Clock.seconds(10)))
  assert(a.ok, a.stderr)
  assert(b.ok, b.stderr)
  local next_index: mut {string:integer} = { a = 1, b = 1 }
  local data = assert(Fs.read(tmp .. "/log"))
  assert(#data == 14000)
  for name, index in data:gmatch("([ab]):(%d%d%d%d)\n") do
    local expected = assert(next_index[name], "the pattern matches only a and b")
    assert(tonumber(index) == expected)
    next_index[name] = expected + 1
  end
  assert(next_index.a == 1001 and next_index.b == 1001) -- checked: map_field*2
end
