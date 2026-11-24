--- `cosmic mcp`'s command line, and its answers from a [`cosmic.mcp.server`] served on the worker's loopback.

local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local HttpServer = require("cosmic.http.server")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local McpServer = require("cosmic.mcp.server")
local Net = require("cosmic.net")
local Test = require("cosmic.test")
local verb = require("build.mcp")

Test.policy{ loopback = { "127.0.0.1" } }

local TOKEN <const> = "0123456789abcdef-token"

--- What one run wrote.
local record Ran
  code: integer
  out: string
  err: string
end

--- Runs `cosmic mcp` with `words`, `MCP_TOKEN` set to `token` where given.
local function run(words: {string}, token?: string): Ran
  local out, err: mut {string}, mut {string} = {}, {}
  local argv: mut {string} = { "mcp" }
  for _, w in ipairs(words) do argv[#argv + 1] = w end
  local code = verb.run(argv, {
    out = function(text: string): boolean, string
      out[#out + 1] = text
      return true, ""
    end,
    err = function(line: string) err[#err + 1] = line end,
    env = function(name: string): string?
      if name == "MCP_TOKEN" then return token end
      return nil
    end,
  })
  return { code = code, out = table.concat(out), err = table.concat(err, "\n") }
end

local function test_a_command_line_it_cannot_read_is_refused()
  local function refused(words: {string}, says: string)
    local ran = run(words)
    assert(ran.code == 2 and ran.out == "" and ran.err:find(says, 1, true) ~= nil, ran.err)
  end
  refused({}, "name an action")
  refused({ "list" }, "list is no action")
  refused({ "call", "--", "x" }, "call takes 1 or 2 words")
  refused({ "tools", "extra", "--", "x" }, "tools takes 0 words after it")
  refused({ "tools" }, "name the server")
  refused({ "tools", "--url", "http://127.0.0.1:1/mcp", "--", "x" }, "two servers")
  refused({ "tools", "--token-env", "MCP_TOKEN", "--", "x" }, "--token-env is for --url")
  refused({ "tools", "--timeout", "0", "--", "x" }, "--timeout takes seconds")
  refused({ "tools", "--timeout", "1e3", "--", "x" }, "--timeout takes seconds")
  refused({ "tools", "--url", "https://me:secret@example.com/mcp" }, "--url holds credentials")
  assert(not run({ "tools", "--url", "https://me:secret@example.com/mcp" }).err:find("secret", 1, true))
  assert(verb.program_slot({ "mcp", "tools", "--", "srv", "--", "x" }) == 4)
  assert(verb.program_slot({ "mcp", "tools", "--" }) == nil)
end

local function server(): McpServer.Instance
  return McpServer.new{
    info = { name = "web", version = "1" },
    instructions = "Add.",
    tools = { {
      tool = { name = "add", inputSchema = Mcp.object_schema({ a = { type = "integer" }, b = { type = "integer" } }) },
      call = function(args: {string: Json.Value}, _: McpServer.Call): (Mcp.ToolResult) | (nil, Failure)
        local a, b = math.tointeger(args["a"]), math.tointeger(args["b"])
        if a == nil or b == nil then return Mcp.result({ "a and b must be integers" }, true) end
        return Mcp.result({ tostring(a + b) })
      end,
    } },
    resources = { {
      resource = { uri = "note://one", name = "one" },
      read = function(_: McpServer.Call): ({Mcp.ResourceContents}) | (nil, Failure)
        return { { uri = "note://one", text = "the first" } }
      end,
    } },
    prompts = { {
      prompt = { name = "greet", arguments = { { name = "who", required = true } } },
      get = function(args: {string: string}, _: McpServer.Call): (Mcp.PromptResult) | (nil, Failure)
        return { messages = { { role = "user", content = Mcp.text("hello " .. (args["who"] or "?")) } } }
      end,
    } },
  }
end

local function test_it_prints_what_a_server_over_http_answers()
  assert(HttpServer.serve{
    listeners = { Net.tcp("127.0.0.1", 0) },
    handle = server():handler{ authorize = McpServer.bearer(TOKEN) },
    on_ready = function(addresses: {Net.Address}, running: Net.Server)
      local at = assert(addresses[1])
      local url = "http://127.0.0.1:" .. tostring(at.port) .. "/mcp"
      local function asked(words: {string}, token?: string): Ran
        local all: mut {string} = {}
        for _, w in ipairs(words) do all[#all + 1] = w end
        for _, w in ipairs({ "--url", url, "--token-env", "MCP_TOKEN", "--timeout", "20" }) do
          all[#all + 1] = w
        end
        return run(all, token or TOKEN)
      end
      local d = asked({ "discover" })
      assert(d.code == 0, d.err)
      local found = assert(Json.decode_object(d.out))
      assert(found["instructions"] == "Add." and d.out:sub(-1) == "\n", d.out)
      local tools = asked({ "tools" })
      assert(tools.code == 0 and tools.out:find('"name":"add"', 1, true) ~= nil, tools.out)
      local sum = asked({ "call", "add", '{"a":2,"b":5}' })
      assert(sum.code == 0 and sum.out == '{"content":[{"text":"7","type":"text"}]}\n', sum.out)
      local wrong = asked({ "call", "add", '{"a":2}' })
      assert(wrong.code == 1 and wrong.out:find('"isError":true', 1, true) ~= nil, "a tool's error exits 1")
      local not_object = asked({ "call", "add", "[1]" })
      assert(not_object.code == 1 and not_object.err:find("must be a JSON object", 1, true) ~= nil, not_object.err)
      local read = asked({ "read", "note://one" })
      assert(read.code == 0 and read.out:find('"text":"the first"', 1, true) ~= nil, read.out)
      local prompt = asked({ "prompt", "greet", '{"who":"you"}' })
      assert(prompt.code == 0 and prompt.out:find("hello you", 1, true) ~= nil, prompt.out)
      local bad_prompt = asked({ "prompt", "greet", '{"who":1}' })
      assert(bad_prompt.code == 1 and bad_prompt.err:find("must be a string", 1, true) ~= nil, bad_prompt.err)
      local lists = asked({ "resources" })
      assert(lists.code == 0 and lists.out:find("note://one", 1, true) ~= nil, lists.out)
      local unset = run({ "tools", "--url", url, "--token-env", "MCP_TOKEN" })
      assert(unset.code == 1 and unset.err:find("is not set", 1, true) ~= nil, unset.err)
      local wrong_token = run({ "tools", "--url", url, "--token-env", "MCP_TOKEN", "--timeout", "20" }, TOKEN .. "x")
      assert(wrong_token.code == 1 and not wrong_token.err:find(TOKEN, 1, true), "a refused token is not printed")
      local stranger = run({ "tools", "--url", url, "--timeout", "20" })
      assert(stranger.code == 1 and stranger.err:find("401", 1, true) ~= nil, stranger.err)
      running:stop()
    end,
  })
  local _ = Clock
end

local function test_a_token_goes_over_plain_http_only_to_a_loopback_host()
  local ran = run({ "tools", "--url", "http://192.0.2.1/mcp", "--token-env", "MCP_TOKEN" }, TOKEN)
  assert(ran.code == 1 and ran.err:find("in the clear", 1, true) ~= nil and not ran.err:find(TOKEN, 1, true), ran.err)
  local upper = run({ "tools", "--url", "HTTP://192.0.2.1/mcp", "--token-env", "MCP_TOKEN" }, TOKEN)
  assert(upper.code == 1 and upper.err:find("in the clear", 1, true) ~= nil, upper.err)
  local tricked = run({ "tools", "--url", "http://127.0.0.1:1@192.0.2.1/mcp", "--token-env", "MCP_TOKEN" }, TOKEN)
  assert(tricked.code == 2 and tricked.err:find("holds credentials", 1, true) ~= nil, tricked.err)
  local unread = run({ "tools", "--url", "http://127.0.0.1/a b", "--token-env", "MCP_TOKEN" }, TOKEN)
  assert(unread.code == 1 and unread.err:find("--url", 1, true) ~= nil and not unread.err:find(TOKEN, 1, true),
    unread.err)
end
