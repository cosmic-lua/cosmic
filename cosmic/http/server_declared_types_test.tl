--- The declarations of cosmic.http.server tell the truth about nil: a
--- handler is a Reply only by its declaration, and the server checks what
--- one answered, nothing included. A checked run
--- (`cosmic test --check-types`) says whether a value crossed a typed
--- boundary of the server as a kind its type does not admit; in any
--- other run the test skips.
--- Until a compile writes the boundary checks (build/type_watch.tl), they skip in a checked run too.

local Net = require("cosmic.net")
local Server = require("cosmic.http.server")
local Test = require("cosmic.test")
local TypeWatch = require("build.type_watch")

Test.policy{ loopback = { "127.0.0.1" } }

local function test_a_handler_that_answers_nothing_is_a_500_the_server_declares()
  local answered: string = ""
  local found = TypeWatch.during(function()
    Server.serve({
      listeners = { Net.tcp("127.0.0.1", 0) },
      handle = function(_req: Server.Request): Server.Reply
        -- The handler's lie, which the server must survive: its own
        -- declarations are what is watched, not this return.
        local nothing: any = nil
        return nothing as Server.Reply
      end,
      on_error = function(_trouble: string) end,
      on_ready = function(addresses: {Net.Address}, server: Net.Server)
        local listening = assert(addresses[1], "the server listens")
        local conn = assert(Net.connect(listening))
        assert(conn:write("GET / HTTP/1.1\r\nHost: test\r\n\r\n"))
        local piece = assert(conn:read())
        answered = piece
        assert(conn:close())
        server:stop()
      end,
    })
  end, "cosmic/http/server.tl")
  assert(answered:find("500", 1, true) ~= nil, answered)
  assert(#found == 0, tostring(#found) .. " violations:\n" .. table.concat(found, "\n"))
end
