--- Worked examples for `cosmic.net`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Stream = require("cosmic.stream")

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

return Example
