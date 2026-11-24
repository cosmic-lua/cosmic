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
local wire = require("cosmic.mcp.wire")

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

local function piped(server: Server.Instance, opts?: Client.Options): Client.Session
  local pipe: Pipe = { pending = "" }
  local reader: PipeReader = { pipe = pipe, skip = nil }
  local writer: PipeWriter = { pipe = pipe, server = server }
  return Client.stdio(reader, writer, opts)
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
      if not ok then return nil, why.message end
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

--- Waits in a run until `ready` answers true, a millisecond at a time, for at most 20 seconds.
local function until_true(ready: function(): boolean)
  for _ = 1, 20000 do
    if ready() then return end
    assert(Poll.delay(Clock.ms(1)))
  end
  error("waited 20 seconds")
end

--- A subscription over stdio hears the acknowledgment first, then a notice of each change it asked for, while
--- other calls of the session go on. The server's end answers it true; a cancelled one tells the server, and the
--- session goes on after it.
local function test_a_stdio_subscription_hears_changes_while_calls_go_on()
  Poll.run(function()
    local up, down = duct(), duct()
    local server_in: DuctReader = { duct = up, skip = nil }
    local server_out: DuctWriter = { duct = down }
    local server = adder()
    local served = Poll.spawn(function()
      assert(server:serve_stdio(server_in, server_out))
    end)
    local client_in: DuctReader = { duct = down, skip = nil }
    local client_out: DuctWriter = { duct = up }
    local session = Client.stdio(client_in, client_out)
    local agreed: Client.Subscription? = nil
    local notices: mut {string} = {}
    local ended: boolean? = nil
    local listener = Poll.spawn(function()
      local ok, why = session:listen({ tools = true, uris = { "note://hello", "note://other" } },
        function(n: Client.Notice)
          -- A callback may call the session: its request is read for while the subscription's waits.
          if n.kind == "updated" then assert(session:read(assert(n.uri))) end
          notices[#notices + 1] = n.kind .. " " .. (n.uri or "")
        end,
        function(a: Client.Subscription) agreed = a end)
      assert(ok, tostring(why))
      ended = ok
    end)
    until_true(function(): boolean return agreed ~= nil end)
    local a = assert(agreed)
    assert(a.tools == true and a.prompts == false and #assert(a.uris) == 2)
    local said = assert(session:call("add", { a = 1, b = 2 }))
    assert(assert(said.content[1]).text == "3", "a call goes on while the subscription waits")
    local caps = assert(session:discover()).capabilities
    assert(assert(caps.tools).listChanged == true and assert(caps.resources).subscribe == true, "it offers what it tells of")
    server:update({ prompts = {} })
    server:update({ tools = {} })
    server:resource_updated("note://elsewhere")
    server:resource_updated("note://hello")
    until_true(function(): boolean return #notices >= 2 end)
    server:end_subscriptions()
    assert(listener:join(Clock.seconds(20)))
    assert(ended == true)
    assert(table.concat(notices, "|") == "tools |updated note://hello", table.concat(notices, "|"))
    local acked = false
    local second = Poll.spawn(function()
      local ok, why = session:listen({ prompts = true }, function(_: Client.Notice) end,
        function(_: Client.Subscription) acked = true end)
      assert(not ok and why.kind == "cancelled", tostring(why))
    end)
    until_true(function(): boolean return acked end)
    second:cancel()
    assert(second:join(Clock.seconds(20)))
    assert(session:close())
    assert(served:join(Clock.seconds(20)))
  end)
end

--- A request whose id is one a running request has is refused, as a cancel could not tell the two apart.
local function test_over_stdio_a_running_id_is_not_taken_again()
  local seen: mut {string} = {}
  local cancel = '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}'
  local input = Stream.from_string(request(1, "tools/call", '"name":"long"') .. "\n" ..
      request(1, "tools/call", '"name":"short"') .. "\n" .. cancel .. "\n")
  local output = Stream.collect()
  assert(stepper(seen):serve_stdio(input, output))
  local said = decoded(output:result():match("[^\n]+"))
  assert(said["id"] == 1 and object(said["error"])["code"] == Mcp.INVALID_REQUEST, output:result())
  assert(#seen == 1, "the first is still the one cancelled")
end

--- A tool that asks the person for a name, keeps a count over the rounds, and greets them.
local function greeter(rounds: mut {integer}): Server.Instance
  return Server.new{
    info = { name = "greeter", version = "1" },
    tools = {
      {
        tool = { name = "greet", inputSchema = Mcp.object_schema({}) },
        call = function(_: {string: Json.Value}, call: Server.Call): (Mcp.ToolResult) | (nil, Failure)
          local round = (math.tointeger(tonumber(call.state or "0")) or 0) + 1
          rounds[#rounds + 1] = round
          call.keep(tostring(round))
          local answer, why = call.elicit("who", Mcp.elicit_form("Who are you?",
            Mcp.object_schema({ name = { type = "string", minLength = 1 } }, { "name" })))
          if answer == nil then return nil, why end
          if answer.action ~= "accept" then
            return Mcp.result({ "no name, round " .. tostring(round) })
          end
          local name = assert(answer.content)["name"]
          return Mcp.result({ "hello " .. tostring(name) .. ", round " .. tostring(round) })
        end,
      },
    },
  }
end

--- A tool asks for input: the client's `elicit` answers, and the call is asked again with the answer and the
--- state the handler kept. An answer that does not hold to the form is asked for again; a client that gives no
--- `elicit` fails the call, and one that declares nothing is never asked.
local function test_a_tool_asks_the_person_and_the_client_answers()
  local rounds: mut {integer} = {}
  local asked: mut {string} = {}
  local answers: {Mcp.Elicited} = { { action = "accept", content = { name = "" } }, { action = "accept", content = { name = "Ada" } } }
  local session = piped(greeter(rounds), { elicit = function(e: Mcp.Elicitation): (Mcp.Elicited) | (nil, Failure)
    asked[#asked + 1] = e.mode .. ": " .. e.message
    return assert(answers[#asked])
  end })
  local said = assert(session:call("greet"))
  assert(assert(said.content[1]).text == "hello Ada, round 3", assert(said.content[1]).text)
  assert(#asked == 2 and asked[1] == "form: Who are you?", table.concat(asked, "; "))
  local plain = piped(greeter(rounds))
  local refused = assert(plain:call("greet"))
  local text = assert(assert(refused.content[1]).text)
  assert(text:find("cannot be asked", 1, true) ~= nil and refused.isError == true, text)
end

--- The state a handler keeps is sealed: changed, or sent for another tool, it is refused.
local function test_kept_state_is_sealed_to_its_request()
  local rounds: mut {integer} = {}
  local server = greeter(rounds)
  local caps = '"io.modelcontextprotocol/clientCapabilities":{"elicitation":{}}'
  local first = decoded(server:answer('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"greet",' ..
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' .. caps .. '}}}').body)
  local r = object(first["result"])
  assert(r["resultType"] == "input_required" and object(r["inputRequests"])["who"] ~= nil)
  local state = r["requestState"]
  assert(state is string)
  local function retry(sealed: string, name: string, arguments?: string): {string: Json.Value}
    return decoded(server:answer('{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":' .. Json.quote(name) ..
        (if arguments ~= nil then ',"arguments":' .. arguments else "" end) ..
        ',"requestState":' .. Json.quote(sealed) .. ',"inputResponses":{"who":{"action":"decline"}},' ..
        '"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",' .. caps .. '}}}').body)
  end
  local good = object(retry(state, "greet")["result"])
  local block = object(list(good["content"])[1])
  assert(block["text"] == "no name, round 2", tostring(block["text"]))
  local flipped = state:sub(1, -2) .. (if state:sub(-1) == "A" then "B" else "A" end)
  local bad = object(retry(flipped, "greet")["error"])
  assert(bad["code"] == Mcp.INVALID_PARAMS and tostring(bad["message"]):find("requestState", 1, true) ~= nil)
  local elsewhere = object(retry(state, "other")["error"])
  assert(elsewhere["code"] == Mcp.INVALID_PARAMS, "a state is for the tool it was kept by")
  local changed = object(retry(state, "greet", '{"to":"mallory"}')["error"])
  assert(changed["code"] == Mcp.INVALID_PARAMS, "a state is for the arguments it was kept with")
  assert(rounds[2] == 2, "the second round read the first round's state")
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

local LANGUAGES <const>: {string} = { "python", "perl", "php", "rust" }

--- A server that completes the argument `language` of the prompt `review` and the variables of `repo://{owner}/{name}{?ref}`.
local function completer(troubles: mut {string}): Server.Instance
  return Server.new{ info = { name = "completer", version = "1" },
    templates = { { uriTemplate = "repo://{owner}/{name}{?ref}", name = "repo" } },
    read = function(_: string, _: Server.Call): ({Mcp.ResourceContents} | false) | (nil, Failure)
      return false
    end,
    prompts = { {
      prompt = { name = "review", arguments = { { name = "language" }, { name = "style" } } },
      get = function(_: {string: string}, _: Server.Call): (Mcp.PromptResult) | (nil, Failure)
        return { messages = {} }
      end,
    } },
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end,
    complete = function(asked: Mcp.Completing, call: Server.Call): (Mcp.Completion) | (nil, Failure)
      if asked.value == "boom" then error("boom") end
      if asked.value == "fail" then return nil, Failure.new("no completions today") end
      if asked.value == "ask" then
        local _, why = call.elicit("k", { mode = "form", message = "which?", requestedSchema = Mcp.object_schema({}) })
        return nil, assert(why)
      end
      if asked.value == "exactly" then
        local hundred: mut {string} = {}
        for i = 1, Mcp.MAX_COMPLETIONS do hundred[i] = tostring(i) end
        return { values = hundred }
      end
      if asked.value == "uncounted" then
        local many: mut {string} = {}
        for i = 1, 120 do many[i] = tostring(i) end
        return { values = many, total = -5 }
      end
      if asked.argument == "style" then
        local many: mut {string} = {}
        for i = 1, 150 do many[i] = "style-" .. tostring(i) end
        return { values = many, total = 150 }
      end
      if asked.template ~= nil then
        local owner = (asked.context or {})["owner"] or "?"
        return { values = { owner .. "/" .. asked.value .. "-x" } }
      end
      local fits: mut {string} = {}
      for _, each in ipairs(LANGUAGES) do
        if each:sub(1, #asked.value) == asked.value then fits[#fits + 1] = each end
      end
      return { values = fits, total = #fits }
    end,
  }
end

local function test_a_server_completes_its_own_arguments_and_no_other()
  local troubles: mut {string} = {}
  local server = completer(troubles)
  local caps = object(object(decoded(server:answer(request(1, "server/discover")).body)["result"])["capabilities"])
  local declared = object(caps["completions"])
  assert(next(declared) == nil and not Json.is_array(caps["completions"]), "a server that completes says so, with {}")
  local caps_without = object(object(decoded(adder():answer(request(1, "server/discover")).body)["result"])["capabilities"])
  assert(caps_without["completions"] == nil)
  local refused = decoded(adder():answer(request(2, "completion/complete",
    '"ref":{"type":"ref/prompt","name":"greet"},"argument":{"name":"who","value":"W"}')).body)
  assert(object(refused["error"])["code"] == Mcp.METHOD_NOT_FOUND, "a server with no complete does not answer it")

  local session = piped(server)
  local got = assert(session:complete({ prompt = "review", argument = "language", value = "p" }))
  assert(#got.values == 3 and got.values[1] == "python" and got.total == 3 and got.has_more == nil)
  -- The values past the most a result holds are cut, and the result says there are more.
  local cut = assert(session:complete({ prompt = "review", argument = "style", value = "" }))
  assert(#cut.values == Mcp.MAX_COMPLETIONS and cut.total == 150 and cut.has_more == true)
  -- A template's variable, with the variables chosen before it.
  local repo = assert(session:complete({ template = "repo://{owner}/{name}{?ref}", argument = "name", value = "cos",
    context = { owner = "will" } }))
  assert(repo.values[1] == "will/cos-x", tostring(repo.values[1]))
  assert(session:complete({ template = "repo://{owner}/{name}{?ref}", argument = "ref", value = "" }))
  -- What is not the server's own is refused before the handler is called.
  local wrongs: {Mcp.Completing} = {
    { prompt = "nope", argument = "language", value = "" },
    { prompt = "review", argument = "nope", value = "" },
    { template = "repo://{other}", argument = "other", value = "" },
    { template = "repo://{owner}/{name}{?ref}", argument = "nope", value = "" },
  }
  for _, wrong in ipairs(wrongs) do
    local none, why = session:complete(wrong)
    assert(none == nil and why.code == Mcp.INVALID_PARAMS, tostring(why))
  end
  local both, bwhy = session:complete({ prompt = "review", template = "repo://{owner}", argument = "x", value = "" })
  assert(both == nil and tostring(bwhy):find("exactly one", 1, true) ~= nil, tostring(bwhy))
  -- A handler's failure or raise is withheld, and told to on_error.
  for _, value in ipairs({ "fail", "boom", "ask" }) do
    local none, why = session:complete({ prompt = "review", argument = "language", value = value })
    assert(none == nil and why.code == Mcp.INTERNAL_ERROR, tostring(why))
    assert(tostring(why):find("today", 1, true) == nil and tostring(why):find("boom", 1, true) == nil, tostring(why))
  end
  assert(#troubles == 3, tostring(#troubles))
  -- An update keeps the completer.
  server:update{ prompts = { {
    prompt = { name = "review", arguments = { { name = "language" } } },
    get = function(_: {string: string}, _: Server.Call): (Mcp.PromptResult) | (nil, Failure)
      return { messages = {} }
    end,
  } } }
  assert(session:complete({ prompt = "review", argument = "language", value = "r" }))
  assert(assert(troubles[3]):find("may not ask for input", 1, true) ~= nil, troubles[3])
  assert(assert(troubles[1]):find("prompt review", 1, true) ~= nil, troubles[1])
  -- Exactly as many as a result holds is not more; values cut with a total below 0 are counted.
  local exactly = assert(session:complete({ prompt = "review", argument = "language", value = "exactly" }))
  assert(#exactly.values == Mcp.MAX_COMPLETIONS and exactly.has_more == nil and exactly.total == nil)
  local uncounted = assert(session:complete({ prompt = "review", argument = "language", value = "uncounted" }))
  assert(#uncounted.values == Mcp.MAX_COMPLETIONS and uncounted.total == 120 and uncounted.has_more == true)
  -- Params that do not fit are refused as such.
  for _, params in ipairs({
      '"ref":{"type":"ref/other","name":"review"},"argument":{"name":"language","value":""}',
      '"ref":{"type":"ref/prompt"},"argument":{"name":"language","value":""}',
      '"ref":{"type":"ref/prompt","name":"review"},"argument":{"name":"language"}',
      '"ref":{"type":"ref/prompt","name":"review"},"argument":{"name":"language","value":""},"context":{"arguments":{"a":1}}',
  }) do
    local said = decoded(server:answer(request(3, "completion/complete", params)).body)
    assert(object(said["error"])["code"] == Mcp.INVALID_PARAMS, params)
  end
end

local function test_template_variables_are_read_from_each_expression()
  local names = wire.template_variables("x://{a}/{+b}{#c}{.d}{/e*}{;f:3}{?g,h*}{&i,j:2}{a}")
  assert(table.concat(names, " ") == "a b c d e f g h i j", table.concat(names, " "))
  assert(#wire.template_variables("plain") == 0)
end

local function test_a_null_argument_is_a_value_the_schema_and_the_handler_see()
  local seen: mut {Json.Value} = {}
  local server = Server.new{ info = { name = "nulls", version = "1" }, tools = { {
    tool = { name = "maybe", inputSchema = {
      type = "object",
      properties = { x = { type = Json.array({ "string", "null" }) } },
      required = Json.array({ "x" }),
    } },
    call = function(args: {string: Json.Value}, _: Server.Call): (Mcp.ToolResult) | (nil, Failure)
      local x = args["x"]
      seen[#seen + 1] = if x ~= nil then x else "absent" end
      return Mcp.result({ "ok" })
    end,
  } } }
  local said = decoded(server:answer(request(1, "tools/call", '"name":"maybe","arguments":{"x":null}')).body)
  local result = object(said["result"])
  assert(result["isError"] ~= true, tostring(said["result"]))
  assert(seen[1] == Json.null, "the handler is given null, not nothing")
  -- Absent is not null: the schema requires x.
  local absent = object(decoded(server:answer(request(2, "tools/call", '"name":"maybe","arguments":{}')).body)["result"])
  assert(absent["isError"] == true and #seen == 1)
  -- A prompt's arguments are strings: a null one is absent, as before.
  local greeted = decoded(adder():answer(request(4, "prompts/get", '"name":"greet","arguments":{"who":"Will","x":null}')).body)
  assert(greeted["result"] ~= nil, tostring(greeted["error"]))
  -- Elsewhere a null member is absent, as before: a null cursor is no cursor.
  local listed = decoded(server:answer(request(3, "tools/list", '"cursor":null')).body)
  assert(listed["result"] ~= nil, tostring(listed["error"]))
end

local function test_a_feature_offered_while_empty_is_announced_when_it_comes()
  local function blank(): Server.Instance
    return Server.new{ info = { name = "blank", version = "1" }, offers = { "prompts" } }
  end
  local caps = object(object(decoded(blank():answer(request(1, "server/discover")).body)["result"])["capabilities"])
  assert(caps["prompts"] ~= nil and caps["tools"] == nil)
  local listed = object(decoded(blank():answer(request(2, "prompts/list")).body)["result"])
  assert(#list(listed["prompts"]) == 0 and Json.is_array(listed["prompts"]))
  Poll.run(function()
    local up, down = duct(), duct()
    local server = blank()
    local served = Poll.spawn(function()
      local server_in: DuctReader = { duct = up, skip = nil }
      local server_out: DuctWriter = { duct = down }
      assert(server:serve_stdio(server_in, server_out))
    end)
    local client_in: DuctReader = { duct = down, skip = nil }
    local client_out: DuctWriter = { duct = up }
    local session = Client.stdio(client_in, client_out)
    local agreed: Client.Subscription? = nil
    local notices: mut {string} = {}
    local listener = Poll.spawn(function()
      local ok, why = session:listen({ prompts = true }, function(n: Client.Notice)
        notices[#notices + 1] = n.kind
      end,
        function(a: Client.Subscription) agreed = a end)
      assert(ok, tostring(why))
    end)
    until_true(function(): boolean return agreed ~= nil end)
    assert(assert(agreed).prompts == true, "a feature offered while empty is one a subscription hears of")
    server:update({ prompts = { {
      prompt = { name = "hi" },
      get = function(_: {string: string}, _: Server.Call): (Mcp.PromptResult) | (nil, Failure)
        return { messages = {} }
      end,
    } } })
    until_true(function(): boolean return #notices >= 1 end)
    assert(notices[1] == "prompts")
    assert(#assert(session:prompts()) == 1)
    server:end_subscriptions()
    assert(listener:join(Clock.seconds(20)))
    assert(session:close())
    assert(served:join(Clock.seconds(20)))
  end)
end
