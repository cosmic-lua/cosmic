--- @public
--- The tool of `cosmic agent`: run, which checks and runs a program of cosmic, a snippet, in the session's worker
--- (`cosmic docs cosmic.agent.worker`), under the session's sandbox. The model has no other: it reads, edits and writes
--- files, and runs programs where the session lets it, through the snippet's Host (`cosmic docs cosmic.agent.host`):
--- one environment, not a tool for each thing.
---
---     run    code, timeout?, output_bytes?
---       what it printed, its start and end past 8KB, and the JSON of
---       what it returned; a refused snippet's result is the checker's
---       lines; 120 seconds unless the model says, after which the
---       worker ends
---
--- Each call's whole output is kept in sessions.db (`cosmic agent help
--- files`). Where a call's text is cut, the model reads the id of the
--- whole, so it pulls back what it needs and no more, in a snippet of
--- run: with Host.output, or with Host.history, a read-only query that
--- can use substr() or FTS5 (MATCH, snippet()) over every session's outputs.
---
--- A tool is a value ([`Tools.Tool`]): an agent's `tools` is the list it offers, [`Tools.all`] by default, and a
--- program of its own may add one, for the model or for code to call ([`Host.use`]).
---
---     local agent = Agent.new({ sign = sign, cwd = cwd, tools = Tools.all() })
---
--- A tool that fails says why to the model, which goes on from there.

local AgentMcp = require("cosmic.agent.mcp")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local type AgentEdit = require("cosmic.agent.edit")
local Json = require("cosmic.json")
local RunText = require("cosmic.agent.run_text")
local Sandbox = require("cosmic.sandbox")
local Sessions = require("cosmic.agent.sessions")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Worker = require("cosmic.agent.worker")

local record Tools
  --- A JSON object.
  type Object = {string: Json.Value}

  --- Who may call a tool: the model, code (a snippet of run, by [`Host.use`]), or both.
  enum Callers
    "model"
    "code"
    "both"
  end

  --- What a tool returns: the text the model reads, and whether it is
  --- an error.
  record Result
    --- What the model reads.
    text: string
    --- Whether it is an error.
    is_error: boolean
    --- The whole output, where `text` holds less of it: it is what the
    --- sessions database keeps, and the model is told its id.
    mut raw?: string
    --- The files a snippet of run changed through Host.edit and Host.write, in order, for a person to see: the model
    --- reads none of it. A snippet stopped, or past its time, answers none.
    mut changes?: {Change}
  end

  --- A file a snippet changed: an edit's replacements (the lines they change, with one of context, each cut to 4KB), or
  --- the lines a write wrote. It is for a person to see, not a record of every write.
  record Change
    --- The file, as the snippet named it.
    path: string
    --- An edit's replacements; nil for a write.
    edits?: {AgentEdit.Replacement}
    --- How many lines a write wrote; nil for an edit.
    lines?: integer
    --- How many changes more the answer had no room for, in a last Change of no path.
    more?: integer
  end

  --- Where a tool runs: the working directory, the database of the
  --- sessions kept and the current one's id (nil where none is). The
  --- sandbox is not put on a tool from outside: a tool of your own that
  --- reads or writes a path asks `Sandbox.permits(context.policy, path,
  --- action, context.cwd)` first and opens the real name it returns.
  record Context
    --- The working directory, which a relative path is from.
    cwd: string
    --- The sessions database, for a snippet's history, output and store calls; nil for none.
    db?: Sqlite.Handle
    --- The session's id: `?1` to a history query, and whose store a snippet reads and writes.
    session?: integer
    --- What the tools are held to (cosmic.agent.policy); nil for nothing.
    policy?: Sandbox.Policy
    --- The worker run sends its snippets to (cosmic.agent.worker); nil for none.
    worker?: Worker.Set
    --- The MCP servers a snippet may call (cosmic.agent.mcp); nil for none.
    mcp?: AgentMcp.Set
    --- Whether the user stopped the turn: a tool that waits asks it, and
    --- ends its wait when it says so.
    stopped?: function(): boolean
    --- When the turn's time runs out ([`Clock.monotonic_ns`]), where its
    --- budget limits it: a command that waits is ended then. Nil for no limit.
    deadline_ns?: integer
    --- Whether a snippet of run may run programs ([`Worker.Options`] `commands`, by Host.bash). Nil is false. A run
    --- whose commands differ from those its worker was started with starts a new one.
    commands?: boolean
    --- The tools the agent offers; every tool ([`Tools.all`]) where nil.
    --- A tool's hints name only tools offered.
    tools?: {Tool}
    --- What a snippet's call of the agent is asked first (the agent's
    --- `before`, as a call by code): nil lets it run, a string is why
    --- not, raised in the snippet; a raise blocks it too. `name` is the
    --- call's: history, store.get, store.put, mcp.servers, mcp.tools or
    --- mcp.call, or the name of a tool code may call ([`Tools.for_code`])
    --- that the snippet called by [`Host.use`], a name the snippet chose
    --- only among those. `input` is
    --- the arguments it sent, `{}` where they are no object, unchecked:
    --- history's `{query}`, store's `{key, value?}` (put with no value or
    --- null lets the key go), mcp's `{server?, tool?, arguments?}`.
    --- Calls may come at once, from a snippet's tasks, and while its
    --- time runs.
    guard?: function(name: string, input: Object): string?
    --- What a snippet's call of the agent that ran is given to before
    --- the snippet reads it (the agent's `after`): its result as JSON
    --- text (escaped as JSON is), or its failure as an error result; the
    --- result it returns is what the snippet reads, as JSON where it is
    --- JSON, else as a string, and an error result raises in the
    --- snippet. `raw` is not read. A raise fails the call.
    amend?: function(name: string, input: Object, result: Result): Result
  end

  --- A path a call touches, and how: one of [`Sandbox.permits`]'s actions.
  --- A call that does more than one thing to a path touches it once for each.
  record Touch
    --- The absolute path, with no `.` or `..` in it, but its links not
    --- followed: check it with [`Sandbox.permits`], which follows them.
    path: string
    --- "read", "write", "run", "create" or "remove".
    action: string
  end

  --- One tool: what the model reads of it, and what does it. Make one of
  --- your own to give an agent a tool of its own.
  ---
  ---     local none: {string: Json.Value} = {}
  ---     local now: Tools.Tool = { name = "now", snippet = "Say the time", guidelines = {},
  ---       description = "The time, in seconds since 1970.", schema = { type = "object", properties = none },
  ---       run = function(_: Tools.Object, _: Tools.Context): Tools.Result
  ---         return { text = tostring(Clock.now_ns() // Clock.seconds(1)), is_error = false }
  ---       end }
  record Tool
    --- The name the model calls it by: unique among an agent's tools, of
    --- letters, digits, `_` and `-`, at most 64 (as the API takes it).
    name: string
    --- Its line in the system prompt's list of tools.
    snippet: string
    --- What it adds to the system prompt's rules.
    guidelines: {string}
    --- What the model reads of it in the request.
    description: string
    --- The JSON schema of its input.
    schema: Object
    --- Does it, in `context`. It never raises: what goes wrong is a
    --- result marked as an error.
    run: function(input: Object, context: Context): Result
    --- The paths a call of it with `input` touches, from `cwd`, for a
    --- hook to check ([`Check.paths`]); nil for a tool that touches none
    --- the hook can see.
    paths?: function(input: Object, cwd: string): {Touch}
    --- Who may call it; "model" where nil. A tool code may call is called from a snippet of run with
    --- `Host.use(name, input)`, under the same `before` and `after` as the model's calls, as a call by code; one
    --- for code alone is not offered to the model, which reads of it only in the system prompt. A call by code
    --- runs in the agent, outside the snippet's sandbox, so the tool checks its paths itself ([`Sandbox.permits`]), as
    --- read does; it is held to the snippet's time (`stopped`, `deadline_ns`) and given no worker; and the tasks of
    --- one snippet may call it at once. A name of a host call (history, store.get, ...) is refused to code.
    callers?: Callers
  end
end

local function ok(text: string): Tools.Result
  return { text = text, is_error = false }
end

local function fail(text: string): Tools.Result
  return { text = text, is_error = true }
end

--- The first of `tools` named `name`, or nil.
function Tools.find(tools: {Tools.Tool}, name: string): Tools.Tool?
  for _, t in ipairs(tools) do
    if t.name == name then return t end
  end
  return nil
end

--- Whether the model may call `t` ([`Tools.Callers`]).
function Tools.for_model(t: Tools.Tool): boolean
  return t.callers ~= "code"
end

--- Whether code, a snippet of run, may call `t` ([`Tools.Callers`]).
function Tools.for_code(t: Tools.Tool): boolean
  return t.callers == "code" or t.callers == "both"
end

local function count(input: Tools.Object, name: string): integer?, string
  local v = input[name]
  if v == nil then return nil, "" end
  if v is integer then return v, "" end
  if v is number and v == math.floor(v) then
    local n = math.tointeger(v)
    if n ~= nil then return n, "" end
  end
  return nil, name .. " must be an integer"
end

local function text_of(input: Tools.Object, name: string): string?, string
  local v = input[name]
  if v is string then return v, "" end
  return nil, name .. " must be a string"
end

--- The most seconds a timeout may be: a wait's most ([`Poll.MOST_NS`]), 24 days.
local MOST_SECONDS <const> = 24 * 24 * 60 * 60

--- Why `seconds`, a timeout, is past [`MOST_SECONDS`]; "" where it is not.
local function too_long(seconds?: integer): string
  if seconds == nil or seconds <= MOST_SECONDS then return "" end
  return "timeout is " .. tostring(seconds) .. ": give at most " .. String.counted(MOST_SECONDS, "second")
end

--- The most bytes of a snippet's output run gives the model: a snippet prints what it needs.
local RUN_BYTES <const> = 8 * 1024
--- How long a snippet may run, in seconds, unless the model says.
local RUN_SECONDS <const> = 120

--- The most bytes of a snippet's output the model may ask run for.
local RUN_MOST <const> = 64 * 1024

--- An output within about `most` bytes: all of `text` where it fits, else the first quarter of `start` and the last three
--- of `ending`, each cut at a line's end or start where one is near, with a line between them that says how many of the
--- `total` bytes written were cut; and whether it was cut. `start` and `ending` are `text` but where the worker cut it.
local function run_shown(text: string, start: string, ending: string, total: integer, most: integer): string, boolean
  if #text <= most and start == text then return text, false end
  local head = String.cut(start, most // 4)
  local nl = head:match("^.*()\n")
  if nl ~= nil and nl > #head // 2 then head = head:sub(1, nl) end
  local from = math.max(#ending - (most - most // 4) + 1, 1)
  local next_line = ending:find("\n", from, true)
  if next_line ~= nil and next_line < #ending and next_line - from < most // 8 then
    from = next_line + 1
  end
  while from <= #ending and (ending:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
  local shown_end = ending:sub(from)
  return head .. (if head:sub(-1) == "\n" then "" else "\n" end) .. "[... " ..
    String.counted(math.max(total - #head - #shown_end, 1), "byte") .. " cut ...]\n" .. shown_end, true
end

--- The values `statement` runs with for a history query: `?1` is
--- `session`, where there is one, and any other parameter is NULL.
local function session_values(statement: Sqlite.Statement, session?: integer): {Sqlite.Param}
  local values: mut {Sqlite.Param} = {}
  for index = 1, statement:parameters() do
    values[index] = if index == 1 and session ~= nil then session else Sqlite.NULL end
  end
  return values
end

--- The sessions database of `context`, opened again read-only, so a query cannot change what is kept; or why it is not.
local function reader_of(context: Tools.Context, limit_ns?: integer): (Sqlite.Handle) | (nil, string)
  local db = context.db
  if db == nil then return nil, "no sessions are kept here" end
  local files, files_why = db:rows("SELECT file FROM pragma_database_list WHERE name = 'main'")
  if files == nil then return nil, tostring(files_why) end
  local main = files[1]
  local file = if main ~= nil then main:text(1) else "" end
  if file == "" then return nil, "the sessions database has no file to read" end
  -- Held to queries: a read-only open holds for the main database alone, where ATTACH, VACUUM INTO and a temp table
  -- would still write.
  local reader, open_why = Sqlite.open(file, { reads_only = true })
  if reader == nil then return nil, tostring(open_why) end
  -- A query that runs past its time, or one Ctrl-C stops (the turn holds a guard), fails rather than hold the agent.
  reader:time_limit(limit_ns)
  return reader
end

--- The most bytes of the JSON of the rows a snippet's history call gets: well within the line of 1MB the
--- worker's response line may be, should the snippet return them.
local MAX_REPLY <const> = 512 * 1024

--- The rows of `query` on `db`, each an object of its columns, for a snippet's history call; `?1` is `session`. It stops
--- between rows once `over` is true: the snippet's time ran out, or the user stopped the turn; a step that runs past
--- the time `db` was given, or that Ctrl-C stops, fails ([`Sqlite.Handle.time_limit`]).
local function objects_of(db: Sqlite.Handle, query: string, session: integer?, over: function(): boolean):
    (Json.Value) | (nil, Failure)
  local statement, why = db:prepare(query)
  if statement == nil then return nil, why end
  local names: mut {string} = {}
  for _, name in ipairs(statement:names()) do names[#names + 1] = String.as_utf8(name) end
  local found, query_why = statement:query(session_values(statement, session))
  if found == nil then
    statement:close()
    return nil, query_why
  end
  local rows: mut {Json.Value} = {}
  local bytes = 2
  local function refused(trouble: string): (nil, Failure)
    local _, _ = found:close()
    statement:close()
    return nil, Failure.new(trouble)
  end
  local function too_many(): (nil, Failure)
    return refused("the rows are more than the " .. String.counted(MAX_REPLY, "byte") .. " of JSON a reply holds, " ..
        "after " .. String.counted(#rows, "row") .. ": narrow the query (LIMIT/OFFSET for rows, " ..
        "substr(text, start, length) for a long text)")
  end
  while true do
    if over() then
      return refused("the snippet's time ran out, or the turn was stopped, as the query ran")
    end
    local cells, step_why = found:read()
    if cells == nil then
      if step_why ~= nil then return refused(tostring(step_why)) end
      break
    end
    local row: mut {string: Json.Value} = {}
    for i, name in ipairs(names) do
      local kind = cells:kind(i)
      if kind == "null" then
        row[name] = Json.null
      elseif kind == "integer" then
        row[name] = cells:integer(i)
      elseif kind == "number" then
        local x = cells:number(i)
        if x ~= x or x == math.huge or x == -math.huge then
          return refused("column " .. Json.quote(name) .. " is " .. tostring(x) .. ", which JSON holds no number " ..
              "for: CAST it AS TEXT, or test it in the query")
        end
        row[name] = x
      else
        local cell = cells:bytes(i)
        if #cell > MAX_REPLY then return too_many() end
        row[name] = String.as_utf8(cell)
      end
    end
    local text, encode_why = Json.encode(row)
    if text == nil then return refused(tostring(encode_why)) end
    bytes = bytes + #text + 1
    if bytes > MAX_REPLY then return too_many() end
    rows[#rows + 1] = row
  end
  statement:close()
  return Json.array(rows)
end

--- The most bytes of a key a snippet keeps a value under.
local KEY_BYTES <const> = 256

--- What a snippet of `context` keeps for a later one, in sessions.db ([`Sessions.keep`]): `store.put` keeps `value`
--- under `key` (no value lets it go), and a `store.get` call gets what is kept, null for nothing.
local function stored(context: Tools.Context, name: string, given: {string: Json.Value}): (Json.Value) | (nil, Failure)
  local db, session = context.db, context.session
  if db == nil or session == nil then
    return nil, Failure.new("no session is kept here, so nothing is stored")
  end
  local key = given["key"]
  if not (key is string) or key == "" or #key > KEY_BYTES then
    return nil, Failure.new("a key is a string of 1 to " .. String.counted(KEY_BYTES, "byte"))
  end
  if name == "store.get" then
    local text, why = Sessions.kept(db, session, key)
    if text == nil then
      if why ~= "" then return nil, Failure.new(why) end
      return Json.null
    end
    local value, decode_why = Json.decode(text, { null_value = Json.null })
    if value == nil then
      return nil, Failure.new("what is kept is no JSON: " .. tostring(decode_why))
    end
    return value
  end
  local value = given["value"]
  local text: string? = nil
  if value ~= nil and value ~= Json.null then
    local encoded, encode_why = Json.encode(value)
    if encoded == nil then return nil, Failure.new(tostring(encode_why)) end
    text = encoded
  end
  local kept, why = Sessions.keep(db, session, key, text)
  if not kept then return nil, Failure.new(why) end
  return true
end

--- What serves the calls a snippet of `context` makes of the agent, as they come, with no guard: history (a
--- read-only query of sessions.db), store, and the MCP servers.
local function served_unguarded(context: Tools.Context): Worker.Serve
  return function(name: string, args: Json.Value, budget: Worker.Budget): (Json.Value) | (nil, Failure)
    local fields, _ = Json.to_object(args)
    local given: {string: Json.Value} = fields or {}
    if name == "history" then
      local query = given["query"]
      if not (query is string) then return nil, Failure.new("the call has no query") end
      local reader, open_why = reader_of(context, budget.left())
      if reader == nil then return nil, Failure.new(open_why) end
      local rows, why = objects_of(reader, query, context.session, budget.over)
      local _, _ = reader:close()
      if rows == nil then return nil, why end
      return rows
    end
    if name == "store.put" or name == "store.get" then return stored(context, name, given) end
    if name ~= "mcp.servers" and name ~= "mcp.tools" and name ~= "mcp.call" then
      return nil, Failure.new("the agent serves no call " .. Json.quote(String.as_utf8(name)) ..
          ": it serves history, store.put, store.get, mcp.servers, mcp.tools, mcp.call and use")
    end
    local set = context.mcp
    if name == "mcp.servers" then
      if set == nil then return Json.array({}) end
      return AgentMcp.listed(set)
    end
    if set == nil then
      return nil, Failure.new("no MCP server is configured: see `cosmic help agent`")
    end
    local server = given["server"]
    if not (server is string) then return nil, Failure.new("the call names no server") end
    local answer: Json.Value
    if name == "mcp.tools" then
      local tools, why = AgentMcp.tools(set, server)
      if tools == nil then return nil, why end
      answer = tools
    else
      local tool = given["tool"]
      if not (tool is string) then return nil, Failure.new("the call names no tool") end
      local stated = given["arguments"]
      local none: {string: Json.Value} = {}
      local arguments, _ = Json.to_object(if stated == nil then none else stated end)
      if arguments == nil then return nil, Failure.new("the call's arguments are no object") end
      local result, why = AgentMcp.call(set, server, tool, arguments)
      if result == nil then return nil, why end
      answer = result
    end
    local text, encode_why = Json.encode(answer)
    if text == nil then
      return nil, Failure.new("the answer is no JSON: " .. tostring(encode_why))
    end
    if #text > MAX_REPLY then
      return nil, Failure.new("the answer is " .. String.counted(#text, "byte") .. " of JSON, more than the " ..
          String.counted(MAX_REPLY, "byte") .. " a reply holds")
    end
    return answer
  end
end

--- The calls a snippet may make of the agent, each by the name its guard and amend know it by.
local SERVED <const>: {string: boolean} = {
  ["history"] = true, ["store.get"] = true, ["store.put"] = true,
  ["mcp.servers"] = true, ["mcp.tools"] = true, ["mcp.call"] = true,
}

--- What `context`'s amend makes of the host call `name` with `given`, whose result is `result`: the value the
--- snippet reads, or nil and why. An amend that raises, or returns no text, makes the call fail.
local function amended(context: Tools.Context, name: string, given: Tools.Object, result: Tools.Result):
    (Json.Value) | (nil, Failure)
  local amend = context.amend
  if amend == nil then return nil, Failure.new("no amend") end
  local amend_ran, made = pcall(amend, name, given, result)
  if not amend_ran then
    return nil, Failure.new("the agent's after hook failed: " .. tostring(made))
  end
  local text = made.text
  if not (text is string) then
    return nil, Failure.new("the agent's after hook answered no text")
  end
  if made.is_error then return nil, Failure.new(text) end
  if #text > MAX_REPLY then
    return nil, Failure.new("the after hook's answer is " .. String.counted(#text, "byte") .. ", more than the " ..
        String.counted(MAX_REPLY, "byte") .. " a reply holds")
  end
  local value, _ = Json.decode(text, { null_value = Json.null })
  if value == nil then return text end
  return value
end

--- What a tool code may call ([`Tools.for_code`]) returns to a snippet of `context` that calls it with `args`,
--- `{name, input}` ([`Host.use`]): its text, or its error result as a failure. The call is asked of the guard first,
--- and given to the amend after, by the tool's own name, as the model's calls of it are.
local function used(context: Tools.Context, args: Json.Value, budget: Worker.Budget): (Json.Value) | (nil, Failure)
  local fields, _ = Json.to_object(args)
  local given: {string: Json.Value} = fields or {}
  local named = given["name"]
  if not (named is string) then return nil, Failure.new("the call names no tool") end
  local t = Tools.find(context.tools or {}, named)
  -- A host call's name is the host call's: a hook told it could not tell the two apart.
  if t ~= nil and Tools.for_code(t) and SERVED[named] == true then
    return nil, Failure.new("the tool " .. named .. " has the name of a host call, so code cannot call it by Host.use")
  end
  if t == nil or not Tools.for_code(t) then
    local callable: mut {string} = {}
    for _, other in ipairs(context.tools or {}) do
      if Tools.for_code(other) then callable[#callable + 1] = other.name end
    end
    return nil, Failure.new("no tool " .. Json.quote(String.as_utf8(named)) .. " is one code may call; " ..
        (if #callable == 0 then "none is" else "these are: " .. table.concat(callable, ", ") end))
  end
  local none: {string: Json.Value} = {}
  local stated = given["input"]
  local input, _ = Json.to_object(if stated == nil then none else stated end)
  if input == nil then return nil, Failure.new("the call's input is no object") end
  local guard = context.guard
  if guard ~= nil then
    local guard_ran, reason = pcall(guard, named, input)
    if not guard_ran then
      return nil, Failure.new("Blocked: the agent's before hook failed: " .. tostring(reason))
    end
    if reason ~= nil then return nil, Failure.new("Blocked: " .. tostring(reason)) end
  end
  -- The tool runs in the agent, outside the snippet's sandbox, held to the snippet's time, with no worker: the
  -- snippet that called it holds the worker until it returns.
  local left = budget.left()
  local deadline = context.deadline_ns
  if left ~= nil then
    local by_snippet = Clock.monotonic_ns() + left
    if deadline == nil or by_snippet < deadline then deadline = by_snippet end
  end
  local scoped: Tools.Context = { ...context, stopped = budget.over, deadline_ns = deadline, worker = nil }
  local tool_ran, answered = pcall(t.run, input, scoped)
  local result: Tools.Result = if tool_ran then answered else
    { text = "the tool " .. named .. " failed: " .. tostring(answered), is_error = true } end
  local amend = context.amend
  if amend ~= nil then
    local amend_ran, made = pcall(amend, named, input, result)
    if not amend_ran then
      return nil, Failure.new("the agent's after hook failed: " .. tostring(made))
    end
    if not (made.text is string) then
      return nil, Failure.new("the agent's after hook answered no text")
    end
    result = made
  end
  if result.is_error then return nil, Failure.new(result.text) end
  if #result.text > MAX_REPLY then
    return nil, Failure.new("the tool's answer is " .. String.counted(#result.text, "byte") .. ", more than the " ..
        String.counted(MAX_REPLY, "byte") .. " a reply holds")
  end
  return result.text
end

--- What serves the calls a snippet of `context` makes of the agent (history, a read-only query of sessions.db, store.get,
--- store.put, mcp.servers, mcp.tools, mcp.call, and use, a tool's call by [`Host.use`]), each asked of its guard first
--- and given to its amend after, failed or not; use by the tool's own name. A call of no other name is refused before
--- either is asked.
local function served(context: Tools.Context): Worker.Serve
  local answer_of = served_unguarded(context)
  return function(name: string, args: Json.Value, budget: Worker.Budget): (Json.Value) | (nil, Failure)
    if name == "use" then return used(context, args, budget) end
    if SERVED[name] ~= true then
      return nil, Failure.new("the agent serves no call " .. Json.quote(String.as_utf8(name)) ..
          ": it serves history, store.put, store.get, mcp.servers, mcp.tools, mcp.call and use")
    end
    local fields, _ = Json.to_object(args)
    local given: {string: Json.Value} = fields or {}
    local guard = context.guard
    if guard ~= nil then
      local guard_ran, reason = pcall(guard, name, given)
      if not guard_ran then
        return nil, Failure.new("Blocked: the agent's before hook failed: " .. tostring(reason))
      end
      if reason ~= nil then return nil, Failure.new("Blocked: " .. tostring(reason)) end
    end
    local answer, why = answer_of(name, args, budget)
    if context.amend == nil then
      if answer == nil then return nil, why end
      return answer
    end
    if answer == nil then
      return amended(context, name, given, { text = tostring(why), is_error = true })
    end
    local text, encode_why = Json.encode(answer)
    if text == nil then
      return nil, Failure.new("the answer is no JSON: " .. tostring(encode_why))
    end
    return amended(context, name, given, { text = text, is_error = false })
  end
end

--- The changes an answer of the worker names (`{path, edits = {{old, new}}}` or `{path, lines}`); nil for none.
local function changes_in(given?: Json.Value): {Tools.Change}?
  local list, _ = Json.to_array(given)
  if list == nil or #list == 0 then return nil end
  local out: mut {Tools.Change} = {}
  for _, item in ipairs(list) do
    local c, _ = Json.to_object(item)
    local path = c and c["path"]
    local more = c and c["more"]
    if more is integer then
      out[#out + 1] = { path = "", more = more }
    elseif c ~= nil and path is string then
      local edits, _ = Json.to_array(c["edits"])
      if edits ~= nil then
        local made: mut {AgentEdit.Replacement} = {}
        for _, e in ipairs(edits) do
          local r, _ = Json.to_object(e)
          local old, new = r and r["old"], r and r["new"]
          if old is string and new is string then made[#made + 1] = { old = old, new = new } end
        end
        out[#out + 1] = { path = path, edits = made }
      else
        local lines = c["lines"]
        out[#out + 1] = { path = path, lines = if lines is integer then lines else 0 end }
      end
    end
  end
  return out
end

local function run(input: Tools.Object, context: Tools.Context): Tools.Result
  local code, why = text_of(input, "code")
  if code == nil then return fail(why) end
  local seconds, seconds_why = count(input, "timeout")
  if seconds_why ~= "" then return fail(seconds_why) end
  if too_long(seconds) ~= "" then return fail(too_long(seconds)) end
  local most, most_why = count(input, "output_bytes")
  if most_why ~= "" then return fail(most_why) end
  if most ~= nil and (most < 1024 or most > RUN_MOST) then
    return fail("output_bytes is " .. tostring(most) .. ": give 1024 to " .. tostring(RUN_MOST))
  end
  local set = context.worker
  if set == nil then return fail("No worker runs snippets here") end
  local answer, run_why = Worker.run(set, code, { cwd = context.cwd, policy = context.policy, commands = context.commands,
    seconds = seconds or RUN_SECONDS, stopped = context.stopped, serve = served(context) })
  if answer == nil then return fail(tostring(run_why)) end
  local refused, _ = Json.to_array(answer["refused"])
  if refused ~= nil then
    local told: mut {string} = {}
    for _, line in ipairs(refused) do told[#told + 1] = tostring(line) end
    return fail("The checker refused the snippet, so it did not run:\n" .. table.concat(told, "\n"))
  end
  local trouble = answer["error"]
  local output = answer["output"]
  local said = if output is string then output else "" end
  local written = answer["bytes"]
  local head_bytes, tail_bytes = answer["head_bytes"], answer["tail_bytes"]
  local start, ending, total = said, said, #said
  if answer["cut"] == true and head_bytes is integer and tail_bytes is integer and written is integer then
    start, ending, total = said:sub(1, head_bytes), said:sub(#said - tail_bytes + 1), written
  end
  local text, cut = run_shown(said, start, ending, total, most or RUN_BYTES)
  if answer["cut"] == true then
    text = "[Output cut: " .. (if written is integer then String.counted(written, "byte") .. " written; " else "" end) ..
      "its start and end are shown, and the first 16KB and last 48KB kept in sessions.db.]\n" .. text
  elseif cut then
    text = "[Output cut: its start and end are shown; the whole is kept in sessions.db.]\n" .. text
  end
  local value = answer["value"]
  if value ~= nil then
    local encoded, _ = Json.encode(value)
    local shown = encoded or "?"
    if #shown > RUN_BYTES then
      shown = String.cut(shown, RUN_BYTES) .. " ... (" .. String.counted(#shown, "byte") .. "; the whole is kept in sessions.db)"
      said = said .. "\nReturned: " .. (encoded or "?")
      cut = true
    end
    text = text .. (if text == "" or text:sub(-1) == "\n" then "" else "\n" end) .. "Returned: " .. shown
  end
  if text == "" then text = "(no output)" end
  local r = if answer["ok"] == true then ok(text) else
    fail(text .. (if text:sub(-1) == "\n" then "" else "\n" end) .. "Error: " .. tostring(trouble)) end
  if cut then r.raw = said end
  r.changes = changes_in(answer["changes"])
  return r
end

local function string_field(about: string): Json.Value
  return { type = "string", description = about }
end

local function integer_field(about: string): Json.Value
  return { type = "integer", description = about }
end

local function schema(properties: {string: Json.Value}, required: {string}): Tools.Object
  local names: mut {Json.Value} = {}
  for _, r in ipairs(required) do names[#names + 1] = r end
  return { type = "object", properties = properties, required = Json.array(names) }
end

--- What sessions.db holds, as Host.history tells the model.
local KEPT_TABLES <const> = "Tables: sessions (id, cwd, started (Unix time), model); messages (session, seq, " ..
  "message: the JSON the API takes); outputs (id, session, tool, input (JSON), text (the whole output), is_error); " ..
  "outputs_fts, FTS5 over outputs.text with the trigram tokenizer (rowid = outputs.id): " ..
  "outputs_fts MATCH '\"some text\"' for text of 3 characters or more, with snippet(outputs_fts, 0, " ..
  "'>>', '<<', '...', 64) and ORDER BY rank. ?1 is the current session's id."

--- Every tool, in the order the system prompt lists them.
local ALL <const>: {Tools.Tool} = {
  {
    name = "run",
    snippet = "Run a checked cosmic program in place of many tool calls",
    guidelines = { "Each tool's output is kept in sessions.db: read a cut one with Host.output(id), " ..
        "or find what was seen before with Host.history, rather than running a command or fetching again." },
    -- The words are the text template run_text.tmpl (cosmic.template).
    description = RunText.render({ kb = RUN_BYTES // 1024, tables = KEPT_TABLES }),
    schema = schema({
      code = string_field("The cosmic program, as the body of a file"),
      timeout = integer_field("Seconds, " .. tostring(RUN_SECONDS) .. " by default, 0 for none; past it the " ..
          "worker ends"),
      output_bytes = integer_field("About the most bytes of output to show, " .. tostring(RUN_BYTES) ..
          " by default, 1024 to " .. tostring(RUN_MOST)),
    }, { "code" }),
    run = run,
  },
}

--- Every tool, in the order the system prompt lists them: a new list,
--- yours to change.
---
---     for _, t in ipairs(Tools.all()) do print(t.name) end -- run
function Tools.all(): mut {Tools.Tool}
  local out: mut {Tools.Tool} = {}
  for _, t in ipairs(ALL) do out[#out + 1] = t end
  return out
end

--- Runs `tool` on `input` in `context`.
function Tools.call(tool: Tools.Tool, input: Tools.Object, context: Tools.Context): Tools.Result
  return tool.run(input, context)
end

--- What a call of `name`, which none of `tools` is, is answered: that no tool has the name, and the names of those
--- offered to the model, so its next call names one.
---
---     print(Tools.unknown(Tools.all(), "bash")) -- Tool bash not found: the tools are run
function Tools.unknown(tools: {Tools.Tool}, name: string): string
  local offered: mut {string} = {}
  for _, t in ipairs(tools) do
    if Tools.for_model(t) then offered[#offered + 1] = t.name end
  end
  if #offered == 0 then return "Tool " .. name .. " not found" end
  return "Tool " .. name .. " not found: the tools are " .. table.concat(offered, ", ")
end

--- Runs the first of `tools` named `name` on `input` in `context`, as
--- [`Tools.call`] does; one not there is an error result ([`Tools.unknown`]).
function Tools.dispatch(tools: {Tools.Tool}, name: string, input: Tools.Object, context: Tools.Context): Tools.Result
  local t = Tools.find(tools, name)
  if t == nil then return fail(Tools.unknown(tools, name)) end
  return t.run(input, context)
end

--- Runs the tool of [`Tools.all`] named `name` on `input` in `context`;
--- an unknown tool is an error result.
function Tools.run(name: string, input: Tools.Object, context: Tools.Context): Tools.Result
  return Tools.dispatch(ALL, name, input, context)
end

--- The tools of `tools` the model may call ([`Tools.for_model`]), as the Messages API takes them. The last is a cache breakpoint: the tools come first in a request, and
--- are the same in every session of a model with the same `commands` whatever its directory and prompt, so each session
--- reads them from the cache another wrote, where the project's instructions in the system prompt and the messages after them differ.
--- `commands` says whether a snippet may run programs: without it, run's description names no Host.bash.
function Tools.definitions(tools: {Tools.Tool}, commands?: boolean): Json.Value
  local out: mut {Json.Value} = {}
  local last: mut {string: Json.Value}? = nil
  for _, t in ipairs(tools) do
    if Tools.for_model(t) then
      -- Without commands a snippet runs no program, so run's description names no Host.bash.
      local description = if t.name == "run" and commands ~= true then
        (t.description:gsub("Host%.bash%(command%) %-> {output, ok, code}; ", "")) else t.description end
      local def: mut {string: Json.Value} = { name = t.name, description = description, input_schema = t.schema }
      out[#out + 1] = def
      last = def
    end
  end
  if last ~= nil then last["cache_control"] = { type = "ephemeral" } end
  return Json.array(out)
end

return Tools
