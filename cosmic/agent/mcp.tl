--- @public
--- The MCP servers cosmic agent reaches for the snippets its `run` tool runs ([`cosmic.agent.host`]): read from a
--- config, started on the first call to each, and ended with the session. A snippet calls a server's tool through the
--- agent, which holds the session to the server, so the worker's sandbox stays as it is.
---
--- The config is JSON, a server a key of `servers`:
---
---     {"servers": {
---       "notes": {"command": ["/usr/local/bin/notes-mcp", "--dir", "/home/me/notes"],
---                 "policy": {"grants": [{"path": "/home/me/notes", "letters": "r"}]}},
---       "docs":  {"url": "https://docs.example.com/mcp"},
---       "mine":  {"command": ["/home/me/bin/my-server"], "sandbox": "off"}
---     }}
---
--- A program is named by its absolute path, and one in the session's working directory, which the tools write, is
--- not run. A server with a `command` runs under a sandbox by default: the "system" profile, a /tmp of its own and its own
--- program, merged with the `policy` given ([`PolicyJson.decode`]'s fields: grants, connect, env, promises, ...).
--- So it reaches no file of the user's, no host and no key of the environment but those its policy names. `"sandbox":
--- "off"` runs it with the agent's rights and its whole environment, the API key too: only for a server the user
--- trusts as the agent itself. A server with a `url` is reached over Streamable HTTP from the agent. A name is
--- lower-case letters, digits and `_`, from a letter. `description` says what the server is for, which the model
--- reads.
---
--- A server's standard error is dropped. What a server answers is untrusted input, as its tools' descriptions are: the snippet and the model read it.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local type Mcp = require("cosmic.mcp")
local McpClient = require("cosmic.mcp.client")
local Poll = require("cosmic.poll")
local PolicyJson = require("cosmic.policy")
local Sandbox = require("cosmic.sandbox")
local String = require("cosmic.string")

local record AgentMcp
  --- One server of the config.
  record Server
    --- Its name, the key of `servers`.
    name: string
    --- The program and its arguments, for a server over stdio.
    command?: {string}
    --- Its endpoint, for a server over Streamable HTTP.
    url?: string
    --- What it is held to, the default merged with the config's; nil where `sandbox` is off or it has a `url`.
    policy?: Sandbox.Policy
    --- What it is for, as the config says.
    description?: string
  end

  --- The servers of a session, and the sessions to those started.
  record Set
    --- The servers, by name.
    servers: {string: Server}
    --- The names, in order.
    names: {string}
    --- Where a server's program starts: the session's working directory.
    cwd: string
    --- The session to each server started, by name.
    sessions: mut {string: McpClient.Session}
    --- The process of each server started over stdio, by name.
    handles: mut {string: Child.Handle}
    --- The servers a call is out to, by name: one still there when the next call comes was cut off (the snippet's
    --- time ran out, or the user stopped the turn), which may leave the server out of step, so it is ended.
    busy: mut {string: boolean}
    --- The last part of what each server started over stdio wrote to its standard error, by name: read while a call
    --- to it is out, and told where a call gets no answer.
    tails: mut {string: string}
  end
end

--- How long an HTTP request to a server may take.
local HTTP_TIMEOUT <const> = 120 * 1000000000

--- How many bytes of a server's standard error are kept, and how many a failure tells.
local TAIL <const> = 4096
local TOLD <const> = 1024

--- How long a server that gave no answer is read for what it wrote last.
local LAST_READ <const> = Clock.ms(100)
--- The policy a server with a command runs under, before its config's.
local function default_policy(): Sandbox.Policy
  return { profiles = { "system" }, tmp = true }
end

local KEYS <const>: {string: boolean} = { command = true, url = true, policy = true, sandbox = true, description = true }

--- The server `name` the config's `entry` says, or nil and why it says none.
local function server_of(name: string, entry: Json.Value): AgentMcp.Server?, string
  local about = "servers." .. name
  if not name:match("^[a-z][a-z0-9_]*$") then
    return nil, about .. ": a name is lower-case letters, digits and _, from a letter"
  end
  local fields, _ = Json.to_object(entry)
  if fields == nil then return nil, about .. ": want an object" end
  for key in pairs(fields) do
    if KEYS[key] ~= true then return nil, about .. ": no such key " .. Json.quote(key) end
  end
  local stated_description = fields["description"]
  local description: string? = nil
  if stated_description ~= nil then
    if not (stated_description is string) then
      return nil, about .. ".description: want a string"
    end
    description = stated_description
  end
  local command, url = fields["command"], fields["url"]
  if (command == nil) == (url == nil) then return nil, about .. ": give one of command and url" end
  if url ~= nil then
    if not (url is string) or url:sub(1, 8) ~= "https://" and url:sub(1, 7) ~= "http://" then
      return nil, about .. ".url: want an http:// or https:// URL"
    end
    if fields["policy"] ~= nil or fields["sandbox"] ~= nil then
      return nil, about .. ": a server at a url runs elsewhere, so it takes no policy and no sandbox"
    end
    return { name = name, url = url, description = description }, ""
  end
  local words, _ = Json.to_array(command)
  if words == nil or #words == 0 then
    return nil, about .. ".command: want a list of strings, the program first"
  end
  local argv: mut {string} = {}
  for _, word in ipairs(words) do
    if not (word is string) then
      return nil, about .. ".command: want a list of strings, the program first"
    end
    argv[#argv + 1] = word
  end
  local program = assert(argv[1])
  if program:sub(1, 1) ~= "/" then
    return nil, about .. ".command: the program is named by its absolute path (`command -v " .. program ..
      "` prints it), so that no directory a tool writes chooses what runs"
  end
  local sandbox = fields["sandbox"]
  if sandbox ~= nil and sandbox ~= "on" and sandbox ~= "off" then
    return nil, about .. ".sandbox: want \"on\" or \"off\""
  end
  if sandbox == "off" then
    if fields["policy"] ~= nil then
      return nil, about .. ": a server with the sandbox off takes no policy"
    end
    return { name = name, command = argv, description = description }, ""
  end
  local given = default_policy()
  local stated = fields["policy"]
  if stated ~= nil then
    local text, encode_why = Json.encode(stated)
    if text == nil then return nil, about .. ".policy: " .. tostring(encode_why) end
    local decoded, why = PolicyJson.decode(text)
    if decoded == nil then return nil, about .. ".policy: " .. why end
    given = decoded
  end
  local merged, merge_why = Sandbox.merge(default_policy(), given)
  if merged == nil then return nil, about .. ".policy: " .. merge_why end
  return { name = name, command = argv, policy = merged, description = description }, ""
end

--- The servers the config `text` names, or why it names none: a key it does not know, a name or a policy it refuses.
local function decode(text: string): ({AgentMcp.Server}) | (nil, Failure)
  local root, why = Json.decode_object(text, { null_value = Json.null })
  if root == nil then return nil, Failure.new("mcp config: " .. tostring(why)) end
  for key in pairs(root) do
    if key ~= "servers" then
      return nil, Failure.new("mcp config: no such key " .. Json.quote(key) .. ": want servers")
    end
  end
  local entries, _ = Json.to_object(root["servers"])
  if entries == nil then
    return nil, Failure.new("mcp config: servers: want an object of servers by name")
  end
  local names: mut {string} = {}
  for name in pairs(entries) do names[#names + 1] = name end
  table.sort(names)
  local servers: mut {AgentMcp.Server} = {}
  for _, name in ipairs(names) do
    local entry = entries[name]
    assert(entry ~= nil)
    local server, server_why = server_of(name, entry)
    if server == nil then return nil, Failure.new("mcp config: " .. server_why) end
    servers[#servers + 1] = server
  end
  return servers
end

--- The servers of the config at `path`, or why there are none.
function AgentMcp.load(path: string): ({AgentMcp.Server}) | (nil, Failure)
  local text, why = Fs.read(path)
  if text == nil then return nil, why end
  local servers, decode_why = decode(text)
  if servers == nil then return nil, Failure.new(path .. ": " .. tostring(decode_why)) end
  return servers
end

--- A set of `servers`, none started, whose programs start in `cwd`.
function AgentMcp.new(servers: {AgentMcp.Server}, cwd: string): AgentMcp.Set
  local by_name: mut {string: AgentMcp.Server} = {}
  local names: mut {string} = {}
  for _, server in ipairs(servers) do
    by_name[server.name] = server
    names[#names + 1] = server.name
  end
  return { servers = by_name, names = names, cwd = cwd, sessions = {}, handles = {}, busy = {}, tails = {} }
end

--- The session to the server `name` of `set`, started where none is.
local function session_of(set: AgentMcp.Set, name: string): (McpClient.Session) | (nil, Failure)
  local open = set.sessions[name]
  if open ~= nil then return open end
  local server = set.servers[name]
  if server == nil then
    return nil, Failure.new("no MCP server " .. Json.quote(name) .. (if #set.names > 0 then
      " (the servers: " .. table.concat(set.names, ", ") .. ")" else ": none is configured" end))
  end
  local url = server.url
  if url ~= nil then
    local session = McpClient.http(url, { timeout_ns = HTTP_TIMEOUT })
    set.sessions[name] = session
    return session
  end
  local argv = assert(server.command)
  local program, _ = Fs.absolute(assert(argv[1]))
  local cwd, _ = Fs.absolute(set.cwd)
  if program ~= nil and cwd ~= nil and Fs.within(program, cwd) then
    return nil, Failure.new("the MCP server " .. name .. "'s program " .. program .. " lies in the working directory, " ..
        "which the tools write: it is not run")
  end
  -- Its standard error is read while a call to it is out ([`draining`]): between calls the pipe holds what the server
  -- writes, and a server that fills it waits, as one with no call to answer may.
  local handle, why = Child.start(argv, { cwd = set.cwd, stdin = "stream", stdout = "stream", stderr = "stream",
    policy = server.policy, timeout_ns = Child.FOREVER })
  if handle == nil then
    return nil, Failure.new("starting the MCP server " .. name .. ": " .. why)
  end
  local reader, writer = handle.stdout_stream, handle.stdin_stream
  if reader == nil or writer == nil then
    local _, _ = handle:close()
    return nil, Failure.new("the MCP server " .. name .. " has no pipes")
  end
  local session = McpClient.stdio(reader, writer)
  set.sessions[name], set.handles[name], set.tails[name] = session, handle, nil
  return session
end

--- Runs `f`, reading what the server `name` of `set` writes to its standard error while it runs, its last TAIL bytes
--- kept in `set.tails`.
local function draining(set: AgentMcp.Set, name: string, f: function())
  local handle = set.handles[name]
  local reader = if handle ~= nil then handle.stderr_stream else nil end
  if reader == nil then
    f()
    return
  end
  Poll.within(function()
    local drain = Poll.spawn(function()
      while true do
        local chunk, _ = reader:read()
        if chunk == nil then return end
        local kept = (set.tails[name] or "") .. chunk
        set.tails[name] = if #kept > TAIL then kept:sub(-TAIL) else kept end
      end
    end)
    f()
    drain:cancel()
    local _, _ = drain:join()
  end)
end

--- Why a call to the server `name` of `set` got no answer, `why`, and the end of what it wrote to its standard error,
--- read a little longer: a server that ended has said why there.
local function unanswered(set: AgentMcp.Set, name: string, why: string): string
  draining(set, name, function() local _, _ = Poll.delay(LAST_READ) end)
  local tail = set.tails[name]
  if tail == nil or tail == "" then return why end
  local told = if #tail > TOLD then "..." .. tail:sub(-TOLD) else tail end
  return why .. "; the end of its standard error: " .. String.as_utf8(told)
end

--- Ends the server `name` of `set`, where it was started: a call that failed with no answer may have left it out of
--- step, and the next starts it again.
local function ended(set: AgentMcp.Set, name: string)
  local session, handle = set.sessions[name], set.handles[name]
  set.sessions[name], set.handles[name], set.busy[name], set.tails[name] = nil, nil, nil, nil
  if session ~= nil then local _, _ = session:close() end
  if handle ~= nil then local _, _ = handle:close() end
end

--- `value`, a record or a list of records the client answered, as the text of its JSON.
local function json_text(value: any): (string) | (nil, Failure)
  return Json.encode_any(value)
end

--- The tools the server `name` of `set` offers, as JSON objects: each tool's name, description, inputSchema, ...
function AgentMcp.tools(set: AgentMcp.Set, name: string): ({Json.Value}) | (nil, Failure)
  if set.busy[name] == true then ended(set, name) end
  local session, why = session_of(set, name)
  if session == nil then return nil, why end
  set.busy[name] = true
  local tools: {Mcp.Tool}? = nil
  local tools_why: Failure? = nil
  draining(set, name, function() tools, tools_why = session:tools() end)
  set.busy[name] = nil
  local listed = tools
  if listed == nil then
    local failure = assert(tools_why)
    local told = tostring(failure)
    if failure.code == nil then
      told = unanswered(set, name, told)
      ended(set, name)
    end
    return nil, Failure.new(name .. ": " .. told)
  end
  if #listed == 0 then return Json.array({}) end
  local text, text_why = json_text(listed)
  if text == nil then return nil, text_why end
  return Json.decode_array(text, { null_value = Json.null })
end

--- What the tool `tool` of the server `name` answered `arguments`, as a JSON object: its content, structuredContent
--- and isError, as the server sent them.
function AgentMcp.call(set: AgentMcp.Set, name: string, tool: string, arguments: {string: Json.Value}):
    ({string: Json.Value}) | (nil, Failure)
  if set.busy[name] == true then ended(set, name) end
  local session, why = session_of(set, name)
  if session == nil then return nil, why end
  set.busy[name] = true
  local result: Mcp.ToolResult? = nil
  local call_why: Failure? = nil
  draining(set, name, function() result, call_why = session:call(tool, arguments) end)
  set.busy[name] = nil
  local answered = result
  if answered == nil then
    local failure = assert(call_why)
    local told = tostring(failure)
    if failure.code == nil then
      told = unanswered(set, name, told)
      ended(set, name)
    end
    return nil, Failure.new(name .. "." .. tool .. ": " .. told)
  end
  local text, text_why = json_text(answered)
  if text == nil then return nil, text_why end
  return Json.decode_object(text, { null_value = Json.null })
end

--- The servers of `set`, for the model and the snippet: each one's name, how it is reached and what it is for.
function AgentMcp.listed(set: AgentMcp.Set): Json.Value
  local out: mut {Json.Value} = {}
  for _, name in ipairs(set.names) do
    local server = assert(set.servers[name])
    local row: mut {string: Json.Value} = { name = name }
    if server.description ~= nil then row["description"] = server.description end
    row["reached"] = if server.url ~= nil then "http" elseif server.policy ~= nil then "sandboxed" else "unsandboxed" end
    out[#out + 1] = row
  end
  return Json.array(out)
end

--- Ends every server of `set` that was started.
function AgentMcp.close(set: AgentMcp.Set)
  local started: mut {string} = {}
  for name in pairs(set.sessions) do started[#started + 1] = name end
  for _, name in ipairs(started) do ended(set, name) end
end

return AgentMcp
