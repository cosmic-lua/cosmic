--- The processes a build parses and compiles in beside its own.
---
--- A pool ([`importer.Workers`]) starts no worker until a build asks
--- for them with enough source to be worth it, then keeps them for the
--- build's later phases: each worker loads the build's code once and
--- serves one phase after another, on a line of its standard input,
--- answering a line on its standard output ([`build.worker`] is the
--- other half, and owns what a phase's job and results hold). A phase's
--- files live in the pool's scratch directory, under a directory of this
--- user's alone in the temporary directory, which `close` empties. A
--- build that is interrupted or killed leaves its scratch directory
--- until the next pool starts, which sweeps it ([`Fs.scratch`]). A
--- worker stays in its starter's process group, so a signal to the
--- group from a terminal ends it with the build. After a build is killed
--- some other way a worker finishes the job it is on, and ends once it
--- reads the end of its input.
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
local sys = require("cosmic.sys")
local worker = require("build.worker")
local type compiler = require("build.compiler")
local type derivation = require("build.derivation")
local type importer = require("build.importer")
local type Sqlite = require("cosmic.sqlite")

local log = Log.new("cosmic")

--- How long a worker may run before the build gives it up as stuck,
--- from its start, and finishes without it, still holding the rebuild
--- lock: five times what a cold build of the tree takes serially on a
--- slow processor, since a worker's whole life is both phases of one
--- build.
local lifetime_ns <const> = Clock.seconds(600)

--- One started worker: its process, the lines it answers, and whether it
--- has taken every job so far.
local record Process
  handle: Child.Handle
  replies: Stream.Lines
  alive: boolean
end

--- What a pool keeps as it starts, serves and ends its workers.
local record PoolState
  scratch: Fs.Scratch | nil
  jobs_made: integer
  started: boolean
  started_at: integer
  broken: boolean
  running: {Process}
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

--- The variable that moves the compiles every checkout shares, or turns
--- them off with `0` ([`build.shared_compiles`]).
local cache_variable <const> = "COSMIC_BUILD_CACHE"

--- Whether core/bridge.lua can keep and take its compiles, as far as the
--- environment says: it does not with the cache off, a name that is not
--- absolute, or neither `XDG_CACHE_HOME` nor `HOME` an absolute path.
local function bridge_has_a_cache(): boolean
  local named = Env.get_or(cache_variable, "")
  if named == "0" then return false end
  if named ~= "" then return named:sub(1, 1) == "/" end
  if Env.get_or("XDG_CACHE_HOME", ""):sub(1, 1) == "/" then return true end
  return Env.get_or("HOME", ""):sub(1, 1) == "/"
end

--- How a boot starts a worker: the core it runs on, asked to boot the
--- tree at `root` with the seed in `seed_dir` and then serve as a
--- worker ([`build.boot`]). The worker loads the build's code from that
--- source. The bridge ran before this and kept its compiles in the
--- shared cache (core/bridge.lua), so the worker takes them from it and
--- serves a job in a third of a second alone, a second with every
--- processor busy starting one. Where the bridge has no cache
--- ([`bridge_has_a_cache`]) it compiles them again, which takes about
--- nine seconds.
-- TODO: tell a worker's starter whether the bridge could keep and read
-- its compiles: a cache that is unusable though not off (one others can
-- write, or one that cannot be opened) leaves every worker compiling for
-- nine seconds while the build waits on the short start below. Waits on
-- a way for core/bridge.lua to hand build.boot what it did: core/boot.c
-- passes build.boot only the root, the command line and the compiler's Lua.
function workers.boot_spec(root: string, seed_dir: string): workers.Spec
  local argv, _, _ = again({ "--boot", root, seed_dir, "--worker" })
  if not bridge_has_a_cache() then
    return { argv = argv, open_bytes = 3 * 1024 * 1024, phase_bytes = 128 * 1024,
      startup_ns = Clock.seconds(9) }
  end
  return { argv = argv, open_bytes = 512 * 1024, phase_bytes = 128 * 1024,
    startup_ns = Clock.seconds(1) }
end

--- How a tool starts a worker: itself, running [`build.worker`]'s
--- `serve` with the compiler it carries.
function workers.tool_spec(): workers.Spec
  local argv, _, _ = again({ "-e", 'require("cosmic.proc").exit(require("build.worker").serve())' })
  return { argv = argv, open_bytes = 512 * 1024, phase_bytes = 128 * 1024, startup_ns = 0 }
end

--- What `handle`'s worker wrote to its standard error, after it ended, on
--- one line and led by ": ", or "" where it wrote nothing.
local function stderr_of(handle: Child.Handle): string
  local result, _ = handle:wait(1000000000)
  local said = ""
  if result ~= nil and result.stderr ~= nil then said = result.stderr end
  if said == "" then return "" end
  return ": " .. (said:gsub("%s+$", ""):gsub("\n", " / "))
end

--- Makes `path` a directory of this user's alone if it is not there, 0700,
--- and answers whether it is one: the pool's job files become code in the
--- tool, so a directory another user owns or can write is refused, as
--- [`Fs.cache_dir`] refuses one. A link is none.
local function private_dir(path: string): boolean, string
  local made, why, number = sys.mkdir(path, 0x1c0)
  if not made and number ~= sys.EEXIST then
    return false, path .. ": " .. why
  end
  local st, trouble = sys.lstat(path)
  if st == nil then
    return false, path .. ": " .. trouble
  end
  if st.kind == "link" then
    return false, path .. ": is a link"
  end
  if st.kind ~= "dir" then
    return false, path .. ": not a directory"
  end
  if st.uid ~= sys.getuid() then
    return false, path .. ": owned by another user"
  end
  if st.mode & 0x12 ~= 0 then
    return false, path .. ": writable by its group or others"
  end
  return true, ""
end

--- A pool of up to `jobs` workers started as `spec` says, none yet.
--- `jobs` is what `COSMIC_BUILD_JOBS` names, or one fewer than the
--- processors, by default. The caller closes it.
function workers.pool(spec: workers.Spec, jobs?: integer): importer.Workers
  local most = jobs or jobs_of_build()
  local state: PoolState = { jobs_made = 0, started = false, started_at = 0, broken = false, running = {} }

  local function alive(): integer
    local count = 0
    for _, each in ipairs(state.running) do
      if each.alive then count = count + 1 end
    end
    return count
  end

  local function give_up(why: string)
    if state.broken then return end
    state.broken = true
    local _, _ = log:complain("build: workers: " .. why ..
        "; building in this process (" .. variable .. "=1 turns them off)")
  end

  local function finish_workers()
    for _, each in ipairs(state.running) do
      local feed = each.handle.stdin_stream
      if feed ~= nil then
        local _, _ = feed:close()
      end
    end
    for _, each in ipairs(state.running) do
      local waited, _ = each.handle:wait(5000000000)
      if waited == nil then
        local _, _ = each.handle:stop()
      end
      local _, _ = each.handle:close()
    end
    state.running = {}
  end

  local function start(): boolean
    -- An empty or relative TMPDIR names no place to keep files: they would
    -- land at the root, or wherever the process later stands.
    local tmp = Env.get_or("TMPDIR", "")
    if tmp:sub(1, 1) ~= "/" then tmp = "/tmp" end
    local parent = tmp .. "/cosmic-workers-" .. sys.getuid()
    local parent_made, parent_trouble = private_dir(parent)
    if not parent_made then
      give_up(parent_trouble)
      return false
    end
    local made, why = Fs.scratch(parent)
    if made == nil then
      give_up(why)
      return false
    end
    state.scratch = made
    local _, env, fds = again({})
    -- Only here, so a build that starts no worker never loads the module.
    -- TODO: a boot still checks cosmic.child's closure, the relay and
    -- the sandbox among it, where this file is compiled, and that costs
    -- every boot about half a second whether or not it starts a worker: once a
    -- module can start a process without that closure, start workers
    -- with it.
    local child = require("cosmic.child")
    -- TODO: end a worker when its starter dies: one whose starter was killed
    -- finishes its job, and a hung one lives until the end of its own
    -- lifetime, which only the starter enforces. Waits on a binding for
    -- PR_SET_PDEATHSIG (and kqueue's equivalent on macOS) in cosmic.sys,
    -- which a worker's start would set.
    for _ = 1, most do
      local handle, trouble = child.start(spec.argv, {
        env = env, fds = fds, stdin = "stream", stdout = "stream", stderr = "capture",
        -- In the starter's own group, not one of its own, so a signal to
        -- the build's group ends its workers too.
        timeout_ns = lifetime_ns, process_group = false,
      })
      if handle == nil then
        give_up("cannot start a worker: " .. trouble)
        finish_workers()
        return false
      end
      local reader = assert(handle.stdout_stream)
      state.running[#state.running + 1] = { handle = handle, replies = Stream.lines(reader), alive = true }
    end
    state.started = true
    state.started_at = Clock.monotonic_ns()
    return true
  end

  local function ready(bytes: integer): boolean
    if state.broken or most < 2 then return false end
    if state.started then return alive() > 0 and bytes >= spec.phase_bytes end
    if bytes < spec.open_bytes then return false end
    return start()
  end

  local pool: worker.Pool = {
    warming = function(): integer
      if not state.started then return 0 end
      return math.max(0, state.started_at + spec.startup_ns - Clock.monotonic_ns())
    end,
    size = function(): integer
      if state.started then return alive() end
      return state.broken and 0 or most
    end,
    path = function(name: string): string | nil, string
      if state.scratch == nil then return nil, "no workers are running" end
      state.jobs_made = state.jobs_made + 1
      return state.scratch.path .. "/" .. name .. "-" .. state.jobs_made, ""
    end,
    -- TODO: give a phase a deadline: a hung worker holds the build, and
    -- the rebuild lock, until its lifetime ends. Waits on a read of a
    -- worker's reply that takes a timeout of its own, which cosmic.stream's
    -- readers lack, so the build could end the phase and do its work.
    run = function(phase: string, job: string, count: integer): {string}
      local answers: {string} = {}
      local serving: {Process} = {}
      for _, each in ipairs(state.running) do
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
      if state.scratch ~= nil then
        local _gone <close> = state.scratch
        state.scratch = nil
      end
      state.started = false
    end,
  }
end

return workers
