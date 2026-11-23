--- `cosmic agent`: a small coding agent, after pi. Claude, through the
--- Messages API, with tools to read, write and edit files, run commands
--- (in the foreground or as background jobs) and query what it has kept,
--- held to a sandbox. [`cosmic.agent`] runs the loop; this reads the
--- command line, opens the sessions database and writes what the model
--- says.
---
--- `cosmic agent ask [prompt...]` runs one prompt to the end: the words
--- given, else all of standard input. `chat` takes a prompt a line, in
--- one conversation, until `/exit` or the end of standard input. `resume`
--- finishes the turn a run left unfinished. `rpc` runs one session for
--- another program. `sessions` lists the newest sessions in the working
--- directory, `prompt` prints the system prompt the model reads, and
--- `policy` the sandbox the tools would run under (`policy clear-home`
--- empties the commands' kept home).
---
--- The model's words go to standard output, and each tool call to
--- standard error. `ask --json` and `rpc` print events instead, one JSON
--- object a line, each after what it tells of is kept:
---
---     {"type":"session","id":7}            the session (rpc adds
---                                          "unfinished", true or false)
---     {"type":"message","message":{...}}   a message joined the
---                                          conversation, as the API
---                                          takes it: a prompt, a reply,
---                                          or tool results
---     {"type":"tool","name":"bash","input":{...}}   a tool call starts
---     {"type":"result","name":"bash","is_error":false}   it ended
---     {"type":"request","request":{...}}   a request ended: its model,
---                                          status, ms, tokens and cost
---     {"type":"end","ok":true}             the turn ended; when ok is
---                                          false, "error" says why
---     {"type":"error","error":"..."}       a command was refused
---
--- rpc reads commands, one JSON object a line, until standard input ends:
---
---     {"type":"prompt","text":"..."}       runs a turn
---     {"type":"steer","text":"..."}        during a turn: goes to the
---                                          model after the tool running,
---                                          and skips the calls after it
---     {"type":"follow_up","text":"..."}    during a turn: runs after it
---     {"type":"abort"}                     stops the turn at the next
---                                          step (SIGINT stops a tool or
---                                          a request at once)
---     {"type":"resume"}                    finishes an unfinished turn
---
--- Between turns, steer and follow_up run as prompts.
---
--- Like `cosmic json` it prints no summary: its standard output is the
--- model's words, or the events. Exit 0 is ok, 1 an ask or resume turn
--- that failed or a database it could not open (chat and rpc go on past a
--- failed turn, and say why on standard error or in its end event), 2 a command line it refuses or a session
--- it cannot start (no credential, no such session). Complaints go to
--- standard error as `cosmic: agent: ...`. Its `spec`
--- (build/verb_spec.tl) is `bare`.

local Agent = require("cosmic.agent")
local Auth = require("cosmic.agent.auth")
local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Jobs = require("cosmic.agent.jobs")
local Json = require("cosmic.json")
local Number = require("cosmic.number")
local Poll = require("cosmic.poll")
local Policy = require("cosmic.agent.policy")
local Proc = require("cosmic.proc")
local Prompt = require("cosmic.agent.prompt")
local Sandbox = require("cosmic.sandbox")
local Sessions = require("cosmic.agent.sessions")
local Signal = require("cosmic.signal")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local Tools = require("cosmic.agent.tools")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic agent` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  mut spec: verb_spec.Spec

  --- A hold of the signals over one turn.
  record Hold
    --- The signal caught since the hold began, or 0.
    caught: function(): integer
    --- Ends the hold, without acting on what it caught.
    release: function()
  end

  --- Where `run` reads and writes: what a test stands in for.
  record Io
    --- Writes one line to standard output, adding its newline.
    out: function(line: string)
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- The next line typed, `prompt` shown first where standard input
    --- is a terminal: nil at its end.
    read_line: function(prompt: string): string?
    --- All of standard input.
    read_all: function(): string
    --- The next whole line typed while the model works, without
    --- waiting: nil where none is whole yet.
    typed: function(): string?
    --- Holds SIGINT and SIGTERM while a turn runs ([`Signal.guard`]).
    hold: function(): verb.Hold
    --- Whether a person types into standard input.
    tty: function(): boolean
    --- The environment variable `name`.
    env: function(name: string): string?
    --- What opens the API's requests; nil for [`Http.open`].
    send?: Agent.Send
  end
end

local spec = assert(assert(Cli.verbs["agent"]).spec)

local USAGE <const> = "cosmic agent <ask|chat|resume|rpc|sessions|prompt|policy> [options] [words...]"

--- The options each subcommand takes; the rest of the spec is refused.
local SESSION_OPTIONS <const>: {string: boolean} = {
  ["--model"] = true, ["--effort"] = true, ["--continue"] = true, ["--session"] = true,
  ["--sandbox"] = true, ["--network"] = true, ["--grant"] = true,
}
local SANDBOX_OPTIONS <const>: {string: boolean} = { ["--sandbox"] = true, ["--network"] = true, ["--grant"] = true }
local ASK_OPTIONS <const>: mut {string: boolean} = { ["--json"] = true }
for k, v in pairs(SESSION_OPTIONS) do ASK_OPTIONS[k] = v end
local TAKES <const>: {string: {string: boolean}} = {
  ask = ASK_OPTIONS, chat = SESSION_OPTIONS, resume = SESSION_OPTIONS, rpc = SESSION_OPTIONS, sessions = {},
  prompt = {}, policy = SANDBOX_OPTIONS,
}

local EFFORTS <const>: {string: boolean} = { low = true, medium = true, high = true, xhigh = true, max = true }

-- What standard input holds past the last line read.
local pending = ""

local function read_line(prompt: string): string?
  if Proc.is_tty(Fs.stdin) then local _, _ = Fs.put(Fs.stdout, prompt) end
  while true do
    local nl = pending:find("\n", 1, true)
    if nl ~= nil then
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      return line
    end
    local chunk, _ = Fs.take(Fs.stdin, 4096)
    if chunk == nil or chunk == "" then
      if pending == "" then return nil end
      local line = pending
      pending = ""
      return line
    end
    pending = pending .. chunk
  end
end

local function typed(): string?
  while pending:find("\n", 1, true) == nil do
    local ready, _ = Poll.readable(Fs.stdin, 0)
    if not ready then return nil end
    local chunk, _ = Fs.take(Fs.stdin, 4096)
    if chunk == nil or chunk == "" then return nil end
    pending = pending .. chunk
  end
  local nl = assert(pending:find("\n", 1, true))
  local line = pending:sub(1, nl - 1)
  pending = pending:sub(nl + 1)
  return line
end

local function hold(): verb.Hold
  local guard, _ = Signal.guard()
  return {
    caught = function(): integer return if guard ~= nil then guard:cancelled() else 0 end end,
    release = function()
      if guard == nil then return end
      -- Ctrl-C stops the turn alone; SIGTERM, delivered again as the guard
      -- closes, ends the run once the turn is kept.
      if guard:cancelled() == 2 then
        local _, _ = guard:release()
      else
        local _, _ = guard:close()
      end
    end,
  }
end

local function read_all(): string
  local parts: mut {string} = {}
  while true do
    local chunk, _ = Fs.take(Fs.stdin, 65536)
    if chunk == nil or chunk == "" then break end
    parts[#parts + 1] = chunk
  end
  return table.concat(parts)
end

local standard: verb.Io = {
  out = function(line: string) local _, _ = bare.out(line .. "\n") end,
  err = bare.err,
  read_line = read_line,
  read_all = read_all,
  typed = typed,
  hold = hold,
  tty = function(): boolean return Proc.is_tty(Fs.stdin) end,
  env = Env.get,
}

--- Shortens `text` to one line of at most 80 bytes.
local function brief(text: string): string
  local line = text:gsub("\n.*", " ...")
  if #line > 80 then line = String.cut(line, 77) .. "..." end
  return line
end

--- `n` tokens, short: 950, 12.3k, 1.2M.
local function tokens(n: integer): string
  if n < 1000 then return tostring(n) end
  if n < 1000000 then return string.format("%.1fk", n / 1000) end
  return string.format("%.1fM", n / 1000000)
end

--- What the tool's call shows: the first of its input that says most.
local function shown(input: Tools.Object): string
  for _, k in ipairs({ "command", "path" }) do
    local v = input[k]
    if v is string then return brief(v) end
  end
  local text, _ = Json.encode(input)
  return brief(text or "")
end

--- The build that sends each request: the start of this binary's SHA-256,
--- as `cosmic --version` prints it whole; "" where it cannot be read.
local function build(): string
  local path, _ = Proc.executable()
  if path == nil then return "" end
  local digest, _ = Hash.hex_file("sha256", path)
  return if digest ~= nil then digest:sub(1, 12) else "" end
end

--- One run of the verb: its io, and what it read of the environment.
local record Run
  io: verb.Io
  complain: function(line: string)
  --- The variables Fs.data_dir and Fs.cache_dir read.
  environment: {string: string}
end

--- The working directory.
local function cwd(r: Run): string
  local here, _ = Fs.absolute(".")
  return here or r.io.env("PWD") or "."
end

--- The sessions database, or nil and why.
local function store(r: Run): Sqlite.Handle?, string
  local dir, why = Fs.data_dir("cosmic", { environment = r.environment })
  if dir == nil then return nil, "no data directory: " .. tostring(why) end
  return Sessions.open(dir .. "/agent/sessions.db")
end

--- The commands' kept home, under the agent's cache, which [`Fs.cache_dir`]
--- makes and holds to its owner; nil where there is none.
local function sandbox_home(r: Run): string?
  local dir, _ = Fs.cache_dir("agent", { environment = r.environment })
  if dir == nil then return nil end
  return dir .. "/home"
end

--- What no PATH entry may grant: cosmic's data and cache directories.
local function kept_out(r: Run): {string}
  local out: mut {string} = {}
  local data, _ = Fs.data_dir("cosmic", { environment = r.environment, make = false })
  if data ~= nil then out[#out + 1] = data end
  local cache, _ = Fs.cache_dir("agent", { environment = r.environment, make = false })
  if cache ~= nil then out[#out + 1] = Fs.dirname(cache) end
  return out
end

--- The policy the options of `got` ask for in `here`: nil and "" for
--- --sandbox off, or nil and why.
local function policy_of(r: Run, got: Flags.Parsed, here: string): Sandbox.Policy?, string
  local grants: mut {Sandbox.Grant} = {}
  for _, given_grant in ipairs(got.all["--grant"] or {}) do
    local path, letters = given_grant:match("^(.-):(%a+)$")
    if letters ~= nil and letters:match("^[rwxc]+$") == nil then
      return nil, "--grant " .. given_grant .. ": the letters are of rwxc"
    end
    local named = path or given_grant
    local home = r.io.env("HOME") or ""
    if named == "~" or named:sub(1, 2) == "~/" then named = home .. named:sub(2) end
    local real, real_why = Fs.absolute(if named:sub(1, 1) == "/" then named else here .. "/" .. named end)
    if real == nil then return nil, "--grant " .. given_grant .. ": " .. tostring(real_why) end
    grants[#grants + 1] = { path = real, letters = letters or "r" }
  end
  if got.values["--sandbox"] == "off" and (#grants > 0 or got.set["--network"] == true) then
    return nil, "--network and --grant hold a sandbox, which --sandbox off has none of"
  end
  return Policy.of(here, { mode = got.values["--sandbox"] or "write", home = sandbox_home(r),
    path = r.io.env("PATH"), user_home = r.io.env("HOME"), kept_out = kept_out(r),
    network = got.set["--network"] == true, grants = grants })
end

--- A session from the options of `got`, kept in `db`, or nil and why.
--- Where `newest`, no session named is the newest in the directory.
local function session(r: Run, got: Flags.Parsed, db: Sqlite.Handle, newest: boolean): Agent.Session?, string
  local effort = got.values["--effort"] or Agent.EFFORT
  if EFFORTS[effort] ~= true then
    return nil, "--effort is one of low, medium, high, xhigh, max"
  end
  local name = got.values["--model"] or Agent.MODEL
  local model = if name == "opus" then Agent.MODELS.opus elseif name == "sonnet" then Agent.MODELS.sonnet else nil end
  if model == nil then return nil, "--model is opus or sonnet" end
  local base = r.io.env("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"
  local sign, sign_why = Auth.from(r.io.env, base)
  if sign == nil then return nil, sign_why end
  local here = cwd(r)
  local id: integer? = nil
  local given = got.values["--session"]
  if given ~= nil then
    local n, _ = Number.integer(given)
    if n == nil then return nil, "--session takes a session's id" end
    id = n
  elseif got.set["--continue"] == true or newest then
    local latest, why = Sessions.latest(db, here)
    if latest == nil then
      return nil, if why ~= "" then why else "no session in " .. here .. " to go on with" end
    end
    id = latest
  end
  local held: {Json.Value} = {}
  local restarts, ended = 0, true
  if id ~= nil then
    local loaded, why = Sessions.load(db, id)
    if loaded == nil then return nil, why end
    held, restarts, ended = loaded.messages, loaded.restarts, loaded.ended
    -- A session goes on with the model it used last, unless one is named.
    if got.values["--model"] == nil then model = loaded.model end
  end
  -- The policy before a new session's row, so a refused one leaves none.
  local policy, policy_why = policy_of(r, got, here)
  if policy == nil and policy_why ~= "" then return nil, policy_why end
  if id == nil then
    local started, why = Sessions.start(db, here, model, Clock.now_ns() // Clock.seconds(1))
    if started == nil then return nil, why end
    id = started
  end
  local s = Agent.session({ model = model, effort = effort, sign = sign, base_url = base, cwd = here,
    send = r.io.send, system = Prompt.build(here, Prompt.contexts(here)), policy = policy, jobs = Jobs.new(),
    build = build() }, held)
  s.db, s.id, s.restarts, s.ended = db, id, restarts, ended
  local settled, settle_why = Agent.settle(s)
  if not settled then return nil, settle_why end
  return s, ""
end

--- Ends the background jobs of `s`, each output not kept yet kept.
local function end_jobs(s: Agent.Session)
  local set = s.config.jobs
  if set == nil then return end
  Jobs.close(set, function(job: Jobs.Job, output: string)
    local db, id = s.db, s.id
    if db == nil or id == nil then return end
    local input, _ = Json.encode({ command = job.command, background = true })
    local result = job.result
    local _, _ = Sessions.output(db, id, { tool = "bash", input = input or "{}", text = output,
      is_error = result == nil or not result.ok })
  end)
end

--- Runs `go` with a session from `got`: its exit status.
local function with_session(r: Run, name: string, got: Flags.Parsed, go: function(s: Agent.Session): integer,
                            newest?: boolean): integer
  local db, why = store(r)
  if db == nil then
    r.complain(name .. ": " .. why)
    return bare.failed
  end
  local s, session_why = session(r, got, db, newest == true)
  local code = bare.refused
  if s == nil then
    r.complain(name .. ": " .. session_why)
  else
    code = go(s)
    end_jobs(s)
  end
  local _, _ = db:close()
  return code
end

--- The events that print the model's words, and each call to standard error.
local function shown_events(r: Run): Agent.Events
  return {
    text = function(text: string) r.io.out(text) end,
    tool = function(name: string, input: Tools.Object) r.io.err(name .. " " .. shown(input)) end,
    result = function(name: string, result: Tools.Result)
      if result.is_error then r.io.err(name .. " failed: " .. brief(result.text)) end
    end,
  }
end

--- Prints `event` as a line of JSON.
local function emit(r: Run, event: Json.Value)
  local text, why = Json.encode(event)
  r.io.out(text or assert(Json.encode({ type = "error", error = tostring(why) })))
end

--- The end event, which leaves "error" out when the turn went well.
local function emit_end(r: Run, ok: boolean, trouble: string)
  if ok then
    emit(r, { type = "end", ok = true })
  else
    emit(r, { type = "end", ok = false, error = trouble })
  end
end

--- The events that print each as a line of JSON.
local function json_events(r: Run): Agent.Events
  return {
    text = function(_: string) end,
    tool = function(name: string, input: Tools.Object)
      emit(r, { type = "tool", name = name, input = input })
    end,
    result = function(name: string, result: Tools.Result)
      emit(r, { type = "result", name = name, is_error = result.is_error })
    end,
    message = function(message: Json.Value) emit(r, { type = "message", message = message }) end,
    request = function(q: Sessions.Request)
      local usage: mut {string: Json.Value} = { model = q.served or q.model, status = q.status, ms = q.ms }
      local function put(k: string, v?: integer)
        if v ~= nil then usage[k] = v end
      end
      put("input_tokens", q.input_tokens)
      put("output_tokens", q.output_tokens)
      put("cache_read", q.cache_read)
      put("cache_write_5m", q.cache_write_5m)
      put("cache_write_1h", q.cache_write_1h)
      local cost = q.cost
      if cost ~= nil then usage["cost"] = cost end
      emit(r, { type = "request", request = usage })
    end,
  }
end

--- What a turn does: [`Agent.prompt`]'s or [`Agent.resume`]'s work.
local type Go = function(Agent.Session, Agent.Events): (boolean, string)

--- Runs `go` on `s` with `events`, the signals held: Ctrl-C stops the
--- turn. `poll` reads what is typed meanwhile into `steers`, and says
--- whether the user stopped the turn.
local function turn(r: Run, s: Agent.Session, events: Agent.Events, go: Go, poll?: function(): boolean,
                    steers?: mut {string}): boolean, string
  local held_signals = r.io.hold()
  local held: mut {string} = steers or {}
  local e: Agent.Events = {
    text = events.text, tool = events.tool, result = events.result, message = events.message,
    request = events.request,
    steering = function(): {string}
      if poll ~= nil then poll() end
      local out: mut {string} = {}
      for i, t in ipairs(held) do
        out[i] = t
      end
      for i = #held, 1, -1 do table.remove(held, i) end
      return out
    end,
    stopped = function(): boolean
      local asked = poll ~= nil and poll()
      return asked or held_signals.caught() ~= 0
    end,
  }
  local ok, why = go(s, e)
  -- A signal but Ctrl-C ends the run as the hold ends: the jobs first.
  local caught = held_signals.caught()
  if caught ~= 0 and caught ~= 2 then end_jobs(s) end
  held_signals.release()
  if not ok then return false, why end
  return true, ""
end

local function prompting(text: string): Go
  return function(s: Agent.Session, e: Agent.Events): boolean, string
    return Agent.prompt(s, text, e)
  end
end

local function ask(r: Run, got: Flags.Parsed): integer
  local text = table.concat(got.words, " ")
  if text == "" then text = r.io.read_all() end
  if text:match("^%s*$") then
    r.complain("ask: give a prompt, as words or on standard input")
    return bare.refused
  end
  local json = got.set["--json"] == true
  local events = if json then json_events(r) else shown_events(r) end
  return with_session(r, "ask", got, function(s: Agent.Session): integer
    if json then emit(r, { type = "session", id = s.id or 0 }) end
    -- A turn the last run left unfinished is finished first.
    if Agent.unfinished(s) then
      local ok, trouble = turn(r, s, events, Agent.resume)
      if json then emit_end(r, ok, trouble) end
      if not ok then
        r.complain("ask: the unfinished turn: " .. trouble)
        if s.stopped then return bare.failed end
      end
    end
    local ok, trouble = turn(r, s, events, prompting(text))
    if json then emit_end(r, ok, trouble) end
    if not ok then
      r.complain("ask: " .. trouble)
      return bare.failed
    end
    return bare.ok
  end)
end

local function chat(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("chat: takes no words; type the prompts")
    return bare.refused
  end
  local events = shown_events(r)
  return with_session(r, "chat", got, function(s: Agent.Session): integer
    local later: mut {string} = {}
    local steers: mut {string} = {}
    -- What a person types while the model works: /later waits for the turn to end.
    local function poll(): boolean
      if not r.io.tty() then return false end
      while true do
        local line = r.io.typed()
        if line == nil then return false end
        if line == "/exit" then
          later[#later + 1] = line
        elseif line:sub(1, 7) == "/later " then
          local rest = line:sub(8)
          later[#later + 1] = rest
        elseif not line:match("^%s*$") then
          steers[#steers + 1] = line
        end
      end
    end
    if Agent.unfinished(s) then
      local ok, trouble = turn(r, s, events, Agent.resume, poll, steers)
      if not ok then r.complain("chat: the unfinished turn: " .. trouble) end
    end
    while true do
      local line = table.remove(steers, 1) or table.remove(later, 1) or r.io.read_line("> ")
      if line == nil or line == "/exit" then return bare.ok end
      if not line:match("^%s*$") then
        local ok, trouble = turn(r, s, events, prompting(line), poll, steers)
        if not ok then r.complain("chat: " .. trouble) end
      end
    end
  end)
end

local function resume(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("resume: takes no words")
    return bare.refused
  end
  return with_session(r, "resume", got, function(s: Agent.Session): integer
    if not Agent.unfinished(s) then
      r.complain("resume: session " .. tostring(s.id) .. " has no unfinished turn")
      return bare.ok
    end
    local ok, trouble = turn(r, s, shown_events(r), Agent.resume)
    if not ok then
      r.complain("resume: " .. trouble)
      return bare.failed
    end
    return bare.ok
  end, true)
end

local function rpc(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("rpc: takes no words")
    return bare.refused
  end
  local events = json_events(r)
  return with_session(r, "rpc", got, function(s: Agent.Session): integer
    local queue: mut {{string: Json.Value}} = {}
    local steers: mut {string} = {}
    local stopping = false
    local function command(line: string): {string: Json.Value}?
      if line:match("^%s*$") then return nil end
      local c, bad = Json.decode_object(line)
      if c == nil then
        emit(r, { type = "error", error = "not a JSON object: " .. tostring(bad) })
      end
      return c
    end
    -- Commands that come while a turn runs: steer and abort act on it, the rest wait.
    local function poll(): boolean
      while true do
        local line = r.io.typed()
        if line == nil then return stopping end
        local c = command(line)
        local text = c and c["text"]
        if c ~= nil and c["type"] == "steer" and text is string then
          steers[#steers + 1] = text
        elseif c ~= nil and c["type"] == "abort" then
          stopping = true
        elseif c ~= nil then
          queue[#queue + 1] = c
        end
      end
    end
    emit(r, { type = "session", id = s.id or 0, unfinished = Agent.unfinished(s) })
    while true do
      local c = table.remove(queue, 1)
      if c == nil then
        local line = r.io.read_line("")
        if line == nil then return bare.ok end
        c = command(line)
      end
      if c ~= nil then
        local kind, text = c["type"], c["text"]
        local go: Go? = nil
        if (kind == "prompt" or kind == "steer" or kind == "follow_up") and text is string and
            not text:match("^%s*$") then
          go = prompting(text)
        elseif kind == "resume" then
          go = Agent.resume
        end
        if go == nil then
          emit(r, { type = "error", error = "not a command: prompt, steer, follow_up (each with text), abort " ..
              "or resume" })
        else
          stopping = false
          local ok, trouble = turn(r, s, events, go, poll, steers)
          emit_end(r, ok, trouble)
          -- A steer that came too late for the turn is the next prompt.
          for i, t in ipairs(steers) do
            table.insert(queue, i, { type = "prompt", text = t })
          end
          for i = #steers, 1, -1 do table.remove(steers, i) end
        end
      end
    end
  end)
end

local function sessions(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("sessions: takes no words")
    return bare.refused
  end
  local db, why = store(r)
  if db == nil then
    r.complain("sessions: " .. why)
    return bare.failed
  end
  local list, list_why = Sessions.list(db, cwd(r), 20)
  local _, _ = db:close()
  if list == nil then
    r.complain("sessions: " .. list_why)
    return bare.failed
  end
  for _, e in ipairs(list) do
    r.io.out(string.format("%4d  %s  %-17s %3d  %7s  $%.3f  %s", e.id, e.started, e.model, e.messages,
      tokens(e.context), e.cost, brief(e.first)))
  end
  return bare.ok
end

local function prompt(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("prompt: takes no words")
    return bare.refused
  end
  local here = cwd(r)
  r.io.out(Prompt.build(here, Prompt.contexts(here)))
  return bare.ok
end

--- Removes the commands' kept home, made writable first where a tool
--- left it read-only (go's module cache).
local function clear_home(r: Run): integer
  local home = sandbox_home(r)
  if home == nil then return bare.ok end
  local there, _ = Fs.status(home)
  if there == nil or not there.exists then return bare.ok end
  local chmod, _ = Proc.find("chmod")
  local _, _ = Child.run({ chmod or "/bin/chmod", "-R", "u+w", home }, { stdout = "null", stderr = "null",
    timeout_ns = Clock.seconds(60) })
  local removed, why = Fs.remove_tree(home)
  if not removed then
    r.complain("policy: " .. home .. ": " .. tostring(why))
    return bare.failed
  end
  r.io.out("removed " .. home)
  return bare.ok
end

local function policy(r: Run, got: Flags.Parsed): integer
  if got.words[1] == "clear-home" and #got.words == 1 then return clear_home(r) end
  if #got.words > 0 then
    r.complain("policy: takes no words but clear-home")
    return bare.refused
  end
  local p, why = policy_of(r, got, cwd(r))
  if p == nil then
    if why ~= "" then
      r.complain("policy: " .. why)
      return bare.refused
    end
    r.io.out("--sandbox off: no sandbox; the tools have your user's rights")
    return bare.ok
  end
  local merged, merged_why = Sandbox.merge(p)
  if merged == nil then
    r.complain("policy: " .. merged_why)
    return bare.failed
  end
  for _, line in ipairs(Policy.describe(merged, sandbox_home(r))) do r.io.out(line) end
  return bare.ok
end

local SUBCOMMANDS <const>: {string: function(Run, Flags.Parsed): integer} = {
  ask = ask, chat = chat, resume = resume, rpc = rpc, sessions = sessions, prompt = prompt, policy = policy,
}

--- `cosmic agent <subcommand> ...`: runs it and returns the exit code:
--- 0 ok, 1 a turn that failed or a database it could not open, 2 a
--- command line it refuses or a session it cannot start.
--- @param argv the command line, `agent` at slot 1
--- @param io where it reads and writes; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("agent", to.err)
  local got, trouble = Flags.parse(argv, 2, spec)
  if got == nil then
    complain(trouble .. "; " .. USAGE)
    return bare.refused
  end
  local parsed: Flags.Parsed = got
  local sub = table.remove(parsed.words, 1)
  local takes = if sub == nil then nil else TAKES[sub] end
  if sub == nil or takes == nil then
    complain((if sub == nil then "name ask, chat, resume, rpc, sessions, prompt or policy" else
      "no subcommand " .. sub end) .. "; " .. USAGE)
    return bare.refused
  end
  for _, name in ipairs(parsed.given) do
    if takes[name] ~= true then
      complain(name .. " is not an option of " .. sub .. "; " .. USAGE)
      return bare.refused
    end
  end
  local environment: mut {string: string} = {}
  for _, name in ipairs({ "HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME" }) do
    local value = to.env(name)
    if value ~= nil then environment[name] = value end
  end
  local r: Run = { io = to, complain = complain, environment = environment }
  return assert(SUBCOMMANDS[sub])(r, parsed)
end

--- The `agent` verb as [`build/verb_list.tl`] lists it. It reads no
--- tree, so it is never stale-checked.
verb.spec = {
  name = "agent",
  guide = "a coding agent in a sandbox",
  tests = { "build.agent_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "ask, chat, resume, rpc, sessions, prompt or policy, and its options",
  exits = "`agent` prints the model's words or its events, and nothing after; it exits 1 when an ask or resume turn failed or the sessions database could not be opened, 2 when it refuses its command line or cannot start a session.",
  passthrough = "its output is the model's words, so its exit status is the verdict (build/agent_test.tl)",
}

return verb
