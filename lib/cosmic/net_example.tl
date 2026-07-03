--- Examples for cosmic.net module.

-- Example_echo demonstrates a minimal TCP echo exchange on loopback:
-- listen on an OS-assigned port, connect, accept, echo one message back
local function Example_echo()
  local net = require("cosmic.net")
  local srv, port, err = net.listen_tcp(0x7f000001, 0)
  assert(srv, err)
  assert(port > 0)

  local client, cerr = net.connect_tcp(0x7f000001, port)
  assert(client, cerr)

  local conn, _, _, aerr = srv:accept()
  assert(conn, aerr)

  client:send("hello")
  local msg = conn:recv()
  conn:send("echo: " .. msg)
  print(client:recv())

  client:close()
  conn:close()
  srv:close()
  -- Output:
  -- echo: hello
end

-- Example_recv_eof demonstrates end-of-stream detection: recv returns an
-- empty string (not nil) when the peer closes the connection
local function Example_recv_eof()
  local net = require("cosmic.net")
  local srv, port, err = net.listen_tcp(0x7f000001, 0)
  assert(srv, err)

  local client = net.connect_tcp(0x7f000001, port)
  local conn = srv:accept()

  client:close()
  local data = conn:recv()
  print(data == "" and "eof" or "data")

  conn:close()
  srv:close()
  -- Output:
  -- eof
end

return {}
