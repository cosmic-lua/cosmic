local _net = require("cosmic.net")
local sys = require("cosmic.sys")
local unix_socket = require("build.unix_socket")
local testing = require("cosmic.internal.testing")
local Test = require("cosmic.test")
local type raw_socket = require("cosmic.internal.socket")

Test.policy{ requires = { "checked" }, loopback = { "127.0.0.1" } }

local type Searcher = function(string): any, any

local function socket_table(): raw_socket
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.net")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_socket -- cast: the table core/socket.h declares
    end
  end
  error("cosmic.net is handed no raw table")
end

local raw = socket_table()

local function pair(path: string): raw_socket.Socket, raw_socket.Socket
  local address: raw_socket.Address = { kind = "unix", path = path }
  local listener <close> = assert(raw.listen(address, 1))
  local sender = assert(raw.connect(address, 5000))
  return sender, (assert(raw.accept(listener:fd())))
end

--- A channel received from another program may lack the socket option
--- core-created sockets carry. Clearing it before SCM_RIGHTS transfer
--- makes this fail by SIGPIPE if sendfds forgets its own protection.
local function test_sendfds_protects_a_received_channel_without_so_nosigpipe(tmp: string)
  if assert(sys.uname()).sysname ~= "Darwin" then
    local ok, why, errno = testing.socket_sigpipe(-1, false)
    assert(ok == false and why ~= "" and errno == sys.ENOSYS)
    Test.skip("SO_NOSIGPIPE is macOS's send protection; Linux uses MSG_NOSIGNAL")
  end
  local external, peer = pair(tmp .. "/external.sock")
  local _external_owner <close> = external
  local _peer_owner <close> = peer
  assert(testing.socket_sigpipe(external:fd(), false))
  local sending, taking = pair(tmp .. "/transfer.sock")
  local sender <close> = sending
  local receiver <close> = taking
  assert(raw.sendfds(sender:fd(), { external:fd() }))
  local batch = assert(raw.recvfds(receiver:fd(), 1))
  local received <close> = batch[1]
  assert(peer:close())
  local ok, why, errno = raw.sendfds(received:fd(), { sender:fd() })
  assert(ok == false and why ~= "" and errno == sys.EPIPE)
end

--- All kernel-installed rights must close even when the sender bypasses
--- the public batch cap. On Darwin a short ancillary buffer hides most
--- of these descriptors; on Linux this exercises kernel truncation.
local function test_oversized_native_rights_batch_is_closed(tmp: string)
  if assert(sys.uname()).sysname ~= "Darwin" and unix_socket.skipped(tmp) then return end
  local sending, taking = pair(tmp .. "/oversized.sock")
  local sender <close> = sending
  local receiver <close> = taking
  local before = testing.open_descriptors()
  local ok, why, errno = testing.socket_send_rights(sender:fd(), sender:fd(), 253)
  assert(ok, tostring(why) .. " " .. tostring(errno))
  assert(raw.wait(receiver:fd(), false, 5000))
  local batch, refusal, code = raw.recvfds(receiver:fd(), 1)
  assert(batch == nil and refusal ~= "" and code == raw.EPROTO)
  assert(testing.open_descriptors() == before, "oversized rights left descriptors installed")
end
