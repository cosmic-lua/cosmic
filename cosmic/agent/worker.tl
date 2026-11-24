--- @public
--- The worker of `cosmic agent`'s `run` tool: one process a session, `cosmic agent worker`, that checks and runs the
--- snippets of Teal the model sends, one after another, under the sandbox the other tools are held to. It is started
--- when the model first calls `run`, and lives until the session ends. A snippet that runs past its timeout, or a turn
--- the user stops, ends the worker, and the next `run` starts another. Its checker lives as long as it does, so a snippet that requires what an
--- earlier one did is checked in a few milliseconds.
---
---     local w = Worker.new()
---     local answer = assert(Worker.run(w, "print(1)", { cwd = "/work", seconds = 30 }))
---     print(answer["output"]) -- 1
---     Worker.close(w)
---
--- The worker reads requests, `{"id":1,"code":"..."}`, one JSON object a line, and answers each with a line holding
--- the request's `id` and one of: `refused`, the checker's lines, for a snippet that did not run; `ok` true and `value`
--- (the JSON of what it returned, where it returned one, at most 64KB); `ok` false and `error`, for one that raised; or
--- `error` alone, for a request it could not read. What a snippet writes to standard output and standard error goes to
--- the worker's standard error, a pipe this module reads while the snippet runs, between the request's marks
--- ([`Worker.mark`]): an answer of `ok` gains `output`, all of it as UTF-8 where it is 64KB or less, else its first
--- 16KB and its last 48KB with a line between them of how many bytes were cut, `cut` true then, and `head_bytes` and
--- `tail_bytes`, the length of each part; and `bytes`, how much was written. Only its start and its end are held, so a
--- snippet that prints without end fills no file. Before its answer, a snippet may call the
--- agent ([`cosmic.agent.host`]): a line `{"id":1,"call":"sql","args":{...}}`, which [`Worker.Options.serve`] answers
--- in the agent and the reply goes back on the worker's input, `{"reply":...}` or `{"failed":"..."}`. A snippet sets no global, which the checker
--- refuses; what it keeps for the next it keeps with [`Host.store`], or writes to a file. Its standard input is /dev/null.
---
--- Under a policy the worker is held as bash is, with these changes. Where it runs no commands
--- ([`Worker.Options.commands`] false), on Linux it keeps no right to run a file but this program's own, and has no
--- fork promise, so no program runs; on macOS it keeps them (Seatbelt's `x` maps libraries too). Beside that: it is granted this program's own file (read and
--- run), which it runs as, and it is not given the nest promise, beside which this program cannot be started again, so
--- Landlock holds its files too. Its environment is the policy's alone, so no key of the user's reaches it. With no
--- policy (`--sandbox off`) it has the agent's whole environment, the API key included, as bash does then.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Failure = require("cosmic.failure")
local Json = require("cosmic.json")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local String = require("cosmic.string")
local Sandbox = require("cosmic.sandbox")
local Stream = require("cosmic.stream")

local record Worker
  --- The most bytes of a snippet's output an answer holds: 64KB.
  OUTPUT_BYTES: integer

  --- What the worker writes on its output before (`kind` "start") and after ("end") the output of the request `id`.
  --- What comes before the start is not that request's: a program an earlier snippet started may still write. The
  --- id keeps one request's marks from ending another's; a snippet that prints its own end mark ends its own output.
  mark: function(kind: string, id: integer): string

  --- The last `most` bytes of `text`, [`Worker.OUTPUT_BYTES`] by default, from a character's start, as UTF-8.
  tail: function(text: string, most?: integer): string

  --- What one snippet runs with.
  record Options
    --- Where the worker starts: the session's working directory.
    cwd: string
    --- What it is held to (cosmic.agent.policy); nil for nothing.
    policy?: Sandbox.Policy
    --- How long the snippet may run, in seconds; nil or 0 for no limit.
    seconds?: integer
    --- Whether the user stopped the turn, which ends the worker as a timeout does.
    stopped?: function(): boolean
    --- The agent's reply to a call the snippet makes ([`cosmic.agent.host`]), or why it has none; nil to serve no
    --- call. It runs in the agent, outside the sandbox: it checks what it is given as a tool checks its input.
    serve?: Worker.Serve
    --- Whether a snippet may run programs (Host.bash, cosmic.child): false holds the worker to no new process and
    --- no file run, by its policy, so that what it does is only what the agent serves it and its grants allow. That
    --- holds on Linux under a policy: on macOS, or with no policy, a snippet may still run a program. Only the first
    --- snippet's starts the worker; nil is true.
    commands?: boolean
  end

  --- What answers a snippet's call `name` with `args`.
  --- How long a call a snippet makes may take: a long call tests it, and stops.
  record Budget
    --- Whether the snippet's time ran out, or the user stopped the turn.
    over: function(): boolean
    --- The time left to the snippet, in nanoseconds, 0 once it ran out; nil where it has no limit.
    left: function(): integer?
  end

  type Serve = function(name: string, args: Json.Value, budget: Budget): (Json.Value) | (nil, Failure)

  --- The worker of a session: none until the first snippet.
  record Set
    --- The command that starts it; `cosmic agent worker` by this program's own file by default.
    argv: {string}
    --- The environment and descriptors it starts with beside its pipes, where given: a test's.
    base?: Child.Options
    --- The worker running, nil where none runs.
    mut handle?: Child.Handle
    --- Its answers, a line each.
    mut lines?: Stream.Lines
    --- Its requests.
    mut writer?: Stream.Writer
    --- The output of its snippets.
    mut output?: Stream.Reader
    --- The id the next request is sent with.
    mut next: integer
    --- How many workers it started.
    mut started: integer
  end

  --- What the worker answered for a snippet, as it sent it: see above.
  type Answer = {string: Json.Value}
end

--- How often a wait for an answer looks whether the user stopped the turn.
local STOP_CHECK <const> = Clock.ms(100)

--- How long the output of a snippet that answered may take to end.
local OUTPUT_WAIT <const> = Clock.seconds(5)

--- A set with no worker yet, started by `argv` where given, with the `env` and `fds` of `base`.
function Worker.new(argv?: {string}, base?: Child.Options): Worker.Set
  local command = argv
  if command == nil then
    local self, _ = Proc.executable()
    command = { self or "cosmic", "agent", "worker" }
  end
  return { argv = command, base = base, next = 1, started = 0 }
end

--- Ends the worker of `set`, if one runs; the next snippet starts another.
function Worker.close(set: Worker.Set)
  local writer, handle = set.writer, set.handle
  set.writer, set.lines, set.handle, set.output = nil, nil, nil, nil
  if writer ~= nil then local _, _ = writer:close() end
  if handle ~= nil then local _, _ = handle:close() end
end

--- The worker of `set`, started under `opts` where none runs.
local function started(set: Worker.Set, opts: Worker.Options): (Stream.Lines) | (nil, Failure)
  local lines = set.lines
  if lines ~= nil then return lines end
  local policy: Sandbox.Policy? = nil
  local given = opts.policy
  if given ~= nil then
    -- TODO: copy `merged` whole, changing its promises alone, once a record can be copied with a field changed: a field
    -- Sandbox.Policy gains is left out of this copy, and so given to the worker as nothing.
    local merged, why = Sandbox.union(given, { profiles = { "cosmic" } })
    if merged == nil then return nil, Failure.new("worker: " .. why) end
    local promises: mut {Sandbox.Promise} = {}
    local runs = opts.commands ~= false
    for _, promise in ipairs(merged.promises or {}) do
      if promise ~= "nest" and (runs or promise ~= "fork") then
        promises[#promises + 1] = promise
      end
    end
    local grants: mut {Sandbox.Grant} = {}
    -- The worker is this program, which its start runs as its core where the policy grants it `x` ("cosmic").
    local self, _ = Proc.executable()
    -- On macOS `x` lets dyld map a library as well as run a file, so it stays: with no `fork` the worker starts no
    -- process there either, though it could still become another program.
    -- TODO: hold an x grant on macOS as map-only (Seatbelt's file-map-executable alone) once a grant can say so.
    local strip = not runs and not Sandbox.on_macos()
    for _, grant in ipairs(merged.grants or {}) do
      -- With no commands, no other grant runs a file, so the worker cannot become another program either; as this
      -- one, it is held as it was, with no process to start. A grant of `x` alone is then no grant.
      local letters = if strip and grant.path ~= self then (grant.letters:gsub("x", "")) else grant.letters end
      if letters ~= "" then
        grants[#grants + 1] = { path = grant.path, letters = letters, from = grant.from }
      end
    end
    policy = { grants = grants, isolate = merged.isolate, promises = promises, connect = merged.connect,
      loopback = merged.loopback, env = merged.env, set_env = merged.set_env, set_env_digests = merged.set_env_digests,
      tmp = merged.tmp, limits = merged.limits, user = merged.user, group = merged.group, database = merged.database }
  end
  local base = set.base
  local handle, why = Child.start(set.argv, { cwd = opts.cwd, stdin = "stream", stdout = "stream", stderr = "stream",
    policy = policy, timeout_ns = Child.FOREVER, env = if base ~= nil then base.env else nil end,
    fds = if base ~= nil then base.fds else nil end })
  if handle == nil then return nil, Failure.new("worker: starting it: " .. tostring(why)) end
  local reader, writer, output = handle.stdout_stream, handle.stdin_stream, handle.stderr_stream
  if reader == nil or writer == nil or output == nil then
    local _, _ = handle:close()
    return nil, Failure.new("worker: it has no pipes")
  end
  lines = Stream.lines(reader)
  set.handle, set.writer, set.lines, set.output = handle, writer, lines, output
  set.started = set.started + 1
  return lines
end

--- The reply to the call `message` a snippet made, as `serve` answers it: `{"reply":...}` or `{"failed":"..."}`, with
--- the call's `call_id`.
local function reply_to(message: {string: Json.Value}, serve: Worker.Serve?, budget: Worker.Budget): string
  local call = message["call"]
  local reply: mut {string: Json.Value}
  if not (call is string) then
    reply = { failed = "a call is named by a string" }
  elseif serve == nil then
    reply = { failed = "the agent serves no call to this worker" }
  else
    local args = message["args"]
    local value, why = serve(call, if args == nil then Json.null else args end, budget)
    reply = if value == nil then { failed = tostring(why) } else { reply = value } end
  end
  local call_id = message["call_id"]
  if call_id ~= nil then reply["call_id"] = call_id end
  local text, encode_why = Json.encode(reply)
  if text == nil then
    local failed: mut {string: Json.Value} = { failed = "the reply is no JSON: " .. tostring(encode_why) }
    if call_id ~= nil then failed["call_id"] = call_id end
    text = assert(Json.encode(failed))
  end
  return text
end

--- The worker's answer to the request `id`, read from `lines`, each call it makes before it answered by `serve` and
--- replied to on `writer`: or why there is none, which ends the worker. Each call is served in a task of its own, so
--- calls a snippet makes from tasks of its own are served at once; each reply goes out whole, one at a time.
local function answer_of(lines: Stream.Lines, writer: Stream.Writer, id: integer, serve: Worker.Serve?,
                         budget: Worker.Budget): Worker.Answer?, string
  local answer: Worker.Answer? = nil
  local trouble = ""
  Poll.within(function()
    local serving: mut {Poll.Task} = {}
    local writing = false
    local done = false
    local written = Poll.notifier()
    while true do
      local line, read_why = lines:read()
      if line == nil then
        trouble = "it ended" .. (if read_why ~= "" then ": " .. read_why else "" end)
        break
      end
      local message, decode_why = Json.decode_object(line, { null_value = Json.null })
      if message == nil then
        trouble = "its answer is no JSON object: " .. tostring(decode_why)
        break
      end
      -- A line for another request (one the snippet wrote where the answers go) puts every later one out of step.
      if message["id"] ~= id then
        trouble = "it answered another request than this one"
        break
      end
      if message["call"] == nil then
        answer = message
        break
      end
      local task = Poll.spawn(function()
        local text = reply_to(message, serve, budget)
        while writing and not done do local _, _ = written:wait() end
        -- Once the snippet answered, no reply goes out: one cut short would be read as the next request.
        if done then return end
        writing = true
        -- A worker that ended is read as ended next. Shielded: a reply cut short when the snippet answers would be read
        -- as the start of the next request.
        Poll.shielded(function() local _, _ = writer:write(text .. "\n") end)
        writing = false
        written:notify_all()
      end)
      serving[#serving + 1] = task
    end
    done = true
    -- Shielded: a cancelled run (a timeout, a stop) still waits for the calls it served to end.
    Poll.shielded(function()
      for _, task in ipairs(serving) do task:cancel() end
      for _, task in ipairs(serving) do local _, _ = task:join() end
    end)
  end)
  local got = answer
  if got == nil then return nil, trouble end
  return got, ""
end

--- The mark of `kind` ("start" or "end") of the output of the request `id`.
function Worker.mark(kind: string, id: integer): string
  return "\0\0cosmic agent worker: " .. kind .. " " .. tostring(id) .. "\0\0"
end

--- The last `most` bytes of `text`, [`Worker.OUTPUT_BYTES`] by default, from a character's start, as UTF-8.
function Worker.tail(text: string, most?: integer): string
  local top = most or Worker.OUTPUT_BYTES
  if #text <= top then return String.as_utf8(text) end
  local from = #text - top + 1
  while from <= #text and (text:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
  return String.as_utf8(text:sub(from))
end

--- A request's output, as it is read.
local record Output
  --- Its marks ([`Worker.mark`]).
  start: string
  finish: string
  --- Whether its start mark was read.
  mut started: boolean
  --- Whether its end mark was read.
  mut ended: boolean
  --- What came after its start mark: before the end mark, its last bytes alone, past what an answer holds by a mark's
  --- length, which may be the start of a mark cut in two; before the start mark, those bytes alone.
  mut kept: string
  --- Whether bytes after the start mark were let go.
  mut cut: boolean
  --- What came before the start mark, its last bytes: what the worker wrote as it failed to start.
  mut before: string
  --- The first [`HEAD_BYTES`] after the start mark, held once bytes are let go.
  mut head: string
  --- How many bytes after the start mark were let go.
  mut dropped: integer
end

--- How many bytes an output holds past what an answer does: one more tells it was cut, and a mark cut in two is held.
local HOLD_MORE <const> = 64

--- The most bytes of the start of a snippet's output an answer holds, where the whole is more than it holds: the
--- rest, TAIL_BYTES, is the end, and between them a line says how much was cut.
local HEAD_BYTES <const> = 16 * 1024
local TAIL_BYTES <const> = 48 * 1024

--- The last `most` bytes of `text`, from a character's start.
local function last(text: string, most: integer): string
  if #text <= most then return text end
  local from = #text - most + 1
  while from <= #text and (text:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
  return text:sub(from)
end

--- How many bytes of what came before the start mark a failure tells.
local TOLD <const> = 1024

--- `output` with `chunk` read: what comes before its start mark dropped, after its end mark too, and only the end held.
local function took(output: Output, chunk: string)
  local text = output.kept .. chunk
  if not output.started then
    local _, at = text:find(output.start, 1, true)
    if at == nil then
      output.before = (output.before .. chunk):sub(-TOLD)
      output.kept = text:sub(-(#output.start - 1))
      return
    end
    output.started = true
    text = text:sub(at + 1)
    output.kept = ""
  end
  -- The end mark is looked for only where it can begin: in what was held but a mark's length, and in the chunk.
  local ends = text:find(output.finish, math.max(1, #output.kept - #output.finish + 2), true)
  if ends ~= nil then
    text = text:sub(1, ends - 1)
    output.ended = true
  end
  -- Cut back only past twice what is held, so that a run of small chunks does not copy the whole each time.
  local hold = Worker.OUTPUT_BYTES + HOLD_MORE
  if #text > 2 * hold or (output.ended and #text > hold) then
    -- What was held until now is the start of the output: nothing was let go before.
    if not output.cut then output.head = String.cut(text, HEAD_BYTES) end
    output.dropped = output.dropped + #text - hold
    text = text:sub(-hold)
    output.cut = true
  end
  output.kept = text
end

--- Checks and runs `code` in the worker of `set`, starting one under `opts` where none runs: the worker's answer, or
--- why there is none. A snippet that runs past `opts.seconds` ends the worker, and is answered so.
function Worker.run(set: Worker.Set, code: string, opts: Worker.Options): (Worker.Answer) | (nil, Failure)
  local lines, why = started(set, opts)
  if lines == nil then return nil, why end
  local writer = assert(set.writer)
  local reader = assert(set.output)
  local id = set.next
  local output: Output = { start = Worker.mark("start", id), finish = Worker.mark("end", id), started = false,
    ended = false, kept = "", cut = false, before = "", head = "", dropped = 0 }
  set.next = id + 1
  local request, encode_why = Json.encode({ id = id, code = code })
  if request == nil then return nil, Failure.new("worker: " .. tostring(encode_why)) end
  local wrote, write_why = writer:write(request .. "\n")
  if not wrote then
    Worker.close(set)
    return nil, Failure.new("worker: it ended: " .. write_why)
  end
  local seconds = opts.seconds
  local answer: Worker.Answer? = nil
  local trouble = ""
  local timed_out, halted = false, false
  local stopped = opts.stopped
  local deadline = if seconds ~= nil and seconds > 0 then Clock.monotonic_ns() + Clock.seconds(seconds) else nil end
  local budget: Worker.Budget = {
    over = function(): boolean
      return (deadline ~= nil and Clock.monotonic_ns() >= deadline) or (stopped ~= nil and stopped())
    end,
    left = function(): integer?
      if deadline == nil then return nil end
      return math.max(deadline - Clock.monotonic_ns(), 0)
    end,
  }
  Poll.within(function()
    local reading = Poll.spawn(function()
      answer, trouble = answer_of(lines, writer, id, opts.serve, budget)
    end)
    local printed = Poll.spawn(function()
      while not output.ended do
        local chunk, _ = reader:read()
        if chunk == nil then return end
        took(output, chunk)
      end
    end)
    while true do
      local slice = STOP_CHECK
      if deadline ~= nil then
        slice = math.max(math.min(slice, deadline - Clock.monotonic_ns()), 0)
      end
      local done, _ = reading:join(slice)
      if done then break end
      if stopped ~= nil and stopped() then
        halted = true
      elseif deadline ~= nil and Clock.monotonic_ns() >= deadline then
        timed_out = true
      end
      if halted or timed_out then
        reading:cancel()
        local _, _ = reading:join()
        break
      end
    end
    -- The worker marks the end of the output before it answers, so it is near once the answer is in; an answer to a
    -- request the worker could not read has no output.
    local given = answer
    if given ~= nil and given["ok"] ~= nil and not timed_out and not halted then
      local waited = Clock.monotonic_ns() + OUTPUT_WAIT
      while not output.ended and Clock.monotonic_ns() < waited and not (stopped ~= nil and stopped()) do
        local done, _ = printed:join(STOP_CHECK)
        if done then break end
      end
    end
    printed:cancel()
    local _, _ = printed:join()
  end)
  local got = answer
  if timed_out or halted or got == nil then
    Worker.close(set)
    if halted then return nil, Failure.new("stopped by the user; the worker was ended") end
    if timed_out then
      return nil, Failure.new("the snippet ran past " .. String.counted(seconds or 0, "second") .. "; the worker was ended, " ..
          "and the next run starts a new one")
    end
    -- TODO: tell the end of a snippet's output when it ran past its timeout or was stopped: it is in hand.
    local said = if output.before ~= "" and not output.started then "; it wrote: " ..
        (String.as_utf8(output.before):gsub("[%z\1-\8\11-\31\127]", "")) else "" end
    return nil, Failure.new("worker: " .. trouble .. said .. "; the next run starts a new one")
  end
  if got["ok"] ~= nil then
    if not output.ended then
      Worker.close(set)
      return nil, Failure.new("worker: its output has no end; the worker was ended, and the next run starts a new one")
    end
    local with: mut {string: Json.Value} = {}
    for k, v in pairs(got) do with[k] = v end
    local total = output.dropped + #output.kept
    if total <= Worker.OUTPUT_BYTES then
      with["output"] = String.as_utf8(output.kept)
    else
      -- Its start and its end, and between them how much was cut, counted in the bytes written; `head_bytes` and
      -- `tail_bytes` tell where each part is, as UTF-8, so that what shows less of it cuts from each.
      local raw_head = String.cut(if output.cut then output.head else output.kept end, HEAD_BYTES)
      local raw_tail = last(output.kept, TAIL_BYTES)
      local head, tail = String.as_utf8(raw_head), String.as_utf8(raw_tail)
      with["output"] = head .. (if head:sub(-1) == "\n" then "" else "\n" end) .. "[... " ..
        String.counted(total - #raw_head - #raw_tail, "byte") .. " cut ...]\n" .. tail
      with["cut"] = true
      with["head_bytes"] = #head
      with["tail_bytes"] = #tail
    end
    with["bytes"] = total
    return with
  end
  return got
end

Worker.OUTPUT_BYTES = 64 * 1024

return Worker
