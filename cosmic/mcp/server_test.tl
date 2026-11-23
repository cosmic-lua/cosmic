--- [`cosmic.mcp.server`] answering messages as text, over stdio, and to
--- [`cosmic.mcp.client`] through a pipe in memory, where each line the
--- client writes is answered before it reads.

local Client = require("cosmic.mcp.client")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local Poll = require("cosmic.poll")
local Server = require("cosmic.mcp.server")
local Stream = require("cosmic.stream")
local Test = require("cosmic.test")

local function add(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
  local a, b = math.tointeger(args["a"]), math.tointeger(args["b"])
  if a == nil or b == nil then return nil, Failure.new("a and b must be integers") end
  return Mcp.result({ tostring(a + b) })
end

local function boom(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
  error("the secret path /etc/x")
end

local function adder(troubles?: mut {string}): Server.Instance
  return Server.new{
    info = { name = "adder", version = "1.0.0" },
    instructions = "Add numbers.",
    page_size = 1,
    tools = {
      {
        tool = {
          name = "add",
          description = "Adds two integers.",
          inputSchema = Mcp.object_schema({ a = { type = "integer" }, b = { type = "integer" } }, { "a", "b" }),
        },
        call = add,
      },
      { tool = { name = "boom", inputSchema = Mcp.object_schema({}) }, call = boom },
    },
    resources = {
      {
        resource = { uri = "note://hello", name = "hello", mimeType = "text/plain" },
        read = function(_: Server.Call): ({Mcp.ResourceContents}) | (nil, Failure)
          return { { uri = "note://hello", mimeType = "text/plain", text = "hi" } }
        end,
      },
    },
    prompts = {
      {
        prompt = { name = "greet", arguments = { { name = "who", required = true } } },
        get = function(args: {string: string}, _: Server.Call): (Mcp.PromptResult) | (nil, Failure)
          return { messages = { { role = "user", content = Mcp.text("Say hello to " .. (args["who"] or "")) } } }
        end,
      },
    },
    on_error = function(trouble: string)
      if troubles ~= nil then troubles[#troubles + 1] = trouble end
    end,
  }
end

local META <const> = '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'

local function request(id: integer, method: string, params?: string): string
  local inner = if params ~= nil then params .. "," .. META else META end
  return '{"jsonrpc":"2.0","id":' .. tostring(id) .. ',"method":"' .. method .. '","params":{' .. inner .. "}}"
end

local function decoded(text?: string): {string: Json.Value}
  assert(text ~= nil, "an answer")
  return assert(Json.decode_object(text))
end

local function object(v: Json.Value?): {string: Json.Value}
  return assert(Json.to_object(v))
end

local function list(v: Json.Value?): {Json.Value}
  return assert(Json.to_array(v))
end

local function test_discover_names_the_version_and_the_features()
  local said = adder():answer(request(1, "server/discover"))
  assert(said.status == 200, tostring(said.status))
  local result = object(decoded(said.body)["result"])
  assert(result["resultType"] == "complete")
  assert(list(result["supportedVersions"])[1] == Mcp.VERSION)
  local caps = object(result["capabilities"])
  assert(caps["tools"] ~= nil and caps["resources"] ~= nil and caps["prompts"] ~= nil)
  assert(result["instructions"] == "Add numbers.")
  assert(result["ttlMs"] == 0 and result["cacheScope"] == "private")
  local info = object(object(result["_meta"])["io.modelcontextprotocol/serverInfo"])
  assert(info["name"] == "adder")
end

local function test_a_request_without_meta_or_of_another_version_is_refused()
  local server = adder()
  local bare = server:answer('{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
  assert(bare.status == 400)
  assert(object(decoded(bare.body)["error"])["code"] == Mcp.INVALID_PARAMS)
  local old = server:answer('{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":' ..
      '{"io.modelcontextprotocol/protocolVersion":"2025-11-25","io.modelcontextprotocol/clientCapabilities":{}}}}')
  local err = object(decoded(old.body)["error"])
  assert(err["code"] == Mcp.UNSUPPORTED_VERSION, tostring(err["code"]))
  local data = object(err["data"])
  assert(list(data["supported"])[1] == Mcp.VERSION and data["requested"] == "2025-11-25")
  local init = server:answer('{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}')
  local ierr = object(decoded(init.body)["error"])
  assert(ierr["code"] == Mcp.UNSUPPORTED_VERSION)
  assert(tostring(ierr["message"]):find(Mcp.VERSION, 1, true) ~= nil)
end

local function test_bad_json_and_unknown_methods_are_refused_with_their_codes()
  local server = adder()
  local parse = server:answer("{")
  assert(parse.status == 400)
  local perr = decoded(parse.body)
  assert(perr["id"] == nil and object(perr["error"])["code"] == Mcp.PARSE_ERROR)
  local missing = server:answer(request(4, "no/such"))
  assert(missing.status == 404)
  assert(object(decoded(missing.body)["error"])["code"] == Mcp.METHOD_NOT_FOUND)
  local note = server:answer('{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}')
  assert(note.body == nil and note.status == 202)
  local bad_id = server:answer('{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}')
  assert(object(decoded(bad_id.body)["error"])["code"] == Mcp.INVALID_REQUEST)
end

local function test_lists_come_a_page_at_a_time()
  local server = adder()
  local first = object(decoded(server:answer(request(1, "tools/list")).body)["result"])
  local tools = list(first["tools"])
  assert(#tools == 1 and object(assert(tools[1]))["name"] == "add")
  local cursor = first["nextCursor"]
  assert(cursor is string)
  local second = object(decoded(server:answer(request(2, "tools/list", '"cursor":' .. Json.quote(cursor))).body)["result"])
  assert(object(list(second["tools"])[1])["name"] == "boom" and second["nextCursor"] == nil)
  local bad = server:answer(request(3, "tools/list", '"cursor":"nope"'))
  assert(object(decoded(bad.body)["error"])["code"] == Mcp.INVALID_PARAMS)
end

local function test_a_tool_failure_is_a_result_and_a_raise_is_withheld()
  local troubles: mut {string} = {}
  local server = adder(troubles)
  local failed = object(decoded(server:answer(request(1, "tools/call", '"name":"add","arguments":{"a":"x","b":1}')).body)["result"])
  assert(failed["isError"] == true)
  local said = tostring(object(list(failed["content"])[1])["text"])
  assert(said:find("do not hold to the tool's inputSchema", 1, true) ~= nil and said:find("/a", 1, true) ~= nil, said)
  local raised = decoded(server:answer(request(2, "tools/call", '"name":"boom"')).body)
  local err = object(raised["error"])
  assert(err["code"] == Mcp.INTERNAL_ERROR)
  assert(tostring(err["message"]):find("secret", 1, true) == nil, "the words stay on the server")
  assert(#troubles == 1 and troubles[1]:find("secret path", 1, true) ~= nil)
  local unknown = decoded(server:answer(request(3, "tools/call", '"name":"nope"')).body)
  assert(object(unknown["error"])["code"] == Mcp.INVALID_PARAMS)
end

local function test_an_empty_result_list_is_an_array()
  local server = Server.new{ info = { name = "x", version = "1" }, tools = {
    { tool = { name = "nothing", inputSchema = Mcp.object_schema({}) },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({})
      end },
  } }
  local text = assert(server:answer(request(1, "tools/call", '"name":"nothing"')).body)
  assert(text:find('"content":[]', 1, true) ~= nil, text)
end

local function test_a_spec_that_does_not_hold_raises()
  local schema = Mcp.object_schema({})
  local call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
    return Mcp.result({})
  end
  Test.raises(function()
    Server.new{ info = { name = "x", version = "1" }, tools = { { tool = { name = "a b", inputSchema = schema }, call = call } } }
  end, "not 1 to 128")
  Test.raises(function()
    Server.new{ info = { name = "x", version = "1" }, tools = {
      { tool = { name = "a", inputSchema = schema }, call = call }, { tool = { name = "a", inputSchema = schema }, call = call } } }
  end, "named twice")
  local bad_header: {string: Json.Value} = { type = "object", properties = { x = { type = "number", ["x-mcp-header"] = "X" } } }
  Test.raises(function()
    Server.new{ info = { name = "x", version = "1" }, tools = { { tool = { name = "a", inputSchema = bad_header }, call = call } } }
  end, "x-mcp-header")
end

--- A tool that promises a structure: `answer` is what its handler answers.
local function measured(answer: Mcp.ToolResult, troubles: mut {string}): Server.Instance
  return Server.new{ info = { name = "m", version = "1" }, tools = { {
    tool = {
      name = "measure",
      inputSchema = Mcp.object_schema({ word = { type = "string", minLength = 1 } }, { "word" }),
      outputSchema = Mcp.object_schema({ length = { type = "integer", minimum = 0 } }, { "length" }),
    },
    call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      return answer
    end,
  } }, on_error = function(trouble: string) troubles[#troubles + 1] = trouble end }
end

local function test_arguments_and_a_structure_are_held_to_their_schemas()
  local troubles: mut {string} = {}
  local good = measured(Mcp.structured({ length = 3 }), troubles)
  local ok = object(decoded(good:answer(request(1, "tools/call", '"name":"measure","arguments":{"word":"abc"}')).body)["result"])
  assert(ok["isError"] == nil and object(ok["structuredContent"])["length"] == 3)
  assert(object(list(ok["content"])[1])["text"] == '{"length":3}', "the structure is its text too")
  local empty = object(decoded(good:answer(request(2, "tools/call", '"name":"measure","arguments":{"word":""}')).body)["result"])
  local said = tostring(object(list(empty["content"])[1])["text"])
  assert(empty["isError"] == true and said:find("/word", 1, true) ~= nil and said:find("minLength", 1, true) ~= nil, said)
  local extra = object(decoded(good:answer(request(3, "tools/call", '"name":"measure","arguments":{"word":"a","x":1}')).body)["result"])
  assert(extra["isError"] == true)
  assert(#troubles == 0, table.concat(troubles, "\n"))
  for i, answer in ipairs({ Mcp.result({ "3" }), Mcp.structured({ length = -1 }), Mcp.structured({ size = 3 }) }) do
    local bad = measured(answer, troubles)
    local err = object(decoded(bad:answer(request(i, "tools/call", '"name":"measure","arguments":{"word":"a"}')).body)["error"])
    assert(err["code"] == Mcp.INTERNAL_ERROR)
  end
  assert(#troubles == 3 and troubles[1]:find("no structuredContent", 1, true) ~= nil and
      troubles[2]:find("/length", 1, true) ~= nil, table.concat(troubles, "\n"))
  local failed = measured(Mcp.result({ "no" }, true), troubles)
  local f = object(decoded(failed:answer(request(9, "tools/call", '"name":"measure","arguments":{"word":"a"}')).body)["result"])
  assert(f["isError"] == true, "an error needs no structure")
end

local function test_a_schema_it_cannot_check_raises()
  local call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
    return Mcp.result({})
  end
  local patterned = Mcp.object_schema({ s = { type = "string", pattern = "^a" } })
  Test.raises(function()
    Server.new{ info = { name = "x", version = "1" }, tools = { { tool = { name = "a", inputSchema = patterned }, call = call } } }
  end, "inputSchema: /properties/s/pattern")
  local list_out: {string: Json.Value} = { type = "array" }
  Test.raises(function()
    Server.new{ info = { name = "x", version = "1" }, tools = { { tool = { name = "a", inputSchema = Mcp.object_schema({}),
      outputSchema = list_out }, call = call } } }
  end, "outputSchema must have")
end

local function test_stdio_answers_a_line_for_each_request()
  local input = Stream.from_string(request(1, "server/discover") .. "\n\n" ..
      '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}\n' .. request(2, "tools/list") .. "\n")
  local output = Stream.collect()
  assert(adder():serve_stdio(input, output))
  local lines: mut {string} = {}
  for line in output:result():gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 2, output:result())
  assert(decoded(assert(lines[1]))["id"] == 1 and decoded(assert(lines[2]))["id"] == 2)
end

--- What a server answered and the client has not read yet.
local record Pipe
  mut pending: string
end

--- The client's end of the pipe it reads.
local class PipeReader is Stream.Reader
  pipe: Pipe

  function read(self, _max?: integer): string?, string
    if self.pipe.pending == "" then return nil, "" end
    local out = self.pipe.pending
    self.pipe.pending = ""
    return out, ""
  end

  function close(self): boolean, string return true, "" end
end

--- The client's end of the pipe it writes: each line is answered as it
--- is written.
local class PipeWriter is Stream.Writer
  pipe: Pipe
  mut server: Server.Instance

  function write(self, data: string): boolean, string
    for line in data:gmatch("[^\n]+") do
      local said = self.server:answer(line)
      if said.body ~= nil then self.pipe.pending = self.pipe.pending .. said.body .. "\n" end
    end
    return true, ""
  end

  function close(self): boolean, string return true, "" end
  function abort(self): boolean, string return true, "" end
end

local function piped(server: Server.Instance): Client.Session
  local pipe: Pipe = { pending = "" }
  local reader: PipeReader = { pipe = pipe, skip = nil }
  local writer: PipeWriter = { pipe = pipe, server = server }
  return Client.stdio(reader, writer)
end

--- A server of the tool `measure`, which answers `answer`, promising `promised` where given.
local function promising(answer: Mcp.ToolResult, promised?: {string: Json.Value}): Server.Instance
  return Server.new{ info = { name = "m", version = "1" }, tools = { {
    tool = { name = "measure", inputSchema = Mcp.object_schema({}), outputSchema = promised },
    call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      return answer
    end,
  } } }
end

--- A client reads a structure a tool did not promise as a failure: here the tool listed is not the one called.
local function test_a_client_holds_a_structure_to_the_schema_it_listed()
  local promise = Mcp.object_schema({ length = { type = "integer" } }, { "length" })
  local pipe: Pipe = { pending = "" }
  local writer: PipeWriter = { pipe = pipe, server = promising(Mcp.structured({ length = 1 }), promise) }
  local reader: PipeReader = { pipe = pipe, skip = nil }
  local session = Client.stdio(reader, writer)
  assert(session:tools())
  assert(assert(session:call("measure")).structuredContent ~= nil)
  writer.server = promising(Mcp.structured({ length = "1" }))
  local wrong, why = session:call("measure")
  assert(wrong == nil and tostring(why):find("/length", 1, true) ~= nil, tostring(why))
  writer.server = promising(Mcp.result({ "1" }))
  local bare, bwhy = session:call("measure")
  assert(bare == nil and tostring(bwhy):find("no structuredContent", 1, true) ~= nil, tostring(bwhy))
  writer.server = promising(Mcp.result({ "no" }, true))
  assert(assert(session:call("measure")).isError == true, "an error needs no structure")
end

local function test_the_client_and_the_server_agree_over_stdio()
  local session = piped(adder())
  local d = assert(session:discover())
  assert(d.supportedVersions[1] == Mcp.VERSION and d.instructions == "Add numbers.")
  assert(d.serverInfo ~= nil and d.serverInfo.name == "adder")
  local tools = assert(session:tools())
  assert(#tools == 2 and assert(tools[1]).name == "add" and assert(tools[2]).name == "boom", "both pages are read")
  local sum = assert(session:call("add", { a = 2, b = 3 }))
  assert(sum.isError ~= true and assert(sum.content[1]).text == "5")
  local failed = assert(session:call("add", { a = "x" }))
  assert(failed.isError == true)
  local raised, why = session:call("boom")
  assert(raised == nil and why.code == Mcp.INTERNAL_ERROR, tostring(why))
  local resources = assert(session:resources())
  assert(#resources == 1 and assert(resources[1]).uri == "note://hello")
  local contents = assert(session:read("note://hello"))
  assert(assert(contents[1]).text == "hi")
  local none, nwhy = session:read("note://none")
  assert(none == nil and nwhy.code == Mcp.INVALID_PARAMS)
  local prompts = assert(session:prompts())
  assert(assert(prompts[1]).name == "greet")
  local p = assert(session:prompt("greet", { who = "Will" }))
  assert(assert(p.messages[1]).content.text == "Say hello to Will")
  local missing, mwhy = session:prompt("greet")
  assert(missing == nil and mwhy.code == Mcp.INVALID_PARAMS)
  assert(session:close())
  local after, awhy = session:tools()
  assert(after == nil and tostring(awhy):find("closed", 1, true) ~= nil)
end

local function test_an_answer_json_cannot_hold_is_an_internal_error_and_the_server_goes_on()
  local troubles: mut {string} = {}
  local server = Server.new{
    info = { name = "x", version = "1" },
    tools = { { tool = { name = "bytes", inputSchema = Mcp.object_schema({}) },
      call = function(_: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
        return Mcp.result({ "\xff\xfe" })
      end } },
    resources = { { resource = { uri = "file://x", name = "x" },
      read = function(_: Server.Call): ({Mcp.ResourceContents}) | (nil, Failure)
        return nil, Failure.new("No such file or directory", "/srv/secret/x")
      end } },
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
  }
  local input = Stream.from_string(request(1, "tools/call", '"name":"bytes"') .. "\n" .. request(2, "server/discover") .. "\n")
  local output = Stream.collect()
  assert(server:serve_stdio(input, output))
  local lines: mut {string} = {}
  for line in output:result():gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 2, output:result())
  assert(object(decoded(assert(lines[1]))["error"])["code"] == Mcp.INTERNAL_ERROR)
  assert(decoded(assert(lines[2]))["result"] ~= nil, "the next request is answered")
  local read = assert(server:answer(request(3, "resources/read", '"uri":"file://x"')).body)
  assert(read:find("secret", 1, true) == nil, read)
  assert(object(decoded(read)["error"])["code"] == Mcp.INTERNAL_ERROR)
  assert(#troubles == 2 and assert(troubles[2]):find("/srv/secret/x", 1, true) ~= nil)
end

local function test_an_unknown_method_is_not_found_before_its_meta_is_read()
  local said = adder():answer('{"jsonrpc":"2.0","id":1,"method":"no/such"}')
  assert(said.status == 404)
  local init = adder():answer('{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}')
  local data = object(object(decoded(init.body)["error"])["data"])
  assert(data["requested"] == "2025-11-25")
end

local function test_a_read_is_never_for_a_shared_cache()
  local server = Server.new{ info = { name = "x", version = "1" }, cache_scope = "public", resources = {
    { resource = { uri = "a://b", name = "b" },
      read = function(_: Server.Call): ({Mcp.ResourceContents}) | (nil, Failure)
        return { { uri = "a://b", text = "t" } }
      end },
  } }
  local listed = object(decoded(server:answer(request(1, "resources/list")).body)["result"])
  assert(listed["cacheScope"] == "public")
  local read = object(decoded(server:answer(request(2, "resources/read", '"uri":"a://b"')).body)["result"])
  assert(read["cacheScope"] == "private")
end

--- [`McpServer.Instance.main`] refuses a command line that would serve where it should not, before it serves.
local function test_a_main_refuses_a_line_it_cannot_serve()
  local s = adder()
  assert(s:main({ "--http", "127.0.0.1:0" }) == 2, "HTTP needs a token or --anyone")
  assert(s:main({ "--http", "0.0.0.0:0", "--anyone" }) == 2, "--anyone only on loopback")
  assert(s:main({ "--http", "127.0.0.1:0", "--token-env", "COSMIC_MCP_TEST_NO_SUCH" }) == 2, "an unset token")
  assert(s:main({ "--http", "nowhere" }) == 2)
  assert(s:main({ "--origin", "https://a.example" }) == 2, "--origin is for --http")
  assert(s:main({ "--nosuch" }) == 2)
  assert(s:main({ "word" }) == 2)
  assert(s:main({ "--http", "127.0.0.1.evil:0", "--anyone" }) == 2, "a name is not the loopback")
  assert(s:main({ "--http", "localhost:0", "--anyone" }) == 2, "nor is localhost")
  assert(s:main({ "--http", "127.0.0.1:65536", "--anyone" }) == 2)
  assert(s:main({ "--http", "127.0.0.1:0", "--anyone", "--token-env", "X" }) == 2, "a token and --anyone")
  assert(s:main({ "--http", "127.0.0.1:0", "--anyone", "--path", "mcp" }) == 2, "a path starts with /")
  assert(s:main({ "--http", "127.0.0.1:0", "--http", "127.0.0.1:1", "--anyone" }) == 2, "--http twice")
  assert(s:main({ "--path", "/x" }) == 2, "--path is for --http")
end

--- A tool that tells its progress `steps` times, a pause apart, and notes in `seen` when it finds itself cancelled.
local function stepping(name: string, steps: integer, seen: mut {string}): Server.ToolSpec
  return {
    tool = { name = name, inputSchema = Mcp.object_schema({}) },
    call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      for i = 1, steps do
        call.progress(i, steps)
        call.progress(i - 1, steps, "backwards, dropped")
        local ok, why = Poll.delay(Clock.ms(10))
        if not ok or call.cancelled() then
          local said = "cancelled: " .. tostring(why)
          seen[#seen + 1] = said
          return nil, Failure.new("cancelled")
        end
      end
      return Mcp.result({ "done" })
    end,
  }
end

local function stepper(seen: mut {string}): Server.Instance
  return Server.new{ info = { name = "steps", version = "1" },
    tools = { stepping("short", 2, seen), stepping("long", 1000, seen) } }
end

local function test_over_stdio_progress_comes_before_the_answer_and_a_cancel_ends_a_call()
  local seen: mut {string} = {}
  local with_token = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"short","arguments":{},' ..
    '"_meta":{"progressToken":"t","io.modelcontextprotocol/protocolVersion":"2026-07-28",' ..
    '"io.modelcontextprotocol/clientCapabilities":{}}}}'
  local cancel = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"enough"}}'
  local input = Stream.from_string(with_token .. "\n" .. request(2, "tools/call", '"name":"long"') .. "\n" .. cancel .. "\n" ..
      request(3, "tools/call", '"name":"short"') .. "\n")
  local output = Stream.collect()
  assert(stepper(seen):serve_stdio(input, output))
  local said: mut {{string: Json.Value}} = {}
  for line in output:result():gmatch("[^\n]+") do said[#said + 1] = decoded(line) end
  local kinds: mut {string} = {}
  for _, m in ipairs(said) do
    kinds[#kinds + 1] = if m["method"] == "notifications/progress" then "p" .. tostring(object(m["params"])["progressToken"]) else
      "r" .. tostring(m["id"]) end
  end
  local order = table.concat(kinds, " ")
  -- Two notices of progress for request 1 before its answer, none for 3, which asked for none; 2 is not answered.
  assert(order:find("pt pt r1", 1, true) ~= nil and order:find("r2", 1, true) == nil and order:find("r3", 1, true) ~= nil, order)
  assert(#seen == 1, table.concat(seen, "; "))
end

--- One direction of a pipe in a run: what is written waits for a read.
local record Duct
  mut held: string
  mut closed: boolean
  notifier: Poll.Notifier
end

local class DuctReader is Stream.Reader
  duct: Duct

  function read(self, _max?: integer): string?, string
    while self.duct.held == "" do
      if self.duct.closed then return nil, "" end
      local ok, why = self.duct.notifier:wait()
      if not ok then return nil, tostring(why) end
    end
    local out = self.duct.held
    self.duct.held = ""
    return out, ""
  end

  function close(self): boolean, string return true, "" end
end

local class DuctWriter is Stream.Writer
  duct: Duct

  function write(self, data: string): boolean, string
    self.duct.held = self.duct.held .. data
    self.duct.notifier:notify_all()
    return true, ""
  end

  function close(self): boolean, string
    self.duct.closed = true
    self.duct.notifier:notify_all()
    return true, ""
  end

  function abort(self): boolean, string return self:close() end
end

local function duct(): Duct
  return { held = "", closed = false, notifier = Poll.notifier() }
end

--- The client hears progress over stdio as it comes, and a cancelled caller tells the server.
local function test_a_stdio_client_hears_progress_and_cancels()
  local seen: mut {string} = {}
  Poll.run(function()
    local up, down = duct(), duct()
    local server_in: DuctReader = { duct = up, skip = nil }
    local server_out: DuctWriter = { duct = down }
    local served = Poll.spawn(function()
      assert(stepper(seen):serve_stdio(server_in, server_out))
    end)
    local client_in: DuctReader = { duct = down, skip = nil }
    local client_out: DuctWriter = { duct = up }
    local session = Client.stdio(client_in, client_out)
    local heard: mut {number} = {}
    local done = assert(session:call("short", {}, { on_progress = function(p: Mcp.Progress)
      heard[#heard + 1] = p.progress
    end }))
    assert(assert(done.content[1]).text == "done" and #heard == 2 and heard[2] == 2, tostring(#heard))
    local caller = Poll.spawn(function()
      local none, why = session:call("long")
      assert(none == nil and tostring(why):find("cancelled", 1, true) ~= nil, tostring(why))
    end)
    assert(Poll.delay(Clock.ms(30)))
    caller:cancel()
    assert(caller:join(Clock.seconds(20)))
    assert(session:close())
    assert(served:join(Clock.seconds(20)))
  end)
  assert(#seen == 1, table.concat(seen, "; "))
end

--- A cancel is read while every place is taken: 33 long calls, then a cancel of each, end at once.
local function test_a_cancel_is_read_while_the_server_is_full()
  local seen: mut {string} = {}
  local text: mut {string} = {}
  for i = 1, 33 do text[#text + 1] = request(i, "tools/call", '"name":"long"') end
  for i = 1, 33 do
    text[#text + 1] = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":' .. tostring(i) .. "}}"
  end
  local output = Stream.collect()
  assert(stepper(seen):serve_stdio(Stream.from_string(table.concat(text, "\n") .. "\n"), output))
  assert(output:result() == "", output:result())
  -- The 33rd starts once one of the first ends, or not at all where its cancel is read first.
  assert(#seen == 32 or #seen == 33, tostring(#seen))
end

local class FailingWriter is Stream.Writer
  function write(self, _: string): boolean, string return false, "the pipe is broken" end
  function close(self): boolean, string return true, "" end
  function abort(self): boolean, string return true, "" end
end

--- A write that fails ends the server, though its input has nothing more to say and never ends.
local function test_a_failed_write_ends_the_server_while_its_input_waits()
  local seen: mut {string} = {}
  Poll.run(function()
    local up = duct()
    local input: DuctReader = { duct = up, skip = nil }
    local broken: FailingWriter = {}
    local feeder: DuctWriter = { duct = up }
    assert(feeder:write(request(1, "tools/call", '"name":"short"') .. "\n"))
    local ok, why = stepper(seen):serve_stdio(input, broken)
    assert(not ok and tostring(why):find("broken", 1, true) ~= nil, tostring(why))
  end)
end
