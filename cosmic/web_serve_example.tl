--- Worked examples of serving a [`cosmic.web`] app, run on the worker's own
--- loopback; `web_example.tl` has the rest.

local Net = require("cosmic.net")
local Test = require("cosmic.test")
local Web = require("cosmic.web")

Test.policy{ loopback = { "127.0.0.1" } }

local Example = {}

--- [`Web.serve`] runs an app over the HTTP server until it is stopped: it
--- runs the app's `lifespan` first and its cleanup after the last request,
--- and gives in-flight requests ten seconds to finish. A real program
--- listens at `Net.tcp("127.0.0.1", 8080)`; here the kernel picks the port
--- and `on_ready` stops the server.
function Example.serve()
  local app = Web.app{
    routes = { Web.get("/", function(_req: Web.Request): Web.Response return Web.text("hello\n") end) },
    lifespan = function(_app: Web.App): Web.Shutdown?, string
      print("lifespan: open")
      return function() print("lifespan: closed") end, ""
    end,
  }
  assert(Web.serve(app, {
    listeners = { Net.tcp("127.0.0.1", 0) },
    on_ready = function(_addresses: {Net.Address}, server: Net.Server)
      print("listening")
      server:stop()
    end,
    on_stop = function(_server: Net.Server) print("stopping", app:stopping()) end,
  }))
end

--- [`Web.with_server`] serves an app on the loopback and hands a client of
--- one kept-alive connection to a function, for what in-process calls
--- cannot show: here, that a HEAD has the GET's length and no body.
function Example.with_server()
  local app = Web.app{ routes = { Web.get("/", function(_req: Web.Request): Web.Response
    return Web.text("hello\n")
  end) } }
  Web.with_server(app, function(client: Web.LoopbackClient)
    local head = assert(client:head("/"))
    local get = assert(client:get("/"))
    print(head.headers["content-length"], #head.body, get.body) -- 6  0  hello
    assert(head.headers["content-length"] == "6" and head.body == "" and get.body == "hello\n")
  end)
end

return Example
