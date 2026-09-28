--- A test worker run sandboxed: `cosmic test` starts each worker
--- through `cosmic.child`'s `sandbox`, held to its test's effective
--- inputs (`build.test_inputs`) and what the runtime needs to run it at
--- all, with every process it starts, wherever this host can sandbox
--- one (`available`). `COSMIC_TEST_SANDBOX` chooses (`mode`): unset,
--- each worker is sandboxed where one can be and runs unsandboxed where
--- none can (macOS, a host that refuses user namespaces); "1" requires
--- it, and the run fails where none can be; "0" turns it off.
---
--- What a sandboxed worker has (`test_sandbox.plan`):
---
--- - the tree at `test_sandbox.tree`, /tree, wherever the host keeps
---   it, and its working directory there, holding only its store at
---   o/cosmic.db -- the store of its module's import closure
---   (`build.closure_store`'s `write`), or the whole projection for a
---   module that declares `store` -- its module's import closure as
---   source files, the fuzz corpora for a module that uses
---   `build.fuzz`, and what the module declares it `reads`, with o/bin
---   for one that declares `tool` -- each read-only;
--- - its scratch directory at `test_sandbox.scratch`, /tmp, writable:
---   the test's own directory (/tmp/tmp, a link to /tmp/real), where
---   the processes it starts write their coverage (/tmp/children), and
---   its TMPDIR;
--- - the host caches the module declares (`build.caches`), writable,
---   each at its own name, made first where missing, and the variables
---   that locate them;
--- - /proc and the devices every program takes for granted, the
---   program's core and the stamp that says the core was verified, and
---   the program itself only for a module that declares `tool`
---   (`confine.worker_unveil`), the system's own paths (/usr, /bin,
---   /lib, /etc and the like) only where the module declares `system`,
---   and the `host` paths the module declares, each at its own name --
---   one a variable names (`$NAME/path`) where the variable says, as
---   `test_inputs.resolve` put it, refused where that is the tree's,
---   the scratch directory's, or above either;
--- - no network but a loopback, unless the module declares `network`
---   beyond loopback hosts (`test_inputs.offline`);
--- - the pinned environment and the variables it declares, `"*"` for
---   all of the runner's (`environment`).
---
--- A read of anything else finds nothing, and so does one of every
--- process the worker starts, which has the worker's sandbox and no
--- more: what a test declares for itself it declares for them.
--- The worker is pid 2 of a pid
--- namespace of its own, whose init ends when it does, ending whatever
--- it left running there: no descendant of a sandboxed worker outlives
--- it. Its verdict is keyed by what it was given (`build.declared_key`),
--- not by what it read. What the worker reports, it reports as it saw
--- it, at /tree and /tmp; `to_host` puts each path back where the host
--- has it, for the audit of what it read and for its `runs` row.

local Child = require("cosmic.child")
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

--- A sandboxed worker's environment: of `environment`, the runner's
--- view of a worker's (`build.test`'s `worker_environment`), the pinned
--- variables, those `effective` declares -- all of them for `"*"`; and
--- TMPDIR, whatever the host's, its scratch
--- directory, the one it can write to.
function test_sandbox.environment(environment: {string:string},
                                  effective: test_inputs.Effective): {string:string}
  local out: {string:string} = {}
  if effective.env["*"] then
    for name, value in pairs(environment) do out[name] = value end
  else
    for name in pairs(effective.env) do out[name] = environment[name] end
  end
  out.TMPDIR = test_sandbox.scratch
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
  -- TODO: hide from a worker where the host keeps what it is given:
  -- /proc/self/mountinfo names each bind's source, the tree's location,
  -- the scratch directory's and the program's among them. Wants a
  -- procfs that shows a mount's source as its target (none does), or
  -- mountinfo refused to a test (a Landlock rule on /proc files).
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
  local made, trouble = caches.make(effective.cache_paths or {})
  for _, path in ipairs(effective.cache_paths or {}) do writes[#writes + 1] = path end
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
  -- Offline, too, where every host declared is a loopback one, which
  -- the worker's own loopback answers as the host's would: the answer
  -- `declared_key.keyable` takes, which must be this one.
  local offline = test_inputs.offline(effective)
  return {
    sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = offline },
    env = test_sandbox.environment(environment, effective),
    over = over,
    trouble = refused ~= "" and refused or made and "" or "a cache it declares: " .. trouble,
    kept = kept,
    held = held,
    made = made_dirs,
  }
end

--- Whether a worker given `writes` to write -- the host caches its
--- module declares -- can be kept from running `programs`, this very
--- program (`confine.forbid_running`): not where one of them is
--- beneath a path it may write, by its name or where it resolves -- the
--- cores directory a portable cosmic extracts to, which the `bootstrap`
--- cache holds -- since a core another cosmic extracts there after the
--- worker holds itself could not be run.
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

--- Why a sandboxed start failed with `trouble`, said plainly where it
--- is the kernel refusing a user namespace -- none may be made (ENOSPC:
--- user.max_user_namespaces is 0), or none for this user (EPERM or
--- EACCES: a container's seccomp profile, AppArmor's
--- kernel.apparmor_restrict_unprivileged_userns) -- and `trouble` as it
--- is otherwise.
function test_sandbox.refusal(trouble: string): string
  local why: string = nil
  if trouble:find("No space left on device", 1, true) then
    why = "this host allows no user namespaces (user.max_user_namespaces is 0)"
  elseif trouble:find("Operation not permitted", 1, true) or
      trouble:find("Permission denied", 1, true) then
    why = "this host refuses this user a user namespace (a container's seccomp " ..
      "profile, or kernel.apparmor_restrict_unprivileged_userns)"
  end
  if why == nil then return trouble end
  return why .. " (" .. trouble .. ")"
end

--- Whether this host can run a worker sandboxed: `argv`, this program
--- started again with `env` and `fds`, runs a chunk that holds itself
--- to running anything but this program, as a worker whose test does not
--- declare `tool` does (`confine.forbid_running`), held to the
--- least a worker is given -- /proc, the devices and the program, none
--- of the system's own paths -- offline, in `scratch`. False and why
--- where it cannot: no worker then runs sandboxed, and no verdict is
--- keyed by its declared inputs.
function test_sandbox.available(argv: {string}, env: {string:string}, fds: {integer:integer},
                                scratch: string): boolean, string
  local base = confine.worker_unveil(scratch, nil, scratch)
  local command: {string} = {}
  for i, word in ipairs(argv) do command[i] = word end
  -- As a worker whose test does not declare `tool` holds itself
  -- (`confine.forbid_running`): where it cannot, no worker is
  -- sandboxed, since what such a test would run no key holds.
  command[#command + 1] = "-e"
  command[#command + 1] = "local o = require('build.confine') " ..
    "local ok, why = o.forbid_running(o.itself()) if not ok then error(why) end"
  local given: {integer:integer | string} = {}
  for number, fd in pairs(fds) do given[number] = fd end
  -- Started and waited for, not `Child.run`, which would take the one
  -- signal guard a caller running tests in-process may hold.
  -- No group of its own to end, nor strays to adopt: its sandbox gives
  -- it a pid namespace of its own, which ends when it does.
  local handle, trouble = Child.start(command, { env = env, fds = given,
    cwd = test_sandbox.scratch, stdin = "null", stdout = "capture", stderr = "stdout",
    process_group = false, sandbox = { unveil = { reads = base.reads, writes = { scratch },
      at = { [scratch] = test_sandbox.scratch } }, offline = true } })
  if handle == nil then return false, test_sandbox.refusal(trouble) end
  -- Past the bound, `wait` ends it, and its pid namespace with it;
  -- `close` makes sure of it if the wait failed.
  local result, wait_trouble = handle:wait(30000)
  if result == nil then
    local _, _ = handle:close()
    return false, wait_trouble
  end
  if result.timed_out then return false, "a sandboxed start of this program took 30 s" end
  if not result.ok then
    local said = (result.stdout or ""):gsub("%s+$", "")
    return false, "a sandboxed start of this program " ..
      (result.signal ~= nil and ("was killed by signal " .. tostring(result.signal)) or
        ("exited " .. tostring(result.code))) .. (said ~= "" and (": " .. said) or "")
  end
  return true, ""
end

--- A fresh directory to probe the sandbox in (`available`), removed by
--- the caller.
function test_sandbox.probe_directory(): string | nil, string
  local made, trouble = Fs.mkdtemp("cosmic-sandbox-probe-")
  if made == nil then return nil, trouble end
  return Fs.absolute(made)
end

return test_sandbox
