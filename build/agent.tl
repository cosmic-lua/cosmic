--- `cosmic agent`: a small coding agent, after pi. Claude, through the
--- Messages API, with tools to read, write and edit files, run commands
--- (in the foreground or as background jobs), check and run snippets in
--- the cosmic environment, and query what it has kept, held to a sandbox. `cosmic agent
--- worker` is the process that runs the snippets ([`build.agent_worker`]);
--- the agent starts it. [`cosmic.agent`] runs the loop; this reads the
--- command line, opens the sessions database and writes what the model
--- says.
---
--- `cosmic agent ask [prompt...]` runs one prompt to the end: the words
--- given, else all of standard input. `chat` takes a prompt a line, in
--- one conversation, until `/exit` or the end of standard input. `resume`
--- finishes the turn a run left unfinished. ask and chat go on with the
--- newest session here unless `--new`; `--fork` goes on in a copy of
--- one. `rpc` runs one session for
--- another program. `sessions` lists the newest sessions in the working
--- directory, `prompt` prints the system prompt the model reads (then the
--- working directory, which follows it past its cache mark), and
--- `policy` the sandbox the tools would run under (`policy clear-home`
--- empties the commands' kept home).
---
--- A snippet of the run tool may call MCP servers through the agent
--- ([`cosmic.agent.host`]): those of the config `--mcp` names, else of
--- `~/.config/cosmic/mcp.json` (`$XDG_CONFIG_HOME/cosmic/mcp.json`)
--- where it is there ([`cosmic.agent.mcp`] holds its form). Each server
--- runs sandboxed unless its config says not, starts at its first call,
--- and ends with the session. The tools cannot reach that directory, so
--- no tool chooses what a later session starts.
---
--- The turn's answer goes to standard output. Each tool call, and what
--- the model says on the way, go to standard error. `ask --json` and `rpc` print events instead, one JSON
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
local AgentMcp = require("cosmic.agent.mcp")
local Auth = require("cosmic.agent.auth")
local Child = require("cosmic.child")
local Verb = require("cosmic.cli.agent")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Grant = require("cosmic.relay.grant")
local sys = require("cosmic.sys")
local Hash = require("cosmic.hash")
local Jobs = require("cosmic.agent.jobs")
local Worker = require("cosmic.agent.worker")
local Json = require("cosmic.json")
local Number = require("cosmic.number")
local String = require("cosmic.string")
local Poll = require("cosmic.poll")
local Policy = require("cosmic.agent.policy")
local Proc = require("cosmic.proc")
local Prompt = require("cosmic.agent.prompt")
local Sandbox = require("cosmic.sandbox")
local Sessions = require("cosmic.agent.sessions")
local Show = require("cosmic.agent.show")
local Signal = require("cosmic.signal")
local Sqlite = require("cosmic.sqlite")
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
    --- Waits at most `ns` nanoseconds for a whole line, or the end, on
    --- standard input: whether one came, for [`read_line`] to take. Nil
    --- where nothing waits: [`read_line`] alone is used.
    wait?: function(ns: integer): boolean
    --- The time, as [`Clock.now_ns`] gives it; nil for that.
    now?: function(): integer
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

local subcommands = Verb.subcommands or {}

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

local function wait(ns: integer): boolean
  local deadline = Clock.now_ns() + ns
  while pending:find("\n", 1, true) == nil do
    local left = deadline - Clock.now_ns()
    if left <= 0 then return false end
    local ready, _ = Poll.readable(Fs.stdin, left)
    if not ready then return false end
    local chunk, _ = Fs.take(Fs.stdin, 4096)
    -- The end is for read_line to see.
    if chunk == nil or chunk == "" then return true end
    pending = pending .. chunk
  end
  return true
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
  wait = wait,
  read_all = read_all,
  typed = typed,
  hold = hold,
  tty = function(): boolean return Proc.is_tty(Fs.stdin) end,
  env = Env.get,
}

--- `n` tokens, short: 950, 12.3k, 1.2M.
local function tokens(n: integer): string
  if n < 1000 then return tostring(n) end
  if n < 1000000 then return string.format("%.1fk", n / 1000) end
  return string.format("%.1fM", n / 1000000)
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

--- The MCP config read by default: `$XDG_CONFIG_HOME/cosmic/mcp.json`, else `$HOME/.config/cosmic/mcp.json`.
local function mcp_config(r: Run): string
  local base = r.io.env("XDG_CONFIG_HOME") or ""
  if base:sub(1, 1) ~= "/" then base = (r.io.env("HOME") or "") .. "/.config" end
  return base .. "/cosmic/mcp.json"
end

--- The MCP servers `got` names: those of `--mcp`'s file, else of the default config where it is there, else none;
--- or nil and why.
local function mcp_servers(r: Run, got: Flags.Parsed): {AgentMcp.Server}?, string
  local given = got.values["--mcp"]
  local path = given or mcp_config(r)
  if given == nil then
    local status, _ = Fs.status(path)
    if status == nil or not status.exists then return {}, "" end
  end
  local servers, why = AgentMcp.load(path)
  if servers == nil then
    return nil, (if given ~= nil then "--mcp: " else "" end) .. tostring(why)
  end
  return servers, ""
end

--- What the tools may not reach, which no PATH entry and no grant may give: cosmic's data and cache directories, and
--- the directories of the MCP config, the default and `named`.
local function kept_out(r: Run, named?: string): {string}
  local out: mut {string} = {}
  local data, _ = Fs.data_dir("cosmic", { environment = r.environment, make = false })
  if data ~= nil then out[#out + 1] = data end
  local cache, _ = Fs.cache_dir("agent", { environment = r.environment, make = false })
  if cache ~= nil then out[#out + 1] = Fs.dirname(cache) end
  -- The MCP config, the default and the one --mcp names, where each lies and where its links lead: a tool that wrote
  -- it would choose what the next session starts, and with what rights.
  local configs: mut {string} = { mcp_config(r) }
  if named ~= nil then configs[#configs + 1] = named end
  for _, config in ipairs(configs) do
    local absolute = if config:sub(1, 1) == "/" then config else cwd(r) .. "/" .. config end
    out[#out + 1] = Fs.dirname(absolute)
    local real, _ = Fs.absolute(absolute)
    if real ~= nil then out[#out + 1] = Fs.dirname(real) end
  end
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
  local connect: mut {string} = {}
  for _, target in ipairs(got.all["--connect"] or {}) do
    local parsed, parse_why = Grant.parse(target)
    if parsed == nil then return nil, "--connect " .. target .. ": " .. tostring(parse_why) end
    connect[#connect + 1] = parsed.text
  end
  if got.values["--sandbox"] == "off" and (#grants > 0 or #connect > 0 or got.set["--network"] == true) then
    return nil, "--network, --connect and --grant hold a sandbox, which --sandbox off has none of"
  end
  return Policy.of(here, { mode = got.values["--sandbox"] or "write", home = sandbox_home(r),
    path = r.io.env("PATH"), user_home = r.io.env("HOME"), kept_out = kept_out(r, got.values["--mcp"]),
    network = got.set["--network"] == true, connect = connect, grants = grants,
    cert_file = r.io.env("SSL_CERT_FILE") })
end

-- What each unit of --budget's time is, in seconds.
local SECONDS_OF <const>: {string: number} = { [""] = 1, s = 1, m = 60, h = 3600 }

--- The budget `text` names, as `--budget` takes it: limits joined by
--- commas, each tokens=N, cost=USD, turns=N or time=N (seconds, or with
--- s, m or h), such as `cost=0.50,time=10m`. Nil and why where it names
--- none, one twice, or a value not a positive number.
local function budget_of(text: string): Agent.Budget?, string
  local most_tokens, turns: integer?, integer? = nil, nil
  local cost, seconds: number?, number? = nil, nil
  local named: mut {string: boolean} = {}
  local usage = "--budget takes limits joined by commas: tokens=N, cost=USD, turns=N, time=N[s|m|h]"
  for part in text:gmatch("[^,]+") do
    local key, value = part:match("^%s*(%a+)=(.-)%s*$")
    if key == nil or value == nil then return nil, usage .. "; not one: " .. part end
    if named[key] == true then return nil, "--budget names " .. key .. " twice" end
    named[key] = true
    if key == "tokens" or key == "turns" then
      local n = if value:match("^[1-9]%d*$") then math.tointeger(tonumber(value)) else nil end
      if n == nil then
        return nil, "--budget " .. key .. " takes a positive whole number: " .. value
      end
      if key == "tokens" then most_tokens = n else turns = n end
    elseif key == "cost" then
      local n = if value:match("^%d*%.?%d+$") then tonumber(value) else nil end
      if n == nil or n <= 0 then
        return nil, "--budget cost takes a positive number of USD: " .. value
      end
      cost = n
    elseif key == "time" then
      local amount, unit = value:match("^(%d*%.?%d+)([smh]?)$")
      local n = if amount ~= nil then tonumber(amount) else nil end
      local per = if unit ~= nil then SECONDS_OF[unit] else nil end
      if n == nil or per == nil or n <= 0 then
        return nil, "--budget time takes a positive number of seconds, or of s, m or h: " .. value
      end
      seconds = n * per
    else
      return nil, usage .. "; not a limit: " .. key
    end
  end
  if next(named) == nil then return nil, usage end
  return { tokens = most_tokens, cost = cost, turns = turns, seconds = seconds }, ""
end

--- The tools `got` offers: those --tools names ([`Tools.named`]), else the default, with --with's added and
--- --without's taken out ([`Tools.changed`]); under --sandbox read with no
--- --grant that writes, none that changes a file, since the sandbox refuses each change.
local function offered_tools(got: Flags.Parsed): ({Tools.Tool}) | (nil, string)
  local given = got.values["--tools"]
  local offered: {Tools.Tool} = Tools.default()
  if given ~= nil then
    local named, why = Tools.named(given)
    if named == nil then return nil, why end
    offered = named
  end
  local changed, changed_why = Tools.changed(offered, got.values["--with"], got.values["--without"])
  if changed == nil then return nil, changed_why end
  offered = changed
  if got.values["--sandbox"] ~= "read" then return offered end
  for _, given_grant in ipairs(got.all["--grant"] or {}) do
    local letters = given_grant:match(":([rwxc]+)$")
    if letters ~= nil and letters:find("w", 1, true) ~= nil then return offered end
  end
  return Tools.without(offered, { "edit", "write" })
end

--- Holds session `id` for this run, so no other run appends to it at once: the lock's descriptor, or nil where
--- another run holds it (why is "" then), or nil and why. The lock ends when the descriptor closes, or the run.
local function hold_session(r: Run, id: integer): integer?, string
  local dir, why = Fs.data_dir("cosmic", { environment = r.environment })
  if dir == nil then return nil, "no data directory: " .. tostring(why) end
  local path = dir .. "/agent/held-" .. tostring(id) .. ".lock"
  local fd, open_why = sys.open(path, sys.O_RDWR | sys.O_CREAT, 0x180)
  if fd == nil then return nil, path .. ": " .. tostring(open_why) end
  local locked, lock_why, errno = sys.flock(fd, "exclusive", 0)
  if locked then return fd, "" end
  local _, _ = sys.close(fd)
  -- A wait of 0 ms on a held lock ends in ETIMEDOUT.
  if sys.errno_name(errno) == "ETIMEDOUT" then return nil, "" end
  return nil, path .. ": " .. tostring(lock_why)
end

--- A session and the descriptor of its lock ([`hold_session`]), or nil where none was held.
local type Opened = {session: Agent.Session, lock: integer?}

--- The session the options of `got` name, kept in `db`, or nil and why.
--- Where `newest`, no session named is the newest in the directory; where `by_default`, the newest is gone on with
--- unless --new, and a fresh one starts where there is none, or another run holds it.
local function session(r: Run, got: Flags.Parsed, db: Sqlite.Handle, newest: boolean,
                       by_default: boolean): Opened?, string
  local effort = got.values["--effort"] or Agent.EFFORT
  local budget: Agent.Budget? = nil
  local limits = got.values["--budget"]
  if limits ~= nil then
    local b, budget_why = budget_of(limits)
    if b == nil then return nil, budget_why end
    budget = b
  end
  local name = got.values["--model"] or Agent.MODEL
  local model = if name == "opus" then Agent.MODELS.opus elseif name == "sonnet" then Agent.MODELS.sonnet else nil end
  if model == nil then return nil, "--model is opus or sonnet" end
  local base = r.io.env("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"
  local sign, sign_why = Auth.from(r.io.env, base)
  if sign == nil then return nil, sign_why end
  local here = cwd(r)
  local fresh, fork = got.set["--new"] == true, got.set["--fork"] == true
  if fresh and (newest or fork or got.set["--continue"] == true or got.values["--session"] ~= nil) then
    return nil, "--new starts a session, so it takes no --continue, --session or --fork, and resume none"
  end
  -- Only the default goes past a session another run holds; a session asked for by name or flag is refused.
  local asked = got.values["--session"] ~= nil or got.set["--continue"] == true or newest or fork
  local id: integer? = nil
  local given = got.values["--session"]
  if given ~= nil then
    local n, _ = Number.integer(given)
    if n == nil then return nil, "--session takes a session's id" end
    id = n
  elseif got.set["--continue"] == true or newest or fork or (by_default and not fresh) then
    local latest, why = Sessions.latest(db, here)
    if latest == nil and why ~= "" then return nil, why end
    -- Going on is the default, so a directory with no session yet starts one.
    if latest == nil and asked then return nil, "no session in " .. here .. " to go on with" end
    id = latest
  end
  local lock: integer? = nil
  local passed: integer? = nil
  -- A fork reads the other session alone, and so holds only its own.
  if id ~= nil and not fork then
    local fd, hold_why = hold_session(r, id)
    if fd == nil and hold_why ~= "" then return nil, hold_why end
    if fd == nil and asked then
      return nil, "session " .. tostring(id) .. " is in use by another run"
    end
    if fd == nil then passed, id = id, nil end
    lock = fd
  end
  local function refused(why: string): (nil, string)
    local open_lock = lock
    if open_lock ~= nil then local _, _ = sys.close(open_lock) end
    return nil, why
  end
  local held: {Json.Value} = {}
  local restarts, ended = 0, true
  local forked: integer? = nil
  if id ~= nil then
    local loaded, why = Sessions.load(db, id)
    if loaded == nil then return refused(why) end
    held, restarts, ended = loaded.messages, loaded.restarts, loaded.ended
    -- A session goes on with the model it used last, unless one is named.
    if got.values["--model"] == nil then model = loaded.model end
    if fork then forked, id, restarts = id, nil, 0 end
  end
  -- The policy and the MCP servers before a new session's row, so a refused one leaves none.
  local policy, policy_why = policy_of(r, got, here)
  if policy == nil and policy_why ~= "" then return refused(policy_why) end
  local servers, servers_why = mcp_servers(r, got)
  if servers == nil then return refused(servers_why) end
  local offered, picked_why = offered_tools(got)
  if offered == nil then return refused("tools: " .. picked_why) end
  local now = Clock.now_ns() // Clock.seconds(1)
  if id == nil then
    -- A fork is a new session that holds all the other kept, which goes on there alone.
    local started: integer? = nil
    local why = ""
    if forked ~= nil then
      started, why = Sessions.fork(db, forked, here, model, now)
    else
      started, why = Sessions.start(db, here, model, now)
    end
    if started == nil then return refused(why) end
    id = started
    local fd, hold_why = hold_session(r, started)
    if fd == nil then
      return refused(if hold_why ~= "" then hold_why else "session " .. tostring(started) ..
          " is in use by another run" end)
    end
    lock = fd
    if forked ~= nil then
      r.io.err("cosmic: agent: session " .. tostring(started) .. ", forked from session " .. tostring(forked))
    elseif passed ~= nil then
      r.io.err("cosmic: agent: session " .. tostring(passed) .. " is in use by another run; started session " ..
          tostring(started))
    end
  elseif #held > 0 then
    local unfinished = if not ended then ", and first finishes the turn it left unfinished" else "" end
    r.io.err("cosmic: agent: going on with session " .. tostring(id) .. " (" .. String.counted(#held, "message") ..
        ", " .. model .. unfinished .. "); --new starts a fresh one")
  end
  local s = Agent.new({ model = model, effort = effort, sign = sign, base_url = base, cwd = here,
    send = r.io.send, system = Prompt.build(here, Prompt.contexts(here), { servers = servers, tools = offered }),
    sandbox = policy, jobs = Jobs.new(), worker = Worker.new(), mcp = AgentMcp.new(servers, here), build = build(),
    tools = offered, messages = held, db = db, id = id, restarts = restarts, ended = ended, budget = budget })
  if budget ~= nil and budget.cost ~= nil and Agent.cost(model, {}) == nil then
    s:close()
    return refused("--budget cost: no price is known for " .. model .. ", so its cost cannot be counted")
  end
  local settled, settle_why = s:settle()
  if not settled then return refused(settle_why) end
  return { session = s, lock = lock }, ""
end

--- Runs `go` with a session from `got`: its exit status.
-- The cache keeps a request's prefix 5 minutes from when it was sent: a
-- warm request goes out at 4.5, while the user is idle for at most
-- `--keep-warm` minutes (60 unless given). Each costs 0.05x of the
-- conversation's input price, where a miss writes it all again at
-- 1.25x: an hour of them costs about half of one miss.
local WARM_EVERY <const> = Clock.seconds(270)
local WARM_FOR <const> = 60

--- How long `got` says to keep the cache warm while idle, in
--- nanoseconds (0 for not at all): nil and why for a value not a
--- whole number of minutes.
local function warm_for(got: Flags.Parsed): integer?, string
  local given = got.values["--keep-warm"]
  if given == nil then return Clock.minutes(WARM_FOR), "" end
  if not given:match("^%d+$") then
    return nil, "--keep-warm takes whole minutes, such as 60, or 0 for never: " .. given
  end
  return Clock.minutes(assert(math.tointeger(tonumber(given)))), ""
end

--- The next line `r` reads, `prompt` shown first, keeping `s`'s cache
--- warm while it waits, for at most `keep` nanoseconds: nil at the
--- input's end. Each warm request is told to `on`.
local function next_line(r: Run, s: Agent.Session, name: string, prompt: string, keep: integer,
                         on?: function(event: Agent.Event)): string?
  local waits = r.io.wait
  local sent = s.sent_ns
  if waits == nil or sent == nil or keep <= 0 then return r.io.read_line(prompt) end
  local clock = r.io.now or Clock.now_ns
  local idle = clock()
  -- When the next warm request is due, on `clock`: the last request was
  -- sent `Clock.now_ns() - sent` ago.
  local due = idle + WARM_EVERY - (Clock.now_ns() - sent)
  local shown = r.io.tty()
  if shown then local _, _ = bare.out(prompt) end
  while true do
    local now = clock()
    if now - idle >= keep then break end
    if due > now then
      if waits(math.min(due, idle + keep) - now) then break end
    else
      local before = s.on
      s.on = on
      local ok, why = s:warm()
      s.on = before
      if not ok then
        r.complain(name .. ": keeping the cache warm: " .. why)
        -- The complaint took the prompt's line.
        if shown then local _, _ = bare.out(prompt) end
        break
      end
      due = clock() + WARM_EVERY
    end
  end
  return r.io.read_line("")
end

local function with_session(r: Run, name: string, got: Flags.Parsed, go: function(s: Agent.Session): integer,
                            newest?: boolean): integer
  local db, why = store(r)
  if db == nil then
    r.complain(name .. ": " .. why)
    return bare.failed
  end
  -- ask and chat go on with the newest session here unless told not to.
  local opened, session_why = session(r, got, db, newest == true, name == "ask" or name == "chat")
  local code = bare.refused
  if opened == nil then
    r.complain(name .. ": " .. session_why)
  else
    code = go(opened.session)
    opened.session:close()
    local lock = opened.lock
    if lock ~= nil then local _, _ = sys.close(lock) end
  end
  local _, _ = db:close()
  return code
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

--- What a turn does: an agent's `prompt` or `resume`.
local type Go = function(Agent.Session): (boolean, string)

--- Runs `go` on `s` with `on` hearing its events, the signals held:
--- Ctrl-C stops the turn. `poll` reads what is typed meanwhile into
--- `steers`, and says whether the user stopped the turn. The agent's
--- `on`, `steering` and `stopping` are as they were after.
local function turn(r: Run, s: Agent.Session, on: function(event: Agent.Event), go: Go, poll?: function(): boolean,
                    steers?: mut {string}): boolean, string
  local held_signals = r.io.hold()
  local held: mut {string} = steers or {}
  local was_on, was_steering, was_stopping = s.on, s.steering, s.stopping
  s.on = on
  s.steering = function(): {string}
    if poll ~= nil then poll() end
    local out: mut {string} = {}
    for i, t in ipairs(held) do
      out[i] = t
    end
    for i = #held, 1, -1 do table.remove(held, i) end
    return out
  end
  s.stopping = function(): boolean
    local asked = poll ~= nil and poll()
    return asked or held_signals.caught() ~= 0
  end
  local ok, why = go(s)
  s.on, s.steering, s.stopping = was_on, was_steering, was_stopping
  local lost = s.on_failed
  if lost ~= nil then
    r.io.err("cosmic: agent: an event could not be shown: " .. lost)
    s.on_failed = nil
  end
  -- A signal but Ctrl-C ends the run as the hold ends: the jobs first.
  local caught = held_signals.caught()
  if caught ~= 0 and caught ~= 2 then s:close() end
  held_signals.release()
  if not ok then return false, why end
  return true, ""
end

--- The turn that resumes the unfinished one.
local function resuming(s: Agent.Session): boolean, string
  return s:resume()
end

local function prompting(text: string): Go
  return function(s: Agent.Session): boolean, string
    return s:prompt(text)
  end
end

local function ask(r: Run, got: Flags.Parsed): integer
  local text = table.concat(got.words, " ")
  if text == "" then text = r.io.read_all() end
  if text:match("^%s*$") then
    r.complain("ask: give a prompt, as words or on standard input; " .. Flags.usage(Verb, "cosmic agent", { "ask" }))
    return bare.refused
  end
  local json = got.set["--json"] == true
  local events = if json then Show.json(r.io.out) else Show.text(r.io.out, r.io.err) end
  return with_session(r, "ask", got, function(s: Agent.Session): integer
    if json then emit(r, { type = "session", id = s.id or 0 }) end
    -- A turn the last run left unfinished is finished first.
    if s:unfinished() then
      local ok, trouble = turn(r, s, events, resuming)
      if json then emit_end(r, ok, trouble) end
      if not ok then
        r.complain("ask: the unfinished turn: " .. trouble)
        if s.stopped then return bare.failed end
      end
    end
    local ok, trouble = turn(r, s, events, prompting(text))
    if json then emit_end(r, ok, trouble) end
    if not ok then
      -- A spent turn is over: resume finds nothing to finish, and a new prompt goes on.
      local next_step = if s.spent then
        "; go on with `cosmic agent ask --session " .. tostring(s.id or 0) .. " 'go on'` and a larger --budget" else
        "" end
      r.complain("ask: " .. trouble .. next_step)
      return bare.failed
    end
    return bare.ok
  end)
end

local function chat(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("chat: takes no words; type the prompts; " .. Flags.usage(Verb, "cosmic agent", { "chat" }))
    return bare.refused
  end
  local keep, keep_why = warm_for(got)
  if keep == nil then
    r.complain("chat: " .. keep_why)
    return bare.refused
  end
  local events = Show.text(r.io.out, r.io.err)
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
    if s:unfinished() then
      local ok, trouble = turn(r, s, events, resuming, poll, steers)
      if not ok then r.complain("chat: the unfinished turn: " .. trouble) end
    end
    while true do
      local line = table.remove(steers, 1) or table.remove(later, 1) or next_line(r, s, "chat", "> ", keep)
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
    r.complain("resume: takes no words; " .. Flags.usage(Verb, "cosmic agent", { "resume" }))
    return bare.refused
  end
  return with_session(r, "resume", got, function(s: Agent.Session): integer
    if not s:unfinished() then
      r.complain("resume: session " .. tostring(s.id) .. " has no unfinished turn")
      return bare.ok
    end
    local ok, trouble = turn(r, s, Show.text(r.io.out, r.io.err), resuming)
    if not ok then
      r.complain("resume: " .. trouble)
      return bare.failed
    end
    return bare.ok
  end, true)
end

local function rpc(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("rpc: takes no words; " .. Flags.usage(Verb, "cosmic agent", { "rpc" }))
    return bare.refused
  end
  local keep, keep_why = warm_for(got)
  if keep == nil then
    r.complain("rpc: " .. keep_why)
    return bare.refused
  end
  local events = Show.json(r.io.out)
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
    emit(r, { type = "session", id = s.id or 0, unfinished = s:unfinished() })
    while true do
      local c = table.remove(queue, 1)
      if c == nil then
        local line = next_line(r, s, "rpc", "", keep, events)
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
          go = resuming
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
    r.complain("sessions: takes no words; " .. Flags.usage(Verb, "cosmic agent", { "sessions" }))
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
  if #list == 0 then
    r.io.err("sessions: none in " .. cwd(r))
    return bare.ok
  end
  r.io.out(string.format("%4s  %-19s  %-17s  %4s  %7s  %7s  %s", "id", "started", "model", "msgs", "context", "cost",
    "first prompt"))
  for _, e in ipairs(list) do
    r.io.out(string.format("%4d  %-19s  %-17s  %4d  %7s  %7s  %s", e.id, e.started, e.model, e.messages,
      tokens(e.context), string.format("$%.3f", e.cost), Show.brief(e.first)))
  end
  return bare.ok
end

local function prompt(r: Run, got: Flags.Parsed): integer
  if #got.words > 0 then
    r.complain("prompt: takes no words; " .. Flags.usage(Verb, "cosmic agent", { "prompt" }))
    return bare.refused
  end
  local here = cwd(r)
  local offered, why = offered_tools(got)
  if offered == nil then
    r.complain("prompt: tools: " .. why)
    return bare.refused
  end
  -- The system prompt, then the working directory that follows it.
  r.io.out(Prompt.build(here, Prompt.contexts(here), { tools = offered }) .. "\n\n" .. Prompt.where(here))
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
    r.complain("policy: takes no words but clear-home; " .. Flags.usage(Verb, "cosmic agent", { "policy" }))
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
  local offered, offered_why = offered_tools(got)
  if offered == nil then
    r.complain("policy: tools: " .. offered_why)
    return bare.refused
  end
  -- The grants below hold bash; without it the worker runs no program, however much x they give.
  if Tools.find(offered, "bash") ~= nil then
    r.io.out("programs: bash runs those the grants below let it run (x)")
  elseif not Sandbox.on_macos() then
    r.io.out("programs: none run, since no tool offered is bash: the sandbox lets no file but cosmic's own run, " ..
        "whatever x the grants below give (--with bash runs them)")
  else
    r.io.out("programs: no tool offered is bash, but on macOS a snippet may still run those the grants below let it " ..
        "run (x)")
  end
  for _, line in ipairs(Policy.describe(merged, sandbox_home(r))) do r.io.out(line) end
  return bare.ok
end

--- `cosmic agent worker`: the process the `run` tool sends its snippets to ([`build.agent_worker`]), required here
--- alone, since it brings the checker.
local function worker(_r: Run, _got: Flags.Parsed): integer
  return require("build.agent_worker").main()
end

local SUBCOMMANDS <const>: {string: function(Run, Flags.Parsed): integer} = {
  ask = ask, chat = chat, resume = resume, rpc = rpc, sessions = sessions, prompt = prompt, policy = policy,
  worker = worker,
}

--- `cosmic agent <subcommand> ...`: runs it and returns the exit code:
--- 0 ok, 1 a turn that failed or a database it could not open, 2 a
--- command line it refuses or a session it cannot start.
--- @param argv the command line, `agent` at slot 1
--- @param io where it reads and writes; the process's own when nil
function verb.run(argv: {string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("agent", to.err)
  local sub = argv[2]
  local described = if sub == nil then nil else subcommands[sub] end
  if sub == nil or described == nil then
    complain((if sub == nil then "name ask, chat, resume, rpc, sessions, prompt, policy or worker" else
      "no such command: " .. sub end) .. "; " .. Flags.usage(Verb, "cosmic agent"))
    return bare.refused
  end
  local got, trouble = Flags.parse(argv, 3, described.spec or {})
  if got == nil then
    complain(sub .. ": " .. trouble .. "; " .. Flags.usage(Verb, "cosmic agent", { sub }))
    return bare.refused
  end
  local parsed: Flags.Parsed = got
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
  guide = "more quick tools",
  tests = { "build.agent_test" },
  run = function(argv: {string}): integer return verb.run(argv) end,
  bare = true,
  takes = "ask, chat, resume, rpc, sessions, prompt, policy or worker, and its options",
  exits = "`agent` prints the model's words or its events, and nothing after; it exits 0 when it did what was asked, 1 when an ask or resume turn failed or the sessions database could not be opened, 2 when it refuses its command line or cannot start a session.",
  passthrough = "its output is the model's words, so its exit status is the verdict (build/agent_test.tl)",
}

return verb
