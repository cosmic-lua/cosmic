--- The sandbox a test's processes run in: what a test declares the
--- processes it starts need (`confine`, `must_confine`); the stand-in
--- for the process table's `spawn` that holds each process it starts to
--- that (`enter`); and what a sandboxed worker of this very
--- program is given and held to (`worker_unveil`, `forbid_running`,
--- `itself`), with the system's paths a sandbox gives (`in_system`)
--- and where a path leads as one binds it (`resolution`).

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- The raw process table, whose `spawn` `cosmic.child` starts every
--- child with: this module is handed it (core/store.c's `raw_modules`)
--- to confine each child a test starts, by standing in for that call,
--- and for the Landlock ruleset `forbid_running` puts up. Boot mode
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

  --- The calls the stand-in, and each question this module asks of
  --- the filesystem and the environment, makes: `cosmic.sys`'s and the
  --- process table's own `spawn` where nothing observes them, or the
  --- same calls past the log of an observer (see `Observer`), so its
  --- own questions are none of the test's.
  record Calls
    getcwd: function(): string | nil, string, integer
    realpath: function(path: string): string | nil, string, integer
    lstat: function(path: string): sys.Stat | nil, string, integer
    stat: function(path: string): sys.Stat | nil, string, integer
    readdir: function(path: string): {string:string} | nil, string, integer
    getenv: function(name: string): string | nil
    environ: function(): {string:string}
    spawn: function(path: string, argv: {string}, environment?: {string:string},
                    cwd?: string, stdin?: integer, stdout?: integer, stderr?: integer,
                    process_group?: boolean, fds?: {integer:integer},
                    sandbox?: raw_process.Sandbox): integer | nil, string, integer
  end

  --- What observes the processes a stand-in (see `enter`) starts --
  --- build.filesystem_observations' capture of a test's calls -- and
  --- what it tells the stand-in: the calls it makes past its log, and
  --- the sandbox of the worker it runs in. Each function hears one
  --- thing the stand-in did.
  -- TODO: drop the observer, and each call of it here, once a test
  -- worker runs its test under `enter` alone rather than in a capture of
  -- what it reads (removing the observation log, step 4): nothing then keys a
  -- run by what its processes were given.
  record Observer
    --- The calls past the observer's log.
    calls: Calls
    --- What this process's own sandbox gives it to read, every process
    --- it starts inheriting it -- `cosmic test`'s sandboxed worker
    --- (build/test_sandbox.tl) -- or nil where it runs unsandboxed. A
    --- process the test starts with no confinement of its own is held
    --- to that, and heard of as a confined one is, by `given`.
    held: {string} | nil
    --- Why a process `held` holds is none a key holds -- the sandbox
    --- is online, say -- or nil: such a process is heard of by
    --- `unkeyed` too, with it.
    unkeyable: string | nil
    --- The directories the running test owns now, its own directory
    --- first: what a confined process may change.
    own: function(): {string}
    --- A process is to start `program`, found from `cwd` -- this
    --- process's working directory where nil -- when relative.
    program: function(program: string, cwd: string | nil)
    --- A process started held to `reads` and `writes` and the test's
    --- own directories `own`, with `environment` (this process's where
    --- nil) and the descriptors it was handed.
    given: function(reads: {string}, writes: {string}, own: {string},
                     environment: {string:string} | nil, stdin: integer | nil,
                     stdout: integer | nil, stderr: integer | nil,
                     fds: {integer:integer} | nil)
    --- The variable `name` of this process, `value`, decided how a
    --- process started.
    variable: function(name: string, value: string | nil)
    --- A process started as it was asked, confined by nothing the
    --- stand-in knows: `program`.
    unconfined: function(program: any)
    --- What the stand-in did that no key holds: `why`, the program, a
    --- path or a reason.
    unkeyed: function(why: any)
  end

  --- What hears of each start a stand-in (see `enter`) saw refused:
  --- in a sandboxed worker, a program its sandbox does not give it, or
  --- one whose interpreter or loader it does not, is refused there, and
  --- the worker's record of what its sandbox refused
  --- (build.refusals) names it for the audit. Each function hears one
  --- start.
  record Refused
    --- `program`, found from `cwd` -- this process's working directory
    --- where nil -- when relative, did not start: the spawn failed
    --- with `errno`.
    start: function(program: string, cwd: string | nil, errno: integer)
    --- `program` was refused a root of its own (`refuse_nesting`).
    nests: function(program: string)
  end

  --- The most paths a sandbox unveils, its reads and writes together.
  unveil_max: integer

  --- See below.
  system_paths: {string}

  --- See below.
  held_variable: string
  nests_note: string
end

--- The calls this module makes with nothing observing them.
local unobserved: confine.Calls = {
  getcwd = sys.getcwd, realpath = sys.realpath, lstat = sys.lstat, stat = sys.stat,
  readdir = sys.readdir, getenv = sys.getenv, environ = sys.environ, spawn = own_spawn,
}

--- One running stand-in (see `enter`): what observes it, if anything,
--- and the running test's own directory, if it has one.
local record Entry
  observer: confine.Observer | nil
  own: string | nil
end

--- Every running stand-in, innermost last: one wraps another when a
--- test runs a capture of its own inside the one running it.
local entered: {Entry} = {}

--- The calls to make now: past the log of the innermost running
--- stand-in's observer, which logs while any runs, or, with none,
--- `cosmic.sys`'s own.
local function calls(): confine.Calls
  for at = #entered, 1, -1 do
    local observer = entered[at].observer
    if observer ~= nil then return observer.calls end
  end
  return unobserved
end

--- What the sandbox this process runs in gives it to read, as the
--- innermost running stand-in whose observer knows it says (`Observer`'s
--- `held`): a capture a test runs of its own inside its sandboxed
--- worker's knows no sandbox, but the worker's does. Nil where none
--- does.
local function sandbox_held(): {string} | nil
  for at = #entered, 1, -1 do
    local observer = entered[at].observer
    if observer ~= nil and observer.held ~= nil then return observer.held end
  end
  return nil
end

--- The system's programs and libraries and its configuration: what a
--- host program, or the dynamic loader that starts one, reads.
local system_paths: {string} = { "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32",
  "/etc" }

confine.system_paths = system_paths

--- Whether `path`, absolute, is one of `system_paths` or beneath one.
function confine.in_system(path: string): boolean
  for _, system_path in ipairs(system_paths) do
    if Fs.within(path, system_path) then return true end
  end
  return false
end

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
--- `confine.confine`.
local confinement: confine.Confinement | nil = nil

--- How the declaration in `confinement` is held: nil where a process
--- the kernel cannot confine starts unconfined, and otherwise what
--- names the call that asked for no fallback, for the failure a spawn
--- answers instead (see `confine.must_confine`).
local strict: string | nil = nil

--- What the library whose work is running declared its processes need,
--- or nil: see `confine.declaring`.
local library: confine.Confinement | nil = nil

--- The variable that turns every `confine` into `must_confine`.
local SANDBOX_MODE <const> = "COSMIC_SANDBOX"

--- Whether this process runs with every `confine` a `must_confine`:
--- `SANDBOX_MODE` set to "must". Unset or empty, it does not; any other
--- value raises, so a misspelt mode never passes for the default. Read
--- past the log, as the call is made: it decides whether a run that
--- could never stand fails, never what a standing verdict read.
local function must_everywhere(): boolean
  local mode = calls().getenv(SANDBOX_MODE)
  if mode == nil or mode == "" then return false end
  if mode == "must" then return true end
  error(string.format("%s is %q: set it to \"must\", or leave it unset", SANDBOX_MODE, mode), 3)
end

--- The variable a sandboxed worker held by a Landlock ruleset is
--- started with (`forbid_running`), naming its module: every process it
--- starts inherits the hold, and, through `this_program.environment`,
--- the variable, so a `cosmic test` one of them runs refuses to sandbox
--- its workers (`build.test`) as a spawn here refuses a root of its own
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
-- ruleset (`test_sandbox.refusal`).
confine.held_variable = "COSMIC_TEST_HELD"

--- The module whose worker's Landlock ruleset holds this process
--- (`held_variable`), or nil where none does. Read past the log, as
--- `must_everywhere` is: it decides whether a test fails, never what a
--- standing verdict read.
local function held_by(): string | nil
  local module = calls().getenv(confine.held_variable)
  if module == nil or module == "" then return nil end
  return module
end

--- What leads what an observer hears as `unkeyed` of a start refused
--- a root of its own (`refuse_nesting`), the program after it: what the
--- audit names `nests` for (`build.test`).
confine.nests_note = "nests "

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
  local here, _ = calls().getcwd()
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
--- in its module's `Test.needs`, whose sandboxed worker holds them to it
--- (`Observer`'s `held`).
---
--- `declared.reads` is read-only and `declared.writes` may be changed,
--- beside `system` -- each of it the worker has: a sandboxed worker
--- whose module does not declare `system` has only the runtime's -- and
--- the test's own directory and every directory it made, which a process
--- may change too. The kernel holds each process to that: a root of its
--- own holding those paths and nothing else, and no network (the
--- process table's `Sandbox`, `unveil` and `offline`). So what a process
--- read is known, and a test whose processes all ran confined can
--- stand: every path it was given enters the verdict key, one under the
--- tree by its contents and any other by a walk of what `lstat` says of
--- it and everything beneath it.
---
--- A process started with a sandbox of its own is not confined further.
--- Where the kernel cannot confine one, it starts as it would have, and
--- the run never stands. A process given no directory to start in
--- starts in the test's own, since the one the test runs in, the tree's
--- root, is not its to read. A process has a /tmp of its own, and one
--- that inherits a TMPDIR it may not change has the test's own
--- directory for it.
---
--- Called at a test module's top level, it holds for each of its tests;
--- called in a test, for the rest of that test. A relative path is taken
--- from the directory this is called in. Nil ends the declaration: a
--- process started after it is not confined. With COSMIC_SANDBOX=must in
--- the environment, it is `must_confine`.
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
--- confines, has the sandboxed worker's own sandbox and is keyed by it
--- (`Observer`'s `held`), or, where the worker runs unsandboxed,
--- runs unconfined and never stands. Only the sandbox's own tests
--- confine: every other test's processes are the worker's to hold,
--- which its module's `Test.needs` declares for them.
function confine.must_confine(declared: confine.Confinement | nil)
  must_everywhere() -- a misspelt mode raises here too
  declare(declared, "must_confine")
end

--- Calls `fn`, the work of a library that starts processes whose every
--- input it can name -- build/c/init.tl's compilers: their toolchain and
--- what they compile. Each process it starts with no sandbox of its own
--- is held to `declared`: `declared.reads`, read-only, and
--- `declared.writes`, which it may change, beside `system` and the
--- running test's own directories, as `confine` holds a test's. So what
--- it read is known and keyed by what it was given.
---
--- Where this process runs in a sandbox -- a sandboxed worker's
--- (`Observer`'s `held`), or one a Landlock ruleset holds -- the process
--- inherits that and is held by it alone, as one started undeclared is:
--- a root of its own would nest in the worker's, which a ruleset
--- refuses. A test's own `confine` holds the process rather than this.
---
--- Where no stand-in runs (see `enter`) -- no test, `cosmic fix` --
--- nothing holds it. Where the kernel cannot confine one, it starts
--- unconfined, noted "p", and with COSMIC_SANDBOX=must it does not
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
      local there, _ = calls().lstat(stamp)
      if there ~= nil and there.kind == "file" then program[#program + 1] = stamp end
    end
  end
  return program
end

--- Whether this host gives a sandboxed process a procfs of its own pid
--- namespace (core/process.h's `unveil`): whether /proc, as this
--- process sees it, is writable and has nothing mounted beneath it but
--- /proc/sys/fs/binfmt_misc, which the kernel keeps empty. A user
--- namespace may mount a procfs only where one is wholly visible, which
--- a container's masked /proc paths are not; where one is not, a
--- sandboxed process has the host's /proc, read-only.
-- TODO: ask the kernel rather than read the mounts -- start a confined
-- process once and see whether its /proc has a /proc/sys, as
-- build/sandbox_probe.tl's "a /proc of its own" part does -- so a
-- mount beneath /proc the kernel lets through (a host's
-- /proc/fs/nfsd, an NFS server's) is not taken for a mask: today it
-- is, and the tests that ask expect the fallback where there is none.
-- TODO: key an unsandboxed verdict by which /proc a confined process
-- gets, as a sandboxed one's is (`declared_key.host_identity`): today
-- one that stood where a sandbox gets a procfs of its own stands where
-- it gets the host's, and the other way about, though the tests that
-- ask expect different things of each.
function confine.own_proc_given(): boolean
  local text, _ = Fs.read("/proc/self/mountinfo")
  if text == nil then return false end
  for line in text:gmatch("[^\n]+") do
    local point, options = line:match("^%S+ %S+ %S+ %S+ (%S+) (%S+)")
    if point == "/proc" and ("," .. options .. ","):find(",ro,", 1, true) then return false end
    if point ~= nil and point:sub(1, 6) == "/proc/" and point ~= "/proc/sys/fs/binfmt_misc" then
      return false
    end
  end
  return true
end

--- What a sandboxed worker of this very program -- `cosmic test`'s,
--- started as `Proc.relaunch` says, in `cwd` -- has to be given to start
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
--- there as it is given, so each may be handed to `process.spawn`'s
--- `unveil` whole. The worker can confine what its test starts in
--- turn, having a /proc of its own -- but where the kernel refuses it
--- one and its /proc is the host's, read-only. `cosmic test`'s sandbox
--- (build/test_sandbox.tl) gives a worker these, and what its test's
--- module reads.
function confine.worker_unveil(tree: string, cwd: string | nil, scratch: string,
                               with_system?: boolean, with_program?: boolean): raw_process.Unveil
  local reads: {string} = {}
  local seen: {string:boolean} = {}
  local stat = calls().stat
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
    local a, _ = calls().stat(program)
    local b, _ = calls().stat(core)
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
--- `nests` (`cosmic.test`). False and why where there is no Landlock.
-- TODO: let build/filesystem_observations_tool_test.tl,
-- build/test_sandbox_system_test.tl and core/syscalls_tool_test.tl
-- declare `nests` alone, dropping the `tool` they declare only to
-- start what they confine, once a confined process is given only what
-- its worker has (the TODO above build/test.tl's `the_tool`): today
-- `itself` is given to the process it confines, and a worker without
-- the program fails the start EACCES.
-- TODO: hold a copy of the program as the program -- one a test copies
-- or links elsewhere and runs, or a core it loads some other way than
-- by exec -- once a ruleset can name a file by its contents: today a
-- test that copies the program into its own directory runs it
-- undeclared.
function confine.forbid_running(programs: {string}): boolean, string
  local now = calls()
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
    local own = entered[at].own
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
  local realpath = calls().realpath
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
--- skipped (`Test.skip`) and returns unchecked, and `cosmic test` fails
--- a skipped test where this answers true, so a run held to sandboxing
--- proves the host checked it. Read through the log, so an unsandboxed
--- verdict is keyed by them; a sandboxed test that reads it declares
--- `COSMIC_CI_REQUIRE_SANDBOX` (the other two are pinned).
function confine.held_to_sandbox(): boolean
  return sys.getenv("COSMIC_TEST_SANDBOX") == "1" or sys.getenv(SANDBOX_MODE) == "must" or
    sys.getenv("COSMIC_CI_REQUIRE_SANDBOX") == "1"
end

--- The errnos a confined spawn fails with where the kernel cannot
--- confine a process at all: no user namespaces, or none for this user.
--- Under `must_confine` none of them falls back: the spawn fails.
-- TODO: fall back only on a failure of the sandbox's own setup, and name
-- that step in `must_confine`'s failure (the user namespace, the root,
-- the network namespace), once `process.spawn` says which step failed
-- (the status pipe carrying it beside the errno): an EACCES or EINVAL
-- from exec, or an unreadable path declared, falls back unconfined too,
-- and the test runs uncached where it should fail.
-- TODO: treat the EROFS a process confined inside a sandbox fails with
-- where that sandbox's /proc is the host's (a container masking parts of
-- its /proc, without --security-opt systempaths=unconfined) -- its
-- uid_map write, on a /proc read-only whole -- as a sandbox the kernel
-- cannot give, falling back or, under `must_confine`, refused, once
-- `process.spawn` says which step failed (the TODO above): today the
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

--- `sandbox` as the core reads it -- raw, with no metamethod answering
--- for a field -- in a plain table of its own; nil when a field holds
--- what the core would refuse, for the core to refuse.
local function plain_sandbox(sandbox: raw_process.Sandbox): raw_process.Sandbox | nil
  local raw = sandbox as {string:any}
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
  local realpath = calls().realpath
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
--- starts unconfined, or under `must_confine` not at all.
local function unfit_for(program: string, reads: {string}, writes: {string}): Unfit | nil
  if #reads + #writes > UNVEIL_MAX then
    return { why = string.format("%d paths, more than the %d a sandbox unveils",
      #reads + #writes, UNVEIL_MAX), errno = sys.EINVAL }
  end
  local realpath = calls().realpath
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
-- TODO: ask `access` past the log too, once core/observed.c's table
-- carries it beside `stat`: logged, as a stat of its path, it is asked
-- only of a program whose spawn was refused, which is noted "x"
-- besides, so the run never stands.
local function runnable(program: string): boolean
  local st, _ = calls().stat(program)
  if st == nil or st.kind ~= "file" then return false end
  local may, _ = sys.access(program, sys.X_OK)
  return may
end

--- The first spawn `must_confine` refused while each running stand-in
--- ran, by its entry: which fails that stand-in's call, whatever the
--- test made of the spawn's answer.
local refusals: {Entry:string} = {}

--- Refuses a spawn `must` holds to its sandbox: `program` could not
--- start with `part` of it applied, for `why` (`errno`). Every running
--- stand-in hears it, and its observer. Answers the message the spawn
--- fails with.
local function refuse(must: string, program: string, part: string, why: string,
                      errno: integer): string
  local name = sys.errno_name(errno) or ("errno " .. tostring(errno))
  local message = string.format(
    "%s: %s could not start confined: %s could not be applied: %s (%s)",
    must, program, part, why, name)
  for _, each in ipairs(entered) do
    local observer = each.observer
    if observer ~= nil then observer.unkeyed(program) end
    if refusals[each] == nil then refusals[each] = message end
  end
  return message
end

--- Whatever hears of a refused start now (`confine.hear`), in the order
--- each began.
local hearers: {confine.Refused} = {}

--- Has `refused` hear of each start a running stand-in saw refused
--- (`confine.Refused`), until the function this answers is called. It
--- hears nothing of a process started past the stand-in, nor while none
--- stands in: only a capture's stand-in, which a test worker's test runs
--- under, sees a start.
function confine.hear(refused: confine.Refused): function()
  hearers[#hearers + 1] = refused
  return function()
    for at = #hearers, 1, -1 do
      if hearers[at] == refused then table.remove(hearers, at) break end
    end
  end
end

--- Refuses a start of `program` in a root of its own -- a sandbox that
--- unveils, its own or `confine`'s -- where the worker of `module` is
--- held by a Landlock ruleset (`held_by`), which would refuse its
--- mounts: not tried, so it never falls back to running unconfined.
--- Every running stand-in hears it, which fails its test whatever the
--- test made of the answer, and its observer, for the audit. Answers
--- the message the spawn fails with.
local function refuse_nesting(program: string, module: string): string
  local message = nests_refusal(program, module)
  for _, each in ipairs(hearers) do each.nests(program) end
  for _, each in ipairs(entered) do
    local observer = each.observer
    if observer ~= nil then observer.unkeyed(confine.nests_note .. program) end
    if refusals[each] == nil then refusals[each] = message end
  end
  return message
end

--- Stands in for the process table's `spawn` until the function this
--- answers is called, which puts back what it stood in for and answers
--- the first spawn `must_confine` refused meanwhile, or nil. `own` is
--- the running test's own directory, where a process it starts may
--- write and makes its temporary files; `observer`, what hears of each
--- process it starts (see `Observer`), or nil.
---
--- A process the test starts is confined (`confine.confine`) or held
--- by what its own sandbox gives it, which the stand-in decides; one
--- started past it, through a reference taken before it stood in, is
--- not. A reference to the stand-in taken while it stood in starts a
--- process as the process table's own does, once it no longer stands
--- in -- or, under `must_confine`, none.
function confine.enter(own: string | nil, observer?: confine.Observer): function(): string | nil
  local past = observer ~= nil and observer.calls or calls()
  -- The call the stand-in wraps: what `spawn` was as it began, past
  -- the log when it is the process table's own, since the observer
  -- hears what it starts from the stand-in itself.
  local spawn = process.spawn
  if spawn == own_spawn then spawn = past.spawn end
  local ended = false
  local entry: Entry = { observer = observer, own = own }
  -- What the running test owns now, which a confined process may change.
  local function own_now(): {string}
    if observer ~= nil then return observer.own() end
    if own == nil then return {} end
    return { own }
  end
  local function unkeyed(why: any)
    if observer ~= nil then observer.unkeyed(why) end
  end
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                           cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                           stderr: integer | nil, process_group: boolean,
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox):
                           integer | nil, string, integer
    if ended then
      -- A reference to a stand-in that no longer stands in starts a
      -- process no confinement holds: under `must_confine`, none.
      if strict ~= nil and confinement ~= nil then
        return nil, refuse(strict, path, "unveil and offline",
          "started through a spawn taken while an earlier capture ran", sys.EINVAL), sys.EINVAL
      end
      return own_spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group,
        fds, sandbox)
    end
    if observer ~= nil then observer.program(path, cwd) end
    -- A sandbox of its own that unveils and takes the network holds a
    -- process as a confinement does, and is heard of the same. It is
    -- read as the core reads it, raw, and a plain copy is what the core
    -- is given, so what is heard of is what holds the process.
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
      local owned = own_now()
      local pid, trouble, errno = spawn(path, argv, environment, cwd, stdin, stdout, stderr,
        process_group, fds, plain)
      if pid ~= nil or not unconfinable[errno] then
        if observer ~= nil then
          observer.given(plain.unveil.reads, plain.unveil.writes, owned, environment,
            stdin, stdout, stderr, fds)
        end
      elseif must ~= nil and runnable(path) then
        return nil, refuse(must, path, "its own sandbox's unveil and offline", trouble, errno),
          errno
      else
        -- Nothing ran; what the test does now turns on the host, or,
        -- for a program exec could not run, on nothing of the sandbox.
        unkeyed(path)
      end
      return pid, trouble, errno
    end
    -- A sandbox of its own that does not both unveil and take the
    -- network -- a pledge or a ruleset alone -- leaves the process
    -- reading what no key holds: under `must_confine` it does not
    -- start, rather than be held to a sandbox it was not given. One the
    -- core would refuse raises there.
    if plain ~= nil and must ~= nil then
      return nil, refuse(must, path, "unveil and offline",
        "a sandbox of its own that does not unveil and take the network, which " ..
        "must_confine does not add to", sys.EINVAL), sys.EINVAL
    end
    -- A process this sandboxed process starts with no sandbox of its
    -- own and no confinement declared has this one's sandbox and no
    -- more: heard of by what that gives it to read, as a confined one
    -- is, and started as it is, with no sandbox nested in it. Where it
    -- starts, and with what environment, are as the test asked.
    local held = observer ~= nil and observer.held or nil
    -- One a library's work starts (`declaring`), where no confinement
    -- of the test's holds it: where this process runs in a sandbox, by
    -- that, as below, whichever capture hears of it -- a test's own,
    -- inside its worker's, is heard of what the worker's sandbox gives
    -- -- and elsewhere by what the library declared, as a test's own
    -- confinement holds one, but where a ruleset holds this process,
    -- whose sandbox no capture here knows: that one starts as one
    -- declared by nothing does.
    local declared = confinement
    local declared_strict = strict
    if sandbox == nil and declared == nil and library ~= nil then
      local outer = sandbox_held()
      if outer ~= nil then
        held = outer
      elseif holder == nil then
        declared = library
        declared_strict = must_everywhere() and "confine (" .. SANDBOX_MODE .. "=must)" or nil
      end
    end
    if sandbox == nil and declared == nil and held ~= nil then
      local owned = own_now()
      local pid, trouble, errno = spawn(path, argv, environment, cwd, stdin, stdout, stderr,
        process_group, fds, nil)
      -- Whether it started turns on the same paths as what it read.
      if observer ~= nil then
        observer.given(held, {}, owned, environment, stdin, stdout, stderr, fds)
        local unkeyable = observer.unkeyable
        if unkeyable ~= nil and unkeyable ~= "" then unkeyed(unkeyable) end
      end
      return pid, trouble, errno
    end
    if sandbox == nil and declared ~= nil then
      local owned = own_now()
      local reads: {string} = {}
      for _, given in ipairs(system) do
        local there, _ = past.stat(given)
        if there ~= nil then reads[#reads + 1] = given end
      end
      for _, given in ipairs(declared.reads) do reads[#reads + 1] = given end
      local writes: {string} = {}
      for _, given in ipairs(owned) do
        local there, _ = past.stat(given)
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
        local inherited = past.getenv("TMPDIR")
        local temporary = inherited
        if environment ~= nil then
          temporary = environment.TMPDIR
          -- Whether its TMPDIR is replaced turns on the worker's own,
          -- which an environment given whole does not otherwise key.
          if observer ~= nil then observer.variable("TMPDIR", inherited) end
        end
        local replace = temporary ~= nil and temporary == inherited
        for _, given in ipairs(writes) do
          if replace and Fs.within(temporary, given) then replace = false end
        end
        if replace and writes[1] ~= nil then
          given_environment = {}
          for name, value in pairs(environment or past.environ()) do
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
        -- runs on (`itself`) is bound, or which the launcher makes. No
        -- key holds the name it leads to, as none holds the host's
        -- TMPDIR: the variable's value is keyed with the environment, and
        -- what the process reads there, by what it was given.
        -- TODO: give a confined process each link on a path it was given
        -- as the host has it (core/syscalls.c's unveil links a name only
        -- at its last part, where the launcher refuses a link for its
        -- cache), and declare in `itself` the cache a launcher finds by
        -- default, from XDG_CACHE_HOME or HOME: a default cache reached
        -- through a link is still not there.
        -- TODO: drop this renaming (and `led_to`) once core/syscalls.c's
        -- unveil gives a confined process each link on a path as the
        -- host has it (the TODO above): only the sandbox's own tests
        -- confine now, but one of them run where COSMIC_PORTABLE_CACHE
        -- is named through a link still needs it.
        local cache = (given_environment or past.environ()).COSMIC_PORTABLE_CACHE
        local leads = cache ~= nil and led_to(cache) or nil
        if leads ~= nil and leads ~= cache then
          local renamed: {string:string} = {}
          for name, value in pairs(given_environment or past.environ()) do renamed[name] = value end
          renamed.COSMIC_PORTABLE_CACHE = leads
          given_environment = renamed
        end
        local pid, trouble, errno = spawn(path, argv, given_environment, start_in, stdin, stdout,
          stderr, process_group, fds, { unveil = { reads = reads, writes = writes },
            offline = true })
        if pid ~= nil or not unconfinable[errno] then
          if observer ~= nil then
            observer.given(reads, declared.writes, owned, environment, stdin, stdout, stderr, fds)
          end
          return pid, trouble, errno
        end
        if declared_strict ~= nil then
          -- Nothing ran, and nothing runs in its place. A program exec
          -- could not have run unconfined either failed there, not in
          -- the sandbox: its failure is its own to answer.
          if not runnable(path) then
            unkeyed(path)
            return pid, trouble, errno
          end
          return nil, refuse(declared_strict, path, "unveil and offline", trouble, errno), errno
        end
      end
      cwd = start_in
    end
    if observer ~= nil then observer.unconfined(path) end
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds,
      sandbox)
  end
  -- Whatever hears of a refused start hears of each the stand-in saw
  -- fail, however it failed: what it makes of one is its own.
  local standing = process.spawn
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                           cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                           stderr: integer | nil, process_group: boolean,
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox):
                           integer | nil, string, integer
    local pid, trouble, errno = standing(path, argv, environment, cwd, stdin, stdout, stderr,
      process_group, fds, sandbox)
    local program: any = path
    if pid == nil and not ended and program is string then
      for _, each in ipairs(hearers) do each.start(path, cwd, errno) end
    end
    return pid, trouble, errno
  end
  entered[#entered + 1] = entry
  return function(): string | nil
    ended = true
    process.spawn = spawn == past.spawn and own_spawn or spawn
    for at = #entered, 1, -1 do
      if entered[at] == entry then table.remove(entered, at) break end
    end
    local refused = refusals[entry]
    refusals[entry] = nil
    return refused
  end
end

return confine
