--- Examples for cosmic.net module.

-- Example_echo demonstrates a minimal TCP echo exchange on loopback:
-- listen on an OS-assigned port, connect, accept, echo one message back
local function Example_echo()
  local net = require("cosmic.net")
  local srv, port, err = net.listen_tcp(0x7f000001, 0)
  assert(srv, err)
  assert(port > 0)
  local srv = srv as net.Socket

  local client, cerr = net.connect_tcp(0x7f000001, port)
  assert(client, cerr)
  local client = client as net.Socket

  local conn, _, _, aerr = srv:accept()
  assert(conn, aerr)
  local conn = conn as net.Socket

  client:send("hello")
  local msg = conn:recv()
  conn:send("echo: " .. (msg as string))
  print(client:recv())

  client:close()
  conn:close()
  srv:close()
  -- Output:
  -- echo: hello
end

-- Example_recv_eof demonstrates end-of-stream detection: recv returns
-- bare nil (no error) when the peer closes the connection, matching the
-- stream contract (cosmic.stream)
local function Example_recv_eof()
  local net = require("cosmic.net")
  local srv, port, err = net.listen_tcp(0x7f000001, 0)
  assert(srv, err)
  local srv = srv as net.Socket

  local client = net.connect_tcp(0x7f000001, port) as net.Socket
  local conn = srv:accept() as net.Socket

  client:close()
  local data, recv_err = conn:recv()
  assert(recv_err == nil)
  print(data == nil and "eof" or "data")

  conn:close()
  srv:close()
  -- Output:
  -- eof
end

return {}
