# MCP servers and clients

<!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->

The Model Context Protocol (MCP) lets a program offer tools, resources and
prompts to a model's host, and lets a host ask for them. [`cosmic.mcp.server`]
serves the protocol and [`cosmic.mcp.client`] asks it, over stdio or
Streamable HTTP. Both speak revision 2026-07-28 only. That revision is
stateless: there is no `initialize` and no session, and each request names
its version and the client's capabilities in its `_meta`.

This guide builds `notes`, a server that keeps short notes, tests it, asks it
from the shell, and then shows a sandboxed tool and a server behind OAuth.

## a server

A server is a spec given to [`McpServer.new`]. A tool is its listing and a
handler. The server checks the arguments against the tool's `inputSchema`
before the handler runs, so the handler can trust them. A tool with an
`outputSchema` returns [`Mcp.structured`], and the server checks that
too. A resource template names a family of resources, and `read` reads one
of them by its URI. A prompt fills in messages from its arguments, and
`complete` suggests values for an argument while a person types it.

```teal file=notes.tl
--- An MCP server of notes: a tool to add one and a tool to count them, each note a resource, and a prompt that
--- completes its argument.

local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local McpServer = require("cosmic.mcp.server")

local record Notes
  --- A server that keeps its notes in memory, for as long as it runs.
  new: function(): McpServer.Instance
end

local STYLES <const>: {string} = { "brief", "bullets", "detailed" }

function Notes.new(): McpServer.Instance
  local notes: mut {string} = {}
  return McpServer.new{
    info = { name = "notes", version = "1.0.0" },
    instructions = "Keeps short notes. Add one with add_note.",
    tools = {
      {
        tool = {
          name = "add_note",
          description = "Adds a note and returns its number.",
          inputSchema = Mcp.object_schema({ text = { type = "string", minLength = 1 } }, { "text" }),
          outputSchema = Mcp.object_schema({ id = { type = "integer" } }, { "id" }),
        },
        call = function(args: {string: Json.Value}, _: McpServer.Call): (Mcp.ToolResult) | (nil, Failure)
          -- The schema holds: text is a string by now.
          local text = tostring(args["text"])
          notes[#notes + 1] = text
          return Mcp.structured({ id = #notes })
        end,
      },
      {
        tool = { name = "count", description = "How many notes there are.", inputSchema = Mcp.object_schema({}) },
        call = function(_: {string: Json.Value}, _: McpServer.Call): (Mcp.ToolResult) | (nil, Failure)
          return Mcp.result({ tostring(#notes) })
        end,
      },
    },
    templates = { { uriTemplate = "note://{id}", name = "note", mimeType = "text/plain" } },
    read = function(uri: string, _: McpServer.Call): ({Mcp.ResourceContents} | false) | (nil, Failure)
      local id = math.tointeger(tonumber(uri:match("^note://(%d+)$")))
      local text = if id ~= nil then notes[id] else nil end
      if text == nil then return false end
      return { { uri = uri, mimeType = "text/plain", text = text } }
    end,
    prompts = { {
      prompt = { name = "summarize", description = "Summarize the notes.",
        arguments = { { name = "style", description = "brief, bullets or detailed" } } },
      get = function(args: {string: string}, _: McpServer.Call): (Mcp.PromptResult) | (nil, Failure)
        local text = "Summarize these notes, " .. (args["style"] or "brief") .. ":\n" .. table.concat(notes, "\n")
        return { messages = { { role = "user", content = Mcp.text(text) } } }
      end,
    } },
    complete = function(asked: Mcp.Completing, _: McpServer.Call): (Mcp.Completion) | (nil, Failure)
      local fits: mut {string} = {}
      for _, style in ipairs(STYLES) do
        if style:sub(1, #asked.value) == asked.value then fits[#fits + 1] = style end
      end
      return { values = fits }
    end,
  }
end

return Notes
```

The program's main serves the server: [`McpServer.Instance.main`] serves
stdio. `--http host:port` serves Streamable HTTP instead, with
`--token-env NAME` naming the variable that holds the bearer token each
request must carry (or `--anyone`, on a loopback host only).

```teal file=main.tl
local Notes = require("notes")

return function(argv: {string}): integer
  return Notes.new():main(argv)
end
```

## test it

[`McpServer.Instance.answer`] takes one message as text and returns the
reply, with no stdio and no HTTP. A test sends it requests as a client would, each with its
`_meta`, and reads the JSON that comes back.

```teal file=notes_test.tl
local Json = require("cosmic.json")
local McpServer = require("cosmic.mcp.server")
local Notes = require("notes")

--- The request `method` with `params`, as a client of revision 2026-07-28 sends it.
local function request(method: string, params: {string: Json.Value}): string
  local none: {string: Json.Value} = {}
  local with: mut {string: Json.Value} = { _meta = {
    ["io.modelcontextprotocol/protocolVersion"] = "2026-07-28",
    ["io.modelcontextprotocol/clientCapabilities"] = none,
  } }
  for k, v in pairs(params) do with[k] = v end
  return assert(Json.encode({ jsonrpc = "2.0", id = 1, method = method, params = with }))
end

--- The result the server returns for `method`.
local function result(server: McpServer.Instance, method: string, params: {string: Json.Value}): {string: Json.Value}
  local said = assert(Json.decode_object(assert(server:answer(request(method, params)).body)))
  local got = assert(Json.object_of(said["result"]), tostring(said["error"]))
  return got
end

local function test_a_note_added_is_read_back()
  local server = Notes.new()
  local added = result(server, "tools/call", { name = "add_note", arguments = { text = "milk" } })
  assert(assert(Json.object_of(added["structuredContent"]))["id"] == 1)
  local read = result(server, "resources/read", { uri = "note://1" })
  local first = assert(Json.object_of(assert(Json.array_of(read["contents"]))[1]))
  assert(first["text"] == "milk")
end

local function test_a_style_is_completed()
  local done = result(Notes.new(), "completion/complete",
    { ref = { type = "ref/prompt", name = "summarize" }, argument = { name = "style", value = "b" } })
  local values = assert(Json.array_of(assert(Json.object_of(done["completion"]))["values"]))
  assert(#values == 2 and values[1] == "brief" and values[2] == "bullets")
end
```

## ask it from the shell

`cosmic test` runs the tests. `cosmic mcp` starts the program after `--`,
asks it one thing over stdio, and prints the reply as one line of JSON:

```text
cosmic test
cosmic mcp call add_note '{"text":"milk"}' -- main.tl
cosmic mcp prompts -- main.tl
cosmic mcp call add_note '{"text":""}' -- main.tl
```

The server keeps its notes only while it runs, so each command starts with
none. Arguments that do not hold to the schema are an error result, the
handler is not called, and the command exits 1. The next block runs those
commands through [`cosmic.child`] and prints what each says.

```teal
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Proc = require("cosmic.proc")

local relaunch = assert(Proc.relaunch())
local env = Env.all()
for name, value in pairs(relaunch.env) do env[name] = value end
env["COSMIC_TEST_SANDBOX"] = "0"
local function cosmic(...: string): Child.Result
  local argv = { table.unpack(relaunch.argv) }
  for _, word in ipairs({ ... }) do argv[#argv + 1] = word end
  local ran = assert(Child.run(argv, { env = env, fds = relaunch.fds, cwd = tmp, stdout = "capture",
    stderr = "capture", timeout_ns = Clock.seconds(120) }))
  return ran
end
print((cosmic("test").stdout or ""):match("test: %d+ tests? passed"))
print(cosmic("mcp", "call", "add_note", '{"text":"milk"}', "--", "main.tl").stdout)
print(cosmic("mcp", "prompts", "--", "main.tl").stdout)
local refused = cosmic("mcp", "call", "add_note", '{"text":""}', "--", "main.tl")
print(refused.code, refused.stdout)
```

```output
test: 2 tests passed
{"content":[{"text":"{\"id\":1}","type":"text"}],"structuredContent":{"id":1}}

[{"arguments":[{"description":"brief, bullets or detailed","name":"style"}],"description":"Summarize the notes.","name":"summarize"}]

1	{"content":[{"text":"the arguments do not hold to the tool's inputSchema: /text: the string is shorter than 1 (minLength)","type":"text"}],"isError":true}

```

## ask it from a program

[`McpClient.spawn`] starts a server and speaks to it over stdio. Each method
returns its result, or nil and a [`Failure`]. A refusal from the server
carries its JSON-RPC code in `code`.

```teal
local Clock = require("cosmic.clock")
local McpClient = require("cosmic.mcp.client")

local session = assert(McpClient.spawn({ "cosmic", "main.tl" }, { timeout_ns = Clock.seconds(30) }))
local added = assert(session:call("add_note", { text = "milk" }))
assert(added.isError ~= true)
local styles = assert(session:complete({ prompt = "summarize", argument = "style", value = "d" }))
assert(styles.values[1] == "detailed")
assert(session:close())
```

## a tool in a sandbox

[`McpServer.command`] makes a tool of a program. The program reads the
call's arguments, a JSON object, on stdin, and what it prints is the
result. It runs under a sandbox policy: what the policy does not grant, the
program cannot reach, the server's files, sockets and environment among
them. The `system` profile grants the host's programs and libraries,
and the few files under /etc a libc reads to start (passwd and group among
them). A call that runs past its time, or writes too much, is an
error result.

```teal
local Mcp = require("cosmic.mcp")
local McpServer = require("cosmic.mcp.server")

local word_count = McpServer.command{
  tool = {
    name = "word_count",
    description = "Counts the words of the call's arguments, as JSON.",
    inputSchema = Mcp.object_schema({ text = { type = "string" } }, { "text" }),
  },
  argv = { "/usr/bin/wc", "-w" },
  policy = { profiles = { "system" } },
}
local server = McpServer.new{ info = { name = "words", version = "1" }, tools = { word_count } }
assert(server:serve_stdio())
```

## over HTTP, behind OAuth

[`McpServer.Instance.handler`] serves the endpoint under
[`cosmic.http.server`]. With `oauth`, the endpoint is an OAuth 2.1 resource
server: a request needs an access token that `verify` takes, and one with
none gets HTTP 401 with a challenge that says where the authorization
server is. [`McpServer.jwt`] takes a JWT access token only when the
authorization server's keys signed it, its `iss` is that server, its `aud`
holds this endpoint, its `typ` is `at+jwt`, and it is within its time: a
token for another server is refused. The endpoint here listens on
loopback behind a proxy that ends TLS for `https://notes.example.com`. A tool's `scopes` are the scopes a call of it
needs; a token without them gets HTTP 403, and the client signs in again
for them.

```teal
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local HttpServer = require("cosmic.http.server")
local Jose = require("cosmic.jose")
local Json = require("cosmic.json")
local Mcp = require("cosmic.mcp")
local McpServer = require("cosmic.mcp.server")
local Net = require("cosmic.net")

-- The authorization server's JWKS, as its jwks_uri serves it.
local jwks = assert(Json.decode_object(assert(Fs.read("jwks.json"))))
local server = McpServer.new{ info = { name = "notes", version = "1" }, tools = { {
  tool = { name = "count", inputSchema = Mcp.object_schema({}) },
  scopes = { "notes:read" },
  call = function(_: {string: Json.Value}, call: McpServer.Call): (Mcp.ToolResult) | (nil, Failure)
    return Mcp.result({ "no notes yet for " .. assert(call.grant).subject })
  end,
} } }
local handle = server:handler{ oauth = {
  resource = "https://notes.example.com/mcp",
  authorization_servers = { "https://auth.example.com" },
  scopes = { "notes:read" },
  verify = McpServer.jwt{ issuer = "https://auth.example.com", keys = assert(Jose.keys(jwks)) },
} }
assert(HttpServer.serve{ listeners = { Net.tcp("127.0.0.1", 8080) }, handle = handle })
```

A client of such an endpoint names its OAuth client id, and how to show a
person the authorization URL. It finds the authorization server from the
401, signs in with PKCE and a redirect to its own listener on 127.0.0.1,
sends the token only to this endpoint, and refreshes it when it is
refused. When the refreshed token is refused too, it signs in again.

```teal
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local McpClient = require("cosmic.mcp.client")

local session = McpClient.http("https://notes.example.com/mcp", { timeout_ns = Clock.seconds(30), oauth = {
  client_id = "notes-desktop",
  open = function(url: string): (true) | (false, Failure)
    print("sign in at " .. url)
    return true
  end,
} })
local count, why = session:call("count")
assert(count ~= nil, tostring(why))
```

## what is left out

Revision 2026-07-28 deprecates sampling, roots and logging, so cosmic has
none of them. Elicitation is there: a handler asks the person for input with
`call.elicit`, and the client replies through its `elicit` option.

[`cosmic.child`]: ../../cosmic/child.tl
[`cosmic.http.server`]: ../../cosmic/http/server.tl
[`cosmic.mcp.client`]: ../../cosmic/mcp/client.tl
[`cosmic.mcp.server`]: ../../cosmic/mcp/server.tl
[`Failure`]: ../../cosmic/failure.tl
[`Mcp.structured`]: ../../cosmic/mcp/init.tl
[`McpClient.spawn`]: ../../cosmic/mcp/client.tl
[`McpServer.command`]: ../../cosmic/mcp/server.tl
[`McpServer.Instance.answer`]: ../../cosmic/mcp/server.tl
[`McpServer.Instance.handler`]: ../../cosmic/mcp/server.tl
[`McpServer.Instance.main`]: ../../cosmic/mcp/server.tl
[`McpServer.jwt`]: ../../cosmic/mcp/server.tl
[`McpServer.new`]: ../../cosmic/mcp/server.tl
