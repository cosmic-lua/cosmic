--- `cosmic mcp`: asks a Model Context Protocol server ([`cosmic.mcp.client`]) what it offers, or has it run a tool,
--- read a resource or fill a prompt, and prints the answer as one line of JSON.
---
--- THE SERVER is a program this starts and speaks to over its stdin and stdout, every word after `--` (a `.tl` file
--- first is run by this program, as `cosmic <file.tl>` runs one), or one at `--url`, over Streamable HTTP, with the
--- bearer token in the environment variable `--token-env` names (never on the command line, where `ps` shows it),
--- sent over plain `http://` only to a loopback host. `--timeout` bounds each request over HTTP, and a program's
--- whole run, its process group ended with it. A word of the action that starts with `-` is read as an option.
--- A program's stderr is this one's. A server written with [`cosmic.mcp.server`] serves either way through
--- [`McpServer.Instance.main`].
---
--- THE ACTIONS: `discover` (what the server is), `tools`, `resources`, `templates` and `prompts` (each list, all its
--- pages), `call <tool> [json]` (the arguments a JSON object), `read <uri>`, and `prompt <name> [json]` (the
--- arguments an object of strings). What each prints is the protocol's own JSON for it: a tool's result as
--- `tools/call` answers it, say.
---
--- Like `cosmic json` it prints no summary. Exit 0 is ok, 1 a server that failed or refused, or a tool's result
--- that is an error, 2 a command line it refuses or a write that failed. Complaints go to standard error as
--- `cosmic: mcp: ...`. Its `spec` (build/verb_spec.tl) is `bare`.

local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Failure = require("cosmic.failure")
local Flags = require("cosmic.flags")
local Json = require("cosmic.json")
local McpClient = require("cosmic.mcp.client")
local McpJson = require("cosmic.mcp.json")
local Net = require("cosmic.net")
local Proc = require("cosmic.proc")
local String = require("cosmic.string")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic mcp` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec
  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes to standard output, as given. False and why when the bytes did not all go.
    out: function(text: string): boolean, string
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- An environment variable's value, nil when it is not set.
    env: function(name: string): string?
  end
end

local spec = assert(assert(Cli.verbs["mcp"]).spec)

local usage = "cosmic mcp <discover|tools|resources|templates|prompts|call <tool> [json]|read <uri>|" ..
  "prompt <name> [json]> [--url URL [--token-env NAME]] [--timeout seconds] [-- program args...]"

--- How many words each action takes after its name: the least and the most.
local ACTIONS <const>: {string: {integer}} = {
  discover = { 0, 0 }, tools = { 0, 0 }, resources = { 0, 0 }, templates = { 0, 0 }, prompts = { 0, 0 },
  call = { 1, 2 }, read = { 1, 1 }, prompt = { 1, 2 },
}

--- What the command line asks for.
local record Request
  action: string
  words: {string}
  url?: string
  token_env?: string
  mut timeout_ns: integer
  mut program?: {string}
end

--- The slot of the server's program in `argv` (the verb at slot 1): the word after the first `--`, nil when there
--- is none. The words from it on are the program's own.
function verb.program_slot(argv: {string}): integer?
  local slot = 2
  while argv[slot] ~= nil do
    if argv[slot] == "--" then
      if argv[slot + 1] ~= nil then return slot + 1 end
      return nil
    end
    slot = slot + 1
  end
  return nil
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {string}): Request?, string
  local at = verb.program_slot(argv)
  local mine: mut {string} = {}
  for slot = 2, #argv do
    if argv[slot] == "--" then break end
    mine[#mine + 1] = argv[slot]
  end
  local parsed, trouble = Flags.parse(mine, 1, spec)
  if parsed == nil then return nil, trouble end
  local action = parsed.words[1]
  if action == nil then return nil, "name an action" end
  local counts = ACTIONS[action]
  if counts == nil then return nil, action .. " is no action" end
  local words: mut {string} = {}
  for slot, word in ipairs(parsed.words) do
    if slot > 1 then words[#words + 1] = word end
  end
  local least, most = assert(counts[1]), assert(counts[2])
  if #words < least or #words > most then
    local wanted = if least == most then String.counted(least, "word") else
      ("%d or %s"):format(least, String.counted(most, "word")) end
    return nil, action .. " takes " .. wanted .. " after it, not " .. tostring(#words)
  end
  local request: Request = { action = action, words = words, url = parsed.values["--url"],
    token_env = parsed.values["--token-env"], timeout_ns = Clock.seconds(30) }
  local timeout = parsed.values["--timeout"]
  if timeout ~= nil then
    local seconds = tonumber(timeout)
    if seconds == nil or not timeout:match("^%d+%.?%d*$") or seconds <= 0 or seconds > 86400 then
      return nil, "--timeout takes seconds, above 0 and at most 86400, not " .. timeout
    end
    request.timeout_ns = Clock.seconds(seconds)
  end
  if at ~= nil then
    local program: mut {string} = {}
    for slot, word in ipairs(argv) do
      if slot >= at then program[#program + 1] = word end
    end
    request.program = program
  end
  local url = request.url
  if url ~= nil and url:match("^%a[%w+.-]*://[^/?#]*@") ~= nil then
    return nil, "--url holds credentials, which a complaint would print: give the token by --token-env"
  end
  if request.url ~= nil and request.program ~= nil then
    return nil, "--url and a program are two servers: give one"
  elseif request.url == nil and request.program == nil then
    return nil, "name the server: --url URL, or a program after --"
  elseif request.token_env ~= nil and request.url == nil then
    return nil, "--token-env is for --url"
  end
  return request, ""
end

--- `text` as a JSON object, or nil and why.
local function object_of(text: string, what: string): ({string: Json.Value}) | (nil, Failure)
  local value, why = Json.decode_object(text)
  if value == nil then
    return nil, Failure.new(what .. " must be a JSON object: " .. tostring(why))
  end
  return value
end

--- The session `request` names, or nil and why.
local function session_of(to: verb.Io, request: Request): (McpClient.Session) | (nil, Failure)
  local url = request.url
  if url ~= nil then
    local headers: mut {string: string} = {}
    local name = request.token_env
    if name ~= nil then
      local host = url:match("^[Hh][Tt][Tt][Pp]://%[([^%]]+)%]") or url:match("^[Hh][Tt][Tt][Pp]://([^/:?#]+)")
      if host ~= nil and not Net.is_loopback(host) then
        return nil, Failure.new("--token-env sends the token in the clear over http:// to " .. host ..
            ": use https://, or a loopback host")
      end
      local token = to.env(name)
      if token == nil or token == "" then
        return nil, Failure.new("--token-env " .. name .. ": $" .. name .. " is not set")
      end
      headers["Authorization"] = "Bearer " .. token
    end
    return McpClient.http(url, { timeout_ns = request.timeout_ns, headers = headers })
  end
  local program = assert(request.program)
  local argv: mut {string} = {}
  local env: mut {string: string} = Env.all()
  local fds: mut {integer: integer | string} = {}
  local first = assert(program[1])
  if first:match("%.tl$") then
    local relaunch, _ = Proc.relaunch()
    if relaunch ~= nil then
      for _, word in ipairs(relaunch.argv) do argv[#argv + 1] = word end
      for k, v in pairs(relaunch.env) do env[k] = v end
      for number, fd in pairs(relaunch.fds) do fds[number] = fd end
    else
      local exe, why = Proc.executable()
      if exe == nil then
        return nil, Failure.new("finding this program to run " .. first .. ": " .. tostring(why))
      end
      argv[1] = exe
    end
  end
  for _, word in ipairs(program) do argv[#argv + 1] = word end
  return McpClient.spawn(argv, { env = env, fds = fds, stderr = "inherit", process_group = true,
    timeout_ns = request.timeout_ns })
end

--- What `request`'s action answers from `session`: the JSON to print, whether it is a tool's error, or nil and why.
local function asked(session: McpClient.Session, request: Request): (Json.Value, boolean) | (nil, Failure)
  local action, words = request.action, request.words
  if action == "discover" then
    local d, why = session:discover()
    if d == nil then return nil, why end
    return McpJson.discovery(d), false
  elseif action == "tools" then
    local tools, why = session:tools()
    if tools == nil then return nil, why end
    return McpJson.list(tools, McpJson.tool), false
  elseif action == "resources" then
    local resources, why = session:resources()
    if resources == nil then return nil, why end
    return McpJson.list(resources, McpJson.resource), false
  elseif action == "templates" then
    local templates, why = session:templates()
    if templates == nil then return nil, why end
    return McpJson.list(templates, McpJson.template), false
  elseif action == "prompts" then
    local prompts, why = session:prompts()
    if prompts == nil then return nil, why end
    return McpJson.list(prompts, McpJson.prompt), false
  elseif action == "read" then
    local contents, why = session:read(assert(words[1]))
    if contents == nil then return nil, why end
    return McpJson.list(contents, McpJson.contents), false
  elseif action == "call" then
    local args: {string: Json.Value} = {}
    local given = words[2]
    if given ~= nil then
      local object, bad = object_of(given, "the arguments")
      if object == nil then return nil, bad end
      args = object
    end
    local result, why = session:call(assert(words[1]), args)
    if result == nil then return nil, why end
    return McpJson.tool_result(result), result.isError == true
  end
  local args: mut {string: string} = {}
  local given = words[2]
  if given ~= nil then
    local object, bad = object_of(given, "the arguments")
    if object == nil then return nil, bad end
    for k, v in pairs(object) do
      if not v is string then
        return nil, Failure.new("the prompt's argument " .. k .. " must be a string")
      end
      args[k] = v
    end
  end
  local result, why = session:prompt(assert(words[1]), args)
  if result == nil then return nil, why end
  return McpJson.prompt_result(result), false
end

local standard: verb.Io = { out = bare.out, err = bare.err, env = Env.get }

--- `cosmic mcp <action> ...`: asks the server and prints its answer, and returns the exit code: 0 ok, 1 a server
--- that failed or refused or a tool's error, 2 a command line it refuses or a write that failed.
--- @param argv the command line, `mcp` at slot 1
--- @param io where text is written and the environment read; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("mcp", to.err)
  local found, trouble = arguments(argv)
  if found == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  local request: Request = found
  local session, failed = session_of(to, request)
  if session == nil then
    complain((tostring(failed):gsub("^mcp: ", "")))
    return bare.failed
  end
  local value, flag_or_why = asked(session, request)
  local closed, close_why = session:close()
  if value == nil then
    complain((tostring(flag_or_why):gsub("^mcp: ", "")))
    if not closed then complain((tostring(close_why):gsub("^mcp: ", ""))) end
    return bare.failed
  end
  local tool_error = flag_or_why == true
  local text, bad = Json.encode(value)
  if text == nil then
    complain("the answer cannot be printed as JSON: " .. tostring(bad))
    return bare.failed
  end
  local written = bare.written(complain, to.out(text .. "\n"))
  if written ~= bare.ok then return written end
  if not closed then
    complain(tostring(close_why))
    return bare.failed
  end
  return if tool_error then bare.failed else bare.ok end
end

--- The `mcp` verb as [`build/verb_list.tl`] lists it. It reads no tree, so it is never stale-checked.
verb.spec = {
  name = "mcp",
  guide = "more quick tools",
  tests = { "build.mcp_test", "build.mcp_tool_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  program_slot = verb.program_slot,
  takes = "an action and its words, then the server",
  exits = "`mcp` prints the server's answer as one line of JSON, and nothing after; it exits 1 when the server failed or refused, or a tool's result is an error, 2 when it refuses its command line or a write fails.",
  passthrough = "its output is data for a pipe, so its exit status is the verdict (build/mcp_test.tl)",
}

return verb
