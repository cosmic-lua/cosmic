--- `cosmic mcp` asking a server it starts: a script of [`cosmic.mcp.server`] run by this program, named by its
--- `.tl` file.

local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local tool_fixture = require("build.tool_fixture")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local SERVER <const> = [[
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")
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
return function(argv: {string}): integer
  return server:main(argv)
end
]]

local function test_it_asks_a_server_it_starts(tmp: string)
  assert(Fs.write(tmp .. "/server.tl", SERVER))
  local ran = tool_fixture.cosmic(tmp, { "mcp", "call", "twice", '{"n":21}', "--", "server.tl" })
  assert(ran.code == 0 and ran.out == '{"content":[{"text":"42","type":"text"}]}\n', ran.out .. ran.err)
  local listed = tool_fixture.cosmic(tmp, { "mcp", "tools", "--", "server.tl" })
  assert(listed.code == 0 and listed.out:find('"name":"twice"', 1, true) ~= nil, listed.out .. listed.err)
  local failed = tool_fixture.cosmic(tmp, { "mcp", "call", "twice", '{"n":"x"}', "--", "server.tl" })
  assert(failed.code == 1 and failed.out:find('"isError":true', 1, true) ~= nil, "a tool that fails exits 1")
end
