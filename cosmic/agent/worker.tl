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
--- the worker's standard error, a pipe this module reads while the snippet runs, between [`Worker.MARK_START`] and
--- [`Worker.MARK_END`]: an answer of `ok` gains `output`, the last 64KB of it as UTF-8, and `cut` true where more was
--- written. Only the end is held, so a snippet that prints without end fills no file. Before its answer, a snippet may call the
--- agent ([`cosmic.agent.host`]): a line `{"id":1,"call":"sql","args":{...}}`, which [`Worker.Options.serve`] answers
--- in the agent and the reply goes back on the worker's input, `{"reply":...}` or `{"failed":"..."}`. A snippet sets no global, which the checker
--- refuses; what it keeps for the next it writes to a file. Its standard input is /dev/null.
---
--- Under a policy the worker is held as bash is, with two changes: it is granted this program's own file (read and
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
  --- What the worker writes on its output before a request's, which ends what came before: a program an earlier
  --- snippet started may still write.
  MARK_START: string
  --- What the worker writes on its output after a request's.
  MARK_END: string

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
    local merged, why = Sandbox.merge(given, { profiles = { "cosmic" } })
    if merged == nil then return nil, Failure.new("worker: " .. why) end
    local promises: mut {Sandbox.Promise} = {}
    for _, promise in ipairs(merged.promises or {}) do
      if promise ~= "nest" then promises[#promises + 1] = promise end
    end
    policy = { grants = merged.grants, isolate = merged.isolate, promises = promises, connect = merged.connect,
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

--- The worker's answer to the request `id`, read from `lines`, each call it makes before it answered by `serve` and
--- replied to on `writer`: or why there is none, which ends the worker.
local function answer_of(lines: Stream.Lines, writer: Stream.Writer, id: integer, serve: Worker.Serve?,
                         budget: Worker.Budget): Worker.Answer?, string
  while true do
    local line, read_why = lines:read()
    if line == nil then
      return nil, "it ended" .. (if read_why ~= "" then ": " .. read_why else "" end)
    end
    local message, decode_why = Json.decode_object(line, { null_value = Json.null })
    if message == nil then return nil, "its answer is no JSON object: " .. tostring(decode_why) end
    -- A line for another request (one the snippet wrote where the answers go) puts every later one out of step.
    if message["id"] ~= id then return nil, "it answered another request than this one" end
    local call = message["call"]
    if call == nil then return message, "" end
    local reply: {string: Json.Value}
    if not (call is string) then
      reply = { failed = "a call is named by a string" }
    elseif serve == nil then
      reply = { failed = "the agent serves no call to this worker" }
    else
      local args = message["args"]
      local value, why = serve(call, if args == nil then Json.null else args end, budget)
      reply = if value == nil then { failed = tostring(why) } else { reply = value } end
    end
    local text, encode_why = Json.encode(reply)
    if text == nil then
      text = assert(Json.encode({ failed = "the reply is no JSON: " .. tostring(encode_why) }))
    end
    local wrote, write_why = writer:write(text .. "\n")
    if not wrote then return nil, "it ended: " .. write_why end
  end
end

--- The last [`Worker.OUTPUT_BYTES`] of `text`, from a character's start, as UTF-8.
function Worker.tail(text: string): string
  if #text <= Worker.OUTPUT_BYTES then return String.as_utf8(text) end
  local from = #text - Worker.OUTPUT_BYTES + 1
  while from <= #text and (text:byte(from) or 0) & 0xC0 == 0x80 do from = from + 1 end
  return String.as_utf8(text:sub(from))
end

--- A request's output, as it is read: what came after its start mark, at most its last [`Worker.OUTPUT_BYTES`] and a
--- few, and whether more came.
local record Output
  mut started: boolean
  mut ended: boolean
  mut kept: string
  mut cut: boolean
end

--- `output` with `chunk` read: what comes before the start mark dropped, what comes after the end mark too, and only the
--- end kept, with a mark's length beside it, which may be the start of a mark cut in two.
local function took(output: Output, chunk: string)
  local text = output.kept .. chunk
  if not output.started then
    local _, at = text:find(Worker.MARK_START, 1, true)
    if at == nil then
      output.kept = text:sub(-(#Worker.MARK_START - 1))
      return
    end
    output.started = true
    text = text:sub(at + 1)
  end
  local ends = text:find(Worker.MARK_END, 1, true)
  if ends ~= nil then
    text = text:sub(1, ends - 1)
    output.ended = true
  end
  -- 4 more than an answer holds, so that a character cut at the start is told apart from one more byte.
  local hold = Worker.OUTPUT_BYTES + 4 + (if output.ended then 0 else #Worker.MARK_END - 1 end)
  if #text > hold then
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
  local output: Output = { started = false, ended = false, kept = "", cut = false }
  local id = set.next
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
    -- The worker marks the end of the output before it answers, so it is near once the answer is in.
    if answer ~= nil and not timed_out and not halted then
      local _, _ = printed:join(OUTPUT_WAIT)
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
    return nil, Failure.new("worker: " .. trouble .. "; the next run starts a new one")
  end
  if got["ok"] ~= nil then
    if not output.ended then
      Worker.close(set)
      return nil, Failure.new("worker: its output has no end; the worker was ended, and the next run starts a new one")
    end
    local with: mut {string: Json.Value} = {}
    for k, v in pairs(got) do with[k] = v end
    with["output"] = Worker.tail(output.kept)
    if output.cut or #output.kept > Worker.OUTPUT_BYTES then with["cut"] = true end
    return with
  end
  return got
end

Worker.OUTPUT_BYTES = 64 * 1024
Worker.MARK_START = "\0\0cosmic agent worker: start\0\0"
Worker.MARK_END = "\0\0cosmic agent worker: end\0\0"

return Worker
