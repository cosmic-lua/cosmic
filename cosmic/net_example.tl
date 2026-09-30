--- Worked examples for [`cosmic.net`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

--- The TCP example listens on the worker's own loopback.
Test.needs{ network = { "127.0.0.1" } }

local Example = {}

--- A server on a socket file: it makes the file, and `close` (here, the
--- `<close>` variable going out of scope) removes it. Every wait is
--- bounded by `timeout_ms`, which a connection accepted inherits.
function Example.listen()
  local dir = assert(Fs.mkdtemp("cosmic-net-example-"))
  do
    local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock"), { timeout_ms = 5000 }))
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
  local dir = assert(Fs.mkdtemp("cosmic-net-example-"))
  local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock"), { timeout_ms = 5000 }))
  local client <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
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
  assert(Fs.remove_tree(dir))
end

--- A TCP server on the loopback at a port the kernel chose, which the
--- listener's `address` names for a client to connect to.
function Example.tcp()
  local server <close> = assert(Net.listen(Net.tcp("127.0.0.1", 0), { timeout_ms = 5000 }))
  print(server.address.port > 0)
  local client <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
  local conn <close> = assert(server:accept())
  assert(client:write("hello"))
  assert(assert(conn:read()) == "hello")
end

--- A server that serves each connection in a task of its own, in a
--- task of [`Poll.run`]: while one connection waits to be read, the
--- others are served.
function Example.accept()
  local dir = assert(Fs.mkdtemp("cosmic-net-example-"))
  local server <close> = assert(Net.listen(Net.unix(dir .. "/app.sock"), { timeout_ms = 5000 }))
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
    local quiet <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
    local client <close> = assert(Net.connect(server.address, { timeout_ms = 5000 }))
    assert(client:write("world\n"))
    local greeting = assert(Stream.lines(client):read())
    print(greeting)
    assert(greeting == "hello, world")
    assert(quiet:write("quiet\n"))
    assert(Stream.lines(quiet):read() == "hello, quiet")
  end)
  assert(Fs.remove_tree(dir))
end

--- Two connections to each other, for a task at each end of [`Poll.run`]:
--- the pair is closed, both ends, with its `<close>` variable.
function Example.pair()
  local ends <close> = assert(Net.pair())
  Poll.run(function()
    Poll.spawn(function()
      local request = assert(Stream.lines(ends.second):read())
      assert(ends.second:write(request:upper() .. "\n"))
    end)
    assert(ends.first:write("hello\n"))
    local answer = assert(Stream.lines(ends.first):read())
    print(answer)
    assert(answer == "HELLO", answer)
  end)
end

return Example
