--- The sandbox a test's processes run in: what a test declares the
--- processes it starts need (`confine`, [`must_confine`]); the stand-in
--- for the process table's `spawn` that holds each process it starts to
--- that (`enter`); and what a sandboxed worker of this very
--- program is given and held to ([`worker_unveil`], [`forbid_running`],
--- `itself`), with the system's paths a sandbox gives
--- (`system_paths`) and where a path leads as one binds it
--- (`resolution`).

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- The raw process table, whose `spawn` [`cosmic.child`] starts every
--- child with: this module is handed it (core/store.c's `raw_modules`)
--- to confine each child a test starts, by standing in for that call,
--- and for the Landlock ruleset [`forbid_running`] puts up. Boot mode
--- falls back to requiring it by name, which only boot's own preload
--- answers.
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local process: raw_process
if type(extra) == "table" then
  process = extra as raw_process
else
  process = require("cosmic.internal.process")
end

--- The process table's questions of this host, as this module loads.
local sandbox_platform, may_map_ids, maps_id, own_proc = process.sandbox_platform,
  process.may_map_ids, process.maps_id, process.own_proc

--- The process table's own `spawn`, as this module loads -- before any
--- stand-in for it (see `enter`) is put in its place.
local own_spawn = process.spawn

local record confine
  --- What a test declares the processes it starts need, beyond the
  --- system's own files (see `confine`) and its own directory:
  --- the paths they read, and the ones they change too.
  record Confinement
    reads: {string}
    writes: {string}
  end

  --- What a call `call` made came to: whether it returned, and its
  --- first result, or what it raised.
  record Ran
    ok: boolean
    produced: any
    --- Why each start that failed for what its sandbox lacked failed
    --- ([`confine.unseen`]), once each, in order: what a failed test's
    --- report adds where its own message does not say it.
    unseen: {string}
  end

  --- The most paths a sandbox unveils, its reads and writes together.
  unveil_max: integer

  --- See below.
  system_paths: {string}

  --- See below.
  held_variable: string
  --- See below.
  unseen: function(path: string, use: Use): string | nil

  --- What a test reads or starts that a process may meet missing.
  enum Use
    "reads"
    "starts"
  end
end

--- The calls each question this module asks of the filesystem and the
--- environment makes, taken as it loads, ahead of any test that could
--- replace them on [`cosmic.sys`]'s shared table: none of this module's
--- questions is its test's to bend.
local record Calls
  getcwd: function(): string | nil, string, integer
  realpath: function(path: string): string | nil, string, integer
  lstat: function(path: string): sys.Stat | nil, string, integer
  stat: function(path: string): sys.Stat | nil, string, integer
  readdir: function(path: string): {string:sys.Kind} | nil, string, integer
  getenv: function(name: string): string | nil
  environ: function(): {string:string}
  access: function(path: string, mode: integer): boolean, string, integer
  open: function(path: string, flags: integer, mode?: integer): integer | nil, string, integer
  read: function(fd: integer, count: integer): string | nil, string, integer
  close: function(fd: integer): boolean, string, integer
end
local asked: Calls = {
  getcwd = sys.getcwd, realpath = sys.realpath, lstat = sys.lstat, stat = sys.stat,
  readdir = sys.readdir, getenv = sys.getenv, environ = sys.environ, access = sys.access,
  open = sys.open, read = sys.read, close = sys.close,
}

--- One running stand-in (see `enter`): the directories the running
--- test owns, its own directory first, and whether this process runs
--- in a sandbox every process it starts inherits -- `cosmic test`'s
--- sandboxed worker (build/test_sandbox.tl).
local record Entry
  own: {string}
  sandboxed: boolean
  --- What each start that failed for what the sandbox lacked said of
  --- it ([`confine.unseen`]), once each.
  unseen: {string}
end

--- Every running stand-in, innermost last: one wraps another when a
--- test runs one of its own ([`confine.call`]) inside the one running it.
local entered: {Entry} = {}

--- Whether this process runs in a sandbox, as a running stand-in says:
--- one a test runs of its own inside its sandboxed worker's knows no
--- sandbox, but the worker's does.
local function in_sandbox(): boolean
  for at = #entered, 1, -1 do
    if entered[at].sandboxed then return true end
  end
  return false
end

--- The system's programs and libraries and its configuration: what a
--- host program, or the dynamic loader that starts one, reads.
local system_paths: {string} = { "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32",
  "/etc" }

confine.system_paths = system_paths

--- The devices a program takes for granted, and /proc, where a program
--- finds itself (`/proc/self/exe`) and its descriptors (`/dev/fd`): all
--- a process of this program needs of the host's to start and run a
--- test that starts no host program. Traced, a worker of such a test
--- opens /dev/urandom (SQLite's unix VFS seeds its randomness there),
--- /dev/null (a child's "null" stream), /proc/self/exe and
--- /proc/thread-self/children, and nothing of /usr, /lib or /etc;
--- /dev/zero it does not open, but a program takes it for granted as it
--- does /dev/null; /dev/full is where a write fails with ENOSPC, for a
--- test of how a program meets a failed write, and macOS has none.
--- /proc alone does not enter a key: a sandboxed process's is a
--- procfs of its own pid namespace, holding its own processes and
--- nothing of the host's. The devices' every answer is the same, or none
--- a key could hold (/dev/urandom's), so the key holds them through the
--- host's identity alone.
-- TODO: keep a confined process from the host's state where the kernel
-- refuses it a procfs of its own and it has the host's /proc (a
-- container masking parts of it: core/syscalls.c's `place_proc`), which
-- it can read there without that entering the key: refused, as the
-- TODO there asks, once no container the tree is tested in masks /proc.
local runtime_paths: {string} = { "/dev/null", "/dev/zero", "/dev/full", "/dev/urandom", "/proc" }

--- What a confined process has without its test naming it, each where
--- this host has it (and, in a sandboxed worker, where the worker was
--- given it): the system's paths and the runtime's.
local system: {string} = {}
for _, path in ipairs(system_paths) do system[#system + 1] = path end
for _, path in ipairs(runtime_paths) do system[#system + 1] = path end

--- What the running test declared its processes need, or nil: see
--- [`confine.confine`].
local confinement: confine.Confinement | nil = nil

--- How the declaration in `confinement` is held: nil where a process
--- the kernel cannot confine starts unconfined, and otherwise what
--- names the call that asked for no fallback, for the failure a spawn
--- answers instead (see [`confine.must_confine`]).
local strict: string | nil = nil

--- What the library whose work is running declared its processes need,
--- or nil: see [`confine.declaring`].
local library: confine.Confinement | nil = nil

--- The variable that turns every `confine` into [`must_confine`].
local SANDBOX_MODE <const> = "COSMIC_SANDBOX"

--- Whether this process runs with every `confine` a [`must_confine`]:
--- `SANDBOX_MODE` set to "must". Unset or empty, it does not; any other
--- value raises, so a misspelt mode never passes for the default. Read
--- as this module loaded `getenv`, past what a test stands in for it:
--- it decides whether a test fails, never what it reads.
local function must_everywhere(): boolean
  local mode = asked.getenv(SANDBOX_MODE)
  if mode == nil or mode == "" then return false end
  if mode == "must" then return true end
  error(string.format("%s is %q: set it to \"must\", or leave it unset", SANDBOX_MODE, mode), 3)
end

--- The variable a sandboxed worker held by a Landlock ruleset is
--- started with ([`forbid_running`]), naming its module: every process it
--- starts inherits the hold, and, through [`this_program.environment`],
--- the variable, so a `cosmic test` one of them runs refuses to sandbox
--- its workers ([`build.test`]) as a spawn here refuses a root of its own
--- (`enter`), naming `nests`, rather than falling back to confining
--- nothing.
-- TODO: refuse a root of its own, naming `nests`, to a process a held
-- worker starts that unveils one itself -- a raw spawn in a program it
-- runs, which no stand-in wraps -- once core/process.h's spawn reads
-- this variable (C, and a boot): today such a spawn fails EPERM as the
-- kernel refuses its mounts, which a test that passes over a kernel
-- that cannot confine (test/coverage_children_test.tl's parent, say)
-- takes for one, and counts skipped (build.sandbox_skip) where the run
-- is not held to sandboxing. So too a `cosmic test` a held worker's process starts
-- with an environment that drops this variable: its probe of the
-- sandbox fails EPERM, and it runs its workers unsandboxed, saying only
-- that the host may be refusing a user namespace or holding it by a
-- ruleset ([`test_sandbox.refusal`]).
confine.held_variable = "COSMIC_TEST_HELD"

--- The module whose worker's Landlock ruleset holds this process
--- (`held_variable`), or nil where none does. Read as
--- [`must_everywhere`] reads its variable: it decides whether a test
--- fails, never what it reads.
local function held_by(): string | nil
  local module = asked.getenv(confine.held_variable)
  if module == nil or module == "" then return nil end
  return module
end

--- Why a process cannot start in a root of its own where the worker of
--- `module` is held by a Landlock ruleset: what the start fails with,
--- naming the declaration that lets it.
local function nests_refusal(program: string, module: string): string
  return string.format("%s cannot start in a root of its own: %s's worker is held by a " ..
      "Landlock ruleset, under which the kernel refuses every mount; declare nests = true " ..
      "in its Test.needs", program, module)
end

--- `wanted`, each relative path taken from the directory this process
--- is in.
local function absolute(wanted: confine.Confinement): confine.Confinement
  local here, _ = asked.getcwd()
  local function from_here(path: string): string
    if path:sub(1, 1) == "/" or here == nil then return path end
    return (here == "/" and "" or here) .. "/" .. path
  end
  local reads: {string} = {}
  local writes: {string} = {}
  for _, path in ipairs(wanted.reads or {}) do reads[#reads + 1] = from_here(path) end
  for _, path in ipairs(wanted.writes or {}) do writes[#writes + 1] = from_here(path) end
  return { reads = reads, writes = writes }
end

--- `confine`'s work, with `must` naming the call that asked for no
--- fallback, or nil.
local function declare(declared: confine.Confinement | nil, must: string | nil)
  if declared == nil then
    confinement, strict = nil, nil
    return
  end
  confinement, strict = absolute(declared), must
end

--- Declares what every process the calling test starts from here on
--- needs. Only a test of the sandbox itself, which nests one sandbox in
--- another, calls it: any other test declares what its processes read
--- in its module's [`Test.needs`], whose sandboxed worker holds them to it.
---
--- `declared.reads` is read-only and `declared.writes` may be changed,
--- beside `system` -- each of it the worker has: a sandboxed worker
--- whose module does not declare `system` has only the runtime's -- and
--- the test's own directories (`enter`'s `own`), which a process may
--- change too. The kernel holds each process to that: a root of its
--- own holding those paths and nothing else, and no network (the
--- process table's `Sandbox`, `unveil` and `offline`).
---
--- A process started with a sandbox of its own is not confined further.
--- Where the kernel cannot confine one, it starts as it would have. A
--- process given no directory to start in
--- starts in the test's own, since the one the test runs in, the tree's
--- root, is not its to read. A process has a /tmp of its own, and one
--- that inherits a TMPDIR it may not change has the test's own
--- directory for it.
---
--- Called at a test module's top level, it holds for each of its tests;
--- called in a test, for the rest of that test. A relative path is taken
--- from the directory this is called in. Nil ends the declaration: a
--- process started after it is not confined. With COSMIC_SANDBOX=must in
--- the environment, it is [`must_confine`].
function confine.confine(declared: confine.Confinement | nil)
  declare(declared, must_everywhere() and "confine (" .. SANDBOX_MODE .. "=must)" or nil)
end

--- `confine` with no fallback: every process the calling test starts
--- from here on runs with the whole of its sandbox -- the root of its
--- own holding only what was declared, and no network -- in force, or
--- does not start.
---
--- Where the kernel refuses a part (no user namespaces for this user, a
--- mount or pivot_root refused), or a process cannot be confined at all
--- (more paths than a sandbox unveils, a program beneath none of them),
--- the spawn fails: `nil`, a message naming the program, the part of the
--- sandbox that could not be applied and why, errno's name included, and
--- the errno. The failure fails the test too, whatever it made of the
--- spawn's answer, so a test cannot pass by passing over a process it
--- never ran. So does every running stand-in's failure (see `enter`),
--- one inside another included.
---
--- A process started with a sandbox of its own that unveils and takes
--- the network is held to that; one whose own sandbox does not -- a
--- pledge or a ruleset alone -- does not start. Nor does one started,
--- while the declaration holds, through a spawn taken while an earlier
--- stand-in ran, which no confinement would hold.
---
--- It covers only a test that declares: a process started with no
--- declaration in force, after `confine(nil)` or in a test that never
--- confines, has the sandboxed worker's own sandbox, or, where the
--- worker runs unsandboxed, runs unconfined. Only the sandbox's own tests
--- confine: every other test's processes are the worker's to hold,
--- which its module's [`Test.needs`] declares for them.
function confine.must_confine(declared: confine.Confinement | nil)
  must_everywhere() -- a misspelt mode raises here too
  declare(declared, "must_confine")
end

--- Calls `fn`, the work of a library that starts processes whose every
--- input it can name -- build/c/init.tl's compilers: their toolchain and
--- what they compile. Each process it starts with no sandbox of its own
--- is held to `declared`: `declared.reads`, read-only, and
--- `declared.writes`, which it may change, beside `system` and the
--- running test's own directories, as `confine` holds a test's.
---
--- Where this process runs in a sandbox -- a sandboxed worker's
--- (`enter`'s `sandboxed`), or one a Landlock ruleset holds -- the process
--- inherits that and is held by it alone, as one started undeclared is:
--- a root of its own would nest in the worker's, which a ruleset
--- refuses. A test's own `confine` holds the process rather than this.
---
--- Where no stand-in runs (see `enter`) -- no test, `cosmic fix` --
--- nothing holds it. Where the kernel cannot confine one, it starts
--- unconfined, and with COSMIC_SANDBOX=must it does not
--- start. An unsandboxed run, keyed by what its tests declare (as
--- macOS runs, where nothing confines), stands on that key all the same,
--- which holds none of what the process read: that gap is the run's
--- own, and a Linux leg's sandbox closes it for the same test.
---
--- Relative paths are taken from the directory this is called in.
function confine.declaring(declared: confine.Confinement, fn: function())
  local before = library
  library = absolute(declared)
  local ok, trouble: boolean, any = pcall(fn)
  library = before
  if not ok then error(trouble, 0) end
end

--- What a confined process of this very program needs to start, for a
--- test's `confine`: the program, and the core its launcher runs it on
--- where it is a portable artifact, with the stamp beside it in the
--- cache that says it was verified, where there is one: without it,
--- the launcher and the core hash the whole core again at every start
--- (core/startup.c's `stamp_path`).
function confine.itself(): {string}
  local program: {string} = {}
  local executable, _ = Proc.executable()
  if executable ~= nil then program[#program + 1] = executable end
  local launched, _ = Proc.relaunch()
  if launched ~= nil then
    local core = launched.argv[1]
    program[#program + 1] = core
    local directory, name = core:match("^(.*)/(core%-[^/]*)$")
    if directory ~= nil then
      local stamp = directory .. "/.verified-" .. name
      local there, _ = asked.lstat(stamp)
      if there ~= nil and there.kind == "file" then program[#program + 1] = stamp end
    end
  end
  return program
end

--- Whether this platform has a sandbox at all (core/process.h's
--- `sandbox_platform`): Linux has, whatever this host then refuses of
--- it; another platform has none to give or to check.
function confine.sandbox_platform(): boolean
  local ok, _, _ = sandbox_platform()
  return ok
end

--- Whether this process may map another user's ids into a sandbox's
--- user namespace from outside, as `spawn`'s `user` does: it is root,
--- holding CAP_SETUID, CAP_SETGID and CAP_SETFCAP in effect
--- (core/process.h's `may_map_ids`).
function confine.may_map_ids(): boolean
  local ok, _, _ = may_map_ids()
  return ok
end

--- Whether this process's user namespace maps `id`, as a user and as a
--- group (core/process.h's `maps_id`).
function confine.maps_id(id: integer): boolean
  local ok, _, _ = maps_id(id)
  return ok
end

--- Whether this host gives a sandboxed process a procfs of its own pid
--- namespace (core/process.h's `unveil`), as the kernel answers a
--- child started to mount one (core/process.h's `own_proc`). A user
--- namespace may mount a procfs only where one is wholly visible, which
--- a container's masked /proc paths are not; where one is not, a
--- sandboxed process has the host's /proc, read-only.
function confine.own_proc_given(): boolean
  local ok, _, _ = own_proc()
  return ok
end

--- What a sandboxed worker of this very program -- `cosmic test`'s,
--- started as [`Proc.relaunch`] says, in `cwd` -- has to be given to start
--- and run a test of the tree at `tree`, beside what the test itself
--- reads: to read, `runtime_paths` (/proc and /dev/null among them),
--- and with `with_system`, for a module that declares `system`,
--- `system_paths` too, each where this host has it; the core and the
--- stamp that spares hashing it again (`itself`), and with
--- `with_program`, for a module that declares `tool`, the program
--- itself -- the artifact, which carries every module of the tool, so a
--- worker whose test does not declare `tool` has no name to read it by
--- (its relaunch hands it the artifact as a descriptor, which the core
--- refuses to its Lua: core/check.h's `cosmic_checkfd`); the
--- tree's store (o/cosmic.db, which a worker attaches), and `cwd`,
--- where given; to change, `scratch`, its temporary directory. Each is
--- there as it is given, so each may be handed to [`process.spawn`]'s
--- `unveil` whole. The worker can confine what its test starts in
--- turn, having a /proc of its own -- but where the kernel refuses it
--- one and its /proc is the host's, read-only. `cosmic test`'s sandbox
--- (build/test_sandbox.tl) gives a worker these, and what its test's
--- module reads.
function confine.worker_unveil(tree: string, cwd: string | nil, scratch: string,
                               with_system?: boolean, with_program?: boolean): raw_process.Unveil
  local reads: {string} = {}
  local seen: {string:boolean} = {}
  local stat = asked.stat
  local function add(path: string)
    if seen[path] then return end
    local there, _ = stat(path)
    if there == nil then return end
    seen[path] = true
    reads[#reads + 1] = path
  end
  if with_system then
    for _, path in ipairs(system_paths) do add(path) end
  end
  for _, path in ipairs(runtime_paths) do add(path) end
  -- The program is withheld only where it is not also what runs: a
  -- host program (its core with the database appended, which the
  -- kernel runs itself) is its own core, which every worker needs.
  -- TODO: keep a worker whose test does not declare `tool` from reading
  -- a host program's carried database by its name too. Its core is
  -- that same file, which the worker must run, and Landlock checks an
  -- exec when it opens the file, execveat's AT_EMPTY_PATH included; so
  -- the fix takes the worker exec'd before its ruleset holds it, and
  -- host startup taking an inherited descriptor on itself rather than
  -- opening /proc/self/exe again (core/executable.c's
  -- `cosmic_executable_fd`). Today such a worker, as in
  -- build/sandboxed_verdicts_test.tl's tool project, reads the program.
  local program, _ = Proc.executable()
  local withheld = ""
  if not with_program and program ~= nil then
    local launched, _ = Proc.relaunch()
    local core = launched ~= nil and launched.argv[1] or program
    local a, _ = asked.stat(program)
    local b, _ = asked.stat(core)
    if a == nil or b == nil or a.dev ~= b.dev or a.ino ~= b.ino then withheld = program end
  end
  for _, path in ipairs(confine.itself()) do
    if path ~= withheld then add(path) end
  end
  add((tree == "/" and "" or tree) .. "/o/cosmic.db")
  if cwd ~= nil then add(cwd) end
  return { reads = reads, writes = { scratch } }
end

--- Holds this process, and every process it starts, to running
--- anything but `programs` -- this very program (`itself`), for a
--- sandboxed worker whose test does not declare `tool` -- through a
--- Landlock ruleset that handles running a file alone
--- (core/process.h's `landlock_restrict_execute`): every entry of
--- every directory above one of them, down from /, may be run beneath
--- it but for the ones on the way to them, and those are walked the same
--- way, so each program alone is left out -- by where it resolves, so a
--- link to it, /proc/self/exe among them, runs nothing either. A link
--- on the way that leads above one of them is left out too. For good:
--- nothing lets it off, and it may not confine a process of its own in a
--- root of its own after: the kernel refuses every mount under a
--- Landlock domain, and a root of its own is made of mounts. With no
--- `programs`, it forbids running nothing, and holds the process only
--- to that: a sandboxed worker whose module declares `tool` but not
--- `nests` ([`cosmic.test`]). False and why where there is no Landlock.
-- TODO: replace this with [`Sandbox.restrict`] ([`cosmic.sandbox`]), which
-- holds the running process to a policy's grants, promises and limits for
-- good, and hold the worker by the policy the test declares, once the
-- harness moves to `Test.policy` (the design's test phase): this holds
-- a worker by a ruleset of its own making, which only the harness uses.
-- TODO: let build/confine_tool_test.tl declare `nests` alone,
-- dropping the `tool` it declares only to start what it confines,
-- once a confined process is given only what its worker has, `confine`
-- narrowing its worker's inputs rather than adding to them: today
-- `itself` is given to the process it confines, and a worker without
-- the program fails the start EACCES.
-- TODO: hold a copy of the program as the program -- one a test copies
-- or links elsewhere and runs, or a core it loads some other way than
-- by exec -- once a ruleset can name a file by its contents: today a
-- test that copies the program into its own directory runs it
-- undeclared.
function confine.forbid_running(programs: {string}): boolean, string
  local now = asked
  local held: {string:boolean} = {}
  local above: {string:boolean} = {}
  for _, program in ipairs(programs) do
    local real, _ = now.realpath(program)
    for _, path in ipairs({ program, real or program }) do
      held[path] = true
      local dir = path:match("^(.*)/[^/]*$")
      while dir ~= nil and dir ~= "" do
        above[dir] = true
        dir = dir:match("^(.*)/[^/]*$")
      end
    end
  end
  local allowed: {string} = {}
  local function walk(dir: string)
    -- A directory above a program that cannot be listed is run nothing
    -- beneath: the safe way to be wrong.
    local listed, _ = now.readdir(dir == "" and "/" or dir)
    if listed == nil then return end
    local names: {string} = {}
    for name in pairs(listed) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      local path = dir .. "/" .. name
      local real, _ = now.realpath(path)
      if held[path] or (real ~= nil and held[real]) then
        -- The program, or a link to it.
      elseif above[path] then
        walk(path)
      elseif real ~= nil and above[real] then
        -- A link to a directory above it.
      else
        allowed[#allowed + 1] = path
      end
    end
  end
  walk("")
  local held_now, trouble = process.landlock_restrict_execute(allowed)
  if not held_now then return false, trouble end
  return true, ""
end

--- The running test's own directory, the innermost running stand-in's
--- (see `enter`), or nil: where a process it starts makes its
--- temporary files (build.this_program's `environment`).
function confine.test_directory(): string | nil
  for at = #entered, 1, -1 do
    local own = entered[at].own[1]
    if own ~= nil then return own end
  end
  return nil
end

--- What an absolute path resolves to, links and all, when it is read:
--- `realpath` of the path, or, when it is not there (a stat or an open
--- of a missing file is a read too), of its nearest existing ancestor
--- with the missing names after it as written, "." and ".." included:
--- the first of them is missing, so nothing after it is reached, and
--- the answer is that ancestor's. Each run of slashes is one, and a
--- name the path ends in with "/" after it is sought in its directory
--- when the whole is not there, as a file is. "" for a relative path,
--- or one not even "/" of which resolves. Nothing is remembered between
--- calls, since a link can be retargeted between two reads. This is
--- where the sandbox binds a path (build/test_sandbox.tl).
function confine.resolution(path: string): string
  if path:sub(1, 1) ~= "/" then return "" end
  local realpath = asked.realpath
  -- The length of `path`'s first `n` bytes with the slashes they end
  -- in taken off.
  local function unslashed(n: integer): integer
    while n > 0 and path:byte(n) == 47 do n = n - 1 end
    return n
  end
  local finish = #path
  local real: string = nil
  while true do
    local found, _ = realpath(path:sub(1, finish))
    if found ~= nil then
      real = found
      break
    end
    local trimmed = unslashed(finish)
    if trimmed == 0 then return "" end
    local name = trimmed
    while name > 0 and path:byte(name) ~= 47 do name = name - 1 end
    finish = unslashed(name)
    if finish == 0 then finish = 1 end
  end
  local names: {string} = {}
  for name in path:sub(finish + 1):gmatch("[^/]+") do names[#names + 1] = name end
  if #names == 0 then return real end
  return (real == "/" and "" or real) .. "/" .. table.concat(names, "/")
end

--- Whether this run is held to sandboxing: `COSMIC_TEST_SANDBOX=1`, as
--- CI's suites set it, `COSMIC_SANDBOX=must`, or CI's
--- `COSMIC_CI_REQUIRE_SANDBOX=1`. A test whose assertion is about a
--- sandbox the host refuses it -- the sandboxed workers of a `cosmic
--- test` it starts, nested in its own sandbox, which the kernel lets root
--- nest only two deep (core/syscalls.c's `map_ids`), where a root
--- runner cannot run its workers as a user of their own
--- (build.test_sandbox's `runs_as`) -- says it is
--- skipped ([`Test.skip`]) and returns unchecked, and `cosmic test` fails
--- a skipped test where this answers true, so a run held to sandboxing
--- proves the host checked it. A sandboxed test that reads it declares
--- `COSMIC_CI_REQUIRE_SANDBOX` (the other two are pinned).
function confine.held_to_sandbox(): boolean
  return sys.getenv("COSMIC_TEST_SANDBOX") == "1" or sys.getenv(SANDBOX_MODE) == "must" or
    sys.getenv("COSMIC_CI_REQUIRE_SANDBOX") == "1"
end

--- The errnos a confined spawn fails with where the kernel cannot
--- confine a process at all: no user namespaces, or none for this user.
--- Under [`must_confine`] none of them falls back: the spawn fails.
-- TODO: fall back only on a failure of the sandbox's own setup, and name
-- that step in [`must_confine`]'s failure (the user namespace, the root,
-- the network namespace), once [`process.spawn`] says which step failed
-- (the status pipe carrying it beside the errno): an EACCES or EINVAL
-- from exec, or an unreadable path declared, falls back unconfined too,
-- and the test runs uncached where it should fail.
-- TODO: treat the EROFS a process confined inside a sandbox fails with
-- where that sandbox's /proc is the host's (a container masking parts of
-- its /proc, without --security-opt systempaths=unconfined) -- its
-- uid_map write, on a /proc read-only whole -- as a sandbox the kernel
-- cannot give, falling back or, under [`must_confine`], refused, once
-- [`process.spawn`] says which step failed (the TODO above): today the
-- spawn fails with it outright, so a test that passes over a failed
-- spawn passes having run nothing, even in must mode, as
-- build/must_confine_test.tl's nested case does there. Where the kernel
-- gives a sandbox a /proc of its own, as a host does, it confines one
-- of its own.
local unconfinable: {integer:boolean} = {
  [sys.ENOSYS] = true, [sys.EPERM] = true, [sys.EACCES] = true, [sys.EINVAL] = true,
  [sys.ENOSPC] = true,
}

--- A list of strings as the core reads one, raw: its entries from 1 on,
--- by rawget, to the first nil; nil when it holds anything else, which
--- the core refuses.
local function raw_strings(list: any): {string} | nil
  local out: {string} = {}
  if list == nil then return out end
  if not list is {any:any} then return nil end
  local at = 1
  while true do
    local value = rawget(list, at)
    if value == nil then return out end
    if not value is string then return nil end
    out[#out + 1] = value
    at = at + 1
  end
end

--- The fields of a sandbox and of its `unveil` that [`plain_sandbox`]
--- carries: one with any other (a policy's: grants, promises, strict) is
--- the core's to read as it stands, and no copy of it is made.
local plain_fields <const>: {string:boolean} = {
  ruleset = true, unveil = true, noexec_scratch = true, offline = true, user = true,
  group = true, pledge = true,
}
local plain_unveil_fields <const>: {string:boolean} = { reads = true, writes = true, at = true }

--- `sandbox` as the core reads it -- raw, with no metamethod answering
--- for a field -- in a plain table of its own; nil when a field holds
--- what the core would refuse, for the core to refuse, or one this does
--- not copy, which the core is given as it is.
local function plain_sandbox(sandbox: raw_process.Sandbox): raw_process.Sandbox | nil
  local raw = sandbox as {string:any}
  for key, _ in next, raw do
    if not key is string or not plain_fields[key] then return nil end
  end
  local listed = rawget(raw, "unveil")
  if listed is {any:any} then
    for key, _ in next, listed do
      if not key is string or not plain_unveil_fields[key] then return nil end
    end
  end
  local plain: raw_process.Sandbox = {}
  local ruleset = rawget(raw, "ruleset")
  if ruleset is integer then plain.ruleset = ruleset elseif ruleset ~= nil then return nil end
  local unveil = rawget(raw, "unveil")
  if unveil is {any:any} then
    local reads, writes = raw_strings(rawget(unveil, "reads")), raw_strings(rawget(unveil, "writes"))
    if reads == nil or writes == nil then return nil end
    plain.unveil = { reads = reads, writes = writes }
    local at = rawget(unveil, "at")
    if at is {any:any} then
      local names: {string:string} = {}
      for given, name in next, at do
        if not given is string or not name is string then return nil end
        names[given] = name
      end
      plain.unveil.at = names
    elseif at ~= nil then
      return nil
    end
  elseif unveil ~= nil then
    return nil
  end
  local noexec = rawget(raw, "noexec_scratch")
  if noexec is boolean then plain.noexec_scratch = noexec elseif noexec ~= nil then return nil end
  plain.offline = rawget(raw, "offline") == true
  local user, group = rawget(raw, "user"), rawget(raw, "group")
  if user is integer then plain.user = user elseif user ~= nil then return nil end
  if group is integer then plain.group = group elseif group ~= nil then return nil end
  local pledge = rawget(raw, "pledge")
  if pledge ~= nil then
    local promises = raw_strings(pledge)
    if promises == nil then return nil end
    plain.pledge = promises
  end
  return plain
end

--- The most paths a sandbox unveils (core/process.h's UNVEIL_MAX).
local UNVEIL_MAX <const> = process.UNVEIL_MAX
confine.unveil_max = UNVEIL_MAX

--- Where the absolute `path` leads, with no link or `..` left in it:
--- its longest leading part that is there, resolved, then the rest as
--- named, since a directory a process is to make need not be there yet.
--- Nil for a relative path, or one no part of which resolves.
local function led_to(path: string): string | nil
  if path:sub(1, 1) ~= "/" then return nil end
  local realpath = asked.realpath
  local head, rest = path:gsub("/+$", ""), ""
  while head ~= "" do
    local real, _ = realpath(head)
    if real ~= nil then
      if rest == "" then return real end
      return (real == "/" and "" or real) .. "/" .. rest
    end
    local parent, last = head:match("^(.*)/([^/]+)$")
    if parent == nil or last == ".." then return nil end
    rest = rest == "" and last or last .. "/" .. rest
    head = parent
  end
  return nil
end

--- Why a process cannot be confined: the reason, and the errno that
--- stands for it.
local record Unfit
  why: string
  errno: integer
end

--- Why a process cannot run confined to `reads` and `writes`, or nil
--- when it can: too many of them, or its program beneath none of them
--- -- where the system's own shell lives elsewhere (/nix/store), it
--- starts unconfined, or under [`must_confine`] not at all.
local function unfit_for(program: string, reads: {string}, writes: {string}): Unfit | nil
  if #reads + #writes > UNVEIL_MAX then
    return { why = string.format("%d paths, more than the %d a sandbox unveils",
      #reads + #writes, UNVEIL_MAX), errno = sys.EINVAL }
  end
  local realpath = asked.realpath
  local real, _ = realpath(program)
  if real == nil then return nil end -- its own failure to report
  for _, list in ipairs({ reads, writes }) do
    for _, given in ipairs(list) do
      local where, _ = realpath(given)
      if where ~= nil and Fs.within(real, where) then return nil end
    end
  end
  return { why = "the program, at " .. real .. ", is beneath none of the paths given",
    errno = sys.ENOENT }
end

--- Whether exec could run `program`, as a spawn given a sandbox names
--- it -- a relative one from this process's working directory: a file
--- this process may execute (`access`, its X_OK). One that is not fails
--- at exec, sandbox or none.
-- TODO: take a relative program from the directory the child starts in,
-- as exec does for a spawn given no sandbox, once core/syscalls.c's
-- spawn makes it absolute from there for a sandboxed one too: today it
-- does from this process's, so `Child.run({ "script" }, { cwd = dir })`
-- runs dir/script unconfined but, confined, this process's ./script.
local function runnable(program: string): boolean
  local st, _ = asked.stat(program)
  if st == nil or st.kind ~= "file" then return false end
  local may, _ = asked.access(program, sys.X_OK)
  return may
end

--- Whether `top`, a first part of a path, is one of the system's own
--- paths (`system_paths`).
local function system_path(top: string): boolean
  for _, given in ipairs(system_paths) do
    if given == top then return true end
  end
  return false
end

--- What a test declares to be given `top`, the first part of a path it
--- `use`s, for what [`confine.unseen`] says.
local function remedy(top: string, use: confine.Use): string
  if system_path(top) and use == "starts" then
    return "a test that starts a host program declares Test.needs { system = true } " ..
      "(see cosmic docs cosmic.test)"
  elseif system_path(top) then
    return "a test that reads the system's own files declares Test.needs " ..
      "{ system = true }, or names the few it reads in `host` (see cosmic docs cosmic.test)"
  end
  return "a test names each host file it starts or reads in Test.needs " ..
    "{ host = { ... } } (see cosmic docs cosmic.test)"
end

--- Why a process in a sandboxed worker's sandbox (build/test_sandbox.tl)
--- found nothing at the absolute `path` it `use`s, where the sandbox is
--- why: the sandbox's root holds only what the worker was given, so the
--- path's first part missing there is the sandbox's doing. One of the
--- system's own paths is given with /usr, which every Linux host has, so
--- with /usr there it is the host that lacks it. A start meets the same
--- in the `#!` interpreter of a script that is there. Nil where the path
--- is relative or its first part is there: what is missing is then the
--- test's own to report. Only a caller in such a sandbox asks: elsewhere
--- a first part missing is the host's own.
-- TODO: say the same of a program's ELF interpreter (its PT_INTERP,
-- /lib64/ld-linux-x86-64.so.2), which a host program declared in `host`
-- without `system` fails to start without, ENOENT: today the start says
-- only that.
-- TODO: say the same of a bare name (`Child.run({ "sh" })`), and of
-- Proc.find's finding nothing on PATH, where the sandbox has none of
-- the system's programs, once cosmic.child hears from the stand-in
-- before it adds its own hint: today a sandboxed start of "sh" says
-- Proc.find("sh") answers where a shell would find it, which there it
-- does not.
local function unseen(path: string, use: confine.Use): string | nil
  local first = path:match("^/+([^/]+)")
  if first == nil then return nil end
  local top = "/" .. first
  local there, _ = asked.lstat(top)
  if there == nil then
    local usr, _ = asked.lstat("/usr")
    if system_path(top) and usr ~= nil then return nil end
    return path .. " is not in this test's sandbox, which has nothing of " .. top .. ": " ..
      remedy(top, use)
  end
  if use ~= "starts" then return nil end
  -- Only a regular file is read for its `#!`: a FIFO there would block.
  local st, _ = asked.stat(path)
  if st == nil or st.kind ~= "file" then return nil end
  local fd, _ = asked.open(path, sys.O_RDONLY | sys.O_NONBLOCK)
  if fd == nil then return nil end
  local head, _ = asked.read(fd, 256)
  local _, _ = asked.close(fd)
  local interpreter = head ~= nil and head:match("^#!%s*(/[^%s]+)") or nil
  if interpreter == nil or interpreter == path then return nil end
  local why = unseen(interpreter, "starts")
  if why == nil then return nil end
  return path .. " is a script " .. interpreter .. " runs, and " .. why
end
confine.unseen = unseen

--- The first spawn [`must_confine`] refused while each running stand-in
--- ran, by its entry: which fails that stand-in's call, whatever the
--- test made of the spawn's answer.
local refusals: {Entry:string} = {}

--- Refuses a spawn `must` holds to its sandbox: `program` could not
--- start with `part` of it applied, for `why` (`errno`). Every running
--- stand-in hears it. Answers the message the spawn fails with.
local function refuse(must: string, program: string, part: string, why: string,
                      errno: integer): string
  local name = sys.errno_name(errno) or ("errno " .. tostring(errno))
  local message = string.format(
    "%s: %s could not start confined: %s could not be applied: %s (%s)",
    must, program, part, why, name)
  for _, each in ipairs(entered) do
    if refusals[each] == nil then refusals[each] = message end
  end
  return message
end

--- Refuses a start of `program` in a root of its own -- a sandbox that
--- unveils, its own or `confine`'s -- where the worker of `module` is
--- held by a Landlock ruleset ([`held_by`]), which would refuse its
--- mounts: not tried, so it never falls back to running unconfined.
--- Every running stand-in hears it, which fails its test whatever the
--- test made of the answer. Answers the message the spawn fails with.
local function refuse_nesting(program: string, module: string): string
  local message = nests_refusal(program, module)
  for _, each in ipairs(entered) do
    if refusals[each] == nil then refusals[each] = message end
  end
  return message
end

--- What ends a stand-in (`enter`).
local type Leave = function(): string | nil

--- Stands in for the process table's `spawn` until the function this
--- answers is called, which puts back what it stood in for and answers
--- the first spawn [`must_confine`] refused meanwhile, or nil. `own` holds
--- the directories the running test owns, which a confined process may
--- change: its own directory first, where a process it starts makes its
--- temporary files ([`confine.test_directory`]). `sandboxed` says this
--- process runs in a sandbox every process it starts inherits -- a
--- sandboxed worker's (build/test_sandbox.tl) -- which holds a process
--- a library's work starts (`declaring`) in its place.
---
--- A process the test starts is confined ([`confine.confine`]) or held
--- by what its own sandbox gives it, which the stand-in decides; one
--- started past it, through a reference taken before it stood in, is
--- not. A reference to the stand-in taken while it stood in starts a
--- process as the process table's own does, once it no longer stands
--- in -- or, under [`must_confine`], none.
---
--- Beside that function it answers a list that the stand-in fills, as
--- each start that found nothing for what a sandboxed worker's sandbox
--- left out fails, with why ([`confine.unseen`]).
local function enter(own?: {string}, sandboxed?: boolean): Leave, {string}
  -- The call the stand-in wraps: what `spawn` was as it began.
  local spawn = process.spawn
  local ended = false
  local owned: {string} = {}
  for i, directory in ipairs(own or {}) do owned[i] = directory end
  local entry: Entry = { own = owned, sandboxed = sandboxed == true, unseen = {} }
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                           cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                           stderr: integer | nil, process_group: boolean,
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox,
                           credentials?: raw_process.Credentials):
      integer | nil, string, integer
    if ended then
      -- A reference to a stand-in that no longer stands in starts a
      -- process no confinement holds: under [`must_confine`], none.
      if strict ~= nil and confinement ~= nil then
        return nil, refuse(strict, path, "unveil and offline",
          "started through a spawn taken while an earlier stand-in ran", sys.EINVAL), sys.EINVAL
      end
      return own_spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group,
        fds, sandbox, credentials)
    end
    -- A sandbox of its own that unveils and takes the network holds a
    -- process as a confinement does. It is read as the core reads it,
    -- raw, and a plain copy is what the core is given, so what is
    -- judged of it is what holds the process.
    local plain = sandbox ~= nil and plain_sandbox(sandbox) or nil
    -- A root of its own, which a worker held by a Landlock ruleset
    -- cannot make: refused outright, naming `nests`.
    local holder = held_by()
    if holder ~= nil and ((plain ~= nil and plain.unveil ~= nil) or
        (sandbox == nil and confinement ~= nil)) then
      return nil, refuse_nesting(path, holder), sys.EPERM
    end
    local must = confinement ~= nil and strict or nil
    if plain ~= nil and plain.unveil ~= nil and plain.offline == true then
      local pid, trouble, errno = spawn(path, argv, environment, cwd, stdin, stdout, stderr,
        process_group, fds, plain, credentials)
      if pid == nil and unconfinable[errno] and must ~= nil and runnable(path) then
        return nil, refuse(must, path, "its own sandbox's unveil and offline", trouble, errno),
          errno
      end
      return pid, trouble, errno
    end
    -- A sandbox of its own that does not both unveil and take the
    -- network -- a pledge or a ruleset alone -- leaves the process
    -- reading what its test did not declare: under [`must_confine`] it
    -- does not start, rather than be held to a sandbox it was not given.
    -- One the core would refuse raises there.
    if plain ~= nil and must ~= nil then
      return nil, refuse(must, path, "unveil and offline",
        "a sandbox of its own that does not unveil and take the network, which " ..
          "must_confine does not add to", sys.EINVAL), sys.EINVAL
    end
    -- One a library's work starts (`declaring`), where no confinement
    -- of the test's holds it: where this process runs in a sandbox, by
    -- that alone, started as it is, with no sandbox nested in it -- and
    -- elsewhere by what the library declared, as a test's own
    -- confinement holds one, but where a ruleset holds this process:
    -- that one starts as one declared by nothing does.
    local declared = confinement
    local declared_strict = strict
    if sandbox == nil and declared == nil and library ~= nil and not in_sandbox() and
        holder == nil then
      declared = library
      declared_strict = must_everywhere() and "confine (" .. SANDBOX_MODE .. "=must)" or nil
    end
    if sandbox == nil and declared ~= nil then
      local reads: {string} = {}
      for _, given in ipairs(system) do
        local there, _ = asked.stat(given)
        if there ~= nil then reads[#reads + 1] = given end
      end
      for _, given in ipairs(declared.reads) do reads[#reads + 1] = given end
      local writes: {string} = {}
      for _, given in ipairs(owned) do
        local there, _ = asked.stat(given)
        if there ~= nil then writes[#writes + 1] = given end
      end
      for _, given in ipairs(declared.writes) do
        -- One the test owns is there already.
        local mine = false
        for _, directory in ipairs(owned) do
          if Fs.within(given, directory) then mine = true end
        end
        if not mine then writes[#writes + 1] = given end
      end
      -- The directory a test runs in is the tree's root, which a confined
      -- process does not have: one given no directory starts in the
      -- test's own, confined or not, so it runs the same either way.
      local start_in = cwd
      if start_in == nil then start_in = writes[1] or "/" end
      local unfit = unfit_for(path, reads, writes)
      if unfit ~= nil and declared_strict ~= nil then
        return nil, refuse(declared_strict, path, "unveil", unfit.why, unfit.errno), unfit.errno
      end
      if unfit == nil then
        -- A program takes a directory it can make temporary files in for
        -- granted, as it does /dev/null. Without a TMPDIR it has a /tmp
        -- of its own; one that inherits a TMPDIR it may not change --
        -- the host's, rather than one its test chose -- is given the
        -- test's own directory for it.
        local given_environment = environment
        local inherited = asked.getenv("TMPDIR")
        local temporary = inherited
        if environment ~= nil then temporary = environment.TMPDIR end
        local replace = temporary ~= nil and temporary == inherited
        for _, given in ipairs(writes) do
          if replace and Fs.within(temporary, given) then replace = false end
        end
        if replace and writes[1] ~= nil then
          given_environment = {}
          for name, value in pairs(environment or asked.environ()) do
            given_environment[name] = value
          end
          given_environment.TMPDIR = writes[1]
        end
        -- A portable program's launcher looks for its core in the cache
        -- COSMIC_PORTABLE_CACHE names, and makes the cache there when it
        -- is not. The root a confined process has holds each path it was
        -- given at the name that path resolves to, so a cache named
        -- through a link above it -- under a test's own directory, which
        -- is one -- is not there, and the launcher, which cannot make it
        -- on that read-only root, ends. So the cache is named by where it
        -- leads: the same directory, under which the core this program
        -- runs on (`itself`) is bound, or which the launcher makes.
        -- TODO: give a confined process each link on a path it was given
        -- as the host has it (core/syscalls.c's unveil links a name only
        -- at its last part, where the launcher refuses a link for its
        -- cache), and declare in `itself` the cache a launcher finds by
        -- default, from XDG_CACHE_HOME or HOME: a default cache reached
        -- through a link is still not there.
        -- TODO: drop this renaming (and [`led_to`]) once core/syscalls.c's
        -- unveil gives a confined process each link on a path as the
        -- host has it (the TODO above): only the sandbox's own tests
        -- confine now, but one of them run where COSMIC_PORTABLE_CACHE
        -- is named through a link still needs it.
        local cache = (given_environment or asked.environ()).COSMIC_PORTABLE_CACHE
        local leads = cache ~= nil and led_to(cache) or nil
        if leads ~= nil and leads ~= cache then
          local renamed: {string:string} = {}
          for name, value in pairs(given_environment or asked.environ()) do
            renamed[name] = value
          end
          renamed.COSMIC_PORTABLE_CACHE = leads
          given_environment = renamed
        end
        local pid, trouble, errno = spawn(path, argv, given_environment, start_in, stdin, stdout,
          stderr, process_group, fds, { unveil = { reads = reads, writes = writes },
            offline = true }, credentials)
        if pid ~= nil or not unconfinable[errno] then
          return pid, trouble, errno
        end
        if declared_strict ~= nil then
          -- Nothing ran, and nothing runs in its place. A program exec
          -- could not have run unconfined either failed there, not in
          -- the sandbox: its failure is its own to answer.
          if not runnable(path) then return pid, trouble, errno end
          return nil, refuse(declared_strict, path, "unveil and offline", trouble, errno), errno
        end
      end
      cwd = start_in
    end
    -- Declared by nothing, or where the kernel cannot confine it: as the
    -- test asked, a sandboxed worker's process with this one's sandbox
    -- and no more.
    local pid, trouble, errno = spawn(path, argv, environment, cwd, stdin, stdout, stderr,
      process_group, fds, sandbox, credentials)
    if pid == nil and errno == sys.ENOENT and sandbox == nil and in_sandbox() then
      -- Found nothing for what the worker's sandbox left out: the start
      -- fails as it would have, saying so, and every running stand-in
      -- hears it for a report its test's own message leaves it out of.
      local why = unseen(path, "starts")
      if why ~= nil then
        trouble = trouble .. ": " .. why
        for _, each in ipairs(entered) do
          local heard = false
          for _, said in ipairs(each.unseen) do
            if said == why then heard = true end
          end
          if not heard then each.unseen[#each.unseen + 1] = why end
        end
      end
    end
    return pid, trouble, errno
  end
  entered[#entered + 1] = entry
  return function(): string | nil
    ended = true
    process.spawn = spawn
    for at = #entered, 1, -1 do
      if entered[at] == entry then
        table.remove(entered, at)
        break
      end
    end
    local refused = refusals[entry]
    refusals[entry] = nil
    return refused
  end, entry.unseen
end

--- Calls `fn` with `argument` under a stand-in of its own (`enter`,
--- given `own` and `sandboxed`), which it puts back whether `fn`
--- returned or raised: whether it returned, and its first result or
--- what it raised ([`Ran`]). A call that had a spawn [`must_confine`] refused is one
--- that failed, with that refusal as what it raised -- before what it
--- raised itself, where it raised too. What a test worker runs its
--- module's load and its test under (build.test_worker), and a test of
--- the sandbox its own nested ones.
function confine.call(fn: function(any...): (any...), argument?: any, own?: {string},
                      sandboxed?: boolean): confine.Ran
  local leave, heard = enter(own, sandboxed)
  local ok, produced: boolean, any = pcall(fn, argument)
  local refused = leave()
  if refused ~= nil then
    produced = ok and refused or refused .. "; and then: " .. tostring(produced)
    ok = false
  end
  return { ok = ok, produced = produced, unseen = heard }
end

return confine
