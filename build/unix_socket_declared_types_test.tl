--- The declaration of build.unix_socket's refusal tells the truth about
--- nil: a process that may make a unix socket has no reason to give. A
--- checked run (`cosmic test --check-types`) says whether a value crossed
--- a typed boundary under build/ as a kind its type does not admit; in
--- any other run the test skips. It declares a loopback address, as
--- build/test_own_scratch_test.tl does, so the socket is made.
--- Until a compile writes the boundary checks (build/type_watch.tl), they skip in a checked run too.

local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")
local unix_socket = require("build.unix_socket")

Test.policy{ loopback = { "127.0.0.1" } }

local function test_a_directory_that_holds_a_socket_has_no_refusal(tmp: string)
  local found = TypeWatch.during(function()
    assert(unix_socket.refusal(tmp) == nil, "the worker's own directory refuses a unix socket")
  end, "build/")
  assert(#found == 0, tostring(#found) .. " violations:\n" .. table.concat(found, "\n"))
end
