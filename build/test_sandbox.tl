--- A test worker run sandboxed: with `COSMIC_TEST_SANDBOX=1`, `cosmic
--- test` starts each worker through `cosmic.child`'s `sandbox`, held to
--- its test's effective inputs (`build.test_inputs`) and what the
--- runtime needs to run it at all, with every process it starts. Off by
--- default: nothing is enforced unless the switch is on.
---
--- What a sandboxed worker has (`test_sandbox.plan`):
---
--- - the tree at `test_sandbox.tree`, /tree, wherever the host keeps
---   it, and its working directory there, holding only its store
---   (o/cosmic.db), its module's import closure as source files, the
---   fuzz corpora for a module that uses `build.fuzz`, and what the
---   module declares it `reads`, with o/bin for one that declares `tool`
---   -- each read-only;
--- - its scratch directory at `test_sandbox.scratch`, /tmp, writable:
---   the test's own directory (/tmp/tmp, a link to /tmp/real), where
---   the processes it starts write their coverage (/tmp/children), and
---   its TMPDIR;
--- - the host caches the module declares (`build.caches`), writable,
---   each at its own name, made first where missing, and the variables
---   that locate them;
--- - the system's own paths, the program, its core and the stamp that
---   says the core was verified (`observations.worker_unveil`), and the
---   `host` paths the module declares, each at its own name;
--- - no network but a loopback, unless the module declares `network`;
--- - the pinned environment and the variables it declares, `"*"` for
---   all of the runner's (`environment`).
---
--- A read of anything else finds nothing. The worker is pid 2 of a pid
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
    --- not be made -- or "".
    trouble: string
    --- The paths given at their own names beneath /tree or /tmp, where
    --- the tree and the scratch directory are bound: each is the host's
    --- own there, bound over them, so a read of it stays where it is
    --- (`to_host`).
    kept: {string}
  end
end

test_sandbox.tree = "/tree"
test_sandbox.scratch = "/tmp"
test_sandbox.switch = "COSMIC_TEST_SANDBOX"

--- The most paths a sandbox unveils (core/process.h's UNVEIL_MAX).
local UNVEIL_MAX <const> = observations.unveil_max

--- Whether the switch is on: `COSMIC_TEST_SANDBOX` set to "1". Unset,
--- empty or "0", it is off; any other value is an error, so a misspelt
--- one never passes for either.
function test_sandbox.enabled(): boolean | nil, string
  local value = Env.get(test_sandbox.switch)
  if value == nil or value == "" or value == "0" then return false, "" end
  if value == "1" then return true, "" end
  return nil, string.format("%s is %q: set it to 1, or leave it unset", test_sandbox.switch,
    value)
end

--- The variables a worker is given whatever its module declares, beside
--- the pinned ones: COSMIC_SANDBOX, which says how a test's own
--- processes are confined (`observations.must_confine`).
local carried: {string} = { "COSMIC_SANDBOX" }

--- A sandboxed worker's environment: of `environment`, the runner's
--- view of a worker's (`build.test`'s `worker_environment`), the pinned
--- variables, those `effective` declares -- all of them for `"*"` --
--- and `carried`; and TMPDIR, whatever the host's, its scratch
--- directory, the one it can write to.
function test_sandbox.environment(environment: {string:string},
                                  effective: test_inputs.Effective): {string:string}
  local out: {string:string} = {}
  if effective.env["*"] then
    for name, value in pairs(environment) do out[name] = value end
  else
    for name in pairs(effective.env) do out[name] = environment[name] end
    for _, name in ipairs(carried) do out[name] = environment[name] end
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
--- with the runner's view of a worker's environment `environment`.
function test_sandbox.plan(root: string, scratch: string, effective: test_inputs.Effective,
                           environment: {string:string}): test_sandbox.Plan
  local base = observations.worker_unveil(root, nil, scratch)
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
  local store = root .. "/o/cosmic.db"
  -- TODO: bind the program at /tree/o/bin/cosmic where it is the tree's
  -- own, as the rest of the tree is, once the relaunch contract lets the
  -- runner name the artifact's path to the worker (core/startup.c):
  -- today it is given at its own name, which `Proc.executable()` answers,
  -- so a worker still sees where the host keeps the checkout there.
  -- The projection is given whatever `store` says: the worker attaches
  -- it to load every module of the closure (`build.test_worker`), and
  -- `store` declares a test's own open of it besides.
  -- TODO: hide from a worker where the host keeps what it is given:
  -- /proc/self/mountinfo names each bind's source, the tree's location,
  -- the scratch directory's and the program's among them. Wants a
  -- procfs that shows a mount's source as its target (none does), or
  -- mountinfo refused to a test (a Landlock rule on /proc files).
  -- TODO: bind a store derived from the module's import closure at
  -- /tree/o/cosmic.db in place of the whole projection, once the build
  -- derives one (cosmic/test.tl's TODO on `store`): the bind is this
  -- one path's, and nothing else of the plan changes.
  for _, path in ipairs(base.reads) do
    if path == store then give(path, test_sandbox.tree .. "/o/cosmic.db") else give(path) end
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
  for _, file in ipairs(files) do of_tree(file) end
  for _, relative in ipairs(effective.reads) do of_tree(relative) end
  -- The tool is o/bin/cosmic, given as the directory it is in: the
  -- program itself is given at its own name already (`itself`), which a
  -- test that starts `Proc.executable()` needs.
  if effective.tool then of_tree("o/bin") end
  for _, path in ipairs(effective.host) do
    if path:sub(1, 1) == "/" then give(trimmed(path)) end
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
  local over = math.max(0, #reads + #writes - UNVEIL_MAX)
  -- TODO: keep a worker that declares only loopback hosts (127.0.0.1,
  -- ::1, localhost) offline, whose loopback reaches them, rather than
  -- give it the host's network.
  local offline = next(effective.network) == nil
  return {
    sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = offline },
    env = test_sandbox.environment(environment, effective),
    over = over,
    trouble = made and "" or "a cache it declares: " .. trouble,
    kept = kept,
  }
end

--- `path` as the host has it, for one a sandboxed worker of the tree at
--- `root`, its scratch directory `scratch`, saw: one at or beneath
--- /tree or /tmp, where the sandbox bound them, beneath `root` or
--- `scratch` -- but one beneath a path of `kept`, bound at its own name
--- over them -- and any other where the host has it already.
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

--- What a sandboxed worker of the tree at `root`, its scratch directory
--- `scratch`, reported it read, each path where the host has it
--- (`host_path`): the path of every observation but a variable's, the
--- answer of one whose answer is a path, and a realpath's. `kept` is
--- the plan's (`Plan.kept`), nil for none.
function test_sandbox.to_host(reads: {observations.Observation}, root: string,
                              scratch: string, kept?: {string}): {observations.Observation}
  local out: {observations.Observation} = {}
  local own = kept or {}
  for i, observation in ipairs(reads) do
    local kind, path, answer = observation.kind, observation.path, observation.answer
    if kind ~= "e" and path:sub(1, 1) == "/" then
      path = host_path(path, root, scratch, own)
    end
    if resolution_kinds[kind] and answer:sub(1, 1) == "/" then
      answer = host_path(answer, root, scratch, own)
    elseif kind == "a" and answer:sub(1, 4) == "ok /" then
      answer = "ok " .. host_path(answer:sub(4), root, scratch, own)
    end
    out[i] = { kind = kind, path = path, answer = answer }
  end
  return out
end

--- Whether this host can run a worker sandboxed: `argv`, this program
--- started again with `env` and `fds`, runs a chunk that does nothing,
--- held to the least a worker is given -- the system's own paths and
--- the program -- offline, in `scratch`. False and why where it cannot.
function test_sandbox.available(argv: {string}, env: {string:string}, fds: {integer:integer},
                                scratch: string): boolean, string
  local base = observations.worker_unveil(scratch, nil, scratch)
  local command: {string} = {}
  for i, word in ipairs(argv) do command[i] = word end
  command[#command + 1] = "-e"
  command[#command + 1] = ""
  local given: {integer:integer | string} = {}
  for number, fd in pairs(fds) do given[number] = fd end
  -- Started and waited for, not `Child.run`, which would take the one
  -- signal guard a caller running tests in-process may hold.
  local handle, trouble = Child.start(command, { env = env, fds = given,
    cwd = test_sandbox.scratch, stdin = "null", stdout = "capture", stderr = "stdout",
    sandbox = { unveil = { reads = base.reads, writes = { scratch },
      at = { [scratch] = test_sandbox.scratch } }, offline = true } })
  if handle == nil then return false, trouble end
  -- Past the bound, `wait` ends it and its group, and its pid
  -- namespace with it; `close` makes sure of it if the wait failed.
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
