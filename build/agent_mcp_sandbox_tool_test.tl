--- An MCP server of cosmic agent under its default sandbox ([`cosmic.agent.mcp`]): it reads what its policy grants
--- and nothing else of the host's.
local AgentMcp = require("cosmic.agent.mcp")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Test = require("cosmic.test")
local _ = require("build.standalone")
--- What the server script requires, as its standalone run loads it.
local type _ = require("cosmic.mcp.server")

--- This program, which the server runs as.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" }, { calls = "nest" } }, env = { "PATH", "TMPDIR" },
  requires = { "nest" } }

--- The text of the first block of `result`, a tool's result as JSON.
local function text_of(result: {string: Json.Value}): string
  local content = assert(Json.to_array(result["content"]))
  return tostring(assert(Json.to_object(content[1]))["text"])
end

local function test_a_server_is_held_to_its_policy()
  local dir, outside = assert(Fs.mkdtemp("agent-mcp-")), assert(Fs.mkdtemp("agent-mcp-outside-"))
  assert(Fs.write(outside .. "/secret", "no"))
  assert(Fs.write(dir .. "/granted", "yes"))
  local script = dir .. "/server.tl"
  assert(Fs.write(script, [=[
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Server = require("cosmic.mcp.server")
return function(_: {string}): integer
  local server = Server.new{
    info = { name = "peek", version = "1" },
    tools = { {
      tool = { name = "peek", inputSchema = Mcp.object_schema({ path = { type = "string" } }, { "path" }) },
      call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local body, _ = Fs.read(tostring(args["path"]))
        return Mcp.result({ body or "refused" })
      end,
    } },
  }
  assert(server:serve_stdio())
  return 0
end
]=]))
  local self = assert(Proc.executable())
  local config = assert(Json.encode({ servers = { peek = { command = Json.array({ self, "--standalone", script }),
    policy = { grants = Json.array({ { path = dir, letters = "r" } }) } } } }))
  assert(Fs.write(dir .. "/mcp.json", config))
  local set = AgentMcp.new(assert(AgentMcp.load(dir .. "/mcp.json")), dir)
  local granted = assert(AgentMcp.call(set, "peek", "peek", { path = dir .. "/granted" }))
  assert(text_of(granted) == "yes", text_of(granted))
  local secret = assert(AgentMcp.call(set, "peek", "peek", { path = outside .. "/secret" }))
  assert(text_of(secret) == "refused", text_of(secret))
  AgentMcp.close(set)
end

local function test_a_server_that_crashes_tells_its_stderr_with_its_keys_put_as_names()
  local dir = assert(Fs.mkdtemp("agent-mcp-crash-"))
  local script = dir .. "/server.tl"
  assert(Fs.write(script, [=[
local Env = require("cosmic.env")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Proc = require("cosmic.proc")
local Server = require("cosmic.mcp.server")
return function(_: {string}): integer
  local server = Server.new{
    info = { name = "crash", version = "1" },
    tools = { {
      tool = { name = "crash", inputSchema = Mcp.object_schema({}) },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        local _, _ = Fs.put(Fs.stderr, "\27[31mcrashed with key " .. tostring(Env.get("PATH")) .. "\n")
        Proc.exit(3)
      end,
    } },
  }
  assert(server:serve_stdio())
  return 0
end
]=]))
  local self = assert(Proc.executable())
  local config = assert(Json.encode({ servers = { crash = { command = Json.array({ self, "--standalone", script }),
    policy = { grants = Json.array({ { path = dir, letters = "r" }, { env = "PATH" } }) } } } }))
  assert(Fs.write(dir .. "/mcp.json", config))
  local set = AgentMcp.new(assert(AgentMcp.load(dir .. "/mcp.json")), dir)
  local _, why = AgentMcp.call(set, "crash", "crash", {})
  local said = tostring(why)
  assert(said:find("the end of its standard error: [31mcrashed with key [PATH]\n", 1, true) ~= nil, said)
  assert(said:find("\27", 1, true) == nil, "a control byte is taken out")
  AgentMcp.close(set)
end
