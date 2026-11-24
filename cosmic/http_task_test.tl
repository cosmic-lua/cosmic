--- [`cosmic.http`] in a task of [`Poll.run`]: a request waits through
--- the run, so a server in the same run responds to it and the other tasks
--- go on meanwhile.

local Clock = require("cosmic.clock")
local Http = require("cosmic.http")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" } }

--- How long a request here waits for what the server never fails to do.
local WAIT <const> = Clock.seconds(20)

--- Reads a request's head from `conn`; nil where the client left first.
local function head_of(conn: Net.Conn): string?
  local seen = ""
  while not seen:find("\r\n\r\n", 1, true) do
    local chunk = conn:read(4096)
    if chunk == nil then return nil end
    seen = seen .. chunk
  end
  return seen
end

--- A handler that sends `body` for each request, after `delay_ns`.
local function answering(body: string, delay_ns?: integer): function(conn: Net.Conn)
  return function(conn: Net.Conn)
    if head_of(conn) == nil then return end
    if delay_ns ~= nil then assert(Clock.sleep(delay_ns)) end
    assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: " .. tostring(#body) ..
        "\r\nConnection: close\r\n\r\n" .. body))
  end
end

local function test_a_request_to_a_server_of_the_same_run_is_answered()
  Poll.run(function()
    Net.with_loopback(answering("hello"), function(port: integer)
      local got = assert(Http.get("http://127.0.0.1:" .. tostring(port) .. "/", { timeout_ns = WAIT }))
      assert(got.status == 200, tostring(got.status))
      assert(got.body == "hello", got.body)
    end)
  end)
end

--- The server responds only once another task has run three times after both
--- requests were sent, so the requests end only if the run went on while they
--- waited: no count of ticks in a span of time, which a loaded host shortens.
local function test_other_tasks_run_while_a_request_waits()
  Poll.run(function()
    local heads = 0
    local ticks = 0
    Net.with_loopback(function(conn: Net.Conn)
      if head_of(conn) == nil then return end
      heads = heads + 1
      while heads < 2 or ticks < 3 do assert(Clock.sleep(Clock.ms(5))) end
      assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nlate"))
    end, function(port: integer)
      local done = false
      local ticker = Poll.spawn(function()
        while not done do
          if heads == 2 then ticks = ticks + 1 end
          local _, _ = Clock.sleep(Clock.ms(10))
        end
      end)
      local url = "http://127.0.0.1:" .. tostring(port) .. "/"
      local bodies: mut {integer: string} = {}
      local a = Poll.spawn(function()
        bodies[1] = assert(Http.get(url, { timeout_ns = WAIT })).body
      end)
      local b = Poll.spawn(function()
        bodies[2] = assert(Http.get(url, { timeout_ns = WAIT })).body
      end)
      assert(a:join())
      assert(b:join())
      done = true
      assert(ticker:join())
      assert(bodies[1] == "late" and bodies[2] == "late", tostring(bodies[1]) .. " " .. tostring(bodies[2]))
      assert(ticks >= 3, "the other task ran " .. tostring(ticks) .. " times while the requests waited")
    end)
  end)
end

local function test_a_large_body_is_read_through_the_run()
  -- Past the core's pause threshold (1 MiB), so the transfer pauses and
  -- is resumed between reads.
  local body = string.rep("0123456789abcdef", 200000)
  Poll.run(function()
    Net.with_loopback(answering(body), function(port: integer)
      local response <close> = assert(Http.open("http://127.0.0.1:" .. tostring(port) .. "/", { timeout_ns = WAIT }))
      local read = assert(Stream.read_all(response))
      assert(read == body, "read " .. tostring(#read) .. " bytes of " .. tostring(#body))
    end)
  end)
end

local function test_a_cancelled_task_ends_its_request()
  Poll.run(function()
    local held = false
    Net.with_loopback(function(conn: Net.Conn)
      if head_of(conn) == nil then return end
      held = true
      local _, _ = Clock.sleep(Poll.MOST_NS)
    end, function(port: integer)
      local answer: string = ""
      local asking = Poll.spawn(function()
        local got, why = Http.get("http://127.0.0.1:" .. tostring(port) .. "/", { timeout_ns = WAIT })
        assert(got == nil)
        answer = why
      end)
      while not held do assert(Clock.sleep(Clock.ms(5))) end
      asking:cancel()
      assert(asking:join())
      assert(answer == Poll.CANCELLED, answer)
    end)
  end)
end

local function test_a_refused_connection_fails_as_outside_a_run()
  -- A port nothing listens at: listened at once, then closed.
  local listener = assert(Net.listen(Net.tcp("127.0.0.1", 0)))
  local port = listener.address.port
  assert(listener:close())
  local url = "http://127.0.0.1:" .. tostring(port) .. "/"
  local outside, outside_why = Http.get(url, { timeout_ns = WAIT })
  assert(outside == nil)
  Poll.run(function()
    local inside, inside_why = Http.get(url, { timeout_ns = WAIT })
    assert(inside == nil)
    assert(inside_why == outside_why, inside_why .. " / " .. outside_why)
  end)
end

local function test_a_response_closed_by_another_task_ends_a_read_that_waits()
  Poll.run(function()
    local held = false
    Net.with_loopback(function(conn: Net.Conn)
      if head_of(conn) == nil then return end
      -- The head and a first byte, then nothing.
      assert(conn:write("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nx"))
      held = true
      local _, _ = Clock.sleep(Poll.MOST_NS)
    end, function(port: integer)
      local response = assert(Http.open("http://127.0.0.1:" .. tostring(port) .. "/", { timeout_ns = WAIT }))
      assert(response:read() == "x")
      local answer = ""
      local reading = Poll.spawn(function()
        local chunk, why = response:read()
        assert(chunk == nil)
        answer = why
      end)
      while not held do assert(Clock.sleep(Clock.ms(5))) end
      assert(Clock.sleep(Clock.ms(50)))
      assert(response:close())
      assert(reading:join())
      assert(answer == "http: the response is closed", answer)
    end)
  end)
end

local function test_a_cancelled_task_ends_its_retry_pause()
  Poll.run(function()
    local asked = false
    Net.with_loopback(function(conn: Net.Conn)
      if head_of(conn) == nil then return end
      asked = true
      assert(conn:write("HTTP/1.1 503 Busy\r\nRetry-After: 5\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
    end, function(port: integer)
      local answer = ""
      local asking = Poll.spawn(function()
        local got, why = Http.get("http://127.0.0.1:" .. tostring(port) .. "/", {
          timeout_ns = WAIT,
          retry = { attempts = 3, statuses = { 503 }, max_wait_ns = Clock.seconds(30) },
        })
        assert(got == nil)
        answer = why
      end)
      while not asked do assert(Clock.sleep(Clock.ms(5))) end
      assert(Clock.sleep(Clock.ms(100)))
      asking:cancel()
      assert(asking:join())
      assert(answer == Poll.CANCELLED, answer)
    end)
  end)
end
