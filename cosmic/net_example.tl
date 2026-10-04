--- Worked examples for [`cosmic.net`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

--- The TCP example listens on the worker's own loopback.
Test.needs{ network = { "127.0.0.1" } }

--- Skips the running example, and answers true, where the worker may make
--- no unix socket in `dir`: its seccomp filter refuses `socket` unless its
--- policy has a `u` grant, which needs Landlock ABI 9 beside another
--- directory (as build/unix_socket.tl, which an example may not import).
-- TODO: delete this once the kernels the suite runs on give Landlock ABI 9
-- and the worker is granted its scratch directory's sockets (the TODO at
-- build/unix_socket.tl).
local function unix_refused(dir: string): boolean
  local probe, why = Net.listen(Net.unix(dir .. "/probe.sock"))
  if probe ~= nil then
    local _, _ = probe:close()
    return false
  end
  -- Only a failure under a seccomp filter is the policy's refusal.
  local status, _ = Fs.read("/proc/self/status")
  if status == nil or status:match("\nSeccomp:%s*(%d+)") ~= "2" then return false end
  Test.skip("the worker cannot make a unix socket (" .. why .. "): its policy has no `u` grant")
  return true
end

local Example = {}

--- A server on a socket file: it makes the file, and `close` (here, the
--- `<close>` variable going out of scope) removes it. Every wait is
--- bounded by `timeout_ns`, which a connection accepted inherits.
function Example.listen()
  local dir = assert(Fs.mkdtemp("cosmic-net-example-"))
  if unix_refused(dir) then
    assert(Fs.remove_tree(dir))
    return
  end
  do
    local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock"), { timeout_ns = Clock.seconds(5) }))
    local client <close> = assert(Net.connect(server.address))
    local conn <close> = assert(server:accept())
    assert(client:write("ping\n"))
    local line = assert(Stream.lines(conn):read())
    print(line)
    assert(line == "ping", line)
  end
  assert(Fs.stat(dir .. "/app.sock") == nil, "the socket file was left")
  assert(Fs.remove_tree(dir))
end

--- A request and its answer: `shutdown("write")` tells the server the
--- request is whole while the client still reads what comes back.
function Example.connect()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  local client <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
  assert(client:write("status"))
  assert(client:shutdown("write"))
  local conn = assert(server:accept())
  local request = assert(Stream.read_all(conn))
  assert(conn:write(request == "status" and "ok" or "unknown"))
  assert(conn:close())
  local answer = assert(Stream.read_all(client))
  print(answer)
  assert(answer == "ok", answer)
  assert(server:close())
end

--- A TCP server on the loopback at a port the kernel chose, which the
--- listener's `address` names for a client to connect to.
function Example.tcp()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  print(server.address.port > 0)
  local client <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
  local conn <close> = assert(server:accept())
  assert(client:write("hello"))
  assert(assert(conn:read()) == "hello")
end

--- A server that serves each connection in a task of its own, in a
--- task of [`Poll.run`]: while one connection waits to be read, the
--- others are served.
function Example.accept()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ns = Clock.seconds(5) }))
  Poll.run(function()
    Poll.spawn(function()
      for _ = 1, 2 do
        local conn = assert(server:accept())
        Poll.spawn(function()
          local name = assert(Stream.lines(conn):read())
          assert(conn:write("hello, " .. name .. "\n"))
          assert(conn:close())
        end)
      end
    end)
    local quiet <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
    local client <close> = assert(Net.connect(server.address, { timeout_ns = Clock.seconds(5) }))
    assert(client:write("world\n"))
    local greeting = assert(Stream.lines(client):read())
    print(greeting)
    assert(greeting == "hello, world")
    assert(quiet:write("quiet\n"))
    assert(Stream.lines(quiet):read() == "hello, quiet")
  end)
end

--- A line-echo server on the loopback, each connection served in a
--- task of its own until [`Server.stop`]: here `on_ready`, called once
--- the server listens, is its client, and stops it once answered.
function Example.serve()
  assert(Net.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    limits = { connections = 64 },
    timeout_ns = Clock.seconds(5),
    grace_ns = Clock.seconds(1),
    serve = function(conn: Net.Conn)
      local lines = Stream.lines(conn)
      for line in lines:each() do assert(conn:write(line .. "\n")) end
    end,
    on_ready = function(addresses: {Net.Address}, server: Net.Server)
      local client <close> = assert(Net.connect(addresses[1], { timeout_ns = Clock.seconds(5) }))
      assert(client:write("hello\n"))
      local answer = assert(Stream.lines(client):read())
      print(answer)
      assert(answer == "hello", answer)
      server:stop()
    end,
  })
end

return Example
