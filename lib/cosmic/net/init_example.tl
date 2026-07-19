--- Examples for cosmic.net module.

-- Example_echo demonstrates a minimal TCP echo exchange on loopback:
-- listen on an OS-assigned port, connect, accept, echo one message back
local function Example_echo()
  local net = require("cosmic.net")
  local check = require("cosmic.check")
  local raw_srv, port, err = net.listen_tcp("127.0.0.1", 0)
  local srv = check.must(raw_srv, err)
  assert(port > 0)

  local client = check.must(net.connect_tcp("127.0.0.1", port))

  local raw_conn, _, _, aerr = srv:accept()
  local conn = check.must(raw_conn, aerr)

  client:send("hello")
  local msg = check.must(conn:recv())
  conn:send("echo: " .. msg)
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
  local check = require("cosmic.check")
  local raw_srv, port, err = net.listen_tcp("127.0.0.1", 0)
  local srv = check.must(raw_srv, err)

  local client = check.must(net.connect_tcp("127.0.0.1", port))
  local conn = check.must((srv:accept()))

  client:close()
  local data, recv_err = conn:recv()
  assert(recv_err == nil)
  print(data == nil and "eof" or "data")

  conn:close()
  srv:close()
  -- Output:
  -- eof
end

-- Suppress unused warnings for examples
local _ = {Example_echo, Example_recv_eof}
