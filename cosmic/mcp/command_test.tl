--- [`McpServer.command`]: a tool that is this program run on a script under a policy, which reads what the policy
--- grants and nothing else of the server's. Every call starts a child under a policy, which a host with no sandbox
--- to give cannot: the module is skipped where Linux refuses it.

local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local McpServer = require("cosmic.mcp.server")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local ChildPolicy = require("build.child_policy_fixture")
local searchable = require("build.searchable")

Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  env = { "TMPDIR" },
  requires = { "sandbox" },
}

--- The tool's script: it reads the file its arguments name and prints it, or says it cannot.
local TOOL <const> = [[
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Stream = require("cosmic.stream")
return function(_: {string}): integer
  local text = assert(Stream.read_all(Stream.from_fd(Fs.stdin)))
  local args = assert(Json.decode_object(text))
  local path = args["path"]
  if not path is string then return 2 end
  local got, _ = Fs.read(path)
  if got == nil then
    local _, _ = Fs.put(Fs.stderr, "cannot read " .. path)
    return 3
  end
  local _, _ = Fs.put(Fs.stdout, got)
  return 0
end
]]

--- A directory every user may write, with the tool's script and a file it may read in it, and a secret beside it.
local function laid_out(tmp: string): string
  searchable.open(tmp)
  local work = tmp .. "/work"
  assert(Fs.mkdirs(work))
  searchable.share(work)
  for name, text in pairs({ ["tool.tl"] = TOOL, ["note.txt"] = "the note" }) do
    assert(Fs.write(work .. "/" .. name, text))
    searchable.share(work .. "/" .. name)
  end
  assert(Fs.write(tmp .. "/secret.txt", "the secret"))
  searchable.share(tmp .. "/secret.txt")
  return work
end

--- The tool over `work`, held to reading and writing there.
local function tool(work: string, policy?: Sandbox.Policy, timeout_ns?: integer): McpServer.ToolSpec
  return McpServer.command{
    tool = { name = "cat", inputSchema = Mcp.object_schema({ path = { type = "string" } }, { "path" }) },
    argv = { (assert(Proc.executable())), work .. "/tool.tl" },
    policy = policy or { profiles = { "cosmic" }, grants = { { path = work, letters = "rwc" } } },
    cwd = work,
    timeout_ns = timeout_ns,
  }
end

--- A call made here, not for a client: no progress to send, never cancelled.
local function bare(): McpServer.Call
  return { capabilities = {}, progress = function(_: number, _?: number, _?: string) end,
    cancelled = function(): boolean return false end }
end

--- What the tool answers for `path`; skips the test where the host gives no sandbox.
local function called(spec: McpServer.ToolSpec, path: string): Mcp.ToolResult
  local result, why = spec.call({ path = path }, bare())
  if result == nil then
    assert(ChildPolicy.unsandboxable(tostring(why)), "the start was refused: " .. tostring(why))
    Test.skip(tostring(why))
    error("Test.skip ends the test where it is called")
  end
  return result
end

local function text_of(r: Mcp.ToolResult): string
  return assert(assert(r.content[1]).text)
end

local function test_a_tool_reads_what_its_policy_grants_and_nothing_else(tmp: string)
  local work = laid_out(tmp)
  local cat = tool(work)
  local note = called(cat, work .. "/note.txt")
  assert(note.isError == nil and text_of(note) == "the note", text_of(note))
  local secret = called(cat, tmp .. "/secret.txt")
  assert(secret.isError == true and text_of(secret):find("cannot read", 1, true) ~= nil, text_of(secret))
  assert(not text_of(secret):find("the secret", 1, true))
end

--- Through a server, the tool's arguments are the client's, and its result comes back as a call's.
local function test_a_server_calls_the_command_for_a_client(tmp: string)
  local work = laid_out(tmp)
  local cat = tool(work)
  local probe = called(cat, work .. "/note.txt")
  assert(probe.isError == nil)
  local server = McpServer.new{ info = { name = "cmd", version = "1" }, tools = { cat } }
  local request = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"cat","arguments":{"path":' ..
    Json.quote(work .. "/note.txt") .. '},"_meta":{"io.modelcontextprotocol/protocolVersion":"' .. Mcp.VERSION ..
    '","io.modelcontextprotocol/clientCapabilities":{}}}}'
  local said = server:answer(request)
  assert(said.status == 200 and assert(said.body):find("the note", 1, true) ~= nil, said.body)
end

local function test_a_call_past_its_time_is_an_error(tmp: string)
  local work = laid_out(tmp)
  assert(Fs.write(work .. "/tool.tl", "return function(_: {string}): integer\n  while true do end\nend\n"))
  local slow = tool(work, nil, Clock.seconds(3))
  local r = called(slow, "x")
  assert(r.isError == true and text_of(r):find("past its time", 1, true) ~= nil, text_of(r))
end

local function test_a_spec_it_cannot_run_raises()
  Test.raises(function()
    McpServer.command{ tool = { name = "x", inputSchema = Mcp.object_schema({}) }, argv = {}, policy = {} }
  end, "names no program")
  Test.raises(function()
    McpServer.command{ tool = { name = "x", inputSchema = Mcp.object_schema({}) }, argv = { "/x" },
      policy = { grants = { { path = "x", letters = "zz" } } } }
  end, "command: x")
  Test.raises(function()
    McpServer.command{ tool = { name = "x", inputSchema = Mcp.object_schema({}) }, argv = { "/x" },
      policy = { grants = { { path = "rel", letters = "r" } } } }
  end, "is relative")
  Test.raises(function()
    McpServer.command{ tool = { name = "x", inputSchema = Mcp.object_schema({}) }, argv = { "/x" }, policy = {},
      concurrency = 0 }
  end, "at least 1")
  Test.raises(function()
    McpServer.command{ tool = { name = "x", inputSchema = Mcp.object_schema({}) }, argv = { "/x", "a\0b" }, policy = {} }
  end, "NUL byte")
  Test.raises(function()
    McpServer.command{ tool = { name = "x", inputSchema = Mcp.object_schema({}) }, argv = { "/x" }, policy = {},
      cwd = "/tmp/../etc" }
  end, "no .. step")
end

--- A call that raises gives its place back: with room for one call, a second start fails the same way.
local function test_a_failed_start_gives_its_place_back(tmp: string)
  local work = laid_out(tmp)
  local missing = McpServer.command{ tool = { name = "gone", inputSchema = Mcp.object_schema({}) },
    argv = { work .. "/no-such-program" }, policy = { grants = { { path = work, letters = "rx" } } }, concurrency = 1 }
  for _ = 1, 2 do
    Test.raises(function()
      local _, _ = missing.call({}, bare())
    end, "did not start")
  end
end

--- Only what the client is sent must be text, and a failure's words are cut short.
local function test_what_a_tool_prints_is_held_to_text_and_a_limit(tmp: string)
  local work = laid_out(tmp)
  assert(Fs.write(work .. "/tool.tl", [[
local Fs = require("cosmic.fs")
local Stream = require("cosmic.stream")
return function(_: {string}): integer
  local text = assert(Stream.read_all(Stream.from_fd(Fs.stdin)))
  if text:find("binary", 1, true) ~= nil then
    local _, _ = Fs.put(Fs.stdout, "ok")
    local _, _ = Fs.put(Fs.stderr, "\xff\xfe")
    return 0
  end
  if text:find("long", 1, true) ~= nil then
    local _, _ = Fs.put(Fs.stderr, string.rep("x", 40000))
    return 1
  end
  local _, _ = Fs.put(Fs.stdout, string.rep("y", 300))
  return 0
end
]]))
  local quiet = called(tool(work), "binary")
  assert(quiet.isError == nil and text_of(quiet) == "ok", text_of(quiet))
  local long = called(tool(work), "long")
  assert(long.isError == true and #text_of(long) < 17000 and text_of(long):find("cut at", 1, true) ~= nil)
  local small = McpServer.command{ tool = { name = "cat", inputSchema = Mcp.object_schema({ path = { type = "string" } }) },
    argv = { (assert(Proc.executable())), work .. "/tool.tl" },
    policy = { profiles = { "cosmic" }, grants = { { path = work, letters = "rwc" } } }, cwd = work, output_limit = 100 }
  local over = called(small, "short")
  assert(over.isError == true and text_of(over):find("more than", 1, true) ~= nil, text_of(over))
end

--- The program's environment is what its policy passes on, here nothing (TMPDIR, which this test has, among it); and a program that does not start is the
--- server's failure, not words for the client.
local function test_the_program_sees_none_of_the_servers_environment(tmp: string)
  local work = laid_out(tmp)
  assert(Fs.write(work .. "/tool.tl", [[
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
return function(_: {string}): integer
  local names: mut {string} = {}
  for k in pairs(Env.all()) do names[#names + 1] = k end
  table.sort(names)
  local _, _ = Fs.put(Fs.stdout, table.concat(names, " "))
  return 0
end
]]))
  local r = called(tool(work), "x")
  -- COSMIC_STANDALONE is the program's own, set as it runs a file outside any tree.
  local seen = text_of(r):gsub("COSMIC_STANDALONE", ""):gsub("^ +", "")
  assert(r.isError == nil and seen == "", text_of(r))
  local missing = McpServer.command{ tool = { name = "gone", inputSchema = Mcp.object_schema({}) },
    argv = { work .. "/no-such-program" }, policy = { grants = { { path = work, letters = "rx" } } } }
  local troubles: mut {string} = {}
  local server = McpServer.new{ info = { name = "cmd", version = "1" }, tools = { missing },
    on_error = function(trouble: string) troubles[#troubles + 1] = trouble end }
  local said = server:answer('{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"gone","arguments":{},' ..
      '"_meta":{"io.modelcontextprotocol/protocolVersion":"' .. Mcp.VERSION .. '","io.modelcontextprotocol/clientCapabilities":{}}}}')
  local body = assert(said.body)
  assert(body:find("-32603", 1, true) ~= nil and not body:find("no-such-program", 1, true), body)
  assert(#troubles == 1 and assert(troubles[1]):find("did not start", 1, true) ~= nil, table.concat(troubles, "\n"))
end
