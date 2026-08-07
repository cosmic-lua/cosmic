--- Examples for cosmic.net module.

-- Example_echo demonstrates a minimal TCP echo exchange on loopback:
-- listen on an OS-assigned port, connect, accept, echo one message back
local function Example_echo()
  local net = require("cosmic.net")
  local check = require("cosmic.check")
  local srv = check.must(net.listen_tcp("127.0.0.1", 0))
  local port = check.must(srv:getsockname()).port
  assert(port > 0)

  local client = check.must(net.connect_tcp("127.0.0.1", port))

  -- accept's error is in slot 2 now, so must() forwards it directly.
  local conn = check.must(srv:accept())

  assert(client:send("hello"))
  local msg = check.must(conn:recv())
  assert(conn:send("echo: " .. msg))
  print(check.must(client:recv()))

  assert(client:close())
  assert(conn:close())
  assert(srv:close())
  -- Output:
  -- echo: hello
end

-- Example_recv_eof demonstrates end-of-stream detection: recv returns
-- bare nil (no error) when the peer closes the connection, matching the
-- stream contract (cosmic.stream)
local function Example_recv_eof()
  local net = require("cosmic.net")
  local check = require("cosmic.check")
  local srv = check.must(net.listen_tcp("127.0.0.1", 0))
  local port = check.must(srv:getsockname()).port

  local client = check.must(net.connect_tcp("127.0.0.1", port))
  local conn = check.must(srv:accept())

  assert(client:close())
  local data, recv_err = conn:recv()
  assert(recv_err == nil)
  print(data == nil and "eof" or "data")

  assert(conn:close())
  assert(srv:close())
  -- Output:
  -- eof
end

-- Suppress unused warnings for examples
local _ = {Example_echo, Example_recv_eof}
