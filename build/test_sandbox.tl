--- A test worker run sandboxed: `cosmic test` starts each worker
--- through [`cosmic.child`]'s `sandbox`, held to its test's effective
--- inputs ([`build.test_inputs`]) and what the runtime needs to run it at
--- all, with every process it starts, wherever this host can sandbox
--- one ([`build.test_sandbox_probe`]). `COSMIC_TEST_SANDBOX` chooses (`mode`): unset,
--- each worker is sandboxed where one can be and runs unsandboxed where
--- none can (macOS, a host that refuses user namespaces); "1" requires
--- it, and the run fails where none can be; "0" turns it off.
---
--- What a sandboxed worker has ([`test_sandbox.plan`]):
---
--- - the tree at [`test_sandbox.tree`], /tree, wherever the host keeps
---   it, and its working directory there. Each read-only, it holds only
---   the store at o/cosmic.db (the store of its module's import closure,
---   [`build.closure_store`]'s `write`, or the whole projection for a
---   module that declares `store`), its module's import closure as
---   source files, the fuzz corpora for a module that uses
---   [`build.fuzz`], what the module declares it `reads`, and o/bin for
---   one that declares `tool`;
--- - its scratch directory at [`test_sandbox.scratch`], beneath /tmp at
---   a name padded to `scratch_length`, writable: the test's own
---   directory (`tmp` there, a link to `real` beside it), where
---   the processes it starts write their coverage (`children` there), and
---   its TMPDIR;
--- - the host caches the module declares ([`build.caches`]), writable,
---   each at its own name, made first where missing, and the variables
---   that locate them -- but for the cores a portable cosmic extracts,
---   where the program's own core is: for the `bootstrap` cache, the
---   worker has cores of its own in its scratch directory
---   (`cache_writes`);
--- - /proc and the devices every program takes for granted, the
---   program's core and the stamp that says the core was verified, and
---   the program itself only for a module that declares `tool`
---   ([`confine.worker_unveil`]), the system's own paths (/usr, /bin,
---   /lib, /etc and the like) only where the module declares `system`,
---   and the `host` paths the module declares, each at its own name --
---   one a variable names (`$NAME/path`) where the variable says, as
---   [`test_inputs.resolve`] put it, refused where that is the tree's,
---   the scratch directory's, or above either;
--- - no network but a loopback of its own, which answers the loopback
---   addresses a module may declare ([`cosmic.test`]'s `network`), as the
---   host's would;
--- - the pinned environment and the variables it declares, `"*"` for
---   all of the runner's (`environment`);
--- - where the runner is root, a user of its own to run as ([`runs_as`]),
---   unprivileged, which owns its scratch directory and the copy of the
---   core it runs, so it confines what its test starts at any depth.
---
--- A read of anything else finds nothing, and so does one of every
--- process the worker starts, which has the worker's sandbox and no
--- more: what a test declares for itself it declares for them.
---
--- The worker is pid 2 of a pid namespace of its own, whose init ends
--- when it does, ending whatever it left running there: no descendant of
--- a sandboxed worker outlives it. Its verdict is keyed by what it was
--- given ([`build.declared_key`]), not by what it read.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")
local caches = require("build.caches")
local hashing = require("build.digest")
local String = require("cosmic.string")

local record test_sandbox
  --- Where a sandboxed worker has the tree, and runs.
  tree: string
  --- Where it has its scratch directory.
  scratch: string
  --- How long, at least, the path of every test's scratch directory is,
  --- on every host. macOS's own is 75 bytes, its temporary directory
  --- resolved (/private/var/folders/<2>/<30>/T/) and [`build.test`]'s
  --- `scratch` beneath it, and a path a test builds there runs past a
  --- bound (a socket file's 104 bytes, a tar name's 100) that a shorter
  --- one elsewhere never meets. Padded to this on every host -- a
  --- sandbox's by its name, an unsandboxed one's by its prefix -- a test
  --- meets such a bound on every leg, not on macOS's alone.
  scratch_length: integer
  --- The variable that turns the sandbox on.
  switch: string

  --- The user and group a sandboxed worker runs as in place of the
  --- runner's ([`runs_as`]).
  record User
    uid: integer
    gid: integer
  end

  --- How one worker is sandboxed.
  record Plan
    sandbox: Child.Sandbox
    --- Its environment, before the runner adds its own (the relaunch
    --- contract, coverage from the first instruction): what a test's
    --- read of a variable answers, and so what its key holds.
    env: {string:string}
    --- The paths it was given beyond the most a sandbox holds, or 0.
    over: integer
    --- Why it cannot start as planned -- a cache it declares that could
    --- not be made, a `host` path it declares that cannot be given -- or
    --- "".
    trouble: string
    --- The name the worker has the program by -- the artifact path its
    --- relaunch names (`--artifact`), which [`Proc.executable()`] answers
    --- -- where the program is the tree's own o/bin/cosmic:
    --- /tree/o/bin/cosmic, as the rest of the tree is; where it is the
    --- runner's own beneath /tree, /program/<its name> ([`program_name`]);
    --- nil where it keeps the runner's, as a worker whose module does
    --- not declare `tool` does.
    program: string | nil
    --- What starts it ([`Proc.relaunch`]) where it runs as a user of its
    --- own with a copy of the runner's core ([`runs_as`]), which the
    --- core it is handed must be: the runner's relaunch, with that
    --- copy's descriptor in the core's place. Nil for the runner's own.
    start: Proc.Relaunch | nil
  end
end

test_sandbox.tree = "/tree"

test_sandbox.scratch_length = 80

--- `prefix` padded with "_" to `length` bytes; a prefix that long
--- already is itself.
function test_sandbox.padded(prefix: string, length: integer): string
  return prefix .. string.rep("_", length - #prefix)
end

test_sandbox.scratch = test_sandbox.padded("/tmp/cosmic-test-padded-to-a-macos-length",
  test_sandbox.scratch_length)
test_sandbox.switch = "COSMIC_TEST_SANDBOX"

--- Where a sandboxed worker has the program that runs it, when that is
--- neither the tree's own nor to be had at its own name
--- ([`Plan.program`]).
local program_place <const> = "/program"

--- The most paths a sandbox unveils (core/process.h's UNVEIL_MAX).
local UNVEIL_MAX <const> = confine.unveil_max

--- How the switch asks for the sandbox: "auto", unset or empty, for
--- each worker sandboxed wherever one can be; "on", "1", for every
--- worker sandboxed or the run failing; "off", "0", for none. Any other
--- value is an error, so a misspelt one never passes for any of them.
function test_sandbox.mode(): string | nil, string
  local value = Env.get(test_sandbox.switch)
  if value == nil or value == "" then return "auto", "" end
  if value == "1" then return "on", "" end
  if value == "0" then return "off", "" end
  return nil, string.format("%s is %q: set it to 1 to require it, 0 to turn it off, " ..
    "or leave it unset", test_sandbox.switch, value)
end

--- Where a sandboxed worker that declares the `bootstrap` cache has
--- cores of its own, which COSMIC_PORTABLE_CACHE names to it: beneath
--- its scratch directory, which a portable cosmic it starts makes.
local own_cores <const> = test_sandbox.scratch .. "/cores"

--- The user and group a sandboxed worker runs as where the runner is
--- root ([`runs_as`]). Not `nobody` (65534): in the worker's own user
--- namespace, which maps it alone, root's files are the kernel's
--- overflow id, 65534, and a worker that were 65534 too would seem to
--- own them. 65532 is the unprivileged user distroless images run as,
--- beneath 65536, so a container whose namespace maps the usual 65536
--- ids maps it too.
-- TODO: choose an id no user of this host has -- one /etc/passwd and
-- /etc/group name no entry for, from a range the host keeps for no one
-- (a subordinate id range of root's) -- once a runner reads them
-- (getpwuid, or the files parsed): today a host with a user of its own
-- at 65532 would have root's workers run as that user, and a process of
-- that user could signal or trace them.
local worker_id <const> = 65532

--- What a worker run as `worker_id` has this program's core in place
--- of the cache it is in, by that cache's name ([`Plan`]'s `sandbox`),
--- where it runs a core the launcher extracted (build/launcher.tl),
--- which the launcher keeps as root's alone, 0500 in a 0700
--- directory: a copy of it, and of the stamp that spares hashing it, in
--- a directory of the worker's user's own, 0500, as the launcher keeps
--- them for that user and checks it keeps them where a test runs this
--- program. Each such directory is beneath `worker-cores` in root's
--- cache, root's own and 0700, so no process but root's reaches one:
--- root writes it, by name, and nothing else can swap a link or a core
--- into it. A copy is checked against the digest the core's name holds
--- as it is made, and made in place by a rename, so two runs at once
--- make it alike. The directory, and the cache it stands for, or ""
--- for neither where the core is no launcher's -- a host program, its
--- own core -- and one the worker's user may read and run; nil where
--- the worker could not run it.
-- TODO: prune a directory of `worker-cores` whose core no run has used
-- for a while, as nothing prunes the launcher's own cores directory
-- either, once that has a rule to share (the launcher's cache is
-- pruned by hand today): each core this host runs as root leaves one.
local record Cores
  --- The worker's own copy of the cache, "" for none.
  copy: string
  --- The cache it is given at, "" for none.
  cache: string
  --- The runner's relaunch ([`Proc.relaunch`]) with the core it hands on
  --- that copy's ([`Plan.start`]), nil for none.
  start: Proc.Relaunch
end
local function worker_cores(): Cores | nil, string
  local launched, _ = Proc.relaunch()
  local core: string = nil
  if launched ~= nil then
    core = launched.argv[1]
  else
    local executable, _ = Proc.executable()
    core = executable
  end
  if core == nil then return nil, "this program cannot find its core" end
  local directory, name = core:match("^(.*)/(core%-[^/]*)$")
  if directory == nil then
    local there, _ = sys.stat(core)
    if there ~= nil and there.mode & 0x5 == 0x5 then return { copy = "", cache = "" }, "" end
    return nil, core .. " is not another user's to read and run"
  end
  local digest = name:match("%-(%x+)$")
  if digest == nil then return nil, core .. " names no digest" end
  local base, base_trouble = Fs.cache_path("worker-cores")
  if base == nil then return nil, base_trouble end
  local made, made_trouble = Fs.mkdirs(base)
  if not made then return nil, made_trouble end
  local closed, close_trouble = sys.chmod(base, 0x1c0)
  if not closed then return nil, base .. ": " .. close_trouble end
  -- Root's alone, as made: what is beneath it is written by name.
  local held, _ = sys.lstat(base)
  if held == nil or held.kind ~= "dir" or held.uid ~= 0 or held.mode & 0x1ff ~= 0x1c0 then
    return nil, base .. " is not root's alone"
  end
  local cache = base .. "/" .. name
  local function owned(path: string, mode: integer): boolean, string
    local changed, trouble = sys.chmod(path, mode)
    if changed then changed, trouble = sys.chown(path, worker_id, worker_id) end
    if not changed then return false, path .. ": " .. trouble end
    return true, ""
  end
  local there_dir, _ = sys.lstat(cache)
  if there_dir == nil then
    local ok, trouble = sys.mkdir(cache, 0x140)
    if not ok then return nil, cache .. ": " .. trouble end
  end
  local ready, ready_trouble = owned(cache, 0x140)
  if not ready then return nil, ready_trouble end
  local copy = cache .. "/" .. name
  local function placed(path: string, data: string, mode: integer): boolean, string
    local staged = cache .. "/.staged-" .. tostring(sys.getpid())
    local ok, trouble = Fs.write(staged, data, mode)
    if ok then ok, trouble = owned(staged, mode) end
    if ok then ok, trouble = sys.rename(staged, path) end
    if not ok then
      local _, _ = sys.unlink(staged)
      return false, trouble
    end
    return true, ""
  end
  local there, _ = sys.lstat(copy)
  if there == nil or there.kind ~= "file" or there.uid ~= worker_id or
      there.mode & 0xfff ~= 0x140 then
    local data, read_trouble = Fs.read(core)
    if data == nil then return nil, read_trouble end
    if hashing.hex_sha256(data) ~= digest then return nil, core .. " is not the core it names" end
    local ok, trouble = placed(copy, data, 0x140)
    if not ok then return nil, trouble end
    there, _ = sys.lstat(copy)
  end
  if there == nil then return nil, copy .. " is not there" end
  -- The stamp core/startup.c's `stamp_line` writes of it: its size,
  -- inode, and modification and change seconds.
  local line = string.format("%d|%d|%d|%d\n", there.size, there.ino, there.mtime, there.ctime)
  local stamp = cache .. "/.verified-" .. name
  local stamped, _ = Fs.read(stamp)
  if stamped ~= line then
    local ok, trouble = placed(stamp, line, 0x100)
    if not ok then return nil, trouble end
  end
  -- The core a relaunch hands on as a descriptor, which the worker's
  -- startup holds to be the file it runs, is the copy too.
  local handed: Proc.Relaunch = nil
  if launched ~= nil then
    handed = { argv = launched.argv, env = launched.env, fds = {} }
    local fd, open_trouble = sys.open(copy, sys.O_RDONLY)
    if fd == nil then return nil, copy .. ": " .. open_trouble end
    -- The descriptor the relaunch's environment names the core's
    -- (core/startup.h's COSMIC_PORTABLE_ENV_CORE_FD).
    local core_fd = math.tointeger(tonumber(launched.env.COSMIC_PORTABLE_CORE_FD or ""))
    if core_fd == nil or launched.fds[core_fd] == nil then
      return nil, "the relaunch names no core descriptor"
    end
    for number, given in pairs(launched.fds) do
      handed.fds[number] = number == core_fd and fd or given
    end
  end
  return { copy = cache, cache = directory, start = handed }, ""
end

--- Whether this program starts, sandboxed, as `user`, with `cores` its
--- core ([`worker_cores`]): given /proc, /dev/null and that core alone,
--- it runs nothing and ends. Where the host refuses what a worker run as
--- that user takes -- a user namespace of that user's own (AppArmor's
--- kernel.apparmor_restrict_unprivileged_userns, a kernel that allows
--- none unprivileged), or a map written from outside -- every worker's
--- start would fail; so none is run so there, and each runs as root.
-- TODO: test the fallback on a host that refuses an unprivileged user
-- a user namespace, once CI has a leg run as root on one (doc/roadmap.md):
-- no host the suite runs on refuses one to 65532 but grants it to root.
local function starts_as(user: test_sandbox.User, cores: Cores): boolean, string
  local launched, _ = Proc.relaunch()
  local start: Proc.Relaunch = cores.start or launched
  local reads: {string} = {}
  local at: {string:string} = {}
  if start == nil then
    local executable, trouble = Proc.executable()
    if executable == nil then return false, trouble end
    start = { argv = { executable }, env = {}, fds = {} }
  end
  if cores.copy ~= "" then
    reads[#reads + 1] = cores.copy
    at[cores.copy] = cores.cache
  else
    reads[#reads + 1] = start.argv[1]
  end
  for _, path in ipairs({ "/proc", "/dev/null" }) do
    local there, _ = sys.stat(path)
    if there ~= nil then reads[#reads + 1] = path end
  end
  local argv: {string} = {}
  for i, word in ipairs(start.argv) do argv[i] = word end
  argv[#argv + 1] = "-e"
  argv[#argv + 1] = ""
  local fds: {integer:integer | string} = {}
  for number, fd in pairs(start.fds) do fds[number] = fd end
  local handle, trouble = Child.start(argv, { env = start.env, fds = fds, cwd = "/",
    stdin = "null", stdout = "capture", stderr = "stdout", process_group = false,
    sandbox = { unveil = { reads = reads, writes = {}, at = at }, offline = true,
      user = user.uid, group = user.gid } })
  if handle == nil then return false, trouble end
  local result, wait_trouble = handle:wait(30000)
  if result == nil then
    local _, _ = handle:close()
    return false, wait_trouble
  end
  if not result.ok then
    return false, "a start as " .. tostring(user.uid) .. " ended " ..
      tostring(result.code or result.signal) .. ": " .. (result.stdout or "")
  end
  return true, ""
end

--- Whether, and as whom, a sandboxed worker runs in place of this
--- process's own user: `worker_id`, as user and group, where this
--- process is root holding what mapping another user's ids takes
--- ([`confine.may_map_ids`]), its user namespace maps root and that
--- id -- the host's does, and a container's usual 65536 ids -- the
--- worker has a core it may run ([`worker_cores`]), and a start as that
--- user succeeds ([`starts_as`]). Such a worker gives root up for them
--- once its root is built, as core/process.h's `Sandbox.user` says, and
--- so confines what its test starts at any depth, as an unprivileged
--- runner's worker does -- where a worker left root would not, the
--- kernel refusing a user namespace to a child of its that is unmapped
--- -- and meets the permissions of the files it reads as such a worker
--- does. Its key holds it as that user
--- ([`declared_key.HostSources`]' `worker_uid`). Nil, and why, elsewhere,
--- the worker running as this process's user, as ever. Worked out
--- once.
local worker_user: test_sandbox.User = nil
local worker_trouble: string = nil
local worker_copy: Cores = { copy = "", cache = "" }
function test_sandbox.runs_as(): test_sandbox.User | nil, string
  if worker_trouble == nil then
    worker_trouble = "this process is not root, holding CAP_SETUID, CAP_SETGID and CAP_SETFCAP"
    if confine.may_map_ids() then
      worker_trouble = "this user namespace does not map root and " .. tostring(worker_id)
      if confine.maps_id(0) and confine.maps_id(worker_id) then
        local copy, trouble = worker_cores()
        worker_trouble = trouble
        if copy ~= nil then
          local user: test_sandbox.User = { uid = worker_id, gid = worker_id }
          local started, why = starts_as(user, copy)
          worker_trouble = why
          if started then
            worker_user = user
            worker_copy = copy
          end
        end
      end
    end
  end
  if worker_user ~= nil then return worker_user, "" end
  return nil, worker_trouble
end

--- The user and group a sandboxed worker of `effective` runs as
--- ([`runs_as`]), or nil for this process's own: that of a module that
--- declares a host cache too, which it writes as whoever keeps it.
-- TODO: run a worker that declares a host cache as `worker_id` too,
-- once each cache it writes is one that user may write -- a cache of
-- its own beside root's, as its cores are ([`worker_cores`]), or one
-- root keeps writable by a group of its own: today it runs as root,
-- and confines what its test starts only two deep.
function test_sandbox.worker_user(effective: test_inputs.Effective): test_sandbox.User | nil
  if #(effective.caches or {}) > 0 then return nil end
  local user, _ = test_sandbox.runs_as()
  return user
end

--- A sandboxed worker's environment: of `environment`, the runner's
--- view of a worker's ([`build.test`]'s `worker_environment`), the pinned
--- variables and those `effective` declares (all of them for `"*"`),
--- and TMPDIR, set to its scratch directory, the one it can write to.
function test_sandbox.environment(environment: {string:string},
                                  effective: test_inputs.Effective): {string:string}
  local out: {string:string} = {}
  if effective.env["*"] then
    for name, value in pairs(environment) do out[name] = value end
  else
    for name in pairs(effective.env) do out[name] = environment[name] end
  end
  out.TMPDIR = test_sandbox.scratch
  -- The cores of its own a worker that declares the `bootstrap` cache
  -- writes (`cache_writes`).
  for _, name in ipairs(effective.caches or {}) do
    if name == "bootstrap" then out.COSMIC_PORTABLE_CACHE = own_cores end
  end
  return out
end

--- The environment a worker keyed as a sandboxed one but run
--- unsandboxed is keyed by, with
--- `environment` the runner's view of a worker's: what `environment`
--- gives one of `effective`, but COSMIC_PORTABLE_CACHE as the view has
--- it. The cores of its own a sandbox gives it are at a path only a
--- sandbox has, and a process confined to them (build/c/init.tl's
--- compilers) would find no directory there and not start; nothing
--- here keeps it from writing over this program's core in the host's
--- anyway.
function test_sandbox.unenforced_view(environment: {string:string},
                                      effective: test_inputs.Effective): {string:string}
  local out = test_sandbox.environment(environment, effective)
  if out.COSMIC_PORTABLE_CACHE == own_cores then
    out.COSMIC_PORTABLE_CACHE = environment.COSMIC_PORTABLE_CACHE
  end
  return out
end

--- The environment such a worker is given: its key's
--- ([`unenforced_view`]), but with TMPDIR `scratch`, its own scratch
--- directory on the host, where the key names a sandbox's.
function test_sandbox.unenforced_environment(environment: {string:string},
                                             effective: test_inputs.Effective,
                                             scratch: string): {string:string}
  local out = test_sandbox.unenforced_view(environment, effective)
  out.TMPDIR = scratch
  return out
end

--- The host caches a sandboxed worker of `effective` writes, with
--- `environment` the runner's view of a worker's: each it declares
--- (`effective.cache_paths`) but the cores a portable cosmic extracts
--- ([`caches.cores`]), where this program's own core is. A core another
--- cosmic extracted there after the worker was held would be one it
--- could run however it was held, and one it could write over this
--- program's; so it has cores of its own instead (`own_cores`), and is
--- given the host's only to read, where its own core is.
function test_sandbox.cache_writes(effective: test_inputs.Effective,
                                   environment: {string:string}): {string}
  local cores = caches.cores(environment)
  local out: {string} = {}
  for _, path in ipairs(effective.cache_paths or {}) do
    if path ~= cores then out[#out + 1] = path end
  end
  return out
end

--- What of `path` lies beneath `dir` -- "" for `dir` itself, else the
--- rest from its "/" on -- or nil for a path not beneath it.
local function beneath(path: string, dir: string): string | nil
  if path == dir then return "" end
  if dir == "/" then return path:sub(1, 1) == "/" and path or nil end
  if String.starts_with(path, dir .. "/") then return path:sub(#dir + 1) end
  return nil
end

--- Whether a bind of another path of `reads` shows `path` already,
--- as its own bind would: each given where `at` places it, or at its
--- own name, with `path` beneath the other on the host, beneath its
--- place in the sandbox by the same rest, and resolving beneath where
--- the other resolves by that rest too -- no link on the way between
--- them, which the bind of the other would leave a link, to be followed
--- in the sandbox, where the bind of `path` resolves it.
local function shown_by(path: string, reads: {string}, at: {string:string}): boolean
  local placed = at[path] or path
  for _, other in ipairs(reads) do
    local rest = other ~= path and beneath(path, other) or nil
    if rest ~= nil and rest ~= "" and beneath(placed, at[other] or other) == rest then
      local real, other_real = confine.resolution(path), confine.resolution(other)
      if real ~= "" and other_real ~= "" and beneath(real, other_real) == rest then
        return true
      end
    end
  end
  return false
end

--- The name a sandboxed worker of the tree at `root` has this program
--- by, where the program is a portable artifact ([`Proc.relaunch`] names
--- its artifact's path, which the worker's startup takes as it is
--- given: core/startup.c's `cosmic_startup_adopt`), and whether that is
--- the tree's own, by where each resolves. The tree's own o/bin/cosmic
--- is /tree/o/bin/cosmic, where a worker whose module declares `tool`
--- has it, as it has the rest of o/bin. Another program keeps its own
--- name -- a release run on the tree -- but for one beneath /tree
--- itself, a run started in a sandboxed worker of another tree, whose
--- worker has a tree of its own there: it is given at
--- /program/<its name> instead (`program_place`). Nil where it
--- keeps its own name.
local function program_name(root: string): string | nil, boolean
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil or relaunch.argv[2] ~= "--artifact" then return nil, false end
  local program, _ = Proc.executable()
  if program == nil then return nil, false end
  local real = confine.resolution(program)
  if real ~= "" and real == confine.resolution(root .. "/o/bin/cosmic") then
    return test_sandbox.tree .. "/o/bin/cosmic", true
  end
  if Fs.within(program, test_sandbox.tree) then
    return program_place .. "/" .. Fs.basename(program), false
  end
  return nil, false
end

--- `path` with no "/" after it but for "/" itself.
local function trimmed(path: string): string
  local out = path:gsub("/+$", "")
  return out == "" and "/" or out
end

--- The sandbox a worker of the tree at `root` runs a test of the module
--- `effective` holds the inputs of in, its scratch directory `scratch`,
--- with the runner's view of a worker's environment `environment`, and
--- at o/cosmic.db the closure store at `closure_store`
--- ([`build.closure_store`]'s `write`) where the module does not declare
--- `store`, else the whole projection. A caller keys the store as it gives it
--- ([`build.declared_key`]): the whole projection by its contents only
--- where the module declares `store`, so it gives one that does not the
--- store of its closure, keyed by its bytes.
function test_sandbox.plan(root: string, scratch: string, effective: test_inputs.Effective,
                           environment: {string:string}, closure_store?: string): test_sandbox.Plan
  -- The program is given at its own name only where the worker does
  -- not have it as the tree's own, at /tree/o/bin/cosmic. A worker
  -- whose module does not declare `tool` has no name to read it by, so
  -- it keeps the runner's, which it cannot open either.
  local program, own_program: string | nil, boolean = nil, false
  if effective.tool then program, own_program = program_name(root) end
  local executable, _ = Proc.executable()
  local base = confine.worker_unveil(root, nil, scratch, effective.system,
    effective.tool and not own_program)
  local reads: {string} = {}
  local at: {string:string} = {}
  local seen: {string:boolean} = {}
  local function give(path: string, inside?: string)
    if seen[path] then return end
    local there, _ = sys.stat(path)
    if there == nil then return end -- a read of it finds nothing, as it would
    seen[path] = true
    reads[#reads + 1] = path
    if inside ~= nil then at[path] = inside end
  end
  -- A worker run as a user of its own (`worker_user`) has the core it
  -- runs from a copy that user may run ([`worker_cores`]), given in
  -- place of the cache it is in, where that is a launcher's: the core
  -- and its stamp in the cache are given no more.
  local user = test_sandbox.worker_user(effective)
  local in_cache = ""
  if user ~= nil and worker_copy.copy ~= "" then
    in_cache = worker_copy.cache
    give(worker_copy.copy, worker_copy.cache)
  end
  local store = root .. "/o/cosmic.db"
  -- The store at o/cosmic.db is the one its worker attaches to load
  -- every module of the closure ([`build.test_worker`]): `closure_store`
  -- where the module does not declare `store`, and the whole projection
  -- where it does.
  -- A worker can still learn where the host keeps what it is given:
  -- /proc/self/mountinfo names each bind's source, the tree's location,
  -- the scratch directory's and the program's among them. That stays:
  -- only a test that goes looking reads it, which the rule that no test
  -- depends on where the tree is already forbids (and CI's moved
  -- checkout catches), no procfs shows a mount's source as its target,
  -- and refusing mountinfo would take a Landlock rule on /proc files,
  -- which a program a test starts reads for honest reasons.
  local given_store = store
  if closure_store ~= nil and not effective.store then given_store = closure_store end
  for _, path in ipairs(base.reads) do
    if path == store then
      give(given_store, test_sandbox.tree .. "/o/cosmic.db")
    elseif path == executable and program ~= nil and not own_program then
      give(path, program)
    elseif in_cache == "" or Fs.dirname(path) ~= in_cache then
      give(path)
    end
  end
  local function of_tree(relative: string)
    local plain = test_inputs.plain(relative)
    if plain == "." then
      give(root, test_sandbox.tree)
    elseif plain:sub(1, 1) ~= "/" and plain:sub(1, 3) ~= "../" and plain ~= ".." then
      give(root .. "/" .. plain, test_sandbox.tree .. "/" .. plain)
    end
  end
  local files: {string} = {}
  for file in pairs(effective.files) do files[#files + 1] = file end
  table.sort(files)
  -- The closure's files, which the module's key holds already.
  for _, file in ipairs(files) do of_tree(file) end
  for _, relative in ipairs(effective.reads) do of_tree(relative) end
  -- The tool is o/bin/cosmic, given as the directory it is in: where
  -- it is the program, the worker has it there alone ([`program_name`]),
  -- and a test that starts [`Proc.executable()`] starts it there; another
  -- program is given at its own name too (`worker_unveil`'s
  -- `with_program`).
  if effective.tool then of_tree("o/bin") end
  -- Why a `host` path cannot be given: where a variable names it, one
  -- [`test_inputs.resolve`] could not put anywhere, or one that is where
  -- the sandbox has its own -- its scratch directory, which it gives
  -- at [`test_sandbox.scratch`], or /tree or that, over which a bind at its
  -- own name would go -- or above it: a variable's value, such as the
  -- host's temporary directory, above every test's scratch directory.
  local refused = effective.unresolved or ""
  for _, path in ipairs(effective.host) do
    if path:sub(1, 1) == "/" then
      local plain = test_inputs.plain(path)
      local declared = (effective.spelled or {})[plain]
      -- By its name and by where it resolves: a link to the host's
      -- temporary directory would bind all of it.
      local real = confine.resolution(plain)
      local own_real = confine.resolution(scratch)
      for _, where in ipairs({ plain, real }) do
        for _, own in ipairs({ scratch, own_real, test_sandbox.tree, test_sandbox.scratch }) do
          local mine = own == scratch or own == own_real
          if refused == "" and where ~= "" and own ~= "" and
              ((mine and Fs.within(where, own)) or Fs.within(own, where)) then
            refused = string.format("Test.needs host %q: %s is where its sandbox has %s",
              declared or path, plain, mine and "its scratch directory" or own)
          end
        end
      end
      give(trimmed(path))
    end
  end
  local writes: {string} = { scratch }
  at[scratch] = test_sandbox.scratch
  -- Each host cache the module declares, writable at its own name, made
  -- first where it is not there yet, so a fresh host has one to bind.
  local cache_writes = test_sandbox.cache_writes(effective, environment)
  local made, trouble = caches.make(cache_writes)
  -- Its own cores, made here, before the worker is held: a ruleset that
  -- keeps it from running this program walks the directories above the
  -- program as they are then, and where the program is beneath /tmp's
  -- name on the host, a directory made there after would run nothing.
  for _, name in ipairs(effective.caches or {}) do
    if name == "bootstrap" and made then
      local cores = scratch .. own_cores:sub(#test_sandbox.scratch + 1)
      local there, _ = sys.stat(cores)
      if there == nil then
        local ok, why = sys.mkdir(cores, 0x1c0) -- 0700, as the launcher makes a cache
        if not ok then made, trouble = false, cores .. ": " .. why end
      end
    end
  end
  for _, path in ipairs(cache_writes) do writes[#writes + 1] = path end
  -- A path given to read at its own name that a cache given to write
  -- holds already is not given again on top of it. Bound there, its
  -- mount point would be the host's own file, seen through the cache's
  -- bind, and a mount onto a file the host renames another over as it
  -- is made fails ENOENT (the kernel's lock_mount finds its dentry
  -- unlinked). This program's core and the stamp beside it would fail
  -- so if the cores directory were a cache given to write, since each
  -- start writes the stamp until one holds. The cache gives it.
  -- So too a path given to read inside another given to read, where
  -- the other's bind shows it already, at the same place and the same
  -- file ([`shown_by`]): a closure's source beneath a declared directory
  -- of the tree, a `host` path beneath the system's.
  -- TODO: bind a path given to write inside one given to read at a
  -- mount point of the sandbox's own (core/syscalls.c's build_root: the
  -- path bound first at a name in its tmpfs, then moved into place), so
  -- no mount point is the host's dentry: a cache declared beneath a
  -- `host` directory would meet the same ENOENT were the host to rename
  -- another over it as a worker starts, which nothing in a run does
  -- today.
  local given_reads: {string} = {}
  for _, path in ipairs(reads) do
    local held_by_cache = false
    if at[path] == nil then
      local real = confine.resolution(path)
      for _, cache in ipairs(cache_writes) do
        local cache_real = confine.resolution(cache)
        if Fs.within(path, cache) or (real ~= "" and cache_real ~= "" and
            Fs.within(real, cache_real)) then
          held_by_cache = true
        end
      end
    end
    if not held_by_cache then given_reads[#given_reads + 1] = path end
  end
  reads = {}
  for _, path in ipairs(given_reads) do
    if shown_by(path, given_reads, at) then
      at[path] = nil
    else
      reads[#reads + 1] = path
    end
  end
  -- Its scratch directory its user's, which it writes.
  if user ~= nil then
    for _, path in ipairs({ scratch, scratch .. "/real" }) do
      local owned, why = sys.chown(path, user.uid, user.gid)
      if not owned and refused == "" then refused = path .. ": " .. why end
    end
  end
  local over = math.max(0, #reads + #writes - UNVEIL_MAX)
  -- Offline, always: a module declares only loopback addresses, which
  -- the worker's own loopback answers as the host's would. Keying it is
  -- sound so:
  --
  -- - a new network namespace reaches only the worker's own processes,
  --   and an abstract unix socket is its namespace's alone
  --   (core/process.h's `Sandbox`), so what a test reaches there is
  --   what it started; and
  -- - its `lo` carries 127/8, so a connection to a closed port there
  --   (127.0.0.1:1, 127.0.0.2:1) is refused as on the host's, and a bind
  --   finds no host listener or socket in TIME_WAIT in its way.
  --
  -- A test that needed a service of the host's on its loopback fails,
  -- rather than standing on a verdict that service gave.
  return {
    sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = true,
      user = user ~= nil and user.uid or nil, group = user ~= nil and user.gid or nil },
    env = test_sandbox.environment(environment, effective),
    over = over,
    trouble = refused ~= "" and refused or made and "" or "a cache it declares: " .. trouble,
    program = program,
    start = user ~= nil and worker_copy.start or nil,
  }
end

--- Whether a worker given `writes` to write -- the host caches its
--- module declares, as `cache_writes` gives them -- can be kept from
--- running `programs`, this very program ([`confine.forbid_running`]):
--- not where one of them is beneath a path it may write, by its name or
--- where it resolves -- where COSMIC_PORTABLE_CACHE names a directory
--- beneath another cache, say -- since a core another cosmic extracts
--- there after the worker holds itself could not be run.
function test_sandbox.forbiddable(writes: {string}, programs: {string}): boolean
  for _, path in ipairs(writes) do
    local writable = confine.resolution(path)
    for _, program in ipairs(programs) do
      local real = confine.resolution(program)
      if Fs.within(program, path) or (real ~= "" and writable ~= "" and
          Fs.within(real, writable)) then
        return false
      end
    end
  end
  return true
end

--- Why a sandboxed start failed with `trouble`: said plainly where the
--- kernel refuses a user namespace, else `trouble` as it is. The kernel
--- refuses where none may be made (ENOSPC: user.max_user_namespaces is
--- 0), where none is allowed this user (EPERM or EACCES: a container's
--- seccomp profile, AppArmor's
--- kernel.apparmor_restrict_unprivileged_userns), or, for EPERM, where this process is held by a Landlock ruleset, whose
--- domain refuses every mount. That is a run started in a test worker's
--- process whose environment dropped [`confine.held_variable`], which
--- would have named it.
function test_sandbox.refusal(trouble: string): string
  local why: string = nil
  if trouble:find("No space left on device", 1, true) then
    why = "this host allows no user namespaces (user.max_user_namespaces is 0)"
  elseif trouble:find("Operation not permitted", 1, true) or
      trouble:find("Permission denied", 1, true) then
    why = "this host refuses this user a user namespace (a container's seccomp " ..
      "profile, or kernel.apparmor_restrict_unprivileged_userns)"
    if trouble:find("Operation not permitted", 1, true) then
      why = why .. ", or this process is held by a Landlock ruleset: declare " ..
        "`nests = true` in the starting test's Test.needs"
    end
  end
  if why == nil then return trouble end
  return why .. " (" .. trouble .. ")"
end

return test_sandbox
