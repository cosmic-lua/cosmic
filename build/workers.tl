--- The processes a build parses and compiles in beside its own.
---
--- A pool ([`importer.Workers`]) starts no worker until a build asks
--- for them with enough source to be worth it, then keeps them for the
--- build's later phases: each worker loads the build's code once and
--- serves one phase after another, on a line of its standard input,
--- answering a line on its standard output ([`build.worker`] is the
--- other half, and owns what a phase's job and results hold). A phase's
--- files live in the pool's scratch directory, which `close` removes.
---
--- A pool that cannot start, or loses a worker, says so once on stderr
--- and leaves the work to the build's own process, which does what it
--- would have done without one: a pool changes how long a build takes,
--- never what it makes.

local type Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Log = require("cosmic.log")
local Proc = require("cosmic.proc")
local Stream = require("cosmic.stream")
local worker = require("build.worker")
local type compiler = require("build.compiler")
local type derivation = require("build.derivation")
local type importer = require("build.importer")
local type Sqlite = require("cosmic.sqlite")

local log = Log.new("cosmic")

--- How long a worker may run before the build gives it up as stuck,
--- from its start, which is far past what a cold build of the tree
--- takes serially: it then finishes without it.
local lifetime_ns <const> = Clock.seconds(1800)

--- One started worker: its process, the lines it answers, and whether it
--- has taken every job so far.
local record Process
  handle: Child.Handle
  replies: Stream.Lines
  alive: boolean
end

local record workers
  --- How to start one worker and when one is worth it.
  record Spec
    --- The program and the arguments that make it serve phases
    --- ([`build.worker`]'s `serve`).
    argv: {string}
    --- How much source is worth starting the workers for: a worker that
    --- loads its code from source takes seconds before it serves, a
    --- tool's takes a moment.
    open_bytes: integer
    --- How much source is worth a phase of workers already running.
    phase_bytes: integer
    --- How long, in nanoseconds, a worker takes from its start to serve
    --- its first job, which the build's own process can spend on work
    --- of its own ([`worker.Pool`]'s `warming`).
    startup_ns: integer
  end
end

--- The variable that sets how many workers a build starts.
local variable <const> = "COSMIC_BUILD_JOBS"

--- How many workers a build runs, at most: what `COSMIC_BUILD_JOBS`
--- names, or one fewer than the processors, the build's own process
--- being the last; 1 means none. A value that is not a positive whole
--- number is reported and ignored.
local function jobs_of_build(): integer
  local named = Env.get(variable)
  if named ~= nil and named ~= "" then
    local count = math.tointeger(tonumber(named))
    if count ~= nil and count >= 1 then return count end
    local _, _ = log:complain("build: " .. variable .. "=" .. named ..
        " is not a positive whole number; using the processors' count less one")
  end
  return math.max(Proc.cpu_count() - 1, 1)
end

--- The command line that starts this program again with `args`: the
--- core it runs on, handed its artifact and database directly when it
--- has them ([`Proc.relaunch`]), so no shell or launcher stands between.
--- Its environment is this process's.
local function again(args: {string}): {string}, {string:string}, {integer:integer}
  local launched, _ = Proc.relaunch()
  local argv: {string} = {}
  local env: {string:string} = {}
  local fds: {integer:integer} = {}
  for name, value in pairs(Env.all()) do env[name] = value end
  if launched ~= nil then
    for _, word in ipairs(launched.argv) do argv[#argv + 1] = word end
    for name, value in pairs(launched.env) do env[name] = value end
    for number, fd in pairs(launched.fds) do fds[number] = fd end
  else
    argv[1] = assert(Proc.executable())
  end
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  return argv, env, fds
end

--- How a boot starts a worker: the core it runs on, asked to boot the
--- tree at `root` with the compiler in `tl_dir` and then serve as a
--- worker ([`build.boot`]). The worker loads the build's code from that
--- source, which takes seconds a worker of a tool does not.
-- TODO: once core/bridge.lua takes its compiles from the compiles every
-- checkout shares (the TODOs there), a worker of a boot starts in about
-- two seconds, not nine: lower `startup_ns` and `open_bytes` to match.
function workers.boot_spec(root: string, tl_dir: string): workers.Spec
  local argv, _, _ = again({ "--boot", root, tl_dir, "--worker" })
  return { argv = argv, open_bytes = 3 * 1024 * 1024, phase_bytes = 128 * 1024,
    startup_ns = Clock.seconds(9) }
end

--- How a tool starts a worker: itself, running [`build.worker`]'s
--- `serve` with the compiler it carries.
function workers.tool_spec(): workers.Spec
  local argv, _, _ = again({ "-e", 'require("cosmic.proc").exit(require("build.worker").serve())' })
  return { argv = argv, open_bytes = 512 * 1024, phase_bytes = 128 * 1024, startup_ns = 0 }
end

--- The lines of a worker's reply after `wait`, to say why it ended.
local function stderr_of(handle: Child.Handle): string
  local result, _ = handle:wait(1000000000)
  local said = ""
  if result ~= nil and result.stderr ~= nil then said = result.stderr end
  if said == "" then return "" end
  return ": " .. (said:gsub("%s+$", ""):gsub("\n", " / "))
end

--- A pool of up to `jobs` workers started as `spec` says, none yet.
--- `jobs` is what `COSMIC_BUILD_JOBS` names, or one fewer than the
--- processors, by default. The caller closes it.
function workers.pool(spec: workers.Spec, jobs?: integer): importer.Workers
  local most = jobs or jobs_of_build()
  local scratch: string | nil = nil
  local started = false
  local started_at = 0
  local broken = false

  local running: {Process} = {}

  local function alive(): integer
    local count = 0
    for _, each in ipairs(running) do
      if each.alive then count = count + 1 end
    end
    return count
  end

  local function give_up(why: string)
    if broken then return end
    broken = true
    local _, _ = log:complain("build: workers: " .. why ..
        "; building in this process (" .. variable .. "=1 turns them off)")
  end

  local function finish_workers()
    for _, each in ipairs(running) do
      local feed = each.handle.stdin_stream
      if feed ~= nil then
        local _, _ = feed:close()
      end
    end
    for _, each in ipairs(running) do
      local waited, _ = each.handle:wait(5000000000)
      if waited == nil then
        local _, _ = each.handle:stop()
      end
      local _, _ = each.handle:close()
    end
    running = {}
  end

  local function start(): boolean
    local made, why = Fs.mkdtemp("cosmic-workers-")
    if made == nil then
      give_up(why)
      return false
    end
    scratch = made
    local _, env, fds = again({})
    -- Only here, so a build that starts no worker never loads the module.
    -- TODO: a boot still checks cosmic.child's closure, the relay and
    -- the sandbox among it, where this file is compiled, and that costs
    -- every boot about half a second whether or not it starts a worker: once a
    -- module can start a process without that closure, start workers
    -- with it.
    local child = require("cosmic.child")
    for _ = 1, most do
      local handle, trouble = child.start(spec.argv, {
        env = env, fds = fds, stdin = "stream", stdout = "stream", stderr = "capture",
        timeout_ns = lifetime_ns,
      })
      if handle == nil then
        give_up("cannot start a worker: " .. trouble)
        finish_workers()
        return false
      end
      local reader = assert(handle.stdout_stream)
      running[#running + 1] = { handle = handle, replies = Stream.lines(reader), alive = true }
    end
    started = true
    started_at = Clock.monotonic_ns()
    return true
  end

  local function ready(bytes: integer): boolean
    if broken or most < 2 then return false end
    if started then return alive() > 0 and bytes >= spec.phase_bytes end
    if bytes < spec.open_bytes then return false end
    return start()
  end

  local pool: worker.Pool = {
    warming = function(): integer
      if not started then return 0 end
      return math.max(0, started_at + spec.startup_ns - Clock.monotonic_ns())
    end,
    size = function(): integer
      if started then return alive() end
      return broken and 0 or most
    end,
    path = function(name: string): string | nil, string
      if scratch == nil then return nil, "no workers are running" end
      return scratch .. "/" .. name, ""
    end,
    run = function(phase: string, job: string, count: integer): {string}
      local answers: {string} = {}
      local serving: {Process} = {}
      for _, each in ipairs(running) do
        if each.alive and #serving < count then serving[#serving + 1] = each end
      end
      for index = 1, count do
        local serves = serving[index]
        if serves == nil then
          answers[index] = "no worker is left to serve it"
        else
          local feed = serves.handle.stdin_stream
          local sent, trouble = false, "its input is closed"
          if feed ~= nil then
            sent, trouble = feed:write(phase .. "\t" .. job .. "\t" .. index .. "\t" .. count .. "\n")
          end
          if not sent then
            serves.alive = false
            answers[index] = "a worker took no job: " .. trouble
          end
        end
      end
      for index = 1, count do
        local serves = serving[index]
        if serves ~= nil and answers[index] == nil then
          local reply, _ = serves.replies:read()
          if reply == "ok" then
            answers[index] = ""
          elseif reply ~= nil and reply:sub(1, 5) == "fail\t" then
            answers[index] = reply:sub(6)
          else
            serves.alive = false
            answers[index] = "a worker ended" .. stderr_of(serves.handle)
          end
        end
      end
      for index = 1, count do
        local lost = serving[index]
        if lost ~= nil and not lost.alive then give_up(answers[index]) end
      end
      return answers
    end,
  }

  return {
    size = function(): integer
      return most
    end,
    ready = ready,
    parse = function(db: Sqlite.Handle, built: compiler, fresh: {derivation.Fresh},
                     tally: derivation.Parses, made: {derivation.Source}): boolean, string
      return worker.parse(pool, db, built, fresh, tally, made)
    end,
    compile = function(db: Sqlite.Handle, root: string, order: {importer.Module},
                       wanted: {string:boolean}, own_tree: boolean,
                       judged: boolean): importer.Ahead | nil, string
      return worker.compile(pool, db, root, order, wanted, own_tree, judged)
    end,
    close = function()
      finish_workers()
      if scratch ~= nil then
        local _, _ = Fs.remove_tree(scratch)
        scratch = nil
      end
      started = false
    end,
  }
end

return workers
