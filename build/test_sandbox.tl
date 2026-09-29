--- A test worker run sandboxed: `cosmic test` starts each worker
--- through `cosmic.child`'s `sandbox`, held to its test's effective
--- inputs (`build.test_inputs`) and what the runtime needs to run it at
--- all, with every process it starts, wherever this host can sandbox
--- one (`build.test_sandbox_probe`). `COSMIC_TEST_SANDBOX` chooses (`mode`): unset,
--- each worker is sandboxed where one can be and runs unsandboxed where
--- none can (macOS, a host that refuses user namespaces); "1" requires
--- it, and the run fails where none can be; "0" turns it off.
---
--- What a sandboxed worker has (`test_sandbox.plan`):
---
--- - the tree at `test_sandbox.tree`, /tree, wherever the host keeps
---   it, and its working directory there. Each read-only, it holds only
---   the store at o/cosmic.db (the store of its module's import closure,
---   `build.closure_store`'s `write`, or the whole projection for a
---   module that declares `store`), its module's import closure as
---   source files, the fuzz corpora for a module that uses
---   `build.fuzz`, what the module declares it `reads`, and o/bin for
---   one that declares `tool`;
--- - its scratch directory at `test_sandbox.scratch`, /tmp, writable:
---   the test's own directory (/tmp/tmp, a link to /tmp/real), where
---   the processes it starts write their coverage (/tmp/children), and
---   its TMPDIR;
--- - the host caches the module declares (`build.caches`), writable,
---   each at its own name, made first where missing, and the variables
---   that locate them -- but for the cores a portable cosmic extracts,
---   where the program's own core is: for the `bootstrap` cache, the
---   worker has cores of its own in its scratch directory
---   (`cache_writes`);
--- - /proc and the devices every program takes for granted, the
---   program's core and the stamp that says the core was verified, and
---   the program itself only for a module that declares `tool`
---   (`confine.worker_unveil`), the system's own paths (/usr, /bin,
---   /lib, /etc and the like) only where the module declares `system`,
---   and the `host` paths the module declares, each at its own name --
---   one a variable names (`$NAME/path`) where the variable says, as
---   `test_inputs.resolve` put it, refused where that is the tree's,
---   the scratch directory's, or above either;
--- - no network but a loopback of its own, which answers the loopback
---   addresses a module may declare (`cosmic.test`'s `network`), as the
---   host's would;
--- - the pinned environment and the variables it declares, `"*"` for
---   all of the runner's (`environment`).
---
--- A read of anything else finds nothing, and so does one of every
--- process the worker starts, which has the worker's sandbox and no
--- more: what a test declares for itself it declares for them.
---
--- The worker is pid 2 of a pid namespace of its own, whose init ends
--- when it does, ending whatever it left running there: no descendant of
--- a sandboxed worker outlives it. Its verdict is keyed by what it was
--- given (`build.declared_key`), not by what it read. What the worker reports, it reports as it saw
--- it, at /tree and /tmp; `to_host` puts each path back where the host
--- has it, for the audit of what it read and for its `runs` row.

local type Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")
local caches = require("build.caches")

local record test_sandbox
  --- Where a sandboxed worker has the tree, and runs.
  tree: string
  --- Where it has its scratch directory.
  scratch: string
  --- The variable that turns the sandbox on.
  switch: string

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
    --- The paths given at their own names beneath /tree or /tmp, where
    --- the tree and the scratch directory are bound: each is the host's
    --- own there, bound over them, so a read of it stays where it is
    --- (`to_host`).
    kept: {string}
    --- What a process the worker starts can read of what it was given,
    --- as the worker sees each path, for the key of a test that starts
    --- one (`observations.Resolving`'s `held`): the runtime's paths, the
    --- system's where the module declares `system`, the program, and
    --- what the module declares of the tree and the
    --- host, and the store it is given -- not its closure's files, which
    --- its module's key holds already.
    held: {string}
    --- The directories of the tree the sandbox makes to hold what it
    --- gives beneath them, at /tree and below, each by the name the
    --- worker sees it by, which it holds only part of the host's (see
    --- `to_host`).
    made: {string}
  end
end

test_sandbox.tree = "/tree"
test_sandbox.scratch = "/tmp"
test_sandbox.switch = "COSMIC_TEST_SANDBOX"

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

--- A sandboxed worker's environment: of `environment`, the runner's
--- view of a worker's (`build.test`'s `worker_environment`), the pinned
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

--- The host caches a sandboxed worker of `effective` writes, with
--- `environment` the runner's view of a worker's: each it declares
--- (`effective.cache_paths`) but the cores a portable cosmic extracts
--- (`caches.cores`), where this program's own core is. A core another
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

--- `path` with no "/" after it but for "/" itself.
local function trimmed(path: string): string
  local out = path:gsub("/+$", "")
  return out == "" and "/" or out
end

--- The sandbox a worker of the tree at `root` runs a test of the module
--- `effective` holds the inputs of in, its scratch directory `scratch`,
--- with the runner's view of a worker's environment `environment`, and
--- at o/cosmic.db the closure store at `closure_store`
--- (`build.closure_store`'s `write`) where the module does not declare
--- `store`, else the whole projection. A caller keys the store as it gives it
--- (`build.declared_key`): the whole projection by its contents only
--- where the module declares `store`, so it gives one that does not the
--- store of its closure, keyed by its address.
function test_sandbox.plan(root: string, scratch: string, effective: test_inputs.Effective,
                           environment: {string:string}, closure_store?: string): test_sandbox.Plan
  local base = confine.worker_unveil(root, nil, scratch, effective.system, effective.tool)
  local reads: {string} = {}
  local at: {string:string} = {}
  local seen: {string:boolean} = {}
  local held: {string} = {}
  local holds: {string:boolean} = {}
  -- `holding`: whether a process the worker starts is keyed by it too --
  -- there or not: a path it may read that is not there yet is keyed as
  -- missing, so its verdict moves once the path is made.
  local function give(path: string, inside?: string, holding?: boolean)
    local name = inside or path
    if holding and not holds[name] then
      holds[name] = true
      held[#held + 1] = name
    end
    if seen[path] then return end
    local there, _ = sys.stat(path)
    if there == nil then return end -- a read of it finds nothing, as it would
    seen[path] = true
    reads[#reads + 1] = path
    if inside ~= nil then at[path] = inside end
  end
  local store = root .. "/o/cosmic.db"
  -- TODO: bind the program at /tree/o/bin/cosmic where it is the tree's
  -- own, as the rest of the tree is, once the relaunch contract lets the
  -- runner name the artifact's path to the worker (core/startup.c):
  -- today it is given at its own name, which `Proc.executable()` answers,
  -- so a worker still sees where the host keeps the checkout there.
  -- The store at o/cosmic.db is the one its worker attaches to load
  -- every module of the closure (`build.test_worker`): `closure_store`
  -- where the module does not declare `store`, and the whole projection
  -- where it does. Either is held for a process the worker starts,
  -- which reads what the worker could.
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
      give(given_store, test_sandbox.tree .. "/o/cosmic.db", true)
    else
      give(path, nil, true)
    end
  end
  local function of_tree(relative: string, holding: boolean)
    local plain = test_inputs.plain(relative)
    if plain == "." then
      give(root, test_sandbox.tree, holding)
    elseif plain:sub(1, 1) ~= "/" and plain:sub(1, 3) ~= "../" and plain ~= ".." then
      give(root .. "/" .. plain, test_sandbox.tree .. "/" .. plain, holding)
    end
  end
  local files: {string} = {}
  for file in pairs(effective.files) do files[#files + 1] = file end
  table.sort(files)
  -- The closure's files, which the module's key holds already.
  for _, file in ipairs(files) do of_tree(file, false) end
  for _, relative in ipairs(effective.reads) do of_tree(relative, true) end
  -- The tool is o/bin/cosmic, given as the directory it is in: the
  -- program itself is given at its own name already (`worker_unveil`'s
  -- `with_program`), which a test that starts `Proc.executable()` needs.
  if effective.tool then of_tree("o/bin", true) end
  -- Why a `host` path cannot be given: where a variable names it, one
  -- `test_inputs.resolve` could not put anywhere, or one that is where
  -- the sandbox has its own -- its scratch directory, which it gives
  -- at /tmp, or /tree or /tmp themselves, over which a bind at its
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
      give(trimmed(path), nil, true)
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
  -- start writes the stamp until one holds. The key still holds the
  -- path (`held`), and the cache gives it.
  -- TODO: bind each path given inside another at a mount point of the
  -- sandbox's own (core/syscalls.c's build_root: the file bound first at
  -- a name in its tmpfs, then moved into place), so no mount point is the
  -- host's dentry: a file given inside a directory given to read -- a
  -- closure's source beneath a declared directory of the tree -- would
  -- meet the same ENOENT were the host to rename another over it as a
  -- worker starts, which nothing in a run does today.
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
  reads = given_reads
  local kept: {string} = {}
  for _, list in ipairs({ reads, writes }) do
    for _, path in ipairs(list) do
      if at[path] == nil and (Fs.within(path, test_sandbox.tree) or
          Fs.within(path, test_sandbox.scratch)) then
        kept[#kept + 1] = path
      end
    end
  end
  -- Each directory between /tree and a path given beneath it, but for
  -- one that is itself given, or is beneath one.
  local made_dirs: {string} = {}
  local seen_made: {string:boolean} = {}
  local given_inside: {string} = {}
  for _, inside in pairs(at) do given_inside[#given_inside + 1] = inside end
  local function given_whole(dir: string): boolean
    for _, inside in ipairs(given_inside) do
      if Fs.within(dir, inside) then return true end
    end
    return false
  end
  for _, inside in ipairs(given_inside) do
    local dir = inside
    while Fs.within(dir, test_sandbox.tree) and dir ~= test_sandbox.tree do
      dir = Fs.dirname(dir)
      if not seen_made[dir] and not given_whole(dir) then
        seen_made[dir] = true
        made_dirs[#made_dirs + 1] = dir
      end
    end
  end
  table.sort(made_dirs)
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
    sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = true },
    env = test_sandbox.environment(environment, effective),
    over = over,
    trouble = refused ~= "" and refused or made and "" or "a cache it declares: " .. trouble,
    kept = kept,
    held = held,
    made = made_dirs,
  }
end

--- Whether a worker given `writes` to write -- the host caches its
--- module declares, as `cache_writes` gives them -- can be kept from
--- running `programs`, this very program (`confine.forbid_running`):
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

--- `path` as the host has it, for one a sandboxed worker of the tree at
--- `root`, its scratch directory `scratch`, saw: one at or beneath
--- /tree or /tmp, where the sandbox bound them, beneath `root` or
--- `scratch` -- but one beneath a path of `kept`, bound at its own name
--- over them -- and any other where the host has it already.
-- TODO: put a read beside a host path given beneath /tmp back where
-- the host has it, once the scratch directory is given at a name no
-- host path can be beneath (a mount point of the sandbox's own, not
-- /tmp): today it is put back in the scratch directory, whose own it
-- could as well be, and a sandboxed failure does not name it;
-- `COSMIC_TEST_SANDBOX=0 cosmic test --audit` names it as it is.
local function host_path(path: string, root: string, scratch: string, kept: {string}): string
  for _, own in ipairs(kept) do
    if Fs.within(path, own) then return path end
  end
  for _, pair in ipairs({ { test_sandbox.tree, root }, { test_sandbox.scratch, scratch } }) do
    local inside, outside = pair[1], pair[2]
    if path == inside then return outside end
    if path:sub(1, #inside + 1) == inside .. "/" then
      return outside .. path:sub(#inside + 1)
    end
  end
  return path
end

--- The kinds whose answer is a path, which moves with it: what a read
--- resolved to ("r", "t", "v", "w").
local resolution_kinds: {string:boolean} = { r = true, t = true, v = true, w = true }

--- One observation of a sandboxed worker's, where the host has it
--- (`to_host`).
local function moved(observation: observations.Observation, root: string, scratch: string,
                     own: {string}): observations.Observation
  local kind, path, answer = observation.kind, observation.path, observation.answer
  if kind ~= "e" and path:sub(1, 1) == "/" then
    path = host_path(path, root, scratch, own)
  end
  if resolution_kinds[kind] and answer:sub(1, 1) == "/" then
    answer = host_path(answer, root, scratch, own)
  elseif kind == "a" and answer:sub(1, 4) == "ok /" then
    answer = "ok " .. host_path(answer:sub(4), root, scratch, own)
  end
  return { kind = kind, path = path, answer = answer }
end

--- What a sandboxed worker of the tree at `root`, its scratch directory
--- `scratch`, reported it read, each path where the host has it
--- (`host_path`): the path of every observation but a variable's, the
--- answer of one whose answer is a path, and a realpath's. `kept` is
--- the plan's (`Plan.kept`), nil for none. A stat or an lstat of a
--- directory the sandbox made (`Plan.made`, nil for none) is left out:
--- what it answers -- the sandbox's own inode, device and times, and
--- the entries given there -- is none of the host's, and turns on what
--- the module declares, which its key holds.
function test_sandbox.to_host(reads: {observations.Observation}, root: string,
                              scratch: string, kept?: {string},
                              made?: {string}): {observations.Observation}
  local out: {observations.Observation} = {}
  local own = kept or {}
  local synthetic: {string:boolean} = {}
  for _, dir in ipairs(made or {}) do synthetic[dir] = true end
  for _, observation in ipairs(reads) do
    local kind, path = observation.kind, observation.path
    if (kind == "s" or kind == "l") and synthetic[test_inputs.plain(path)] then
      -- A directory the sandbox made: none of the host's.
    else
      out[#out + 1] = moved(observation, root, scratch, own)
    end
  end
  return out
end

--- Why a sandboxed start failed with `trouble`: said plainly where the
--- kernel refuses a user namespace, else `trouble` as it is. The kernel
--- refuses where none may be made (ENOSPC: user.max_user_namespaces is
--- 0), where none is allowed this user (EPERM or EACCES: a container's
--- seccomp profile, AppArmor's
--- kernel.apparmor_restrict_unprivileged_userns), or, for EPERM, where this process is held by a Landlock ruleset, whose
--- domain refuses every mount. That is a run started in a test worker's
--- process whose environment dropped `confine.held_variable`, which
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
