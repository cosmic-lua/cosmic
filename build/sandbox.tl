--- `cosmic sandbox`: runs one program held to the paths its command line
--- names, with every process it starts, through [`cosmic.child`]'s
--- `sandbox` option: by default in a root of its own that holds those
--- paths alone (its `unveil`), or, with `--landlock`, in the host's own
--- root under a Landlock ruleset over them (its `landlock`), which needs
--- no user namespace.
---
--- The program is found on PATH as a shell finds it, and is given to
--- read and run whatever the paths named: what it loads besides -- its
--- dynamic loader and libraries, a script's interpreter -- is not, and
--- `--system` gives the system's own (`system_paths`). It inherits this
--- process's environment, working directory and standard streams.
--- Unveiled, it starts in its own session, with no controlling terminal,
--- and in the working directory only where that is among the paths, at
--- / otherwise. SIGINT and SIGTERM delivered here are passed on to it,
--- but for a SIGINT to a landlocked program, which shares this
--- process's group and so had the terminal's already.
---
--- Like `cosmic json` it ends in no verdict line: what it prints is the
--- program's own, and it exits with the program's status -- 128 plus
--- the signal's number for one a signal ended -- or, before the program
--- runs, 2 for a command line it refuses, 125 for a sandbox the host
--- refused or a start that failed, 126 for a program it cannot run and
--- 127 for one not found. Its `spec` (build/verb_spec.tl) is `bare`.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local bare = require("build.bare")
local verb_spec = require("build.verb_spec")

--- The `cosmic sandbox` verb: `run` is what [`build/dispatch.tl`] calls.
local record verb
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec
  --- Where `run` complains and how it starts the program: what a test
  --- stands in for.
  record Io
    --- Writes one complaint line, without its newline.
    err: function(line: string)
    --- Starts the program: [`Child.start`] when nil.
    start: function(argv: {string}, opts: Child.Options): Child.Handle | nil, string
  end

  --- The exit code of a sandbox the host refused, or a start that failed.
  NOT_STARTED: integer
end

verb.NOT_STARTED = 125

--- The exit code of a program found but not runnable, as a shell's.
local NOT_RUNNABLE <const> = 126
--- The exit code of a program not found, as a shell's.
local NOT_FOUND <const> = 127

--- The paths `--system` gives to read, each where the host has it: the
--- system's programs and libraries and its configuration, what a host
--- program or the dynamic loader that starts it reads.
local system_paths: {string} = { "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc" }
--- The devices `--system` gives to write.
local system_devices: {string} = { "/dev/null", "/dev/zero", "/dev/full", "/dev/random",
  "/dev/urandom", "/dev/tty" }

local spec = Cli.verbs.sandbox.spec

local usage = "cosmic sandbox [--read PATH]... [--write PATH]... [--system] [--offline] " ..
  "[--landlock] [--] <program> [args...]"

--- How often the wait looks for a signal to pass on.
local SIGNAL_POLL_NS <const> = Time.ms(50)

--- The slot of `argv`'s program: the first word from slot 2 on that is
--- neither an option nor an option's value, or the one after "--"; nil
--- when there is none. The words from it on are the program's, options
--- included, so a `--help` there is not this verb's.
function verb.program_slot(argv: {integer:string}): integer | nil
  local slot = 2
  while argv[slot] ~= nil do
    local word = argv[slot]
    if word == "--" then
      return argv[slot + 1] ~= nil and slot + 1 or nil
    end
    if word:sub(1, 1) ~= "-" or word == "-" then return slot end
    local option = spec[word]
    if option is Flags.Option and option.value ~= nil then slot = slot + 1 end
    slot = slot + 1
  end
  return nil
end

--- What `argv` asks for.
local record Request
  reads: {string}
  writes: {string}
  offline: boolean
  landlock: boolean
  system: boolean
  --- The program as named, then its words.
  command: {string}
end

--- `path` absolute, read from the working directory, with no link in it
--- resolved: a sandbox gives a path through a link at the link's name
--- and the name it resolves to both, as the program names it. Its "."
--- parts and repeated and trailing slashes are dropped. Nil and why when
--- it is empty or the working directory cannot be read.
local function absolute(path: string, option: string): string | nil, string
  if path == "" then return nil, option .. " needs a path, not an empty one" end
  local full = path
  if path:sub(1, 1) ~= "/" then
    local here, trouble = sys.getcwd()
    if here == nil then return nil, option .. " " .. path .. ": " .. trouble end
    full = here .. "/" .. path
  end
  local parts: {string} = {}
  for part in full:gmatch("[^/]+") do
    if part ~= "." then parts[#parts + 1] = part end
  end
  return "/" .. table.concat(parts, "/"), ""
end

--- What `argv` asks for, or nil and why it is refused.
local function arguments(argv: {integer:string}): Request | nil, string
  local at = verb.program_slot(argv)
  if at == nil then return nil, "name a program to run" end
  local options: {integer:string} = { [0] = argv[0], [1] = argv[1] }
  local count = 1
  local slot = 2
  while slot < at do
    if argv[slot] ~= "--" then
      count = count + 1
      options[count] = argv[slot]
    end
    slot = slot + 1
  end
  local parsed, trouble = Flags.parse(options, 2, spec)
  if parsed == nil then return nil, trouble end
  local request: Request = { reads = {}, writes = {}, offline = parsed.set["--offline"] == true,
    landlock = parsed.set["--landlock"] == true, system = parsed.set["--system"] == true,
    command = {} }
  for _, option in ipairs({ "--read", "--write" }) do
    local into = option == "--read" and request.reads or request.writes
    for _, given in ipairs(parsed.all[option] or {}) do
      local path, why = absolute(given, option)
      if path == nil then return nil, why end
      into[#into + 1] = path
    end
  end
  if parsed.set["--system"] then
    for _, path in ipairs(system_paths) do
      local there, _ = Fs.exists(path)
      if there then request.reads[#request.reads + 1] = path end
    end
    for _, path in ipairs(system_devices) do
      local there, _ = Fs.exists(path)
      if there then request.writes[#request.writes + 1] = path end
    end
  end
  slot = at
  while argv[slot] ~= nil do
    request.command[#request.command + 1] = argv[slot]
    slot = slot + 1
  end
  if request.command[1] == "" then return nil, "name a program to run, not an empty word" end
  return request, ""
end

--- Whether `path` is `within` or beneath it, both absolute.
local function beneath(path: string, within: string): boolean
  if within == "/" or path == within then return true end
  return path:sub(1, #within + 1) == within .. "/"
end

--- The directory an unveiled program starts in: the working directory
--- where one of `paths` holds it, "/" otherwise, as nothing else of the
--- host is there.
local function unveiled_cwd(paths: {string}): string
  local here, _ = sys.getcwd()
  if here == nil then return "/" end
  for _, path in ipairs(paths) do
    if beneath(here, path) then return here end
  end
  return "/"
end

local standard: verb.Io = {
  err = bare.err,
  start = Child.start,
}

--- `cosmic sandbox [options] [--] <program> [args...]`: runs the program
--- held to what the options name, and returns its exit code, or this
--- verb's own for a run that never started (see the module's docs).
--- @param argv the command line, `sandbox` at slot 1
--- @param io where complaints go and how the program starts; the process's own when nil
function verb.run(argv: {integer:string}, io?: verb.Io): integer
  local to = io or standard
  local complain = bare.complainer("sandbox", to.err)
  local found, trouble = arguments(argv)
  if found == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  local request: Request = found
  local where = Proc.find_result(request.command[1])
  if where.kind == "not_found" then
    complain(where.reason)
    return NOT_FOUND
  elseif where.kind == "not_executable" then
    complain(where.reason)
    return NOT_RUNNABLE
  end
  local program, why = absolute(where.path, "the program")
  if program == nil then
    complain(why)
    return NOT_FOUND
  end
  local command: {string} = { program }
  for index = 2, #request.command do command[index] = request.command[index] end
  local reads: {string} = { program }
  for _, path in ipairs(request.reads) do reads[#reads + 1] = path end

  local sandbox: Child.Sandbox = { offline = request.offline }
  local opts: Child.Options = { sandbox = sandbox }
  if request.landlock then
    sandbox.landlock = { reads = reads, writes = request.writes }
    -- The program shares this process's group, and so its terminal's
    -- signals and reads, as it would started by a shell.
    opts.process_group = false
  else
    sandbox.unveil = { reads = reads, writes = request.writes }
    local given: {string} = {}
    for _, path in ipairs(reads) do given[#given + 1] = path end
    for _, path in ipairs(request.writes) do given[#given + 1] = path end
    opts.cwd = unveiled_cwd(given)
  end

  -- Every return closes the guard: one before the program has run
  -- delivers a signal caught meanwhile here, and one after releases it,
  -- since the program has had each.
  local guard, guard_trouble = Child.guard()
  if guard == nil then
    complain(guard_trouble)
    return verb.NOT_STARTED
  end
  local start = to.start or Child.start
  local h, start_trouble = start(command, opts)
  if h == nil then
    local _, _ = guard:close()
    complain(start_trouble)
    if not request.system then
      complain("a dynamic program needs its loader and libraries given too, and a " ..
        "script its interpreter: --system gives the system's")
    end
    return verb.NOT_STARTED
  end
  while true do
    local done, wait_trouble = Child.wait_any({ h }, SIGNAL_POLL_NS)
    local signal = guard:take()
    -- A program in this process's group had the terminal's SIGINT
    -- already.
    if signal ~= 0 and not (signal == sys.SIGINT and opts.process_group == false) then
      local _, _ = h:stop(signal)
    end
    if done ~= nil then break end
    if wait_trouble ~= Poll.TIMEOUT then
      local _, _ = h:close()
      local _, _ = guard:release()
      complain(wait_trouble)
      return verb.NOT_STARTED
    end
  end
  -- Released first, so the wait reads no signal of the guard's.
  local _, _ = guard:release()
  local result, result_trouble = h:wait()
  if result == nil then
    complain(result_trouble)
    return verb.NOT_STARTED
  end
  if result.signal ~= nil then return 128 + result.signal end
  return result.code or 0
end

--- The `sandbox` verb as [`build/verb_list.tl`] lists it. It reads no
--- tree, so it is never stale-checked.
verb.spec = {
  name = "sandbox",
  guide = "run a program in a sandbox",
  tests = { "build.sandbox_test", "build.sandbox_tool_test" },
  run = function(argv: {integer:string}): integer return verb.run(argv) end,
  bare = true,
  program_slot = verb.program_slot,
  takes = "options, then a program and its words",
  exits = "`sandbox` prints only what its program prints and exits with its status, 128 plus the signal's number for one a signal ended; before the program runs, it exits 2 when it refuses its command line, 125 when the sandbox or the start failed, 126 for a program it cannot run and 127 for one not found.",
  passthrough = "its output and exit status are its program's (build/sandbox_test.tl)",
}

return verb
