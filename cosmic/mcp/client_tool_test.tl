--- [`Client.spawn`] with a server that is a process of this program,
--- run `--standalone` ([`build.standalone`]) on a script that serves
--- stdio.

local Client = require("cosmic.mcp.client")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local this_program = require("build.this_program")
--- What the server script requires, as the standalone run loads it.
local type _ = require("cosmic.mcp.server")

Test.policy{ profiles = { "cosmic" } }

local function test_a_spawned_server_is_asked_and_ended(tmp: string)
  local script = tmp .. "/server.tl"
  assert(Fs.write(script, [[
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")
return function(_: {string}): integer
  local server = Server.new{
    info = { name = "spawned", version = "1" },
    tools = { {
      tool = { name = "twice", inputSchema = Mcp.object_schema({ n = { type = "integer" } }, { "n" }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local n = math.tointeger(args["n"])
        if n == nil then return nil, Failure.new("n must be an integer") end
        return Mcp.result({ tostring(n * 2) })
      end,
    } },
  }
  assert(server:serve_stdio())
  return 0
end
]]))
  local started = this_program.program({ "--standalone", script }, { stderr = "capture", timeout_ns = Clock.seconds(60) })
  local session = assert(Client.spawn(started.argv, started.options))
  local d = assert(session:discover())
  assert(d.serverInfo ~= nil and d.serverInfo.name == "spawned")
  local said = assert(session:call("twice", { n = 21 }))
  assert(assert(said.content[1]).text == "42")
  assert(session:close())
end
