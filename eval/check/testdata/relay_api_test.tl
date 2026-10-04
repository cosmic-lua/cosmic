--- The relay task's hidden API test: eval/check/grade.tl runs it
--- against a copy of a solver's project, never shown to the solver.
local Clock = require("cosmic.clock")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local relay = require("relay")

--- Both ends of a fresh connection over a socket file at `path`: the
--- one that connected and the one accepted.
local function pair(path: string): Net.Conn, Net.Conn
  local listener = assert(Net.listen(Net.unix(path)))
  local near = assert(Net.connect(Net.unix(path), { timeout_ns = Clock.seconds(5) }))
  local far = assert(listener:accept(Clock.seconds(5)))
  far:set_timeout(Clock.seconds(5))
  assert(listener:close())
  return near, far
end

--- Reads `conn` until `n` bytes have come or it ends.
local function read_n(conn: Net.Conn, n: integer): string, string
  local got = ""
  while #got < n do
    local chunk, trouble = conn:read()
    if chunk == nil then return got, trouble end
    got = got .. chunk
  end
  return got, "ok"
end

--- Runs `body` with a pipe between two pairs, `client` the far end of
--- `a` and `target` the far end of `b`, and answers what pipe answered.
local function piped(dir: string, options: relay.Options,
                     body: function(client: Net.Conn, target: Net.Conn)): relay.Stats
  local stats: relay.Stats = nil
  Poll.run(function()
    local client, a = pair(dir .. "/a.sock")
    local target, b = pair(dir .. "/b.sock")
    local task = Poll.spawn(function()
      stats = relay.pipe(a, b, options)
    end)
    body(client, target)
    assert(task:join(Clock.seconds(5)), "pipe did not return once both ways ended")
    local _, _ = client:close()
    local _, _ = target:close()
  end)
  return stats
end

local function test_pipe_copies_both_ways_through_half_closes(dir: string)
  local stats = piped(dir, {}, function(client: Net.Conn, target: Net.Conn)
    assert(client:write("hello"))
    assert(read_n(target, 5) == "hello", "a to b")
    assert(target:write("world!"))
    assert(read_n(client, 6) == "world!", "b to a")
    assert(client:shutdown("write"))
    local more, ended = target:read()
    assert(more == nil and ended == "", "a's half-close did not reach b")
    assert(target:write("late"))
    assert(read_n(client, 4) == "late", "b to a after a's half-close")
    assert(target:close())
    local last, done = client:read()
    assert(last == nil and done == "", "b's close did not reach a")
  end)
  assert(stats ~= nil, "pipe answered nothing")
  assert(stats.up == 5 and stats.down == 10, "up " .. tostring(stats.up) .. ", down " ..
      tostring(stats.down))
  assert(stats.idle == false, "idle")
end

local function test_pipe_lets_b_speak_first(dir: string)
  local stats = piped(dir, {}, function(client: Net.Conn, target: Net.Conn)
    assert(target:write("banner"))
    assert(target:shutdown("write"))
    local got, ended = read_n(client, 100)
    assert(got == "banner" and ended == "", "got '" .. got .. "' (" .. ended .. ")")
    assert(client:write("reply"))
    assert(client:shutdown("write"))
    assert(read_n(target, 100) == "reply", "a after b's half-close")
  end)
  assert(stats.up == 5 and stats.down == 6, "up " .. tostring(stats.up) .. ", down " ..
      tostring(stats.down))
end

local function test_pipe_ends_a_quiet_pair_at_its_idle_limit(dir: string)
  local started = Clock.monotonic_ns()
  local stats = piped(dir, { idle_ns = Clock.ms(200) }, function(client: Net.Conn, target: Net.Conn)
    assert(client:write("x"))
    assert(read_n(target, 1) == "x")
    local more, ended = client:read()
    assert(more == nil and ended == "", "the idle pair was not closed")
    local other, done = target:read()
    assert(other == nil and done == "", "the idle pair's other side was not closed")
  end)
  local took = (Clock.monotonic_ns() - started) // Clock.ms(1)
  assert(stats.idle == true and stats.up == 1 and stats.down == 0, "stats")
  assert(took >= 150 and took < 2000, "closed after " .. took .. " ms")
end

local function test_pipe_keeps_a_busy_pair_past_its_idle_limit(dir: string)
  local stats = piped(dir, { idle_ns = Clock.ms(200) }, function(client: Net.Conn, target: Net.Conn)
    for _ = 1, 6 do
      assert(client:write("a"))
      assert(read_n(target, 1) == "a", "a byte was lost")
      assert(Poll.delay(Clock.ms(100)))
    end
    assert(client:close())
    assert(target:close())
  end)
  assert(stats.idle == false and stats.up == 6, "stats")
end

local function test_pipe_moves_megabytes_whole(dir: string)
  local data = string.rep("0123456789abcdef", 128 * 1024)
  local got = ""
  local stats = piped(dir, {}, function(client: Net.Conn, target: Net.Conn)
    local writer = Poll.spawn(function()
      assert(client:write(data))
      assert(client:shutdown("write"))
    end)
    local ended: string
    got, ended = read_n(target, #data + 1)
    assert(ended == "", "the end did not follow the data: " .. ended)
    assert(writer:join(Clock.seconds(5)))
    assert(target:close())
  end)
  assert(got == data, #got .. " bytes of " .. #data)
  assert(stats.up == #data, "up " .. tostring(stats.up))
end
