--- [`Client.spawn`] with a server that is a process of this program,
--- run `--standalone` ([`build.standalone`]) on a script that serves
--- stdio.

local Child = require("cosmic.child")
local Client = require("cosmic.mcp.client")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")
local _ = require("build.standalone")
local this_program = require("build.this_program")
--- What the server script requires, as the standalone run loads it.
local type _ = require("cosmic.mcp.server")

--- The next line of `lines`: raises where they ended or failed.
local function line_of(lines: Stream.Lines): string
  local line, why = lines:read()
  if line == nil then error(tostring(why), 2) end
  if line == false then error("the lines ended", 2) end
  return line
end

Test.policy{ profiles = { "cosmic" }, loopback = { "127.0.0.1" } }

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

--- [`McpServer.Instance.main`] with `--http`: the server says its URL on stderr, and a client with the token asks it.
local function test_a_main_serves_http_with_a_token_from_the_environment(tmp: string)
  local script = tmp .. "/server.tl"
  assert(Fs.write(script, [[
local Server = require("cosmic.mcp.server")

local server = Server.new{ info = { name = "web", version = "1" } }
return function(argv: {string}): integer
  return server:main(argv)
end
]]))
  local token = "0123456789abcdef-token"
  local env: mut {string: string} = {}
  for k, v in pairs(this_program.environment()) do env[k] = v end
  env["MCP_TOKEN"] = token
  local started = this_program.program({ "--standalone", script, "--http", "127.0.0.1:0", "--token-env", "MCP_TOKEN" },
    { env = env, stderr = "stream", timeout_ns = Clock.seconds(60) })
  local handle <close> = assert(Child.start(started.argv, started.options))
  local lines = Stream.lines(assert(handle.stderr_stream))
  local said = line_of(lines)
  local url = assert(said:match("^mcp: serving (http://127%.0%.0%.1:%d+/mcp)$"), said)
  local session = Client.http(url, { timeout_ns = Clock.seconds(20), headers = { Authorization = "Bearer " .. token } })
  local d = assert(session:discover())
  assert(d.serverInfo ~= nil and d.serverInfo.name == "web")
  local stranger = Client.http(url, { timeout_ns = Clock.seconds(20) })
  local none, why = stranger:discover()
  assert(none == nil and tostring(why):find("401", 1, true) ~= nil, tostring(why))
  assert(handle:stop())
end
