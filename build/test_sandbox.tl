--- A test worker run sandboxed: `cosmic test` starts each worker under a
--- [`cosmic.sandbox`] policy ([`build.test_policy`]) made of the paths this
--- module plans, held to its test's effective inputs
--- ([`build.test_inputs`]) and what the runtime needs to run it at all,
--- with every process it starts, wherever this host can sandbox one
--- ([`build.test_sandbox_probe`]). `COSMIC_TEST_SANDBOX` chooses (`mode`): unset,
--- each worker is sandboxed where one can be and runs unsandboxed where
--- none can (macOS, a host that refuses user namespaces or Landlock, a
--- root that cannot map the user a policy runs as); "1" requires it, and
--- the run fails where none can be; "0" turns it off.
---
--- What a sandboxed worker has ([`test_sandbox.plan`]):
---
--- - the tree at [`test_sandbox.tree`], /tree, wherever the host keeps
---   it, and its working directory there. Each read-only, it holds only
---   its module's import closure as source files, the fuzz corpora for a
---   module that uses [`build.fuzz`], and what the module declares it
---   `reads`;
--- - the tree's build directory at [`test_sandbox.output`], wherever the
---   host keeps it, read-only, holding only the store at its `cosmic.db`
---   (the store of its module's import closure,
---   [`build.closure_store`]'s `write`, or the whole projection for a
---   module that declares `store`), and its `bin` for one that declares
---   `tool`, each `o/...` as a module declares it;
--- - its scratch directory at [`test_sandbox.scratch`], beneath /tmp at
---   a name padded to `scratch_length`, writable: the test's own
---   directory (`tmp` there, a link to `real` beside it), where
---   the processes it starts write their coverage (`children` there), and
---   its TMPDIR. Where the module
---   declares nothing that binds a directory of the host -- no `system`,
---   `tool`, host cache or `noexec`, and no directory among its
---   `reads` and `host` -- that directory is not the host's: the worker
---   makes it in the sandbox's own /tmp at the same name ([`Plan`]'s
---   `own_scratch`), so its root shows files alone, which holds a unix
---   socket it makes below Landlock ABI 9, and, for a module that declares
---   `nests` (whose worker has no Landlock ruleset), at any ABI;
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
---   refused where that is the tree's, the scratch directory's, or above
---   either ([`test_inputs.resolve`]);
--- - no network but a loopback of its own, which answers the loopback
---   addresses a module may declare ([`cosmic.test`]'s `network`), as the
---   host's would;
--- - the pinned environment and the variables it declares (`environment`).
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
local build_paths = require("build.paths")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local test_inputs = require("build.test_inputs")
local caches = require("build.caches")
local String = require("cosmic.string")

local build_layout = build_paths.resolve

local record test_sandbox
  --- Where a sandboxed worker has the tree, and runs.
  tree: string
  --- Where it has its scratch directory.
  scratch: string
  output: string
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
    --- -- where the program is the tree's own tool: that in the
    --- worker's build directory ([`test_sandbox.output`]); where it is the
    --- runner's own beneath /tree, /program/<its name> ([`program_name`]);
    --- nil where it keeps the runner's, as a worker whose module does
    --- not declare `tool` does.
    program: string | nil
    --- The host
    --- paths among `sandbox.unveil.reads` that are run, which the policy
    --- grants `x` as well: the program and its core, and what its module
    --- declares it reads of the tree or the host (`o/bin` for `tool`) that
    --- the mode of a file lets run.
    runs: {string:boolean}
    --- Whether the worker's scratch
    --- directory is a directory of its own in the sandbox's tmpfs
    --- (`own_scratch`) rather than a bind of the host's, and, where it is
    --- not, what put a directory of the host in the worker's root, which
    --- keeps it from a unix socket below Landlock ABI 9 ("" for
    --- nothing).
    own_scratch: boolean
    why_shared: string
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

--- The base of the build directories a sandboxed worker has
--- (COSMIC_BUILD_HOME), beneath its scratch directory: its tree's, at
--- [`output`], is given there, and a project the worker builds is built
--- there, never in the host's. A fixed name, as /tree is, so no key
--- holds where the host keeps its build directories.
local build_home <const> = test_sandbox.scratch .. "/build"

--- Where a sandboxed worker has its tree's build directory: the one
--- [`build.paths`] names for /tree under [`build_home`], so the worker
--- finds it there as the host finds its own. A declaration names it
--- `o` ([`build.declared_key`]).
test_sandbox.output = build_paths.in_home(test_sandbox.tree, build_home)

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

--- Where a sandboxed worker has the files above the project, one at its
--- relative path beneath: beside /tree, at a fixed name like it, so no
--- key holds where the host keeps them.
local parent_place <const> = "/tree-up"

--- A sandboxed worker's environment: of `environment`, the runner's
--- view of a worker's ([`build.test`]'s `worker_environment`), the pinned
--- variables and those `effective` declares, and TMPDIR, set to its
--- scratch directory, the one it can write to.
function test_sandbox.environment(environment: {string:string},
                                  effective: test_inputs.Effective): {string:string}
  local out: {string:string} = {}
  for name in pairs(effective.env) do out[name] = environment[name] end
  out.COSMIC_TEST_NOEXEC = effective.noexec_ready and "/noexec" or nil
  out.COSMIC_TEST_PARENT = #(effective.parent or {}) > 0 and parent_place or nil
  out.TMPDIR = test_sandbox.scratch
  out.COSMIC_BUILD_HOME = build_home
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
  out.COSMIC_TEST_NOEXEC = nil
  out.COSMIC_TEST_PARENT = nil
  if out.COSMIC_PORTABLE_CACHE == own_cores then
    out.COSMIC_PORTABLE_CACHE = environment.COSMIC_PORTABLE_CACHE
  end
  return out
end

--- The environment such a worker is given: its key's
--- ([`unenforced_view`]), but with TMPDIR `scratch`, its own scratch
--- directory on the host, where the key names a sandbox's, and
--- COSMIC_BUILD_HOME beneath it, as [`unenforced_home`] makes it, and, for a
--- module that declares files above the project, COSMIC_TEST_PARENT the
--- directory above the project's `root`.
function test_sandbox.unenforced_environment(environment: {string:string},
                                             effective: test_inputs.Effective,
                                             scratch: string, root: string): {string:string}
  local out = test_sandbox.unenforced_view(environment, effective)
  if #(effective.parent or {}) > 0 then out.COSMIC_TEST_PARENT = root .. "/.." end
  out.TMPDIR = scratch
  out.COSMIC_BUILD_HOME = scratch .. "/build"
  return out
end

--- Makes the base of the build directories a worker of the tree at `root`
--- run unsandboxed has, beneath its scratch directory `scratch`, as a
--- sandbox gives one at [`build_home`]: a project the worker builds is
--- built there, not in the host's base, and its tree's build directory
--- is a link there to the host's, so the worker finds it as the runner
--- does. False and why where it cannot be made.
function test_sandbox.unenforced_home(root: string, scratch: string): boolean, string
  local home = scratch .. "/build"
  local made, trouble, errno = sys.mkdir(home, 0x1c0)
  if not made and errno ~= sys.EEXIST then return false, home .. ": " .. trouble end
  local canonical, root_trouble = sys.realpath(root)
  if canonical == nil then return false, root .. ": " .. root_trouble end
  local link = build_paths.in_home(canonical, home)
  local linked, link_trouble, link_errno = sys.symlink(build_layout(root).directory, link)
  if not linked and link_errno ~= sys.EEXIST then return false, link .. ": " .. link_trouble end
  return true, ""
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
--- the tree's own, by where each resolves. The tree's own tool is in
--- the worker's build directory ([`output`]), where a worker whose
--- module declares `tool` has it, as it has the rest of its bin
--- directory, `o/bin` as the module declares it. Another program keeps its own
--- name -- a release run on the tree -- but for one beneath /tree
--- itself, a run started in a sandboxed worker of another tree, whose
--- worker has a tree of its own there: it is given at
--- /program/<its name> instead (`program_place`). Nil where it
--- keeps its own name.
local function program_name(root: string): string | nil, boolean
  local relaunch, _ = Proc.relaunch()
  if relaunch == nil or relaunch.argv[2] ~= "--artifact" then return nil, false end
  local program = confine.executable()
  if program == nil then return nil, false end
  local real = confine.resolution(program)
  if real ~= "" and real == confine.resolution(build_layout(root).tool) then
    return build_paths.under(test_sandbox.output).tool, true
  end
  if Fs.within(program, test_sandbox.tree) or Fs.within(program, build_home) then
    return program_place .. "/" .. Fs.basename(program), false
  end
  return nil, false
end

--- `path` with no "/" after it but for "/" itself.
local function trimmed(path: string): string
  local out = path:gsub("/+$", "")
  return out == "" and "/" or out
end

--- Why a worker of `effective` is not given a scratch directory of its own
--- in the sandbox's tmpfs ([`Plan.own_scratch`]), or "": what its module
--- declares that puts a directory of the host in its root, whose sockets a
--- program that makes its own cannot be told from below Landlock ABI 9
--- (core/syscalls.c's `root_shows_no_socket`). The declaration decides,
--- with the kind of the paths it names on this host, which the module's key
--- records already ([`build.declared_key`]): `system`, `tool` (o/bin),
--- a host `caches` or a private `noexec` scratch, and a `reads`
--- or `host` path that is a directory (or a socket) here. The paths are
--- those `reads` came to, the worker's.
--- @param effective what the module declares
--- @param reads the host paths the plan binds
--- @return why, "" for none
local function why_shared_scratch(effective: test_inputs.Effective, reads: {string}): string
  if effective.system then
    return "it declares `system`, which gives it the system's directories"
  end
  if effective.tool then return "it declares `tool`, which gives it the directory o/bin" end
  if effective.noexec then
    return "it declares `noexec`, whose private scratch is a bind of a host directory"
  end
  if #(effective.caches or {}) > 0 then
    return "it declares the host cache " .. effective.caches[1] .. ", a directory it writes"
  end
  for _, path in ipairs(reads) do
    local there, _ = sys.stat(path)
    if there ~= nil and (there.kind == "dir" or there.kind == "socket") and
        path ~= "/proc" then
      return "it reads " .. path .. ", " .. (there.kind == "dir" and "a directory" or "a socket") ..
        " (a grant of its Test.policy): grant the files it reads, not a directory"
    end
  end
  return ""
end

--- Makes the cores directory a module that declares the cache "bootstrap"
--- has in `scratch` ([`own_cores`]), if it is not there yet: true, or false
--- and why.
local function make_own_cores(effective: test_inputs.Effective, scratch: string): boolean, string
  for _, name in ipairs(effective.caches or {}) do
    if name == "bootstrap" then
      local cores = scratch .. own_cores:sub(#test_sandbox.scratch + 1)
      local there, _ = sys.stat(cores)
      if there == nil then
        local ok, why = sys.mkdir(cores, 0x1c0) -- 0700, as the launcher makes a cache
        if not ok then return false, cores .. ": " .. why end
      end
    end
  end
  return true, ""
end

--- The paths of a worker of the tree at `root` that runs a test of the module
--- `effective` holds the inputs of in, its scratch directory `scratch`,
--- with the runner's view of a worker's environment `environment`, and
--- at its build directory's cosmic.db the closure store at `closure_store`
--- ([`build.closure_store`]'s `write`) where the module does not declare
--- `store`, else the whole projection. A caller keys the store as it gives it
--- ([`build.declared_key`]): the whole projection by its contents only
--- where the module declares `store`, so it gives one that does not the
--- store of its closure, keyed by its bytes.
---
--- The plan holds the paths of a worker started under a [`cosmic.sandbox`]
--- policy ([`build.test_policy`]) but for what a policy gives of itself --
--- the system's (its profile "system"), a /proc of the sandbox's own -- and
--- the user it runs as, which a policy chooses. Its `sandbox` holds the
--- paths alone (`unveil`), and `runs` says which reads are run.
function test_sandbox.plan(root: string, scratch: string, effective: test_inputs.Effective,
                           environment: {string:string}, closure_store?: string): test_sandbox.Plan
  -- The program is given at its own name only where the worker does
  -- not have it as the tree's own, in its build directory. A worker
  -- whose module does not declare `tool` has no name to read it by, so
  -- it keeps the runner's, which it cannot open either.
  local program, own_program: string | nil, boolean = nil, false
  if effective.tool then program, own_program = program_name(root) end
  local executable = confine.executable()
  local layout = build_layout(root)
  local output = layout.directory
  local store = layout.projection
  local base = confine.worker_unveil(nil, scratch, false, effective.tool and not own_program, store)
  local reads: {string} = {}
  local at: {string:string} = {}
  local seen: {string:boolean} = {}
  local runs: {string:boolean} = {}
  -- With `run` where the path is run, as it may be by a worker's test; a
  -- read of a path of the closure is not.
  local function give(path: string, inside?: string, run?: boolean)
    if seen[path] then return end
    local there, _ = sys.stat(path)
    if there == nil then return end -- a read of it finds nothing, as it would
    seen[path] = true
    reads[#reads + 1] = path
    if inside ~= nil then at[path] = inside end
    -- A file no one may run is no file to grant `x` on: the start refuses
    -- a grant its user could not use by the file's mode.
    if run and (there.kind == "dir" or there.mode & 0x49 ~= 0) then
      runs[path] = true
    end
  end
  -- The store at its build directory's cosmic.db is the one its worker attaches to load
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
  do
    local launched, _ = Proc.relaunch()
    -- The artifact is run only where the module declares `tool`: a worker that
    -- nests is given it to read alone, where it is given it at all (below).
    if executable ~= nil and effective.tool then runs[executable] = true end
    if launched ~= nil then runs[launched.argv[1]] = true end
  end
  for _, path in ipairs(base.reads) do
    if path == "/proc" then
      -- A policy's sandbox has a /proc of its own, which a grant of the
      -- host's would replace.
    elseif path == store then
      give(given_store, build_paths.under(test_sandbox.output).projection)
    elseif path == executable and program ~= nil and not own_program then
      give(path, program)
    else
      give(path)
    end
  end
  local function of_tree(relative: string, run?: boolean)
    local plain = test_inputs.plain(relative)
    if plain == "." then
      give(root, test_sandbox.tree, run)
    elseif plain:sub(1, 1) ~= "/" and plain:sub(1, 3) ~= "../" and plain ~= ".." then
      local source, inside = root .. "/" .. plain, test_sandbox.tree .. "/" .. plain
      -- `o` in a declaration names the build directory: the host's, given
      -- at the worker's ([`output`]), only each declared entry of it.
      if plain == "o" then
        source, inside = output, test_sandbox.output
      elseif plain:sub(1, 2) == "o/" then
        source, inside = output .. plain:sub(2), test_sandbox.output .. plain:sub(2)
      end
      give(source, inside, run)
    end
  end
  local files: {string} = {}
  for file in pairs(effective.files) do files[#files + 1] = file end
  table.sort(files)
  -- The closure's files, which the module's key holds already.
  for _, file in ipairs(files) do of_tree(file) end
  -- What a module declares it reads of the tree it may run too, as it may
  -- unsandboxed, whose files are all runnable.
  -- TODO: run only the paths a test declares it runs, once [`Test.policy`]
  -- takes a grant of `x` on a path of the tree: today such a grant takes
  -- only "r", and a path a test starts must be run.
  for _, relative in ipairs(effective.reads) do of_tree(relative, true) end
  -- The tool is in the build directory's bin, `o/bin` as a module
  -- declares it, given as the directory it is in: where
  -- it is the program, the worker has it there alone ([`program_name`]),
  -- and a test that starts [`Proc.executable()`] starts it there; another
  -- program is given at its own name too (`worker_unveil`'s
  -- `with_program`).
  if effective.tool then of_tree("o/bin", true) end
  -- A worker that builds roots of its own has no descriptor of the artifact
  -- handed it ([`build.test_worker`]'s `invocation`) and opens it by its
  -- path, which holds every module of the tree. So does one that declares
  -- `lua`, whose children would read what it holds. One that declares
  -- `store` is given the real one; any other runs on a sealed database
  -- ([`build.test`]'s `sealed_for`) and is given none.
  if (effective.nests or effective.lua) and effective.store and not effective.tool then
    local launched, _ = Proc.relaunch()
    if launched ~= nil and launched.argv[2] == "--artifact" and launched.argv[3] ~= nil then
      -- Given by a name a grant may name, which the worker is told it by
      -- too (`program`) where that differs from the runner's.
      local artifact = confine.grantable(launched.argv[3])
      if artifact ~= launched.argv[3] then program = artifact end
      give(artifact)
    end
  end
  -- Why a `host` path cannot be given: one [`test_inputs.resolve`] could
  -- not give, or one that is where the sandbox has its own -- its scratch
  -- directory, which it gives at [`test_sandbox.scratch`], or /tree or
  -- that, over which a bind at its own name would go -- or above it, such
  -- as the host's temporary directory, above every test's scratch directory.
  local refused = effective.unresolved or ""
  for _, path in ipairs(effective.host) do
    if path:sub(1, 1) == "/" then
      local plain = test_inputs.plain(path)
      -- By its name and by where it resolves: a link to the host's
      -- temporary directory would bind all of it.
      local real = confine.resolution(plain)
      local own_real = confine.resolution(scratch)
      for _, where in ipairs({ plain, real }) do
        for _, own in ipairs({ scratch, own_real, test_sandbox.tree, test_sandbox.scratch }) do
          local mine = own == scratch or own == own_real
          if refused == "" and where ~= "" and own ~= "" and
              ((mine and Fs.within(where, own)) or Fs.within(own, where)) then
            refused = string.format("Test.policy grant of the host path %q: %s is where its " ..
                "sandbox has %s", path, plain, mine and "its scratch directory" or own)
          end
        end
      end
      -- A policy's sandbox has a /proc of its own, which is what a module
      -- that declares the host's /proc is given there too.
      if plain ~= "/proc" then give(trimmed(path), nil, true) end
    end
  end
  -- Each file above the project, read-only at its relative path beneath
  -- [`parent_place`]. A file the host lacks is none, as the test
  -- finds ([`test_inputs.resolve`] fails its tests before it starts).
  local above = test_inputs.parent_directory(root)
  for _, relative in ipairs(effective.parent or {}) do
    give(above .. "/" .. relative, parent_place .. "/" .. relative)
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
  if made then made, trouble = make_own_cores(effective, scratch) end
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
    if not runs[path] and shown_by(path, given_reads, at) then
      at[path] = nil
    else
      reads[#reads + 1] = path
    end
  end
  -- Where nothing of the host's but files is in its root, its scratch
  -- directory is the sandbox's own tmpfs's, made by the worker at the same
  -- name, not a bind of the host's.
  local why_shared = why_shared_scratch(effective, reads)
  local own_scratch = why_shared == ""
  if own_scratch then
    writes = {}
    at[scratch] = nil
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
    sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = true },
    env = test_sandbox.environment(environment, effective),
    over = over,
    trouble = refused ~= "" and refused or made and "" or "a cache it declares: " .. trouble,
    program = program,
    runs = runs,
    own_scratch = own_scratch,
    why_shared = why_shared,
  }
end

--- The plan `plan`, made for a worker whose scratch directory was `from`
--- ([`test_sandbox.plan`]), for the worker of the same module, `effective`,
--- whose scratch directory is `scratch`: the same paths, as no part of a
--- plan but the scratch directory depends on the worker. It is the
--- plan of a module made once a run, for the cost of looking at each path of
--- a module's closure again is most of what a plan costs; the paths it
--- looked at are taken to stay as they were for the run: one that vanishes
--- meanwhile is not dropped from the copy, and its worker's start fails
--- with the mount's error, where a plan made afresh would have left it
--- out. The key has moved by then, so no verdict is kept either way. Only a plan
--- with no `trouble` is rebound; the copy shares nothing with `plan`.
function test_sandbox.rebind(plan: test_sandbox.Plan, from: string, scratch: string,
                             effective: test_inputs.Effective): test_sandbox.Plan
  local unveil = plan.sandbox.unveil
  local reads: {string} = {}
  for i, path in ipairs(unveil.reads) do reads[i] = path end
  local writes: {string} = {}
  for i, path in ipairs(unveil.writes) do writes[i] = path == from and scratch or path end
  local at: {string:string} = {}
  for path, inside in pairs(unveil.at) do at[path == from and scratch or path] = inside end
  local env: {string:string} = {}
  for name, value in pairs(plan.env) do env[name] = value end
  local runs: {string:boolean} = {}
  for path in pairs(plan.runs) do runs[path] = true end
  local made, trouble = make_own_cores(effective, scratch)
  return {
    sandbox = { unveil = { reads = reads, writes = writes, at = at }, offline = plan.sandbox.offline },
    env = env,
    over = plan.over,
    trouble = made and "" or "a cache it declares: " .. trouble,
    program = plan.program,
    runs = runs,
    own_scratch = plan.own_scratch,
    why_shared = plan.why_shared,
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
        "the promise \"nest\" in the starting test's Test.policy"
    end
  end
  if why == nil then return trouble end
  return why .. " (" .. trouble .. ")"
end

return test_sandbox
