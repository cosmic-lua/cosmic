--- `cosmic agent worker`: the process that runs cosmic agent's `run` tool. The agent starts one a session, under the
--- sandbox its tools are held to, when the model first calls `run`, and sends it one snippet of Teal after another. It
--- checks each with a checker that lives as long as it does ([`Pipeline.kept_alone`]), so what a snippet lowers of the
--- standard library is not lowered again for the next, and runs the snippet only where the checker passes it: a snippet
--- is checked as `cosmic -e` checks a chunk, and reaches only `cosmic.*`.
---
--- It reads requests, one JSON object a line, on standard input, and responds to each with one response line on standard output:
---
---     {"id":1,"code":"print(1)"}
---     {"id":1,"ok":true,"output":"1\n"}
---
--- A response line holds the request's `id` and one of:
---
---     "refused": ["run.tl:1:7: ..."]   the checker's lines; the snippet did not run
---     "ok": true, "output": "..."      it ran: what it wrote to standard output and
---                                      standard error, together; "value", the JSON
---                                      of what it returned, where it returned one
---     "ok": false, "output", "error"   it raised `error`, after writing `output`
---     "error": "..."                   the request could not be read
---
--- "output" is at most 64KB, its last part, as UTF-8 (a byte that begins no character is U+FFFD), and "cut": true
--- says where more was written; "value" is at most 64KB of JSON, and a note where it is more. A snippet sets no
--- global, which the checker refuses; what it keeps for the next it keeps with Host.store, or writes to a file. It ends at the end of standard
--- input.
---
--- While a snippet runs, each call it makes of the agent ([`cosmic.agent.host`]) goes out as a line too, the request's
--- `id` beside `call`, `call_id` and `args`, and the snippet waits for the line in with that `call_id`:
--- `{"call_id":1,"reply":...}`, or `{"call_id":1,"failed":"..."}`.
---
--- A snippet that requires `mcp.<server>` gets the module of that MCP server's tools ([`cosmic.agent.mcp_module`]): at
--- the first snippet that requires it, the worker asks the agent for the server's tools, and the checker reads the
--- module's types from then on. A server whose tools cannot be listed refuses the snippet.

local Driver = require("build.driver")
local Failure = require("cosmic.failure")
local Fs = require("cosmic.fs")
local Host = require("cosmic.agent.host")
local Json = require("cosmic.json")
local McpModule = require("cosmic.agent.mcp_module")
local Pipeline = require("build.pipeline")
local Poll = require("cosmic.poll")
local Worker = require("cosmic.agent.worker")
local String = require("cosmic.string")
local standalone = require("build.standalone")
local sys = require("cosmic.sys")

local record worker
  --- `cosmic agent worker`: responds to requests on standard input until it ends. 0 at its end, 1 where it could not start.
  main: function(): integer
end

--- A response line, as it is sent.
local type Answer = {string: Json.Value}

--- Where a snippet's output goes while it runs.
local record Capture
  --- Runs `f` with descriptors 1 and 2 pointed at the agent's output pipe, between the marks of the request `id`
  --- ([`Worker.mark`]): what `f` returns.
  run: function(Capture, id: integer, f: function(): Answer): Answer
end

--- The most bytes of the JSON of what a snippet returned a response line holds: well within the line of 1MB the agent reads a
--- response line in, escaped.
local MAX_OUTPUT <const> = Worker.OUTPUT_BYTES

--- The name each snippet is checked and run as.
local SNIPPET <const> = "run.tl"

local function failed(id: Json.Value, why: string): Answer
  return { id = id, error = why }
end

--- What a snippet returned, as a response line holds it: its JSON where that is within MAX_OUTPUT, else its text, cut.
local function value_of(value: any): Json.Value
  local text, _ = Json.encode_any(value)
  if text ~= nil and #text <= MAX_OUTPUT then
    local decoded, _ = Json.decode(text, { null_value = Json.null })
    if decoded ~= nil then return decoded end
  end
  local shown = String.as_utf8(tostring(value))
  if text ~= nil and #text > MAX_OUTPUT then
    return "(" .. String.counted(#text, "byte") .. " of JSON, more than an answer holds: write it to a file)"
  end
  return Worker.tail(shown)
end

--- The lines between the worker and the agent: the requests and the replies to calls come in on `input`, a line each,
--- and the response lines and calls go out on `out`.
local record Channel
  input: integer
  out: integer
  --- What was read of `input` past the last line taken.
  mut pending: string
  --- The id of the request whose snippet runs, which each of its calls carries.
  mut id: Json.Value
  --- The id the next call is sent with, which its reply carries.
  mut next_call: integer
  --- The replies read for calls that wait, by their call's id; one for a call that was cancelled stays until the next
  --- request.
  mut replies: mut {integer: {string: Json.Value}}
  --- Whether a call reads the input for all that wait: one reads at a time.
  mut reading: boolean
  --- Why the input can be read no more, once it cannot.
  mut ended?: string
  --- What the calls that wait wait on, in tasks of a run ([`Poll.notifier`]): nil once none waits, so that each run
  --- makes its own. A task closed as it waits (another task of its run raised) leaves it, and `reading`, as they are,
  --- until the next request starts them anew.
  mut arrived?: Poll.Notifier
  --- How many calls wait for their replies.
  mut waiting: integer
end

--- The most bytes of a call's line: well within the line of 1MB the agent reads.
local MAX_CALL <const> = 512 * 1024

--- The next line of `channel`'s input, nil at its end.
local function line_of(channel: Channel): string?
  while true do
    local nl = channel.pending:find("\n", 1, true)
    if nl ~= nil then
      local line = channel.pending:sub(1, nl - 1)
      channel.pending = channel.pending:sub(nl + 1)
      return line
    end
    local chunk, _ = Fs.take(channel.input, 65536)
    if chunk == nil or chunk == "" then return nil end
    channel.pending = channel.pending .. chunk
  end
end

--- The reply to the call `call` on `channel`, or why there is none. One waiting call reads the input at a time, and
--- hands each reply it reads to the call it is for; in a task of a run ([`Poll.run`]) it waits for the input as a
--- task, so the other tasks send their calls meanwhile, and those wait to be woken.
local function reply_of(channel: Channel, call: integer): ({string: Json.Value}) | (nil, string)
  while true do
    local got = channel.replies[call]
    if got ~= nil then
      channel.replies[call] = nil
      return got
    end
    local ended = channel.ended
    if ended ~= nil then return nil, ended end
    local arrived = channel.arrived
    if channel.reading and arrived ~= nil then
      local woken, why = arrived:wait()
      if not woken then return nil, tostring(why) end
    else
      channel.reading = true
      -- In a task, each read waits for the input as a task, so that a long reply stalls no other task.
      if Poll.in_task() then
        while channel.pending:find("\n", 1, true) == nil do
          local ready, why = Poll.readable(channel.input)
          if not ready then
            -- A cancelled reader hands the reading on.
            channel.reading = false
            if arrived ~= nil then arrived:notify_all() end
            return nil, tostring(why)
          end
          local chunk, _ = Fs.take(channel.input, 65536)
          if chunk == nil or chunk == "" then break end
          channel.pending = channel.pending .. chunk
        end
      end
      local line = line_of(channel)
      channel.reading = false
      if line == nil then
        channel.ended = "the agent ended"
      else
        local reply, reply_why = Json.decode_object(line, { null_value = Json.null })
        local id = if reply ~= nil then reply["call_id"] else nil end
        if reply == nil or not (id is integer) then
          channel.ended = "the agent's reply is no JSON object of a call's id: " .. tostring(reply_why)
        else
          channel.replies[id] = reply
        end
      end
      if arrived ~= nil then arrived:notify_all() end
    end
  end
end

--- How a snippet's calls ([`cosmic.agent.host`]) reach the agent on `channel`: a line `{"id":1,"call":"history",
--- "call_id":1,"args":{...}}` out, and the reply, `{"call_id":1,"reply":...}` or `{"call_id":1,"failed":"..."}`, in.
--- Calls made from tasks of one run ([`Poll.run`]) are out at once, and the agent replies to each as it can.
local function transport_of(channel: Channel): Host.Transport
  return function(name: string, args: Json.Value): (Json.Value) | (nil, Failure)
    local call = channel.next_call
    channel.next_call = call + 1
    if Poll.in_task() and channel.arrived == nil then channel.arrived = Poll.notifier() end
    local text, why = Json.encode({ id = channel.id, call = name, call_id = call, args = args })
    if text == nil then return nil, Failure.new("host: " .. name .. ": " .. tostring(why)) end
    if #text > MAX_CALL then
      return nil, Failure.new("host: " .. name .. ": the call is " .. String.counted(#text, "byte") ..
          ", more than the " .. String.counted(MAX_CALL, "byte") .. " a call may be")
    end
    local sent, _ = Fs.put(channel.out, text .. "\n")
    if not sent then
      return nil, Failure.new("host: " .. name .. ": the agent cannot be reached")
    end
    channel.waiting = channel.waiting + 1
    local reply, reply_why = reply_of(channel, call)
    channel.waiting = channel.waiting - 1
    if channel.waiting == 0 then channel.arrived = nil end
    if reply == nil then return nil, Failure.new("host: " .. name .. ": " .. reply_why) end
    local trouble = reply["failed"]
    if trouble ~= nil then
      return nil, Failure.new("host: " .. name .. ": " .. tostring(trouble))
    end
    local value = reply["reply"]
    if value == nil then return Json.null end
    return value
  end
end

--- The module of each MCP server a snippet required, by its name ("mcp.notes"): the Teal the checker reads of it, and
--- the table `require` returns.
local record Modules
  teal: mut {string: string}
  values: mut {string: {string: Call}}
end

--- A function of an MCP server's module, as it runs: what the snippet's checker reads as the tool's own types.
local type Call = function(arguments?: {string: Json.Value}): Json.Value

--- `result` as the table a snippet reads as a [`Host.Result`].
local function result_value(result: Host.Result): Json.Value
  local content: mut {Json.Value} = {}
  for i, block in ipairs(result.content) do content[i] = block end
  local out: mut {string: Json.Value} = { text = result.text, content = Json.array(content) }
  local structured = result.structured
  if structured ~= nil then out["structured"] = structured end
  return out
end

--- `arguments` as `input`, a tool's schema, says to send them ([`McpModule.shaped`]).
local function sent_as(input: {string: Json.Value}, arguments?: {string: Json.Value}): {string: Json.Value}?
  if arguments == nil then return nil end
  return Json.object_of(McpModule.shaped(input, arguments)) or arguments
end

--- The table of the functions of `made`, each calling its tool of `server`.
local function value_of_module(server: string, made: McpModule.Made): {string: Call}
  local out: mut {string: Call} = {}
  for _, f in ipairs(made.functions) do
    local tool, input = f.tool, f.input
    if f.structured then
      out[f.name] = function(arguments?: {string: Json.Value}): Json.Value
        return Host.structured(server, tool, sent_as(input, arguments))
      end
    else
      out[f.name] = function(arguments?: {string: Json.Value}): Json.Value
        local result: Host.Result = { text = "", content = {} }
        local ok, why = pcall(function()
          result = Host.tool(server, tool, sent_as(input, arguments))
        end)
        -- Raised again, the failure names the snippet's line, not this file's.
        if not ok then error((tostring(why):gsub("^[^:\n]+:%d+: ", "")), 2) end
        return result_value(result)
      end
    end
  end
  return out
end

--- Makes the module of each MCP server `code` requires that `modules` lacks ([`cosmic.agent.mcp_module`]), of the tools
--- the server lists now, so the snippet's `require` returns it. Returns nil, or the line of why a server's could not be made, which
--- refuses the snippet.
local function provide(modules: Modules, code: string): string?
  for server in code:gmatch("require%s*%(?%s*[\"']mcp%.([%w_]+)[\"']") do
    local module = "mcp." .. server
    if modules.teal[module] == nil then
      local tools: {{string: Json.Value}} = {}
      local listed, why = pcall(function() tools = Host.tools(server) end)
      if not listed then
        return SNIPPET .. ": require(" .. Json.quote(module) .. "): " .. (tostring(why):gsub("^[^:\n]+:%d+: ", ""))
      end
      local made = McpModule.made(server, tools)
      modules.teal[module] = made.teal
      modules.values[module] = value_of_module(server, made)
    end
  end
  return nil
end

--- The modules a snippet may use with no require, each by the name it is given: where a snippet reads a field of one
--- ([`Host.read`], `Fs:...`), the require goes before its first line, on that line, so the lines the checker tells of
--- stay the snippet's own.
local PRELUDE <const>: {{string}} = { { "Host", "cosmic.agent.host" }, { "Fs", "cosmic.fs" }, { "Json", "cosmic.json" } }

--- Whether `code` binds `name` itself, as a local (`local Json = ...`, `local A, Json = ...`) or a local function.
local function binds(code: string, name: string): boolean
  for names in code:gmatch("%f[%w_]local%s+([%w_,%s]-)%s*[=<:\n]") do
    if (", " .. names .. ","):find("[,%s]" .. name .. "%s*,") ~= nil then return true end
  end
  return code:find("%f[%w_]local%s+function%s+" .. name .. "%f[^%w_]") ~= nil
end

--- The requires of each [`PRELUDE`] module `code` reads a field of and does not bind itself (each it reads, where
--- `whole`), on one line: "" where it reads none.
local function prelude_of(code: string, whole?: boolean): string
  local bound: mut {string} = {}
  for _, entry in ipairs(PRELUDE) do
    local name, module = entry[1] or "", entry[2] or ""
    if code:find("%f[%w_]" .. name .. "%s*[%.:]") ~= nil and (whole == true or not binds(code, name)) then
      bound[#bound + 1] = "local " .. name .. " = require(\"" .. module .. "\") "
    end
  end
  -- A snippet that begins with `(`, past a comment even, would be read as a call of the last require: `do end` ends
  -- the prelude first.
  if #bound > 0 then bound[#bound + 1] = "do end " end
  return table.concat(bound)
end

--- `lines` with a column of line 1 told as the snippet's own, `width` bytes of prelude before it taken off.
local function unshifted(lines: {string}, width: integer): {string}
  local out: mut {string} = {}
  for _, line in ipairs(lines) do
    local column, rest = line:match("^run%.tl:1:(%d+):(.*)$")
    local at = math.tointeger(tonumber(column))
    local told = if at ~= nil and rest ~= nil and at > width then
      "run.tl:1:" .. tostring(at - width) .. ":" .. rest else line end
    -- A place the message names on line 1 is the snippet's too.
    out[#out + 1] = told:gsub("declared at 1:(%d+)", function(c: string): string
      local n = math.tointeger(tonumber(c)) or 0
      return "declared at 1:" .. tostring(if n > width then n - width else n end)
    end)
  end
  return out
end

--- What `kept` made of `code` and its prelude ([`prelude_of`]). Where the snippet binds a name of the prelude itself,
--- the prelude without it, else the whole one, else the refusal of the first. Otherwise, where that is refused and the
--- snippet alone is not, the snippet alone; where both are, the refusal of the one with the prelude, unless it tells
--- of a name the prelude declares (`declared at 1:C`, C within the prelude).
local function snippet_check(kept: Pipeline.Kept, code: string): Pipeline.Alone
  local prelude = prelude_of(code)
  local whole = prelude_of(code, true)
  -- [`binds`] reads no comment or string apart: where it takes one for a binding and the snippet is refused for it,
  -- the whole prelude is tried.
  if whole ~= prelude then
    local fewer = kept:check(prelude .. code)
    if fewer.code ~= nil then return fewer end
    local all = kept:check(whole .. code)
    if all.code ~= nil then return all end
    return { code = nil, lines = unshifted(fewer.lines, #prelude), stages = fewer.stages }
  end
  if prelude == "" then return kept:check(code) end
  local made = kept:check(prelude .. code)
  if made.code ~= nil then return made end
  local alone = kept:check(code)
  if alone.code ~= nil then return alone end
  for _, line in ipairs(made.lines) do
    for column in line:gmatch("declared at 1:(%d+)") do
      local at = math.tointeger(tonumber(column)) or 0
      if at <= #prelude then return alone end
    end
  end
  return { code = nil, lines = unshifted(made.lines, #prelude), stages = made.stages }
end

--- Whether `line` is a reply to a call, not a request: an object with a `call_id` and no `code` at its top. A reply
--- may hold either word deeper in its value (a column named `code`), so the line is decoded, not searched.
local function stale(line: string): boolean
  if line:find("\"call_id\"", 1, true) == nil then return false end
  local message, _ = Json.decode_object(line)
  return message ~= nil and message["call_id"] ~= nil and message["code"] == nil
end

--- The response line to the request `line` holds, checked by `kept` and run within `capture`, its calls sent on `channel`;
--- the MCP modules a snippet requires are made into `modules`, which `kept` reads.
local function answer_to(kept: Pipeline.Kept, modules: Modules, capture: Capture, channel: Channel, line: string): Answer
  local request, why = Json.decode_object(line)
  if request == nil then
    return failed(Json.null, "the request is no JSON object: " .. tostring(why))
  end
  local given = request["id"]
  local id: Json.Value = if given == nil then Json.null else given end
  local code = request["code"]
  if not (code is string) then return failed(id, "the request has no code") end
  channel.id = id
  -- Each request starts the calls' state anew: what a cancelled call or a closed task of the last one left goes.
  channel.replies, channel.reading, channel.arrived, channel.waiting = {}, false, nil, 0
  local trouble = provide(modules, code)
  if trouble ~= nil then return { id = id, refused = Json.array({ trouble }) } end
  local made = snippet_check(kept, code)
  local lua = made.code
  if lua == nil then return { id = id, refused = Json.array(made.lines) } end
  -- Each snippet gets tables of its own, so one that sets a function changes it for none after.
  local values: mut {string: {string: Call}} = {}
  for module, functions in pairs(modules.values) do
    local copy: mut {string: Call} = {}
    for name, call in pairs(functions) do copy[name] = call end
    values[module] = copy
  end
  local chunk, load_trouble = standalone.loaded_with(SNIPPET, lua, values)
  if chunk == nil then return failed(id, load_trouble) end
  local ran: mut {string: Json.Value} = {}
  -- The agent sends each request an integer id, which marks its output.
  local answer = capture:run(if id is integer then id else 0 end, function(): Answer
    local done, value = pcall(function(): any return (chunk()) end)
    if not done then return { ok = false, error = String.as_utf8(tostring(value)) } end
    if value == nil then return { ok = true } end
    return { ok = true, value = value_of(value) }
  end)
  for k, v in pairs(answer) do ran[k] = v end
  ran["id"] = id
  return ran
end

--- A capture through `output`, the pipe the agent reads a snippet's output on, with `null` the descriptor 0, 1 and 2
--- point at but while a snippet runs: then 1 and 2 are `output`, and 0 stays /dev/null, so neither the snippet nor a
--- program it starts reads the requests. The agent reads the pipe while the snippet runs, keeping its end alone, so no
--- file holds what a snippet prints without end.
local function capture_on(output: integer, null: integer): Capture
  return {
    run = function(_self: Capture, id: integer, f: function(): Answer): Answer
      local _, _ = Fs.put(output, Worker.mark("start", id))
      local _, _ = sys.dup2(output, 1)
      local _, _ = sys.dup2(output, 2)
      local answer = f()
      local _, _ = sys.dup2(null, 1)
      local _, _ = sys.dup2(null, 2)
      local _, _ = Fs.put(output, Worker.mark("end", id))
      return answer
    end,
  }
end

function worker.main(): integer
  local options, why = Pipeline.alone()
  if options == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: agent worker: " .. why .. "\n")
    return 1
  end
  -- The requests come in on a copy of standard input, the response lines go out on a copy of standard output, and a
  -- snippet's output on a copy of standard error ([`Worker.mark`]); descriptors 0, 1 and 2 are /dev/null, but 1
  -- and 2 while a snippet runs.
  local input, input_why = sys.dup(0)
  local out, out_why = sys.dup(1)
  local output, output_why = sys.dup(2)
  local null, null_why = sys.open("/dev/null", sys.O_RDWR)
  if input == nil or out == nil or output == nil or null == nil then
    local _, _ = Fs.put(Fs.stderr, "cosmic: agent worker: " .. input_why .. out_why .. output_why .. null_why .. "\n")
    return 1
  end
  local _, _ = sys.dup2(null, 0)
  local _, _ = sys.dup2(null, 1)
  local _, _ = sys.dup2(null, 2)
  local capture = capture_on(output, null)
  -- The checker reads an MCP server's module where the binary has none of its name.
  local modules: Modules = { teal = {}, values = {} }
  local standard = options.standard or Pipeline.carried()
  local made = Driver.stubs(modules.teal)
  options.standard = function(module: string): Driver.Source?
    return made(module) or standard(module)
  end
  -- A snippet runs once and no one reads it after: an unused name is no reason to refuse it.
  options.lax = true
  local kept = Pipeline.kept_alone(SNIPPET, options)
  local channel: Channel = { input = input, out = out, pending = "", id = Json.null, next_call = 1, replies = {},
    reading = false, waiting = 0 }
  Host.connect(transport_of(channel))
  while true do
    local line = line_of(channel)
    if line == nil then break end
    -- A reply to a call whose snippet ended already (one a task of it left) is no request, and is let go.
    if not stale(line) then
      local answer = answer_to(kept, modules, capture, channel, line)
      local text, encode_why = Json.encode(answer)
      if text == nil then
        local id = answer["id"]
        text = assert(Json.encode(failed(if id == nil then Json.null else id end, tostring(encode_why))))
      end
      -- A response line that cannot go out ends the worker, so the agent reads the end, not a wait.
      local sent, _ = Fs.put(out, text .. "\n")
      if not sent then break end
    end
  end
  return 0
end

return worker
