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
--- the request's `id` and one of: `refused`, the checker's lines, for a snippet that did not run; `ok` true,
--- `output` (what it wrote to standard output and standard error together, its last 64KB as UTF-8, `cut` true where
--- more was written) and `value` (the JSON of what it returned, where it returned one, at most 64KB); `ok` false with `output` and `error`,
--- for one that raised; or `error` alone, for a request it could not read. A snippet sets no global, which the checker
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
  end

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
  set.writer, set.lines, set.handle = nil, nil, nil
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
  local handle, why = Child.start(set.argv, { cwd = opts.cwd, stdin = "stream", stdout = "stream", stderr = "null",
    policy = policy, timeout_ns = Child.FOREVER, env = if base ~= nil then base.env else nil end,
    fds = if base ~= nil then base.fds else nil end })
  if handle == nil then return nil, Failure.new("worker: starting it: " .. why) end
  local reader, writer = handle.stdout_stream, handle.stdin_stream
  if reader == nil or writer == nil then
    local _, _ = handle:close()
    return nil, Failure.new("worker: it has no pipes")
  end
  lines = Stream.lines(reader)
  set.handle, set.writer, set.lines = handle, writer, lines
  set.started = set.started + 1
  return lines
end

--- Checks and runs `code` in the worker of `set`, starting one under `opts` where none runs: the worker's answer, or
--- why there is none. A snippet that runs past `opts.seconds` ends the worker, and is answered so.
function Worker.run(set: Worker.Set, code: string, opts: Worker.Options): (Worker.Answer) | (nil, Failure)
  local lines, why = started(set, opts)
  if lines == nil then return nil, why end
  local writer = assert(set.writer)
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
  local line: string? = nil
  local read_why = ""
  local timed_out, halted = false, false
  local stopped = opts.stopped
  Poll.within(function()
    local reading = Poll.spawn(function()
      line, read_why = lines:read()
    end)
    local deadline = if seconds ~= nil and seconds > 0 then Clock.monotonic_ns() + Clock.seconds(seconds) else nil end
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
  end)
  local got = line
  if timed_out or halted or got == nil then
    Worker.close(set)
    if halted then return nil, Failure.new("stopped by the user; the worker was ended") end
    if timed_out then
      return nil, Failure.new("the snippet ran past " .. String.counted(seconds or 0, "second") .. "; the worker was ended, " ..
          "and the next run starts a new one")
    end
    return nil, Failure.new("worker: it ended" .. (if read_why ~= "" then ": " .. read_why else "" end) ..
        "; the next run starts a new one")
  end
  local answer, decode_why = Json.decode_object(got)
  if answer == nil then
    Worker.close(set)
    return nil, Failure.new("worker: its answer is no JSON object: " .. tostring(decode_why))
  end
  -- An answer to another request (a line the snippet wrote where the answers go) puts every later answer out of step.
  if answer["id"] ~= id then
    Worker.close(set)
    return nil, Failure.new("worker: it answered another request than this one; the next run starts a new one")
  end
  return answer
end

return Worker
