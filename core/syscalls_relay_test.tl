--- `spawn`'s `relay` and `host_network` on a live child (core/process.h's
--- `Sandbox`): the listeners a child binds in the network namespace it makes
--- for itself and hands out over a channel, and the one raw flag that lets a
--- policy child keep the host's network. The child is a stand-in
--- (build/stand_in.tl). Where the platform has no sandbox they are not
--- applicable, and where this host gives no user namespace or seccomp a test
--- skips itself. The arguments' own checks, which raise before a child, are
--- core/syscalls_test.tl's.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Net = require("cosmic.net")
local Poll = require("cosmic.poll")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local stand_in = require("build.stand_in")
local type raw_process = require("cosmic.internal.process")
local type raw_socket = require("cosmic.internal.socket")
-- Required, so the modules whose loaders are handed the raw tables are of
-- this test's import closure, and the store has them to hand them from.
local type _ = require("cosmic.child")

--- `nests`, since the children these tests start make namespaces of their
--- own, which a worker held by a Landlock ruleset cannot start; and a
--- `network`, whose loopback the worker's filter lets it make inet sockets
--- on, the children it starts inheriting that filter.
Test.policy{
  promises = { "nest" },
  loopback = { "127.0.0.1" },
  requires = { "nest" },
}

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares
local socket = raw_behind("cosmic.net") as raw_socket -- cast: the table core/socket.h declares

--- Whether `why`, a start's failure, is this host giving no sandbox of the
--- kind: a namespace, or the filter, refused.
local function unsandboxable(why: string): boolean
  for _, word in ipairs({ "namespace", "seccomp", "not implemented", "Operation not permitted",
      "root could not be built" }) do
    if why:find(word, 1, true) then return true end
  end
  return false
end

--- Starts `probe` running `script` under `sandbox`, its output in a file of
--- `tmp`'s: the pid, or nil and why and the errno. Closes the file.
local function start(tmp: string, probe: string, script: string, sandbox: raw_process.Sandbox): integer | nil, string, integer
  local output = assert(sys.open(tmp .. "/said", sys.O_CREAT | sys.O_RDWR | sys.O_TRUNC, 420))
  local pid, why, errno = process.spawn(probe, { probe, script }, nil, "/", nil, output, output,
    false, nil, sandbox)
  sys.close(output)
  return pid, why, errno
end

--- What the program said, once it ended, and how.
local function finished(tmp: string, pid: integer): string, integer
  local status = assert(process.waitpid(pid, false))
  return (Fs.read(tmp .. "/said")) or "", status.code
end

--- A stream socketpair, which the relay's channel is one end of.
local function channel(): {integer}
  return (assert(process.connector_pair()))
end

--- A start that gave the relay its listeners: the program connects to both
--- ports and says so, and this accepts both connections on the listeners
--- the channel carried, adopted as the listeners they are.
local function relays(tmp: string, probe: string, sandbox: raw_process.Sandbox, ports: {integer})
  local pair = channel()
  sandbox.relay = { fd = pair[1], ports = ports }
  local script = "connect-tcp 127.0.0.1 " .. ports[1] .. "; connect-tcp 127.0.0.1 " .. ports[2]
  local pid, why = start(tmp, probe, script, sandbox)
  if pid == nil then
    sys.close(pair[1])
    sys.close(pair[2])
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip("this host gives no such sandbox: " .. why)
  end
  -- The start waited for the child's exec, so both descriptors are sent.
  local received = assert(socket.recvfds(pair[2], 2))
  local said, code = finished(tmp, pid)
  assert(said == "connected\nconnected\n" and code == 0,
    "the program reaches both ports in its network: " .. said)
  Poll.run(function()
    for index = 1, 2 do
      local listener = assert(Net.listener_from(received[index]:fd(),
        { timeout_ns = Clock.seconds(5) }))
      assert(listener.address.host == "127.0.0.1" and listener.address.port == ports[index],
        "listener " .. index .. " is at its port")
      -- The program has ended: what it connected waits to be accepted.
      local conn = assert(listener:accept(Clock.seconds(5)))
      assert(conn:close())
      assert(listener:close())
    end
  end)
  for index = 1, 2 do assert(received[index]:close()) end
  -- The child's copy of the channel is closed: the other end reads its end.
  assert(sys.close(pair[1]))
  local more, _ = socket.recvfds(pair[2], 1)
  assert(more == nil, "the channel holds nothing more")
  assert(sys.close(pair[2]))
end

local function test_a_child_in_its_own_network_hands_out_listeners_at_the_ports_given(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  relays(tmp, probe, { offline = true, promises = {}, sockets = { "inet" } }, { 3128, 1080 })
end

local function test_the_relay_ports_default_to_http_connect_and_socks(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local pair = channel()
  local pid, why = start(tmp, probe, "sleep 1", { offline = true, promises = {},
    relay = { fd = pair[1] } })
  if pid == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip("this host gives no such sandbox: " .. why)
  end
  local received = assert(socket.recvfds(pair[2], 2))
  local first = assert(socket.bound(received[1]:fd()))
  local second = assert(socket.bound(received[2]:fd()))
  assert(first.port == 3128 and second.port == 1080,
    "the defaults are " .. first.port .. " and " .. second.port)
  for index = 1, 2 do assert(received[index]:close()) end
  finished(tmp, pid)
  assert(sys.close(pair[1]) and sys.close(pair[2]))
end

local function test_an_unveiled_child_hands_out_listeners_too(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  relays(tmp, probe, { strict = true, offline = true, promises = {}, sockets = { "inet" },
    unveil = { reads = { probe, "/proc", "/dev/null" } } }, { 3129, 1081 })
end

--- A start that must fail before exec, naming the relay's listeners: the
--- program never ran, whether or not the start is strict.
local function relay_refused(tmp: string, probe: string, sandbox: raw_process.Sandbox, cause: string)
  local marker = tmp .. "/ran"
  local pid, why, number = start(tmp, probe, "append " .. marker .. " ran", sandbox)
  if pid ~= nil then
    finished(tmp, pid)
    error("a relay that cannot be made started the program")
  end
  if not why:find("relay's listeners", 1, true) then
    assert(unsandboxable(why), "failed otherwise: " .. why)
    Test.skip("this host gives no such sandbox: " .. why)
  end
  assert(why:find(cause, 1, true), "the message names the failed call's errno: " .. why)
  assert(math.type(number) == "integer" and number > 0, "the errno is answered")
  assert(not Fs.exists(marker), "the program ran")
end

local function test_a_port_taken_fails_the_start_naming_the_relay_before_exec(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- The two listeners are bound in one network: a port twice is in use.
  local pair = channel()
  relay_refused(tmp, probe, { offline = true, promises = {},
    relay = { fd = pair[1], ports = { 4000, 4000 } } }, "Address in use")
  assert(sys.close(pair[1]) and sys.close(pair[2]))
  local strict = channel()
  relay_refused(tmp, probe, { strict = true, offline = true, promises = {},
    unveil = { reads = { probe, "/proc", "/dev/null" } },
    relay = { fd = strict[1], ports = { 4000, 4000 } } }, "Address in use")
  assert(sys.close(strict[1]) and sys.close(strict[2]))
end

local function test_a_channel_that_is_no_socket_fails_the_start_naming_the_relay(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local file = assert(sys.open(tmp .. "/not-a-socket", sys.O_CREAT | sys.O_RDWR, 420))
  relay_refused(tmp, probe, { offline = true, promises = {}, relay = { fd = file } }, "Not a socket")
  assert(sys.close(file))
end

local function test_a_channel_not_open_is_refused_before_a_child(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- A number no descriptor of this worker is: it holds a few dozen.
  local pid, _, errno = start(tmp, probe, "sleep 1", { offline = true, promises = {},
    relay = { fd = 999 } })
  assert(pid == nil and errno == sys.EBADF, "a descriptor not open is EBADF")
end

--- A script that makes an inet socket in its own network: it listens on
--- loopback, connects to itself and accepts, and says `connected`.
local script = "loopback-tcp 127.0.0.1"

local function test_host_network_lets_a_policy_child_make_an_inet_socket(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  local pid, why = start(tmp, probe, script,
    { promises = {}, sockets = { "inet" }, host_network = true })
  if pid == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    Test.skip("this host gives no such sandbox: " .. why)
  end
  local said, code = finished(tmp, pid)
  assert(said == "connected\n" and code == 0, "it makes an inet socket: " .. said)
  -- The promises alone name no family: the filter refuses it.
  local held, held_why = start(tmp, probe, script, { promises = {} })
  assert(held ~= nil, tostring(held_why))
  local refused = finished(tmp, held)
  assert(refused:find("not permitted", 1, true), "refused without it: " .. refused)
end
