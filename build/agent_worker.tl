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
--- Where the checker refuses a snippet and its errors have rewrites ([`lang.rewrite`]), the response holds "fixed":
--- `["run.tl:2:12: concat_type: `n` -> `tostring(n)`"]`. The rewritten snippet runs where the checker passes it; where it
--- does not, "refused" holds the errors it has left.
---
--- A response of a snippet that ran may hold "changes", where it changed a file through Host.edit or Host.write:
--- `[{"path":"a.md","edits":[{"old":"...","new":"..."}]}, {"path":"b.md","lines":2}, {"more":3}]`, each text the
--- lines it changes with one of context, cut to 4KB, the whole at most 64KB, and "more" the count past that.
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
local Nearby = require("build.nearby")
local Pipeline = require("build.pipeline")
local Rewrite = require("lang.rewrite")
local Poll = require("cosmic.poll")
local Worker = require("cosmic.agent.worker")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local standalone = require("build.standalone")
local sys = require("cosmic.sys")

local record worker
  --- `cosmic agent worker`: responds to requests on standard input until it ends. 0 at its end, 1 where it could not start.
  --- `modules` is what a snippet may load code from ([`Worker.Options`] `modules`), [`Worker.MODULES`] where nil.
  main: function(modules?: {string}): integer
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

--- The most rounds of the checker's rewrites a refused snippet is given ([`lang.rewrite`]).
local ROUNDS <const> = 4

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
  --- The files the request's snippet changed through Host.edit and Host.write, in order.
  mut changes: mut {Host.Change}
end

-- The most bytes of an edit's old or new text an answer carries, once the lines both begin and end with are trimmed:
-- the agent shows a few lines of each.
local CHANGE_BYTES <const> = 4096

-- The most bytes of changes an answer carries: past them, a change is only counted, so the line stays far below the
-- 1MB the agent reads.
local CHANGES_BYTES <const> = 64 * 1024

--- The lines of `text`, split at each newline: "a\n" is "a" and "".
local function lines_in(text: string): {string}
  local out: mut {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  return out
end

--- `old` and `new` with the lines both begin and end with taken off, but one of each kept for context, each cut to
--- CHANGE_BYTES at a character's end, as UTF-8.
local function trimmed(old: string, new: string): (string, string)
  local a, b = lines_in(old), lines_in(new)
  local head = 0
  while head < #a and head < #b and a[head + 1] == b[head + 1] do head = head + 1 end
  local tail = 0
  while tail < #a - head and tail < #b - head and a[#a - tail] == b[#b - tail] do
    tail = tail + 1
  end
  local from = math.max(head, 1)
  local function part(lines: {string}): string
    local kept: mut {string} = {}
    for i = from, math.min(#lines - tail + 1, #lines) do kept[#kept + 1] = lines[i]! end
    return String.cut(String.as_utf8(table.concat(kept, "\n")), CHANGE_BYTES)
  end
  return part(a), part(b)
end

--- `changes` as JSON for the answer: `{path, edits = {{old, new}}}` or `{path, lines}`, each text [`trimmed`], the
--- whole at most CHANGES_BYTES, and `{more = n}` last for the n past it.
local function changes_of(changes: {Host.Change}): Json.Value
  local out: mut {Json.Value} = {}
  local spent, more = 0, 0
  for _, c in ipairs(changes) do
    local path = String.as_utf8(c.path)
    local edits = c.edits
    local size = #path + 32
    local entry: Json.Value
    if edits ~= nil then
      local list: mut {Json.Value} = {}
      for _, r in ipairs(edits) do
        local old, new = trimmed(r.old, r.new)
        size = size + #old + #new + 32
        list[#list + 1] = { old = old, new = new }
      end
      entry = { path = path, edits = Json.array(list) }
    else
      entry = { path = path, lines = c.lines or 0 }
    end
    if spent + size > CHANGES_BYTES then
      more = more + 1
    else
      spent = spent + size
      out[#out + 1] = entry
    end
  end
  if more > 0 then out[#out + 1] = { more = more } end
  return Json.array(out)
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

--- What a snippet may load code from, and the checker that knows what it loaded.
local record Loading
  --- Whether it may require the standard library's modules (`cosmic.*`).
  cosmic: boolean
  --- The trees whose modules it may require ([`build.nearby`]).
  roots: {string}
  --- The modules of those trees the checker read, by module ([`Pipeline.Options.nearby`]).
  found: mut {string: Pipeline.Nearby}
  --- The MCP servers' modules and the standard library, without the trees: what [`Host.check`] reads beside trees of
  --- its own, so its reads leave `found` as the snippets' checker left it.
  carried: Driver.Provider
  options: Pipeline.Options
  mut kept: Pipeline.Kept
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

--- The modules a snippet may use with no require that are the agent's own, each by the name it is given (the standard
--- library's, `Fs` and `Json` among them, are bound by the checker: [`Pipeline.implied`]): where a snippet reads a field of one
--- ([`Host.read`], `Fs:...`), the require goes before its first line, on that line, so the lines the checker tells of
--- stay the snippet's own.
local PRELUDE <const>: {{string}} = { { "Host", "cosmic.agent.host" } }

--- Whether `code` binds `name` itself, as a local (`local Json = ...`, `local A, Json = ...`) or a local function.
local function binds(code: string, name: string): boolean
  for names in code:gmatch("%f[%w_]local%s+([%w_,%s]-)%s*[=<:\n]") do
    if (", " .. names .. ","):find("[,%s]" .. name .. "%s*,") ~= nil then return true end
  end
  return code:find("%f[%w_]local%s+function%s+" .. name .. "%f[^%w_]") ~= nil
end

--- The requires of each [`PRELUDE`] module `code` reads a field of and does not bind itself (each it reads, where
--- `whole`), on one line: "" where it reads none.
local function prelude_of(code: string, whole?: boolean, cosmic?: boolean): string
  local bound: mut {string} = {}
  for _, entry in ipairs(PRELUDE) do
    local name, module = entry[1] or "", entry[2] or ""
    -- Host is the agent's own; the others are the standard library's, which a snippet may be let load none of.
    local let = cosmic ~= false or name == "Host"
    if let and code:find("%f[%w_]" .. name .. "%s*[%.:]") ~= nil and (whole == true or not binds(code, name)) then
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

--- The edits of `made`, a refusal of a text with `width` bytes of prelude before the snippet, as places of the snippet:
--- an edit within the prelude is left out.
local function edits_of(made: Pipeline.Alone, width: integer): {Rewrite.Edit}
  local out: mut {Rewrite.Edit} = {}
  for _, e in ipairs(made.edits or {}) do
    if e.offset > width then
      out[#out + 1] = { code = e.code, y = e.y, x = if e.y == 1 then e.x - width else e.x end, offset = e.offset - width,
        length = e.length, before = e.before, after = e.after }
    end
  end
  return out
end

--- What `kept` made of `code` and its prelude ([`prelude_of`]). Where the snippet binds a name of the prelude itself,
--- the prelude without it, else the whole one, else the refusal of the first. Otherwise, where that is refused and the
--- snippet alone is not, the snippet alone; where both are, the refusal of the one with the prelude, unless it tells
--- of a name the prelude declares (`declared at 1:C`, C within the prelude). A refusal's edits are the snippet's.
local function snippet_check(kept: Pipeline.Kept, code: string, cosmic: boolean): Pipeline.Alone
  local prelude = prelude_of(code, false, cosmic)
  local whole = prelude_of(code, true, cosmic)
  -- [`binds`] reads no comment or string apart: where it takes one for a binding and the snippet is refused for it,
  -- the whole prelude is tried.
  if whole ~= prelude then
    local fewer = kept:check(prelude .. code, not cosmic)
    if fewer.code ~= nil then return fewer end
    local all = kept:check(whole .. code, not cosmic)
    if all.code ~= nil then return all end
    return { code = nil, lines = unshifted(fewer.lines, #prelude), stages = fewer.stages,
      edits = edits_of(fewer, #prelude) }
  end
  if prelude == "" then return kept:check(code, not cosmic) end
  local made = kept:check(prelude .. code, not cosmic)
  if made.code ~= nil then return made end
  local alone = kept:check(code, not cosmic)
  if alone.code ~= nil then return alone end
  for _, line in ipairs(made.lines) do
    for column in line:gmatch("declared at 1:(%d+)") do
      local at = math.tointeger(tonumber(column)) or 0
      if at <= #prelude then return alone end
    end
  end
  return { code = nil, lines = unshifted(made.lines, #prelude), stages = made.stages, edits = edits_of(made, #prelude) }
end

--- What `kept` made of `code` ([`snippet_check`]), and, where it refused the snippet and the checker's rewrites of
--- its errors ([`lang.rewrite`]) change it, what it made of the rewritten one and the lines that tell what they
--- changed. The model is told them either way: a rewritten snippet the checker passes runs, and one it still refuses is
--- told with the errors the rewrites leave, so that the next snippet need not put right what they did. A rewrite adds no
--- line, so a line of what is left is the line of the snippet as written.
local function checked_fixed(kept: Pipeline.Kept, code: string, cosmic: boolean): Pipeline.Alone, {string}
  local first = snippet_check(kept, code, cosmic)
  local edits = first.edits
  if first.code ~= nil or edits == nil or #edits == 0 then return first, {} end
  local made = first
  -- The text `made` is of.
  local checked = code
  local rewritten = Rewrite.rounds(code, function(text: string): {Rewrite.Edit}
    if text ~= checked then made, checked = snippet_check(kept, text, cosmic), text end
    return if made.code ~= nil then {} else made.edits or {} end
  end, ROUNDS)
  if rewritten.text ~= checked then made = snippet_check(kept, rewritten.text, cosmic) end
  return made, Rewrite.told(SNIPPET, rewritten.made)
end

--- Whether `line` is a reply to a call, not a request: an object with a `call_id` and no `code` at its top. A reply
--- may hold either word deeper in its value (a column named `code`), so the line is decoded, not searched.
local function stale(line: string): boolean
  if line:find("\"call_id\"", 1, true) == nil then return false end
  local message, _ = Json.decode_object(line)
  return message ~= nil and message["call_id"] ~= nil and message["code"] == nil
end

--- Whether a snippet loading as `loading` says may require `name`: Host and an MCP server's module always, a
--- `cosmic.*` module where it may load the standard library, and a module of one of its trees.
local function may_require(loading: Loading, name: string): boolean
  if name == "cosmic.agent.host" or name:find("^mcp%.[%w_]+$") ~= nil then return true end
  if name == "cosmic" or name:sub(1, 7) == "cosmic." then return loading.cosmic end
  return #loading.roots > 0 and Nearby.find(loading.roots, name) ~= nil
end

--- What snippets may load code from, as a refusal says it.
local function loads_of(loading: Loading): string
  local words: mut {string} = { "Host", "the MCP servers' modules" }
  if loading.cosmic then words[#words + 1] = "the standard library (cosmic.*)" end
  for _, root in ipairs(loading.roots) do
    words[#words + 1] = "the modules of " .. (if root == "." then "the working directory" else root end)
  end
  return table.concat(words, ", ")
end

--- The trees snippets may load modules of, as a refusal says them.
local function loads_of_trees(loading: Loading): string
  local words: mut {string} = {}
  for _, root in ipairs(loading.roots) do
    words[#words + 1] = if root == "." then "the working directory" else root end
  end
  return table.concat(words, " or ")
end

--- The lines refusing each module `code`, or a module of a tree it reaches, requires and `loading` lets it load none
--- of; {} where it lets each.
local function unloadable(loading: Loading, code: string): {string}
  local told: mut {string} = {}
  local seen: mut {string: boolean} = {}
  local pending: mut {{string}} = { { SNIPPET, code } }
  while #pending > 0 do
    local item = assert(table.remove(pending))
    local file = assert(item[1])
    local required, _ = Pipeline.requires(file, assert(item[2]))
    for _, name in ipairs(required or {}) do
      if seen[file .. " " .. name] == nil then
        seen[file .. " " .. name] = true
        local tree_name = name ~= "cosmic" and name:sub(1, 7) ~= "cosmic." and name:find("^mcp%.") == nil
        if not may_require(loading, name) and tree_name and #loading.roots > 0 then
          local stem = name:gsub("%.", "/")
          told[#told + 1] = file .. ": require(" .. Json.quote(name) .. "): no module of that name: neither " .. stem ..
            ".tl nor " .. stem .. "/init.tl is in " .. loads_of_trees(loading) .. "; write it first, or check the name"
        elseif not may_require(loading, name) then
          told[#told + 1] = file .. ": require(" .. Json.quote(name) .. "): a snippet here loads code only from " ..
            loads_of(loading) .. " (cosmic agent --modules)"
        elseif #loading.roots > 0 then
          local near = Nearby.find(loading.roots, name)
          if near ~= nil then pending[#pending + 1] = { near.file, near.text } end
        end
      end
    end
  end
  return told
end

--- Makes `loading`'s checker anew where a module of its trees it read has changed on disk, or where `code` requires
--- one it has not read: a module the checker found missing before may be there now.
local function refresh(loading: Loading, code: string)
  if #loading.roots == 0 then return end
  local moved = Nearby.moved(loading.roots, loading.found)
  if not moved then
    local required, _ = Pipeline.requires(SNIPPET, code)
    for _, name in ipairs(required or {}) do
      if loading.found[name] == nil and Nearby.find(loading.roots, name) ~= nil then
        moved = true
      end
    end
  end
  if moved then
    for name in pairs(loading.found) do loading.found[name] = nil end
    loading.kept = Pipeline.kept_alone(SNIPPET, loading.options)
  end
end

--- What checks the Teal text of a file the snippet names ([`Host.check`]): the checker's lines, none where it
--- passes, the lines of each module of the trees it requires among them. It reads what a snippet may load, as `cosmic
--- fix` checks a file of a tree, so an unused name is refused, where a snippet's is not; a `_test.tl` file is checked
--- as a test. It reads the trees anew each time, into a map of its own, so the snippets' checker still sees what
--- changed since it read them.
local function checks_of(loading: Loading): Host.Checks
  return function(path: string, text: string): {string}
    local given = loading.options
    local found: mut {string: Pipeline.Nearby} = {}
    local near = Nearby.provider(loading.roots, found)
    local carried = loading.carried
    local trees = #loading.roots > 0
    -- The trees that are cosmic's own to this tool (it was built from them): there, as `cosmic fix` reads it, a module
    -- the binary carries is read from the tree, so a file is checked against the stdlib it is beside, not the one built.
    local own = Nearby.own(loading.roots, Store.meta("built_from"))
    local strict: Pipeline.Options = { globals = given.globals, types = given.types, project = given.project,
      lax = false, nearby = found, standard = function(module: string): Driver.Source?
        -- Only the stdlib's names: the tree's other modules go through `near`, which records them as found.
        if #own > 0 and (module == "cosmic" or module:sub(1, 7) == "cosmic.") then
          local mine = Nearby.file(own, module)
          if mine ~= nil then return Driver.source(module, mine.file, mine.text, "tl") end
        end
        return carried(module) or (if trees then near(module) else nil end)
      end }
    local made = Pipeline.checked_alone(path, text, strict, path:sub(-8) == "_test.tl")
    if made.code ~= nil then return {} end
    return made.lines
  end
end

--- The response line to the request `line` holds, checked by `kept` and run within `capture`, its calls sent on `channel`;
--- the MCP modules a snippet requires are made into `modules`, which `kept` reads.
local function answer_to(loading: Loading, modules: Modules, capture: Capture, channel: Channel, line: string): Answer
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
  channel.changes = {}
  -- Connected anew for each request: a snippet that connects Host itself changes only its own run.
  Host.connect(transport_of(channel), function(change: Host.Change)
    channel.changes[#channel.changes + 1] = change
  end, checks_of(loading))
  local trouble = provide(modules, code)
  if trouble ~= nil then return { id = id, refused = Json.array({ trouble }) } end
  local refusals = unloadable(loading, code)
  if #refusals > 0 then return { id = id, refused = Json.array(refusals) } end
  refresh(loading, code)
  local made, fixed = checked_fixed(loading.kept, code, loading.cosmic)
  local lua = made.code
  if lua == nil then
    local refusal: mut {string: Json.Value} = { id = id, refused = Json.array(made.lines) }
    if #fixed > 0 then refusal["fixed"] = Json.array(fixed) end
    return refusal
  end
  -- Each snippet gets tables of its own, so one that sets a function changes it for none after.
  local values: mut {string: {string: Call}} = {}
  for module, functions in pairs(modules.values) do
    local copy: mut {string: Call} = {}
    for name, call in pairs(functions) do copy[name] = call end
    values[module] = copy
  end
  local nearby: mut {string: standalone.Near} = {}
  for name, near_lua in pairs(made.nearby or {}) do
    local near = loading.found[name]
    if near ~= nil then nearby[name] = { file = near.file, code = near_lua } end
  end
  local chunk, load_trouble = standalone.loaded_with(SNIPPET, lua, values, nearby, function(name: string): boolean
    return may_require(loading, name)
  end)
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
  if #fixed > 0 then ran["fixed"] = Json.array(fixed) end
  if #channel.changes > 0 then ran["changes"] = changes_of(channel.changes) end
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

function worker.main(given?: {string}): integer
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
  local loads = given or Worker.MODULES
  local roots: mut {string} = {}
  local cosmic = false
  for _, word in ipairs(loads) do
    if word == "cosmic" then cosmic = true else roots[#roots + 1] = word end
  end
  local found: mut {string: Pipeline.Nearby} = {}
  local near = Nearby.provider(roots, found)
  -- The checker reads the standard library whatever a snippet may load: Host's declarations are made of it.
  local carried = function(module: string): Driver.Source?
    return made(module) or standard(module)
  end
  options.standard = function(module: string): Driver.Source?
    return carried(module) or (if #roots > 0 then near(module) else nil end)
  end
  options.nearby = found
  -- A snippet runs once and no one reads it after: an unused name is no reason to refuse it.
  options.lax = true
  local loading: Loading = { cosmic = cosmic, roots = roots, found = found, carried = carried, options = options,
    kept = Pipeline.kept_alone(SNIPPET, options) }
  local channel: Channel = { input = input, out = out, pending = "", id = Json.null, next_call = 1, replies = {},
    reading = false, waiting = 0, changes = {} }
  Host.connect(transport_of(channel), function(change: Host.Change)
    channel.changes[#channel.changes + 1] = change
  end, checks_of(loading))
  while true do
    local line = line_of(channel)
    if line == nil then break end
    -- A reply to a call whose snippet ended already (one a task of it left) is no request, and is let go.
    if not stale(line) then
      local answer = answer_to(loading, modules, capture, channel, line)
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
