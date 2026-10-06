--- A worker whose module declares nothing that puts a directory of the host
--- in its root (build/test_sandbox.tl's `own_scratch`) makes a unix socket
--- under the policy path, below Landlock ABI 9 too: its root shows files and
--- its own /tmp alone, which holds one (core/syscalls.c's
--- `root_shows_no_socket`), and its network is a namespace of its own, which
--- a declared loopback address gives it. This module declares that and
--- nothing else, and does not skip where the socket is refused
--- (build/unix_socket.tl), so a worker that is given a directory of the host
--- fails it.

local Net = require("cosmic.net")
local Test = require("cosmic.test")

Test.policy{ loopback = { "127.0.0.1" }, requires = { "sandbox" } }

local function test_a_unix_socket_is_made_and_reached_in_the_workers_own_directory(tmp: string)
  local path = tmp .. "/own.sock"
  local listener = assert(Net.listen(Net.unix(path)))
  local client = assert(Net.connect(Net.unix(path)))
  local server = assert(listener:accept())
  assert(client:write("hi"))
  assert(server:read(2) == "hi")
  assert(client:close() and server:close() and listener:close())
end
