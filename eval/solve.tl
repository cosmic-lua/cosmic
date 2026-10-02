--- Runs the Claude Code solver for an arena [`eval/arena`] laid, in a
--- sandbox that leaves it the arena and what the CLI needs to run, and
--- nothing else of the host's files: no checkout of this repository, no
--- ~/.claude, no cache, no other arena.
---
---     cosmic --standalone eval/solve.tl <arena> --model <id> [--max-turns N] [--timeout S]
---
--- It writes transcript.jsonl, stderr, started_at, finished_at and
--- exit_code beside the arena's PROMPT.md, as eval/README.md's manual
--- launch does. [`eval/solve`] runs this on the bootstrap cosmic, as
--- [`eval/arena`] runs eval/arena.tl: it requires `cosmic.*` modules
--- only.
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")

local record Solve
  --- What a run was asked for on the command line.
  record Options
    arena: string
    model: string
    max_turns: integer
    --- The solver's deadline, in seconds.
    timeout: integer
  end

  --- The claude program as the sandbox gives it: what to unveil for
  --- it, read-only, and the directories its interpreter, if any, is
  --- found in.
  record Program
    reads: {string}
    path: {string}
  end
end

--- The arena's directories the solver changes: its project, its TMPDIR,
--- and the CLI's own config and home, fresh for each run and outside
--- project/ so nothing the CLI writes lands in what is graded.
local writable: {string} = { "project", "tmp", "config", "home" }

--- The host's paths every run is given read-only, where the host has
--- them. /usr and the links into it (/bin, /lib, /lib64) hold the shell
--- and the tools the solver's Bash calls start, and the dynamic loader
--- the CLI itself needs; /etc holds the loader's cache, passwd and
--- nsswitch, hosts and resolv.conf, and the system's CA store. The
--- devices are those a program takes for granted, and /proc is the
--- sandbox's own pid namespace's (the CLI reads /proc/self).
--- /sys, /opt, /home, /root, /mnt and /var are left out: the CLI runs
--- without them, and ~/.claude, a synced skills directory (/mnt/skills)
--- and every checkout of this repository live there.
-- TODO: keep /etc/claude-code (Claude Code's managed settings and
-- CLAUDE.md, which it reads whatever CLAUDE_CONFIG_DIR says) from the
-- solver once cosmic.child's unveil can hide a path under one it gives;
-- until then eval/README.md asks for a host without it.
local system: {string} = { "/usr", "/bin", "/lib", "/lib64", "/etc", "/dev/null", "/dev/zero",
  "/dev/full", "/dev/random", "/dev/urandom", "/proc" }

--- The host's variables the solver is passed, each where it is set,
--- and nothing else of its environment: the proxy every request goes
--- through, the CA bundle the proxy's certificates chain to, and the
--- credentials and endpoint a host may give the CLI in its environment.
--- What a cloud session sets beside them is never passed: every token
--- for another service, and the variables that would bring this
--- checkout's instructions or a synced skill back in
--- (CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD,
--- CLAUDE_ADDITIONAL_DIRECTORIES, CLAUDE_CODE_SYNC_SKILLS).
local passed: {string} = { "HTTPS_PROXY", "https_proxy", "NO_PROXY", "no_proxy", "SSL_CERT_FILE",
  "NODE_EXTRA_CA_CERTS", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
  "CLAUDE_CODE_OAUTH_TOKEN" }

--- The variables of `passed` that name a file the CLI reads, which the
--- sandbox gives it read-only.
local files_named: {string} = { "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS" }

--- The file a Claude Code cloud session keeps the CLI's credential in,
--- which the CLI reads by this name whatever its environment, and
--- without which it is not logged in: given alone, read-only, so the
--- directory around it (skills/ beside remote/) stays out of reach. A
--- solver can read it, as it could read a credential passed in its
--- environment.
local credentials: {string} = { "/home/claude/.claude/remote/.oauth_token" }

local USAGE <const> = "usage: eval/solve <arena> --model <id> [--max-turns N] [--timeout S]"

local function positive(text: string): integer
  if text == nil or not text:match("^[1-9]%d*$") then return nil end
  return math.tointeger(tonumber(text))
end

--- Reads the command line: the arena, then `--model` (required),
--- `--max-turns` (60 by default) and `--timeout` (600 seconds by
--- default), as eval/README.md's manual launch has them.
function Solve.parse(argv: {integer: string}): Solve.Options | nil, string
  local options: Solve.Options = { max_turns = 60, timeout = 600 }
  local i = 1
  while argv[i] ~= nil do
    local word = argv[i]
    if word == "--model" or word == "--max-turns" or word == "--timeout" then
      local value = argv[i + 1]
      if value == nil then return nil, word .. " needs a value" end
      if word == "--model" then
        options.model = value
      else
        local n = positive(value)
        if n == nil then return nil, word .. " takes a positive integer: " .. value end
        if word == "--max-turns" then options.max_turns = n else options.timeout = n end
      end
      i = i + 2
    elseif word:sub(1, 1) == "-" then
      return nil, "unknown option " .. word
    elseif options.arena ~= nil then
      return nil, "one arena only: " .. word
    else
      options.arena = word
      i = i + 1
    end
  end
  if options.arena == nil then return nil, "an arena is required" end
  if options.model == nil or options.model == "" then return nil, "--model is required" end
  return options, ""
end

--- The arguments the CLI is given after its own name: eval/README.md's
--- manual launch, flag for flag.
function Solve.arguments(prompt: string, options: Solve.Options): {string}
  local tools = "Bash,Read,Write,Edit,Glob,Grep"
  return {
    "-p", prompt, "--model", options.model, "--disable-slash-commands",
    "--tools", tools, "--allowedTools", tools,
    "--disallowedTools", "Skill,WebSearch,WebFetch,Agent,Task,ToolSearch,SearchSkills,"
      .. "ListSkills,SearchPlugins,ListPlugins,SearchMcpRegistry,Workflow,SendMessage,"
      .. "Artifact,NotebookEdit,SendUserFile",
    "--max-turns", tostring(options.max_turns), "--output-format", "stream-json", "--verbose",
  }
end

--- The solver's whole environment: `passed` from `host`, and its own
--- HOME, CLAUDE_CONFIG_DIR, TMPDIR and PATH inside `arena`, PATH
--- putting the arena's bin/ first, then `extra` (an interpreter's
--- directories), then the system's.
function Solve.environment(host: {string:string}, arena: string, extra: {string}): {string:string}
  local env: {string:string} = {}
  for _, name in ipairs(passed) do
    env[name] = host[name]
  end
  local path = { arena .. "/bin" }
  for _, dir in ipairs(extra) do path[#path + 1] = dir end
  for _, dir in ipairs({ "/usr/local/bin", "/usr/bin", "/bin" }) do path[#path + 1] = dir end
  env.PATH = table.concat(path, ":")
  env.HOME = arena .. "/home"
  env.CLAUDE_CONFIG_DIR = arena .. "/config"
  env.TMPDIR = arena .. "/tmp"
  return env
end

--- What of the claude program at `resolved` (links resolved) the
--- sandbox gives, given its first bytes `head` and `find`, which
--- resolves an interpreter's name or path on the host: a native
--- executable alone; a script, its directory (an npm package's) and its
--- interpreter, whose directory goes on PATH for an `env` line.
function Solve.program(resolved: string, head: string,
                       find: function(string): string | nil): Solve.Program | nil, string
  if head:sub(1, 4) == "\127ELF" then
    return { reads = { resolved }, path = {} }, ""
  end
  local line = head:match("^#!%s*([^\n]*)")
  if line == nil then return nil, resolved .. " is neither an executable nor a script" end
  local words: {string} = {}
  for word in line:gmatch("%S+") do words[#words + 1] = word end
  local name = words[1]
  if name ~= nil and name:match("/env$") then name = words[2] end
  if name == nil then return nil, resolved .. ": no interpreter on its #! line" end
  local interpreter = find(name)
  if interpreter == nil then return nil, resolved .. ": interpreter " .. name .. " not found" end
  return { reads = { Fs.dirname(resolved), interpreter }, path = { Fs.dirname(interpreter) } }, ""
end

--- The sandbox's unveil for `arena`: the arena's bin/ and `program`'s
--- `reads`, read-only, with every path of `host_reads` that `exists`;
--- and `writable` under the arena to change. It names no /tmp, so the
--- sandbox makes one of its own, which a stray write outside TMPDIR
--- reaches and the host never sees.
function Solve.unveil(arena: string, program: Solve.Program, host_reads: {string},
                      exists: function(string): boolean): Child.Unveil
  local reads: {string} = {}
  local seen: {string:boolean} = {}
  local function add(path: string)
    if seen[path] or not exists(path) then return end
    seen[path] = true
    reads[#reads + 1] = path
  end
  for _, path in ipairs(host_reads) do add(path) end
  for _, path in ipairs(program.reads) do add(path) end
  add(arena .. "/bin")
  local writes: {string} = {}
  for _, sub in ipairs(writable) do writes[#writes + 1] = arena .. "/" .. sub end
  return { reads = reads, writes = writes }
end

--- The host paths to give beside the program: `system`, the files
--- `files_named` names in `env` where each is absolute, and the
--- credential files.
function Solve.host_reads(env: {string:string}): {string}
  local reads: {string} = {}
  for _, path in ipairs(system) do reads[#reads + 1] = path end
  for _, name in ipairs(files_named) do
    local path = env[name]
    if path ~= nil and path:sub(1, 1) == "/" then reads[#reads + 1] = path end
  end
  for _, path in ipairs(credentials) do reads[#reads + 1] = path end
  return reads
end

--- The exit status the manual launch's `timeout` would have recorded:
--- the child's own, 124 past its deadline, or 128 and the signal that
--- ended it.
function Solve.status(result: Child.Result): integer
  if result.timed_out then return 124 end
  if result.code ~= nil then return result.code end
  return 128 + (result.signal or 0)
end

--- The command, run in the solver's sandbox, that exits 0 only when
--- the sandbox's /proc does not show `host_pid`, a pid outside its pid
--- namespace: when that /proc is its own.
function Solve.proc_probe(host_pid: integer): {string}
  return { "/bin/sh", "-c", "test ! -e /proc/" .. tostring(host_pid) }
end

local function complain(message: string)
  local _, _ = Fs.put(Fs.stderr, "solve: " .. message .. "\n")
end

local function now(): string
  local ns = Time.now_ns()
  return Time.format_rfc3339(ns - ns % 1000000000) .. "\n"
end

--- An arena eval/arena laid, never solved: its own pieces are there,
--- and nothing a run writes is yet.
local function check_arena(arena: string): boolean, string
  for _, sub in ipairs({ "bin", "project", "tmp" }) do
    local dir, trouble = Fs.is_dir(arena .. "/" .. sub)
    if dir == nil then return false, trouble end
    if not dir then return false, arena .. " is no arena: no " .. sub .. "/" end
  end
  for _, name in ipairs({ "transcript.jsonl", "stderr", "started_at", "config", "home" }) do
    local there, trouble = Fs.exists(arena .. "/" .. name)
    if there == nil then return false, trouble end
    if there then return false, arena .. " has run already: " .. name .. " is there" end
  end
  return true, ""
end

local function exists(path: string): boolean
  local there, _ = Fs.exists(path)
  return there == true
end

function Solve.main(argv: {integer: string}): integer
  local options, usage_trouble = Solve.parse(argv)
  if options == nil then
    complain(usage_trouble)
    local _, _ = Fs.put(Fs.stderr, USAGE .. "\n")
    return 2
  end
  local arena, atrouble = Fs.absolute(options.arena)
  if arena == nil then
    complain(atrouble)
    return 2
  end
  local fresh, ftrouble = check_arena(arena)
  if not fresh then
    complain(ftrouble)
    return 2
  end
  local prompt, ptrouble = Fs.read(arena .. "/PROMPT.md")
  if prompt == nil then
    complain(ptrouble)
    return 2
  end
  local claude, ctrouble = Proc.find("claude")
  if claude == nil then
    complain("claude: " .. ctrouble)
    return 2
  end
  local resolved, rtrouble = Fs.absolute(claude)
  if resolved == nil then
    complain(rtrouble)
    return 2
  end
  local fd, otrouble = Fs.open_read(resolved)
  if fd == nil then
    complain(otrouble)
    return 2
  end
  local head, htrouble = Fs.take(fd, 256)
  local _, _ = Fs.close(fd)
  if head == nil then
    complain(htrouble)
    return 2
  end
  local program, gtrouble = Solve.program(resolved, head, function(name: string): string | nil
    local found: string = name
    if name:sub(1, 1) ~= "/" then
      local on_path, _ = Proc.find(name)
      if on_path == nil then return nil end
      found = on_path
    end
    local real, _ = Fs.absolute(found)
    return real
  end)
  if program == nil then
    complain(gtrouble)
    return 2
  end
  for _, sub in ipairs({ "config", "home" }) do
    local made, mtrouble = sys.mkdir(arena .. "/" .. sub)
    if not made then
      complain(arena .. "/" .. sub .. ": " .. mtrouble)
      return 2
    end
  end
  local host = sys.environ()
  local env = Solve.environment(host, arena, program.path)
  local unveil = Solve.unveil(arena, program, Solve.host_reads(env), exists)
  -- Where the kernel refuses the sandbox a procfs of its own, cosmic.child
  -- binds the host's /proc read-only instead (core/syscalls.c's
  -- place_proc), and through it the solver could read every host
  -- process's environment and reach the checkout by /proc/<pid>/root.
  -- This process is outside the sandbox's pid namespace, so its pid
  -- shows under /proc there only when that /proc is the host's.
  local probe, probe_trouble = Child.run(Solve.proc_probe(Proc.pid()), { env = {},
    cwd = arena .. "/project", stdin = "null", stdout = "null", stderr = "null",
    sandbox = { unveil = unveil } })
  if probe == nil then
    complain(probe_trouble .. " (where the sandbox is unavailable, eval/README.md has the manual launch)")
    return 2
  elseif Solve.status(probe) ~= 0 then
    complain("the sandbox's /proc is the host's, not its own; not running the solver there " ..
      "(eval/README.md has the manual launch)")
    return 2
  end
  local outputs: {integer} = {}
  for _, name in ipairs({ "transcript.jsonl", "stderr" }) do
    local out, wtrouble = Fs.open_write(arena .. "/" .. name, 0x1a4)
    if out == nil then
      complain(wtrouble)
      return 2
    end
    outputs[#outputs + 1] = out
  end
  local command: {string} = { resolved }
  for _, word in ipairs(Solve.arguments(prompt, options)) do command[#command + 1] = word end
  local wrote, wtrouble = Fs.write(arena .. "/started_at", now())
  if not wrote then
    complain(wtrouble)
    return 2
  end
  local started = Time.monotonic_ns()
  -- The run's own guard holds a SIGINT or SIGTERM until finished_at and
  -- exit_code are written, then delivers it as it closes.
  local guard <close> = assert(Child.guard())
  local result, trouble = Child.run(command, {
    env = env,
    cwd = arena .. "/project",
    stdin = "null",
    stdout = outputs[1],
    stderr = outputs[2],
    timeout_ns = Time.seconds(options.timeout),
    sandbox = { unveil = unveil },
  })
  for _, out in ipairs(outputs) do local _, _ = Fs.close(out) end
  local status: integer
  if result ~= nil then
    status = Solve.status(result)
  elseif guard:cancelled() ~= 0 then
    status = 128 + guard:cancelled()
  else
    complain(trouble .. " (where the sandbox is unavailable, eval/README.md has the manual launch)")
    status = 125
  end
  local _, _ = Fs.write(arena .. "/finished_at", now())
  local _, _ = Fs.write(arena .. "/exit_code", tostring(status) .. "\n")
  local seconds = (Time.monotonic_ns() - started) // 1000000000
  complain(arena .. ": exit " .. tostring(status) .. " after " .. tostring(seconds) .. "s"
    .. (result ~= nil and result.timed_out and " (past the " .. tostring(options.timeout)
      .. "s deadline)" or ""))
  return status
end

return Solve
