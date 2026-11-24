--- @public
--- The tools of `cosmic agent`: pi's four, read, write, edit and bash; run,
--- which checks and runs a snippet of Teal; and sql, over the sessions and
--- outputs it keeps. Each is a definition the model reads (its name, description
--- and input schema), a line for the system prompt, and a function that
--- does it. A tool never raises: what goes wrong is its result, marked
--- as an error, for the model to read and act on.
---
--- The model has pi's four tools, one for snippets of Teal, one for
--- background jobs, and one over what is kept:
---
---     read   path, offset?, limit?
---       a file's lines, at most 2000 lines or 50KB; offset (from 1) and
---       limit read a part, and a note says where to go on
---     bash   command, timeout?, background?
---       runs `bash -c command` in the working directory, stdout and
---       stderr together; it keeps the last 2000 lines or 50KB, and saves
---       the whole as an output when it cuts; no timeout unless the model
---       gives one, in seconds; background: true starts it as a job and
---       answers at once, with the job's id
---     run    code, timeout?
---       checks and runs a snippet of Teal in the session's worker
---       (`cosmic docs cosmic.agent.worker`), under the same sandbox:
---       what it printed, its last 8KB, and the JSON of what it
---       returned; a refused snippet's answer is the checker's lines;
---       120 seconds unless the model says, after which the worker ends
---     jobs   id?, wait?, kill?
---       no id: each job, its state, seconds run and command; with id:
---       its state and its output since the last read, the last 2000
---       lines or 50KB; wait waits up to that many seconds for it to
---       exit, kill ends it and its group; once it has ended, its whole
---       output (the last 16MB) is kept as the call's output
---     edit   path, edits: [{oldText, newText}]
---       exact replacements, each matched in the file as it was: each
---       oldText must be found once, and no two may overlap
---     write  path, content
---       creates or overwrites a file, and the directories above it
---     sql    query
---       runs one SQLite statement on sessions.db, opened read-only:
---       column names, then a row a line, cells split by tabs, at most
---       2000 lines or 50KB; ?1 is the current session's id
---
--- Each call's whole output is kept in sessions.db (`cosmic agent help
--- files`). Where a tool's text is cut, the model reads the id of the
--- whole, so it pulls back what it needs and no more: with substr(),
--- or with FTS5 (MATCH, snippet()) over every session's outputs.
---
--- Each tool is a value ([`Tools.Tool`]): an agent's `tools` is the list
--- it offers the model, and a program of its own picks or makes its own.
--- [`Tools.all`] is every tool above; [`Tools.default`] is all but bash
--- and jobs, so no program runs: without bash a snippet's worker starts
--- no process either ([`Worker.Options`] `commands`, on Linux under a
--- sandbox); [`Tools.only`] and
--- [`Tools.without`] pick by name.
---
---     local agent = Agent.new({ sign = sign, cwd = cwd, tools = Tools.only(Tools.all(), { "read", "sql" }) })
---
--- A relative path is from the working directory; ~ is HOME. A tool
--- that fails says why to the model, which goes on from there. Each
--- is held to the sandbox (`cosmic docs cosmic.agent.policy`).
---
--- A job writes its output to a file in a private temporary
--- directory, so it never waits on a reader; at most 16 run at once,
--- and one that writes more than 1GB is ended. A job is looked at as
--- each tool call comes, so its timeout ends it then, not sooner.
--- Its whole output, the last 16MB, is kept when jobs first reads it
--- after it ends, or as the session ends. The jobs end as ask, chat
--- or rpc ends, or as SIGTERM ends a turn. A signal that ends the agent
--- between turns, or SIGKILL, ends a sandboxed job with the agent's pid
--- namespace; with --sandbox off, the job lives on. What a job starts
--- in a session of its own (setsid) leaves the job, and kill does not
--- reach it.

local AgentEdit = require("cosmic.agent.edit")
local AgentMcp = require("cosmic.agent.mcp")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Jobs = require("cosmic.agent.jobs")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
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

  --- What a tool answers: the text the model reads, and whether it is
  --- an error.
  record Result
    --- What the model reads.
    text: string
    --- Whether it is an error.
    is_error: boolean
    --- The whole output, where `text` holds less of it: it is what the
    --- sessions database keeps, and the model is told its id.
    mut raw?: string
  end

  --- Where a tool runs: the working directory, the database of the
  --- sessions kept and the current one's id (nil where none is). The
  --- sandbox is not put on a tool from outside: a tool of your own that
  --- reads or writes a path asks `Sandbox.permits(context.policy, path,
  --- action, context.cwd)` first and opens the real name it answers, as
  --- read, write and edit do.
  record Context
    --- The working directory, which a relative path is from.
    cwd: string
    --- The sessions database, for sql; nil for none.
    db?: Sqlite.Handle
    --- The session's id, `?1` to sql.
    session?: integer
    --- What the tools are held to (cosmic.agent.policy); nil for nothing.
    policy?: Sandbox.Policy
    --- The background jobs of this run (cosmic.agent.jobs); nil for none.
    jobs?: Jobs.Set
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
    --- Whether a snippet of run may run programs ([`Worker.Options`] `commands`): only where bash is offered too.
    --- A worker keeps what it was started with: one started with programs, then given a list with no bash, runs
    --- them still until it is closed.
    commands?: boolean
    --- The tools the agent offers; every tool ([`Tools.all`]) where nil.
    --- A tool's hints name only tools offered.
    tools?: {Tool}
    --- What a snippet's call of the agent is asked first (the agent's
    --- `before`, as a call by code): nil lets it run, a string is why
    --- not, raised in the snippet; a raise blocks it too. `name` is the
    --- call's: sql, store.get, store.put, mcp.servers, mcp.tools or
    --- mcp.call, or the name of a tool code may call ([`Tools.for_code`])
    --- that the snippet called by [`Host.use`], a name the snippet chose
    --- only among those. `input` is
    --- the arguments it sent, `{}` where they are no object, unchecked:
    --- sql's `{query}`, store's `{key, value?}` (put with no value or
    --- null lets the key go), mcp's `{server?, tool?, arguments?}`.
    --- Calls may come at once, from a snippet's tasks, and while its
    --- time runs.
    guard?: function(name: string, input: Object): string?
    --- What a snippet's call of the agent that ran is given to before
    --- the snippet reads it (the agent's `after`): its answer as JSON
    --- text (escaped as JSON is), or its failure as an error result; the
    --- result it answers is what the snippet reads, as JSON where it is
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
    --- for code alone is not offered to the model, which reads of it only in the system prompt.
    callers?: Callers
  end
end

--- The most lines of output a tool gives the model.
local MAX_LINES <const> = 2000
--- The most bytes of output a tool gives the model.
local MAX_BYTES <const> = 50 * 1024

--- How much of an output a tool gives the model, as its descriptions say it.
local LIMIT <const> = String.counted(MAX_LINES, "line") .. " or " .. tostring(MAX_BYTES // 1024) .. "KB"

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

--- `path` from `cwd`: absolute as given, `~` as HOME, else under `cwd`.
local function resolve(path: string, cwd: string): string
  local home = Env.get("HOME") or ""
  if path == "~" then return home end
  if path:sub(1, 2) == "~/" then return home .. path:sub(2) end
  if path:sub(1, 1) == "/" then return path end
  return cwd .. "/" .. path
end

--- `text` split at each newline; a final newline makes no empty line.
local function lines(text: string): {string}
  local out: mut {string} = {}
  local at = 1
  while at <= #text do
    local nl = text:find("\n", at, true)
    if nl == nil then
      out[#out + 1] = text:sub(at)
      break
    end
    out[#out + 1] = text:sub(at, nl - 1)
    at = nl + 1
  end
  return out
end

local function size(n: integer): string
  if n < 1024 then return tostring(n) .. "B" end
  return string.format("%.1fKB", n / 1024)
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

--- Lines `offset` on of `body`, at most `limit` and within the limits,
--- with a note of where to go on; `hint` says how to see a line too long.
local function page(body: string, offset?: integer, limit?: integer, hint?: string): Tools.Result
  if limit ~= nil and limit < 1 then return fail("limit must be 1 or more") end
  local all = lines(body)
  local first = math.max(offset or 1, 1)
  if first > #all and #all > 0 then
    return fail(string.format("Offset %d is beyond the end (%s total)", first, String.counted(#all, "line")))
  end
  local last = #all
  if limit ~= nil and first + limit - 1 < last then last = first + limit - 1 end
  local shown: mut {string} = {}
  local bytes, stop = 0, last
  for i, line in ipairs(all) do
    if i >= first and i <= stop then
      local sep = if #shown > 0 then 1 else 0 end
      if #shown >= MAX_LINES or bytes + sep + #line > MAX_BYTES then
        if #shown == 0 then
          return ok(string.format("[Line %d is %s, over the %s limit.%s]", i, size(#line),
            size(MAX_BYTES), hint or ""))
        end
        stop = i - 1
        break
      end
      shown[#shown + 1] = line
      bytes = bytes + sep + #line
    end
  end
  local text = table.concat(shown, "\n")
  if stop < last then
    text = text .. string.format("\n\n[Showing lines %d-%d of %d. Use offset=%d to continue.]",
      first, stop, #all, stop + 1)
  elseif last < #all then
    text = text .. string.format("\n\n[%s more. Use offset=%d to continue.]", String.counted(#all - last, "line"), last + 1)
  end
  return ok(text)
end

--- The real name `context.policy` lets the tools do each of `actions` at
--- ([`Sandbox.permits`]), the name to open, so what is checked is what is
--- changed; `full` itself where there is no policy. Nil and why where one
--- is refused.
local function permitted(context: Tools.Context, full: string, actions: {string}): string?, string
  local policy = context.policy
  if policy == nil then return full, "" end
  -- Each action of the real name the one before answered: a link is
  -- checked, and written, at its target.
  local real = full
  for _, action in ipairs(actions) do
    local checked, why = Sandbox.permits(policy, real, action, context.cwd)
    if checked == nil then
      return nil, "The sandbox does not let the agent " .. action .. " " .. full .. ": " .. why
    end
    real = checked
  end
  return real, ""
end

--- The directory that holds `full`, held with no link on its path ([`Fs.dir`]), and the name in it, under a policy:
--- the real name [`permitted`] checked is what is opened, as a link swapped in on it after the check is met, not
--- followed. With `make`, each missing directory is made in the one above it, one name at a time. Nil and why where
--- the directory cannot be held.
local record Held
  --- The directory, held.
  dir: Fs.Dir
  --- The name in it.
  name: string
end

local function held(full: string, make: boolean): Held?, string
  local dir = Fs.dirname(full)
  local missing: mut {string} = {}
  if make then
    while dir ~= Fs.dirname(dir) do
      local status, _ = Fs.status(dir)
      if status ~= nil and status.exists then break end
      table.insert(missing, 1, Fs.basename(dir))
      dir = Fs.dirname(dir)
    end
  end
  local d, why = Fs.dir(dir)
  if d == nil then return nil, tostring(why) end
  for _, name in ipairs(missing) do
    local made, made_why = d:mkdir(name)
    local inner, inner_why = d:dir(name)
    d:close()
    if inner == nil then return nil, tostring(if made then inner_why else made_why end) end
    d = inner
  end
  return { dir = d, name = Fs.basename(full) }, ""
end

--- The bytes of `full`, a file: through [`held`] under a policy, by its name where there is none.
local function read_file(full: string, path: string, policy?: Sandbox.Policy): string?, string
  if policy == nil then
    -- A device or a pipe may never end: only a file is read whole.
    local status, _ = Fs.status(full)
    local st = status and status.stat
    if st ~= nil and st.kind ~= "file" then
      return nil, path .. " is no file (" .. st.kind .. "): read reads files"
    end
    local body, why = Fs.read(full)
    if body == nil then return nil, tostring(why) end
    return body, ""
  end
  local at, why = held(full, false)
  if at == nil then return nil, why end
  local d, name = at.dir, at.name
  local status, status_why = d:status(name)
  local st = status and status.stat
  if st ~= nil and st.kind ~= "file" then
    d:close()
    return nil, path .. " is no file (" .. st.kind .. "): read reads files"
  end
  if status == nil then
    d:close()
    return nil, tostring(status_why)
  end
  local body, read_why = d:read(name)
  d:close()
  if body == nil then return nil, tostring(read_why) end
  return body, ""
end

--- Writes `content` to `full`, making the directories above it: through [`held`] under a policy.
local function write_file(full: string, content: string, policy?: Sandbox.Policy): boolean, string
  if policy == nil then
    local made, made_why = Fs.mkdirs(Fs.dirname(full))
    if not made then return false, tostring(made_why) end
    local wrote, wrote_why = Fs.write(full, content)
    if not wrote then return false, tostring(wrote_why) end
    return true, ""
  end
  local at, why = held(full, true)
  if at == nil then return false, why end
  local d, name = at.dir, at.name
  local wrote, wrote_why = d:write(name, content)
  d:close()
  if not wrote then return false, tostring(wrote_why) end
  return true, ""
end

local function read(input: Tools.Object, context: Tools.Context): Tools.Result
  local path, why = text_of(input, "path")
  if path == nil then return fail(why) end
  local offset, offset_why = count(input, "offset")
  local limit, limit_why = count(input, "limit")
  if offset_why ~= "" or limit_why ~= "" then return fail(offset_why .. limit_why) end
  local full, refused = permitted(context, resolve(path, context.cwd), { "read" })
  if full == nil then return fail(refused) end
  local body, read_why = read_file(full, path, context.policy)
  if body == nil then return fail(read_why) end
  local line = math.max(offset or 1, 1)
  local offered = context.tools
  local hint = if offered == nil or Tools.find(offered, "bash") ~= nil then
    string.format(" Use bash: sed -n '%dp' %s | head -c %d", line, path, MAX_BYTES)
    else string.format(" Use run: read %s with cosmic.fs and print a part of line %d", path, line) end
  return page(body, offset, limit, hint)
end

local function write(input: Tools.Object, context: Tools.Context): Tools.Result
  local path, why = text_of(input, "path")
  local content, content_why = text_of(input, "content")
  if path == nil or content == nil then return fail(why .. content_why) end
  -- A write makes a new file and renames it over the old (Fs.write), and may make directories: it creates.
  local full, refused = permitted(context, resolve(path, context.cwd), { "write", "create" })
  if full == nil then return fail(refused) end
  -- Each directory the write makes is made in the one above it: each asks c there, not only the last.
  local policy = context.policy
  if policy ~= nil then
    local dir = Fs.dirname(full)
    while dir ~= Fs.dirname(dir) do
      local status, _ = Fs.status(dir)
      if status ~= nil and status.exists then break end
      local made_here, why_not = Sandbox.permits(policy, dir, "create", context.cwd)
      if made_here == nil then
        return fail("The sandbox does not let the agent create " .. dir .. ": " .. why_not)
      end
      dir = Fs.dirname(dir)
    end
  end
  local wrote, wrote_why = write_file(full, content, policy)
  if not wrote then return fail(wrote_why) end
  return ok(string.format("Successfully wrote %s to %s", String.counted(#content, "byte"), path))
end

--- The replacements `input` asks for: its `edits`, and the one of its
--- own `oldText` and `newText` that some models send.
--- The replacements of an edit call's `input`, in each shape models send: `edits` a list, one object or a JSON
--- string of either, or `oldText` and `newText` at the top; or nil and why.
function Tools.replacements(input: Tools.Object): {AgentEdit.Replacement}?, string
  local out: mut {AgentEdit.Replacement} = {}
  local list = input["edits"]
  if list is string then
    local decoded, _ = Json.decode(list)
    list = decoded
  end
  local single, _ = Json.to_object(list)
  if single ~= nil and not Json.is_array(list) then list = Json.array({ single }) end
  local items, _ = Json.to_array(list)
  for i, item in ipairs(items or {}) do
    local e, _ = Json.to_object(item)
    local old, new = e and e["oldText"], e and e["newText"]
    if not (old is string) or not (new is string) then
      return nil, string.format("edits[%d]", i - 1) .. " needs oldText and newText, each a string"
    end
    out[#out + 1] = { old = old, new = new }
  end
  local old, new = input["oldText"], input["newText"]
  if old is string and new is string then
    out[#out + 1] = { old = old, new = new }
  end
  if #out == 0 then return nil, "edits must hold at least one replacement" end
  return out, ""
end

local function edit(input: Tools.Object, context: Tools.Context): Tools.Result
  local path, why = text_of(input, "path")
  if path == nil then return fail(why) end
  local edits, edits_why = Tools.replacements(input)
  if edits == nil then return fail(edits_why) end
  local full, refused = permitted(context, resolve(path, context.cwd), { "read", "write", "create" })
  if full == nil then return fail(refused) end
  local raw, read_why = read_file(full, path, context.policy)
  if raw == nil then return fail(read_why) end
  local edited, made = AgentEdit.apply(raw, edits, path, "oldText")
  if edited == nil then return fail(made) end
  local wrote, wrote_why = write_file(full, edited, context.policy)
  if not wrote then return fail(wrote_why) end
  return ok(string.format("Successfully replaced %d block(s) in %s.", made, path))
end

--- The last MAX_LINES lines of `text`, within MAX_BYTES, and whether
--- that is less than all of it.
local function tail(text: string): string, boolean
  local all = lines(text)
  local first = math.max(#all - MAX_LINES + 1, 1)
  local bytes = 0
  for i = #all, first, -1 do
    local line = all[i] or ""
    bytes = bytes + #line + 1
    if bytes > MAX_BYTES then
      -- A last line too long alone: its end, from a character's start.
      if i == #all then
        local from = #line - MAX_BYTES + 1
        while from <= #line and (line:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
        return line:sub(from), true
      end
      first = i + 1
      break
    end
  end
  return table.concat(all, "\n", first), first > 1
end

--- The most seconds a timeout may be: a wait's most ([`Poll.MOST_NS`]), 24 days.
local MOST_SECONDS <const> = 24 * 24 * 60 * 60

--- Why `seconds`, a timeout, is past [`MOST_SECONDS`]; "" where it is not.
local function too_long(seconds?: integer): string
  if seconds == nil or seconds <= MOST_SECONDS then return "" end
  return "timeout is " .. tostring(seconds) .. ": give at most " .. String.counted(MOST_SECONDS, "second")
end

--- Starts `command` as a background job.
local function background(command: string, seconds: integer?, context: Tools.Context): Tools.Result
  local set = context.jobs
  if set == nil then return fail("No background jobs run here") end
  local job, why = Jobs.start(set, command, { cwd = context.cwd, policy = context.policy, seconds = seconds })
  if job == nil then return fail(why) end
  return ok(string.format("Started job %d. Use jobs with id %d to read its output, wait for it or kill it.",
    job.id, job.id))
end

--- Runs `command` with bash, or sh where there is none, in `context`, for at most `timeout_ns`: stdout and stderr
--- captured together.
local function shell(command: string, timeout_ns: integer, context: Tools.Context): Child.Result?, string
  local deadline = context.deadline_ns
  if deadline ~= nil then
    local left = math.max(deadline - Clock.monotonic_ns(), 1)
    if timeout_ns == Child.FOREVER or left < timeout_ns then timeout_ns = left end
  end
  local found, _ = Proc.find("bash")
  local res, why = Child.run({ found or "/bin/sh", "-c", command }, { cwd = context.cwd, stdin = "null",
    stdout = "capture", stderr = "stdout", policy = context.policy, timeout_ns = timeout_ns })
  -- On Linux, what the command left running outside its group ends
  -- with it; the background jobs' groups are spared.
  local _ = Child.end_strays(Jobs.groups(context.jobs))
  if res == nil then return nil, tostring(why) end
  return res, ""
end

local function bash(input: Tools.Object, context: Tools.Context): Tools.Result
  local command, why = text_of(input, "command")
  if command == nil then return fail(why) end
  local seconds, seconds_why = count(input, "timeout")
  if seconds_why ~= "" then return fail(seconds_why) end
  if too_long(seconds) ~= "" then return fail(too_long(seconds)) end
  local bg = input["background"]
  if bg ~= nil and not (bg is boolean) then return fail("background must be true or false") end
  if bg == true then return background(command, seconds, context) end
  local res, run_why = shell(command, if seconds ~= nil and seconds > 0 then Clock.seconds(seconds) else Child.FOREVER end,
    context)
  if res == nil then return fail(run_why) end
  local said = res.stdout or ""
  local text, cut = tail(said)
  if cut or res.truncated then
    local lost = if res.truncated then " Its first part was lost: it passed 16MB." else "" end
    text = text .. "\n\n[Output truncated to its last lines." .. lost .. "]"
  end
  if text == "" then text = "(no output)" end
  local r = ok(text)
  if res.timed_out then
    r = fail(text .. "\n\nCommand timed out after " .. String.counted(seconds or 0, "second"))
  elseif not res.ok then
    local code = if res.code ~= nil then "code " .. tostring(res.code) else "signal " .. tostring(res.signal) end
    r = fail(text .. "\n\nCommand exited with " .. code)
  end
  if cut then r.raw = said end
  return r
end

--- The most bytes of a snippet's output run gives the model: a snippet prints what it needs, so less than bash gives.
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

--- How `job` stands: running, or how it ended.
local function state(job: Jobs.Job): string
  local r = job.result
  if r == nil then return "running" end
  if job.over then return "ended for passing 1GB of output" end
  if job.killed then return "killed" end
  if r.timed_out then return "timed out" end
  if r.code ~= nil then return "exited with code " .. tostring(r.code) end
  return "ended by signal " .. tostring(r.signal)
end

--- How long `job` has run, or ran, in whole seconds.
local function ran(job: Jobs.Job): integer
  return ((job.ended or Clock.monotonic_ns()) - job.started) // Clock.seconds(1)
end

--- The jobs of `set`, a line each.
local function listed(set: Jobs.Set): Tools.Result
  if #set.list == 0 then return ok("No jobs.") end
  local out: mut {string} = {}
  for _, j in ipairs(set.list) do
    local _ = Jobs.settle(j)
    local line = j.command:gsub("\n.*", " ...")
    if #line > 80 then line = String.cut(line, 77) .. "..." end
    out[#out + 1] = string.format("job %d  %s  %ds  %s", j.id, state(j), ran(j), line)
  end
  return ok(table.concat(out, "\n"))
end

local function jobs(input: Tools.Object, context: Tools.Context): Tools.Result
  local set = context.jobs
  if set == nil then return fail("No background jobs run here") end
  local id, id_why = count(input, "id")
  local wait, wait_why = count(input, "wait")
  if id_why ~= "" or wait_why ~= "" then return fail(id_why .. wait_why) end
  local kill = input["kill"]
  if kill ~= nil and not (kill is boolean) then return fail("kill must be true or false") end
  if id == nil then
    if kill == true or wait ~= nil then return fail("wait and kill take a job's id") end
    return listed(set)
  end
  local job = Jobs.find(set, id)
  if job == nil then return fail("No job " .. tostring(id) .. ": jobs with no id lists them") end
  if kill == true then
    Jobs.kill(job)
  elseif wait ~= nil and wait > 0 then
    local _ = Jobs.wait(job, wait, context.stopped)
  end
  local done = Jobs.settle(job)
  -- A little more than the most shown, to tell whether some is cut.
  local new = Jobs.read(job, MAX_BYTES + 1)
  local earlier = new.skipped
  local said, cut = tail(new.text)
  local head = string.format("Job %d %s, after %ds.", job.id, state(job), ran(job))
  local body = if said == "" then "(no new output)" else said end
  local text = head .. "\n\n" .. body
  if cut or earlier > 0 then
    local whole = if done then "" else " The whole output is kept in sessions.db once the job ends." end
    text = text .. "\n\n[Showing the last lines of its new output." .. whole .. "]"
  end
  local r = ok(text)
  local result = job.result
  -- What the model asked to end is no error.
  if result ~= nil and not result.ok and not job.killed then r = fail(text) end
  if done and not job.kept then
    job.kept = true
    r.raw = Jobs.output(job, Jobs.size(job), Jobs.KEPT)
  end
  return r
end

--- The values `statement` runs with for a query of the sql tool: `?1` is
--- `session`, where there is one, and any other parameter is NULL.
local function session_values(statement: Sqlite.Statement, session?: integer): {Sqlite.Param}
  local values: mut {Sqlite.Param} = {}
  for index = 1, statement:parameters() do
    values[index] = if index == 1 and session ~= nil then session else Sqlite.NULL end
  end
  return values
end

--- The rows of `query` on `db`, as text: the column names, then a line
--- a row, cells split by tabs, within the limits. `?1` is `session`.
local function rows_of(db: Sqlite.Handle, query: string, session?: integer): Tools.Result
  local statement, why = db:prepare(query)
  if statement == nil then return fail("sql: " .. tostring(why)) end
  local names = statement:names()
  local columns = #names
  local found, query_why = statement:query(session_values(statement, session))
  if found == nil then
    statement:close()
    return fail("sql: " .. tostring(query_why))
  end
  local header = table.concat(names, "\t")
  local out: mut {string} = { header }
  local bytes, rows, cut, lines_used = #header, 0, false, 1
  for row in found:each() do
    local cells: mut {string} = {}
    for i = 1, columns do
      cells[#cells + 1] = row:as_text(i) or "NULL"
    end
    local line = table.concat(cells, "\t")
    local _, breaks = line:gsub("\n", "")
    if lines_used + 1 + breaks > MAX_LINES or bytes + 1 + #line > MAX_BYTES then
      if rows == 0 then
        local part = String.cut(line, math.max(MAX_BYTES - bytes - 1, 0))
        local at: integer? = 0
        for _ = 1, MAX_LINES - lines_used do
          if at == nil then break end
          at = part:find("\n", at + 1, true)
        end
        out[#out + 1] = if at ~= nil then part:sub(1, at - 1) else part end
        rows = 1
      end
      cut = true
      break
    end
    out[#out + 1] = line
    bytes, rows, lines_used = bytes + 1 + #line, rows + 1, lines_used + 1 + breaks
  end
  local _, _ = found:close()
  statement:close()
  local failure = found:failure()
  if failure ~= nil then return fail("sql: " .. tostring(failure)) end
  if columns == 0 then return ok("Done.") end
  local text = table.concat(out, "\n")
  if cut then
    text = text .. string.format("\n\n[Stopped after %s, at the %d-line or %s limit. Narrow the query: " ..
        "LIMIT/OFFSET for rows, substr(text, start, length) for a long text.]", String.counted(rows, "row"), MAX_LINES,
      size(MAX_BYTES))
  elseif rows == 0 then
    text = text .. "\n\n[No rows.]"
  end
  return ok(text)
end

--- How long one statement of the sql tool may run, in seconds.
local SQL_SECONDS <const> = 60

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

--- Runs one SQL statement on the sessions database, opened again
--- read-only, so a query cannot change what is kept.
local function sql(input: Tools.Object, context: Tools.Context): Tools.Result
  local query, why = text_of(input, "query")
  if query == nil then return fail(why) end
  local reader, open_why = reader_of(context, Clock.seconds(SQL_SECONDS))
  if reader == nil then return fail("sql: " .. open_why) end
  local r = rows_of(reader, query, context.session)
  local _, _ = reader:close()
  return r
end

--- The most bytes of the JSON of the rows a snippet's sql call is answered: well within the line of 1MB the
--- worker's answer may be, should the snippet return them.
local MAX_REPLY <const> = 512 * 1024

--- The rows of `query` on `db`, each an object of its columns, for a snippet's sql call; `?1` is `session`. It stops
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
--- under `key` (no value lets it go), and `store.get` answers what is kept, null for nothing.
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

--- What answers the calls a snippet of `context` makes of the agent, as they come, with no guard: sql as the
--- sql tool runs it, store, and the MCP servers.
local function served_unguarded(context: Tools.Context): Worker.Serve
  return function(name: string, args: Json.Value, budget: Worker.Budget): (Json.Value) | (nil, Failure)
    local fields, _ = Json.to_object(args)
    local given: {string: Json.Value} = fields or {}
    if name == "sql" then
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
          ": it serves sql, store.put, store.get, mcp.servers, mcp.tools, mcp.call and use")
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
  ["sql"] = true, ["store.get"] = true, ["store.put"] = true,
  ["mcp.servers"] = true, ["mcp.tools"] = true, ["mcp.call"] = true,
}

--- What `context`'s amend makes of the host call `name` with `given`, which answered `result`: the value the
--- snippet reads, or nil and why. An amend that raises, or answers no text, makes the call fail.
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

--- What a tool code may call ([`Tools.for_code`]) answers a snippet of `context` that calls it with `args`,
--- `{name, input}` ([`Host.use`]): its text, or its error result as a failure. The call is asked of the guard first,
--- and given to the amend after, by the tool's own name, as the model's calls of it are.
local function used(context: Tools.Context, args: Json.Value): (Json.Value) | (nil, Failure)
  local fields, _ = Json.to_object(args)
  local given: {string: Json.Value} = fields or {}
  local named = given["name"]
  if not (named is string) then return nil, Failure.new("the call names no tool") end
  local t = Tools.find(context.tools or {}, named)
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
  local tool_ran, answered = pcall(t.run, input, context)
  local result: Tools.Result = if tool_ran then answered else
    { text = "the tool " .. named .. " failed: " .. tostring(answered), is_error = true } end
  local amend = context.amend
  if amend ~= nil then
    local amend_ran, made = pcall(amend, named, input, result)
    if not amend_ran then
      return nil, Failure.new("the agent's after hook failed: " .. tostring(made))
    end
    result = made
  end
  if result.is_error then return nil, Failure.new(result.text) end
  return result.text
end

--- What answers the calls a snippet of `context` makes of the agent (sql as the sql tool runs it, store.get,
--- store.put, and mcp.servers, mcp.tools and mcp.call), each asked of its guard first and given to its amend
--- after, failed or not. A call of no other name is refused before either is asked.
local function served(context: Tools.Context): Worker.Serve
  local answer_of = served_unguarded(context)
  return function(name: string, args: Json.Value, budget: Worker.Budget): (Json.Value) | (nil, Failure)
    if name == "use" then return used(context, args) end
    if SERVED[name] ~= true then
      return nil, Failure.new("the agent serves no call " .. Json.quote(String.as_utf8(name)) ..
          ": it serves sql, store.put, store.get, mcp.servers, mcp.tools, mcp.call and use")
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

--- What a tool of one `path` touches: that path, once for each of `actions`.
local function touches(actions: {string}): function(input: Tools.Object, cwd: string): {Tools.Touch}
  return function(input: Tools.Object, cwd: string): {Tools.Touch}
    local path = input["path"]
    if not path is string then return {} end
    local parts: mut {string} = {}
    for part in resolve(path, cwd):gmatch("[^/]+") do
      if part == ".." then
        if #parts > 0 then table.remove(parts) end
      elseif part ~= "." then
        parts[#parts + 1] = part
      end
    end
    local out: mut {Tools.Touch} = {}
    for _, action in ipairs(actions) do
      out[#out + 1] = { path = "/" .. table.concat(parts, "/"), action = action }
    end
    return out
  end
end

--- Every tool, in the order the system prompt lists them.
local ALL <const>: {Tools.Tool} = {
  {
    name = "read",
    snippet = "Read file contents",
    guidelines = { "Use read to examine files instead of cat or sed." },
    description = "Read the contents of a file. Output is truncated to " .. LIMIT .. " (whichever is hit first). Use offset/limit for large files. " ..
      "When you need the full file, continue with offset until complete.",
    schema = schema({
      path = string_field("Path to the file to read (relative or absolute)"),
      offset = integer_field("Line number to start reading from (1-indexed)"),
      limit = integer_field("Maximum number of lines to read"),
    }, { "path" }),
    run = read,
    paths = touches({ "read" }),
  },
  {
    name = "bash",
    snippet = "Execute bash commands (ls, grep, find, etc.)",
    guidelines = {},
    description = "Execute a bash command in the current working directory. Returns stdout and stderr. " ..
      "Output is truncated to last " .. LIMIT ..
      " (whichever is hit first). If truncated, full output is saved to a temp file. " ..
      "Optionally provide a timeout in seconds.",
    schema = schema({
      command = string_field("Shell command to execute"),
      timeout = integer_field("Timeout in seconds (optional, no default timeout)"),
      background = { type = "boolean", description = "Run it as a background job and answer at once " ..
          "(optional): for servers, watchers and long builds. Read it with jobs." },
    }, { "command" }),
    run = bash,
  },
  {
    name = "run",
    snippet = "Run a checked cosmic program in place of many tool calls",
    guidelines = {},
    -- The words are the text template run_text.tmpl (cosmic.template).
    description = RunText.render({ kb = RUN_BYTES // 1024 }),
    schema = schema({
      code = string_field("The cosmic program, as the body of a file"),
      timeout = integer_field("Seconds, " .. tostring(RUN_SECONDS) .. " by default, 0 for none; past it the " ..
          "worker ends"),
      output_bytes = integer_field("About the most bytes of output to show, " .. tostring(RUN_BYTES) ..
          " by default, 1024 to " .. tostring(RUN_MOST)),
    }, { "code" }),
    run = run,
  },
  {
    name = "jobs",
    snippet = "Read, wait for or kill the background jobs bash started",
    guidelines = { "Start a server, a watcher or a long build with bash background: true, then read it with " ..
        "jobs; jobs end when the session does." },
    description = "Without id, lists the background jobs: id, state, seconds run, command. With id, says " ..
      "how the job stands and gives its output since the last read, its last " ..
      LIMIT .. ". " ..
      "wait waits up to that many seconds for it to exit; kill ends it and what it started.",
    schema = schema({
      id = integer_field("The job's id, as bash answered it"),
      wait = integer_field("Seconds to wait for the job to exit (optional)"),
      kill = { type = "boolean", description = "End the job (optional)" },
    }, {}),
    run = jobs,
  },
  {
    name = "edit",
    snippet = "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
    guidelines = {
      "Use edit for targeted changes. Batch changes to one file in a single call.",
      "Each edits[].oldText must exactly and uniquely match the original file. Keep matches short and " ..
        "non-overlapping; merge nearby changes without including large unchanged regions.",
    },
    description = "Edit a single file using exact text replacement. Every edits[].oldText must match a unique, " ..
      "non-overlapping region of the original file. If two changes affect the same block or nearby lines, " ..
      "merge them into one edit instead of emitting overlapping edits. Do not include large unchanged " ..
      "regions just to connect distant changes.",
    schema = schema({
      path = string_field("Path to the file to edit (relative or absolute)"),
      edits = {
        type = "array",
        description = "One or more targeted replacements. Each edit is matched against the original file, " ..
          "not incrementally. Do not include overlapping or nested edits. If two changes touch the same " ..
          "block or nearby lines, merge them into one edit instead.",
        items = schema({
          oldText = string_field("Exact text for one targeted replacement. It must be unique in the original " ..
              "file and must not overlap with any other edits[].oldText in the same call."),
          newText = string_field("Replacement text for this targeted edit."),
        }, { "oldText", "newText" }),
      },
    }, { "path", "edits" }),
    run = edit,
    paths = touches({ "read", "write", "create" }),
  },
  {
    name = "write",
    snippet = "Create or overwrite files",
    guidelines = { "Use write only for new files or complete rewrites." },
    description = "Write content to a file. Creates the file if it doesn't exist, overwrites if it does. " ..
      "Automatically creates parent directories.",
    schema = schema({
      path = string_field("Path to the file to write (relative or absolute)"),
      content = string_field("Content to write to the file"),
    }, { "path", "content" }),
    run = write,
    paths = touches({ "write", "create" }),
  },
  {
    name = "sql",
    snippet = "Query sessions.db, where every conversation and every tool's whole output is kept",
    guidelines = { "Each tool's whole output is kept in sessions.db: use sql to find and read what was cut, " ..
        "or seen before, rather than running a command again." },
    description = "Run one read-only SQLite statement on sessions.db, where the agent keeps every session. " ..
      "Tables: sessions (id, cwd, started (Unix time), model); messages (session, seq, message: the JSON " ..
      "the API takes); outputs (id, session, tool, input (JSON), text (the whole output), is_error); " ..
      "outputs_fts, FTS5 over outputs.text with the trigram tokenizer (rowid = outputs.id): " ..
      "outputs_fts MATCH '\"some text\"' for text of 3 characters or more, with snippet(outputs_fts, 0, " ..
      "'>>', '<<', '...', 64) and ORDER BY rank. ?1 is the current session's id. " ..
      "Returns the column names, then a line a row, cells split by tabs: at most " .. LIMIT .. ". " ..
      "A statement may run " .. String.counted(SQL_SECONDS, "second") .. ".",
    schema = schema({
      query = string_field("One SQLite statement, for example: SELECT text FROM outputs WHERE id = 3"),
    }, { "query" }),
    run = sql,
  },
}

--- Every tool, in the order the system prompt lists them: a new list,
--- yours to change.
---
---     for _, t in ipairs(Tools.all()) do print(t.name) end -- read bash run jobs edit write sql
function Tools.all(): mut {Tools.Tool}
  local out: mut {Tools.Tool} = {}
  for _, t in ipairs(ALL) do out[#out + 1] = t end
  return out
end

--- Those of `tools` named in `names`, in the order of `tools`; a name
--- that none of them has is passed over.
---
---     local reading = Tools.only(Tools.all(), { "read", "sql" })
function Tools.only(tools: {Tools.Tool}, names: {string}): mut {Tools.Tool}
  local named: mut {string: boolean} = {}
  for _, n in ipairs(names) do named[n] = true end
  local out: mut {Tools.Tool} = {}
  for _, t in ipairs(tools) do
    if named[t.name] == true then out[#out + 1] = t end
  end
  return out
end

--- Those of `tools` not named in `names`, in the order of `tools`.
---
---     local quiet = Tools.without(Tools.all(), { "bash", "jobs" })
function Tools.without(tools: {Tools.Tool}, names: {string}): mut {Tools.Tool}
  local named: mut {string: boolean} = {}
  for _, n in ipairs(names) do named[n] = true end
  local out: mut {Tools.Tool} = {}
  for _, t in ipairs(tools) do
    if named[t.name] == nil then out[#out + 1] = t end
  end
  return out
end

--- What an agent offers unless told: every tool but bash and jobs, so
--- no program runs: without bash a snippet's worker starts no process
--- either ([`Worker.Options`] `commands`, on Linux under a sandbox).
function Tools.default(): mut {Tools.Tool}
  return Tools.without(ALL, { "bash", "jobs" })
end

--- Runs `tool` on `input` in `context`, the background jobs looked at
--- first: those that exited are settled, and their timeouts and the
--- bound on their output kept.
function Tools.call(tool: Tools.Tool, input: Tools.Object, context: Tools.Context): Tools.Result
  Jobs.check(context.jobs)
  return tool.run(input, context)
end

--- Runs the first of `tools` named `name` on `input` in `context`, as
--- [`Tools.call`] does; one not there is an error result.
function Tools.dispatch(tools: {Tools.Tool}, name: string, input: Tools.Object, context: Tools.Context): Tools.Result
  Jobs.check(context.jobs)
  local t = Tools.find(tools, name)
  if t == nil then return fail("Tool " .. name .. " not found") end
  return t.run(input, context)
end

--- Runs the tool of [`Tools.all`] named `name` on `input` in `context`;
--- an unknown tool is an error result.
function Tools.run(name: string, input: Tools.Object, context: Tools.Context): Tools.Result
  return Tools.dispatch(ALL, name, input, context)
end

--- The tools of `names`, a list such as "run,read,edit,write", "all" for every tool ([`Tools.all`]) or "default"
--- for [`Tools.default`]'s, in the order of [`Tools.all`]: or nil and why, for an empty list or a name no tool has.
function Tools.named(names: string): ({Tools.Tool}) | (nil, string)
  if names == "all" then return Tools.all() end
  if names == "default" then return Tools.default() end
  local picked: mut {string} = {}
  local wanted: mut {string: boolean} = {}
  for name in names:gmatch("[^,%s]+") do
    if Tools.find(ALL, name) == nil then
      local known: mut {string} = {}
      for _, t in ipairs(ALL) do known[#known + 1] = t.name end
      return nil, "no tool " .. name .. "; the tools are " .. table.concat(known, ", ")
    end
    picked[#picked + 1] = name
    wanted[name] = true
  end
  if #picked == 0 then return nil, "name at least one tool" end
  if wanted["jobs"] == true and wanted["bash"] ~= true then
    return nil, "jobs reads bash's background jobs: offer bash too"
  end
  return Tools.only(ALL, picked)
end

--- The tools of `tools` the model may call ([`Tools.for_model`]), as the Messages API takes them. The last is a cache breakpoint: the tools come first in a request, and
--- are the same in every session of a model whatever its directory and prompt, so each session reads them from the
--- cache another wrote, where the project's instructions in the system prompt and the messages after them differ.
function Tools.definitions(tools: {Tools.Tool}): Json.Value
  local out: mut {Json.Value} = {}
  local offers_bash = Tools.find(tools, "bash") ~= nil
  local last: mut {string: Json.Value}? = nil
  for _, t in ipairs(tools) do
    if Tools.for_model(t) then
      -- Without bash a snippet runs no program, so run's description names no Host.bash.
      local description = if t.name == "run" and not offers_bash then
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
