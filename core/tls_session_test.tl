--- core/tls.c's sessions over a pair of connected sockets, driven by
--- hand: what a read answers when the peer's socket ends, or after
--- empty records.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local type raw_socket = require("cosmic.internal.socket")
local raw = require("cosmic.internal.socket")
local tls = require("cosmic.internal.tls")

Test.policy{ loopback = { "127.0.0.1" }, grants = { { path = "testdata/tls", letters = "r" } } }

--- The fixture `name` of testdata/tls.
local function fixture(name: string): string
  return (assert(Fs.read("testdata/tls/" .. name)))
end

--- A connection over the loopback and the one its listener accepted.
local function connected(): raw_socket.Socket, raw_socket.Socket
  local listener <close> = assert(raw.listen({ kind = "tcp", host = "127.0.0.1", port = 0 }, 1))
  local bound = assert(raw.bound(listener:fd()))
  local client = assert(raw.connect({ kind = "tcp", host = "127.0.0.1", port = bound.port }, 5000))
  assert(raw.wait(listener:fd(), false, 5000))
  return client, (assert(raw.accept(listener:fd())))
end

--- Handshakes `client` and `server`, over `client_fd` and `server_fd`,
--- in turn until both are done.
local function handshaken(client: tls.Session, client_fd: integer, server: tls.Session, server_fd: integer)
  local client_done, server_done = false, false
  for _ = 1, 1000 do
    if not client_done then
      local done, why, stop = client:handshake()
      assert(done or stop == tls.READ or stop == tls.WRITE, "client: " .. tostring(why))
      client_done = done
    end
    if not server_done then
      local done, why, stop = server:handshake()
      assert(done or stop == tls.READ or stop == tls.WRITE, "server: " .. tostring(why))
      server_done = done
    end
    if client_done and server_done then return end
    -- Either may be the one waiting on the other: a short wait on each,
    -- its timeout no failure.
    if not server_done then local _, _ = raw.wait(server_fd, false, 10) end
    if not client_done then local _, _ = raw.wait(client_fd, false, 10) end
  end
  error("the handshake did not finish")
end

--- A peer whose socket ends with no close_notify has not ended the
--- session: what it sent may be cut short there, by anyone who can cut
--- the socket. A read fails, and says why, and is not taken for an end.
local function test_a_read_after_the_peer_socket_ends_fails_and_says_why()
  local server_config = assert(tls.config({ { cert = fixture("a.pem"), key = fixture("a.key") } }))
  local client_config = assert(tls.client(false))
  local client_socket <close>, server_socket = connected()
  local client = assert(tls.session(client_config, client_socket:fd()))
  local server = assert(tls.session(server_config, server_socket:fd()))
  handshaken(client, client_socket:fd(), server, server_socket:fd())
  -- The server's socket ends: no alert, only the TCP end.
  server:free()
  assert(server_socket:close())
  for _ = 1, 100 do
    local data, why, stop = client:read(100)
    assert(data == nil, "no data was sent")
    if stop ~= tls.READ then
      assert(stop == tls.FAILED and why == "tls: the peer's socket ended with no close_notify",
        "stop " .. tostring(stop) .. ": " .. why)
      client:free()
      return
    end
    assert(raw.wait(client_socket:fd(), false, 5000))
  end
  error("the read never ended")
end

--- Writes all of `data` to `session` over `fd`, waiting where it must.
local function written(session: tls.Session, fd: integer, data: string)
  for _ = 1, 1000 do
    local took, why, stop = session:write(data, 1)
    if took ~= nil then
      assert(took == #data, "took " .. tostring(took) .. " of " .. tostring(#data))
      return
    end
    assert(stop == tls.WRITE or stop == tls.READ, why)
    assert(raw.wait(fd, stop == tls.WRITE, 5000))
  end
  error("the write never finished")
end

--- Two empty application records in a row are no end: mbedtls answers a
--- read of them 0, as it does a socket that ended, and the session reads
--- on to the data after them (#4459 fixed a session that took them for
--- an end, live).
local function test_two_empty_records_and_then_data_read_as_the_data()
  local server_config = assert(tls.config({ { cert = fixture("a.pem"), key = fixture("a.key") } }))
  local client_config = assert(tls.client(false))
  local client_socket <close>, accepted = connected()
  local server_socket <close> = accepted
  local client = assert(tls.session(client_config, client_socket:fd()))
  local server = assert(tls.session(server_config, server_socket:fd()))
  handshaken(client, client_socket:fd(), server, server_socket:fd())
  written(server, server_socket:fd(), "")
  written(server, server_socket:fd(), "")
  written(server, server_socket:fd(), "after")
  for _ = 1, 100 do
    local data, why, stop = client:read(100)
    if data ~= nil then
      assert(data == "after", data)
      client:free()
      server:free()
      return
    end
    assert(stop == tls.READ, "stop " .. tostring(stop) .. ": " .. why)
    assert(raw.wait(client_socket:fd(), false, 5000))
  end
  error("the read never ended")
end
