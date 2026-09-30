--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): a worker's
--- whole plan, and, end to end, what a test run with the switch on
--- sees. These cases declare `tool`, each for a reason of its own:
--- - a plan reads this program: it gives a worker the program's own
---   paths, and so stats them (build.confine's `worker_unveil`);
--- - the end-to-end cases start this program, a `cosmic test` run on a
---   suite of their own;
--- - and the workers of that run nest a sandbox in this test's own,
---   confining each in a root of its own, which a worker that does not
---   declare `tool` cannot give: it is held to running anything but
---   this program through a Landlock domain (build.confine's
---   `forbid_running`), and the kernel refuses a mount inside one.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local sandbox_skip = require("build.sandbox_skip")
local Test = require("cosmic.test")

--- What a worker's plan gives it of the host, the program it runs,
--- roots of their own for the sandboxed workers it starts (`nests`), and
--- what holds a run to sandboxing (`unsandboxed`).
Test.needs{
  host = { "/dev/urandom", "/proc" },
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  tool = true,
  nests = true,
}

--- Makes `root`, a tree for a suite, with a stand-in program
--- (build/stand_in.tl) at bin/probe for its tests to start, which
--- declare it -- not this program, which would take `tool`, and with it
--- the store's hold these tests look at: in the tree, since a sandboxed
--- worker has a /tmp of its own over this test's.
local function suite_tree(tmp: string, root: string)
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(root .. "/bin"))
  assert(stand_in.place(assert(stand_in.build(tmp .. "/stand-in")), root .. "/bin/probe"))
end

--- An `Effective` holding `files` of the tree and nothing else declared.
local function effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    processes = false, tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

--- Whether `list` holds `value`.
local function holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- A path a bind of another shows already, at the same place and as
--- the same file, is not bound again on top of it -- a mount point that
--- would be the host's own file, which a rename over it fails -- but
--- one a link on the way leads elsewhere is: the other's bind leaves
--- the link, which the sandbox would follow to what it does not have.
local function test_a_path_another_bind_shows_is_not_bound_again(tmp: string)
  local root, scratch, dir = tmp .. "/root", tmp .. "/scratch", tmp .. "/host"
  for _, made in ipairs({ root .. "/o", root .. "/data", scratch, dir, tmp .. "/elsewhere" }) do
    assert(Fs.mkdirs(made))
  end
  for _, file in ipairs({ "o/cosmic.db", "data/x.tl" }) do
    assert(Fs.write(root .. "/" .. file, "x"))
  end
  assert(Fs.write(tmp .. "/elsewhere/y.tl", "y"))
  assert(sys.symlink(tmp .. "/elsewhere/y.tl", root .. "/data/y.tl"))
  assert(Fs.write(dir .. "/given", "h"))
  local inputs = effective({ "data/x.tl", "data/y.tl" })
  inputs.reads = { "data" }
  inputs.host = { dir, dir .. "/given" }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  local unveil = plan.sandbox.unveil
  assert(holds(unveil.reads, root .. "/data") and unveil.at[root .. "/data"] == "/tree/data")
  assert(not holds(unveil.reads, root .. "/data/x.tl") and unveil.at[root .. "/data/x.tl"] == nil)
  assert(holds(unveil.reads, root .. "/data/y.tl") and
    unveil.at[root .. "/data/y.tl"] == "/tree/data/y.tl")
  assert(holds(unveil.reads, dir) and not holds(unveil.reads, dir .. "/given"))
  -- What a process the worker starts is keyed by is as it was.
  assert(holds(plan.held, dir .. "/given") and holds(plan.held, "/tree/data"))
end

--- The program is named in the tree, at /tree/o/bin/cosmic, where it is
--- the tree's own o/bin/cosmic by where each resolves -- a tree here
--- whose o/bin/cosmic leads to this program -- and where this program
--- is a portable artifact, whose relaunch names the path; a worker whose
--- module declares `tool` then has it there alone, with the rest of
--- o/bin, not at its own name. In another tree it keeps its own name
--- -- but where that is beneath /tree, as this worker's is sandboxed,
--- where the other's worker has a tree of its own: there it has it at
--- /program/<its name>. A worker that is not a tool keeps the
--- runner's name, which it has no way to read.
local function test_the_tree_s_own_program_is_named_in_the_tree(tmp: string)
  local other, tree, scratch = tmp .. "/other", tmp .. "/tree", tmp .. "/scratch"
  for _, made in ipairs({ other .. "/o/bin", tree .. "/o/bin", scratch }) do
    assert(Fs.mkdirs(made))
  end
  assert(Fs.write(other .. "/o/bin/cosmic", "p"))
  local inputs = effective({})
  inputs.tool = true
  local relaunch, _ = Proc.relaunch()
  local executable, _ = Proc.executable()
  if relaunch == nil or relaunch.argv[2] ~= "--artifact" or executable == nil then
    assert(test_sandbox.plan(other, scratch, inputs, {}).program == nil)
    return -- no portable artifact to name
  end
  local elsewhere = test_sandbox.plan(other, scratch, inputs, {})
  if Fs.within(executable, "/tree") then
    local placed = "/program/" .. Fs.basename(executable)
    assert(elsewhere.program == placed, tostring(elsewhere.program))
    assert(elsewhere.sandbox.unveil.at[executable] == placed)
  else
    assert(elsewhere.program == nil, tostring(elsewhere.program))
  end
  assert(holds(elsewhere.sandbox.unveil.reads, executable))
  assert(sys.symlink(executable, tree .. "/o/bin/cosmic"))
  local plan = test_sandbox.plan(tree, scratch, inputs, {})
  assert(plan.program == "/tree/o/bin/cosmic", tostring(plan.program))
  -- A worker that is not a tool keeps the runner's name.
  local plain = test_sandbox.plan(tree, scratch, effective({}), {})
  assert(plain.program == nil, tostring(plain.program))
  local unveil = plan.sandbox.unveil
  assert(holds(unveil.reads, tree .. "/o/bin") and unveil.at[tree .. "/o/bin"] == "/tree/o/bin")
  assert(not holds(unveil.reads, executable), executable .. " is given at its own name")
end

--- A worker is given the tree's store, its closure's files and what its
--- module declares of the tree, each at its name under /tree; its
--- scratch directory to write, at `test_sandbox.scratch`; the host files it declares at
--- their own names; and no network but its own loopback. A path that is
--- not there is not given: a read of it finds nothing either way.
local function test_a_plan_gives_the_tree_at_tree_and_the_scratch_at_its_padded_name(tmp: string)
  local root, scratch, dir = tmp .. "/root", tmp .. "/scratch", tmp .. "/host"
  for _, made in ipairs({ root .. "/o", root .. "/a", root .. "/data", scratch, dir }) do
    assert(Fs.mkdirs(made))
  end
  for _, file in ipairs({ "o/cosmic.db", "a/x.tl", "data/f" }) do
    assert(Fs.write(root .. "/" .. file, "x"))
  end
  local host = dir .. "/given"
  assert(Fs.write(host, "h"))
  local inputs = effective({ "a/x.tl", "a/missing.tl" })
  inputs.reads = { "data/", "../outside" }
  inputs.host = { host }
  local plan = test_sandbox.plan(root, scratch, inputs, {})
  local unveil = plan.sandbox.unveil
  assert(plan.over == 0 and plan.sandbox.offline == true)
  assert(holds(unveil.reads, root .. "/o/cosmic.db") and
    unveil.at[root .. "/o/cosmic.db"] == "/tree/o/cosmic.db")
  assert(holds(unveil.reads, root .. "/a/x.tl") and unveil.at[root .. "/a/x.tl"] == "/tree/a/x.tl")
  assert(holds(unveil.reads, root .. "/data") and unveil.at[root .. "/data"] == "/tree/data")
  assert(not holds(unveil.reads, root .. "/a/missing.tl"))
  for _, path in ipairs(unveil.reads) do
    assert(path:find("outside", 1, true) == nil, "a read that climbs out of the tree: " .. path)
  end
  assert(holds(unveil.reads, host) and unveil.at[host] == nil)
  -- One given at its own name beneath the scratch directory is kept where it is.
  assert(not Fs.within(host, test_sandbox.scratch) or holds(plan.kept, host), host)
  assert(#unveil.writes == 1 and unveil.writes[1] == scratch and
    unveil.at[scratch] == test_sandbox.scratch)
  -- A process the worker starts is keyed by what it declares, as the
  -- worker sees it, the runtime's own paths (/dev/null everywhere, /proc
  -- where the host has one: a path that is not there is not given) and
  -- the store -- not by its closure's files, nor the system's own paths,
  -- which it is not given undeclared.
  assert(holds(plan.held, "/tree/data") and holds(plan.held, host) and holds(plan.held, "/dev/null"))
  assert(sys.stat("/proc") == nil or holds(plan.held, "/proc"))
  assert(not holds(plan.held, "/tree/a/x.tl") and holds(plan.held, "/tree/o/cosmic.db"))
  assert(not holds(plan.held, "/usr") and not holds(unveil.reads, "/usr"))
  -- Declaring `system` gives the system's own paths too: see
  -- build/test_sandbox_system_test.tl, whose worker has them to give.
  -- Given the store of its closure, a worker has it at o/cosmic.db in
  -- the projection's place, which it has nowhere, and a process it
  -- starts is keyed by it; declaring `store` keeps the projection.
  assert(Fs.mkdirs(root .. "/o/stores"))
  local closure_store = root .. "/o/stores/closure.db"
  assert(Fs.write(closure_store, "c"))
  local closed = test_sandbox.plan(root, scratch, inputs, {}, closure_store)
  assert(closed.sandbox.unveil.at[closure_store] == "/tree/o/cosmic.db" and
    not holds(closed.sandbox.unveil.reads, root .. "/o/cosmic.db"))
  assert(holds(closed.held, "/tree/o/cosmic.db"))
  inputs.store = true
  local whole = test_sandbox.plan(root, scratch, inputs, {}, closure_store)
  assert(whole.sandbox.unveil.at[root .. "/o/cosmic.db"] == "/tree/o/cosmic.db" and
    not holds(whole.sandbox.unveil.reads, closure_store))
  inputs.store = false
  -- A declared path not there yet is held all the same, keyed as
  -- missing until it is made; nothing is given for it.
  inputs.reads = { "data/", "later/x" }
  local later = test_sandbox.plan(root, scratch, inputs, {})
  assert(holds(later.held, "/tree/later/x") and not holds(later.sandbox.unveil.reads,
    root .. "/later/x"))
  inputs.reads = { "data/", "../outside" }
  -- The directories the sandbox makes to hold what it gives beneath
  -- them, /tree itself among them, but none it gives whole.
  assert(holds(plan.made, "/tree/a") and holds(plan.made, "/tree/o") and
    holds(plan.made, "/tree"))
  assert(not holds(plan.made, "/tree/data"))
  -- A declared cache is given to write at its own name, made first.
  inputs.cache_paths = { tmp .. "/caches/zig-global" }
  local cached = test_sandbox.plan(root, scratch, inputs, {})
  assert(cached.trouble == "", cached.trouble)
  assert(holds(cached.sandbox.unveil.writes, tmp .. "/caches/zig-global") and
    cached.sandbox.unveil.at[tmp .. "/caches/zig-global"] == nil)
  assert(Fs.exists(tmp .. "/caches/zig-global"))
  -- A file a declared cache holds is given through the cache alone, not
  -- bound again on top of it: there its mount point would be the host's
  -- own file, and a mount onto one renamed over as it is made fails
  -- the worker's start (the stamp beside this program's core, in the
  -- cores directory the `bootstrap` cache is). The key still holds it.
  local stamp = tmp .. "/caches/cores/.verified-core"
  assert(Fs.mkdirs(tmp .. "/caches/cores"))
  assert(Fs.write(stamp, "s"))
  inputs.host = { stamp }
  inputs.cache_paths = { tmp .. "/caches/cores" }
  local nested = test_sandbox.plan(root, scratch, inputs, {})
  assert(nested.trouble == "", nested.trouble)
  assert(holds(nested.sandbox.unveil.writes, tmp .. "/caches/cores") and
    not holds(nested.sandbox.unveil.reads, stamp))
  assert(holds(nested.held, stamp))
  -- The `bootstrap` cache: cores of its own, made in its scratch
  -- directory before it starts -- a ruleset that holds it walks what is
  -- there then -- and named to it, not the host's, which the cores
  -- directory this program's core is in stays.
  inputs.caches, inputs.cache_paths = { "bootstrap" }, { tmp .. "/caches/cores" }
  local own_cores = test_sandbox.plan(root, scratch, inputs, { COSMIC_PORTABLE_CACHE =
    tmp .. "/caches/cores" })
  assert(own_cores.trouble == "", own_cores.trouble)
  assert(own_cores.env.COSMIC_PORTABLE_CACHE == test_sandbox.scratch .. "/cores",
    tostring(own_cores.env.COSMIC_PORTABLE_CACHE))
  local cores = assert(sys.stat(scratch .. "/cores"))
  assert(cores.kind == "dir" and cores.mode & 511 == 448, tostring(cores.mode))
  assert(not holds(own_cores.sandbox.unveil.writes, tmp .. "/caches/cores") and
    holds(own_cores.sandbox.unveil.reads, stamp))
  inputs.caches, inputs.cache_paths = {}, {}
  local alone = test_sandbox.plan(root, scratch, inputs, {})
  assert(holds(alone.sandbox.unveil.reads, stamp))
  inputs.host = { host }
  -- A host path where the sandbox has its own -- its scratch directory,
  -- or above it, or /tmp or /tree themselves -- cannot be given, and
  -- one a variable names is named as declared.
  for _, own in ipairs({ scratch .. "/x", tmp, "/tmp", "/tree", "/" }) do
    inputs.host = { own }
    inputs.spelled = { [test_inputs.plain(own)] = "$OWN" }
    local refused = test_sandbox.plan(root, scratch, inputs, {})
    assert(refused.trouble:find('Test.needs host "$OWN": ', 1, true) and
      refused.trouble:find("is where its sandbox has", 1, true), own .. ": " .. refused.trouble)
  end
  -- And by where it resolves: a link to the scratch directory.
  assert(Fs.symlink(scratch, tmp .. "/to-scratch"))
  inputs.host, inputs.spelled = { tmp .. "/to-scratch" }, {}
  local linked = test_sandbox.plan(root, scratch, inputs, {})
  assert(linked.trouble:find("is where its sandbox has its scratch directory", 1, true),
    linked.trouble)
  inputs.host, inputs.spelled = { host }, {}
  assert(test_sandbox.plan(root, scratch, inputs, {}).trouble == "")
  -- Offline, whatever it declares: the loopback addresses it may
  -- declare, its own loopback answers.
  for _, hosts in ipairs({ "", "127.0.0.1 127.0.0.2" }) do
    inputs.network = {}
    for name in hosts:gmatch("%S+") do inputs.network[name] = true end
    local planned = test_sandbox.plan(root, scratch, inputs, {})
    assert(planned.sandbox.offline == true, hosts)
  end
  inputs.network = {}
  inputs.tool = true
  local tooled = test_sandbox.plan(root, scratch, inputs, {})
  -- No o/bin here to give.
  assert(not holds(tooled.sandbox.unveil.reads, root .. "/o/bin"))
end

--- Whether the run that printed `text` sandboxed none of its workers,
--- where that is allowed. The workers nest in this test's own sandbox,
--- which a host may refuse (the kernel lets root nest one only two deep:
--- core/syscalls.c's `map_ids`); a case of a sandboxed run then has
--- nothing to check. It says it is skipped (`Test.skip`),
--- which a run held to sandboxing fails
--- (COSMIC_TEST_SANDBOX=1, as CI's suites set it, COSMIC_SANDBOX=must or
--- COSMIC_CI_REQUIRE_SANDBOX=1): CI's unprivileged runners nest them.
local function unsandboxed(text: string): boolean
  if not text:find("no worker can be sandboxed here", 1, true) then return false end
  sandbox_skip.nested(text)
  return true
end

--- Runs `cosmic test` on `root` with `env`, answering what it printed
--- and whether it passed.
local function run(root: string, output: string, env: {string:string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test", "--all" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- Runs `cosmic test` on `root`, with no `--all`, answering what it
--- printed and whether it passed.
local function run_again(root: string, output: string, env: {string:string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local started = this_program.program({ "test" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- End to end: by default, a test's worker runs in /tree, has its own
--- directory under /tmp, reads what its module declares of the tree
--- and nothing else of it, sees nothing of the host it was not given,
--- and reads only the variables it declares -- and so does a process it
--- starts; and the run says it was sandboxed. The same suite with the
--- switch off reads all of the tree and the host, but still only the
--- variables it declares, and says it is keyed by what it declares and
--- shares no verdict. Where this host cannot sandbox the run's workers
--- the run says so, and runs them unsandboxed, sharing none -- but with
--- the switch on, where it fails. A switch that is neither "1", "0" nor unset is refused.
local function test_a_sandboxed_run_holds_each_worker_to_its_inputs(tmp: string)
  local root, hidden = tmp .. "/root", tmp .. "/hidden"
  suite_tree(tmp, root)
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(root .. "/suite/data.txt", "declared"))
  assert(Fs.write(root .. "/suite/secret.txt", "undeclared"))
  assert(Fs.write(root .. "/suite/view_test.tl", string.format([[
local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data.txt", "bin/probe" }, env = { "DECLARED_VAR" } }

local function test_view(tmp: string)
  local here = assert(sys.getcwd())
  -- What a process it starts sees, with the worker's environment.
  local child = assert(Child.run({ "bin/probe",
    "cat-quiet suite/data.txt; cat-quiet suite/secret.txt; print /$DECLARED_VAR/$UNDECLARED_VAR" },
    { stdout = "capture" }))
  error(table.concat({ "seen", here, tmp,
    tostring((Fs.read(here .. "/suite/data.txt"))),
    tostring((Fs.read(here .. "/suite/secret.txt"))),
    tostring(sys.stat(%q) ~= nil), tostring(sys.getenv("DECLARED_VAR")),
    tostring(sys.getenv("UNDECLARED_VAR")), (tostring(child.stdout):gsub("\n", "")), "end" }, "|"))
end
]], hidden)))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.DECLARED_VAR = "d"
  env.UNDECLARED_VAR = "u"
  local real_root = assert(Fs.absolute(root))
  env.COSMIC_TEST_SANDBOX = "0"
  local text, ok = run(root, tmp .. "/plain", env)
  assert(not ok, text)
  assert(text:find("; unsandboxed (COSMIC_TEST_SANDBOX=0), keyed by declared inputs, " ..
    "sharing no verdicts)", 1, true), text)
  assert(text:find("rerun: COSMIC_TEST_SANDBOX=0 cosmic test suite/view_test.tl:test_view", 1,
    true), text)
  local seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  local fields: {string} = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == real_root and fields[3] == "declared" and fields[4] == "undeclared" and
    fields[5] == "true" and fields[6] == "d" and fields[7] == "nil" and
    fields[8] == "declaredundeclared/d/", seen)
  env.COSMIC_TEST_SANDBOX = nil
  text, ok = run(root, tmp .. "/sandboxed", env)
  assert(not ok, text)
  if unsandboxed(text) then
    assert(text:find("; unsandboxed, as no worker can be sandboxed here, keyed by declared " ..
      "inputs, sharing no verdicts)", 1, true), text)
    -- Required, the run fails instead.
    env.COSMIC_TEST_SANDBOX = "1"
    text, ok = run(root, tmp .. "/required", env)
    assert(not ok and text:find("COSMIC_TEST_SANDBOX=1, but no worker can be sandboxed here",
      1, true), text)
    return
  end
  assert(text:find("; sandboxed)", 1, true), text)
  seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  fields = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == "/tree" and fields[2] == test_sandbox.scratch .. "/tmp" and fields[3] == "declared" and
    fields[4] == "nil" and fields[5] == "false" and fields[6] == "d" and fields[7] == "nil" and
    fields[8] == "declared/d/", seen)
  -- Its failure names what it read undeclared, the declaration that
  -- would give it, and how to run it again as it ran.
  assert(text:find("sandboxed, it read what its module does not declare:", 1, true), text)
  assert(text:find("reads        suite/secret.txt", 1, true), text)
  assert(text:find("env          UNDECLARED_VAR", 1, true), text)
  assert(text:find("declare: Test.needs {", 1, true), text)
  assert(text:find("rerun: cosmic test suite/view_test.tl:test_view", 1, true), text)
  -- Required where it can be, the same.
  env.COSMIC_TEST_SANDBOX = "1"
  text, ok = run(root, tmp .. "/required", env)
  assert(not ok and text:find("; sandboxed)", 1, true), text)
  assert(text:find("rerun: COSMIC_TEST_SANDBOX=1 cosmic test suite/view_test.tl:test_view", 1,
    true), text)
  -- A misspelt switch is refused.
  env.COSMIC_TEST_SANDBOX = "yes"
  text, ok = run(root, tmp .. "/misspelt", env)
  assert(not ok and text:find('COSMIC_TEST_SANDBOX is "yes"', 1, true), text)
end

--- End to end: a sandboxed worker writes a host cache its module
--- declares, where the host has it, and cannot write one it does not
--- declare -- which the runner neither gives nor makes. Where no worker
--- can be sandboxed here, the run says so.
local function test_a_sandboxed_worker_writes_only_the_caches_it_declares(tmp: string)
  local root, xdg = tmp .. "/root", assert(Fs.absolute(tmp)) .. "/xdg"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.write(root .. "/suite/cache_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { caches = { "zig" } }

local function test_write()
  local base = assert(sys.getenv("XDG_CACHE_HOME"))
  local declared, _ = Fs.write(base .. "/cosmic/zig-global/entry", "cached")
  local undeclared, _ = Fs.write(base .. "/cosmic/bootstrap/entry", "cached")
  error("wrote|" .. tostring(declared) .. "|" .. tostring(undeclared) .. "|end")
end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- The program's cores stay where they are; only the caches move.
  env.COSMIC_PORTABLE_CACHE = env.COSMIC_PORTABLE_CACHE or Fs.cache_path("cores")
  env.XDG_CACHE_HOME = xdg
  env.COSMIC_ZIG_CACHE, env.COSMIC_ZIG_GLOBAL_CACHE = nil, nil
  env.COSMIC_TEST_SANDBOX = nil
  local text, ok = run(root, tmp .. "/out", env)
  assert(not ok, text)
  if unsandboxed(text) then return end
  assert(text:find("wrote|true|false|end", 1, true), text)
  assert(Fs.read(xdg .. "/cosmic/zig-global/entry") == "cached")
  assert(not Fs.exists(xdg .. "/cosmic/bootstrap"))
end

--- End to end: a module that declares a `host` path by the variable
--- that says where it is (`$PRODUCT_DIR/given.txt`) has its worker
--- given that path there, and nothing beside it. With the variable
--- unset, or naming the tree, each of its tests fails before it
--- starts, naming the variable, sandboxed or not.
local function test_a_host_path_a_variable_names_is_given_where_it_says(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root, product = base .. "/root", base .. "/product"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(product))
  assert(Fs.write(product .. "/given.txt", "given"))
  assert(Fs.write(product .. "/sibling.txt", "sibling"))
  assert(Fs.write(root .. "/suite/variable_test.tl", [[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { host = { "$PRODUCT_DIR/given.txt" } }

local function test_read()
  local dir = assert(sys.getenv("PRODUCT_DIR"))
  error("read|" .. tostring((Fs.read(dir .. "/given.txt"))) .. "|" ..
    tostring((Fs.read(dir .. "/sibling.txt"))) .. "|end")
end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = nil
  -- Unset, or the tree's: refused before the test starts, in either mode.
  for _, mode in ipairs({ "0", "" }) do
    env.COSMIC_TEST_SANDBOX = mode ~= "" and mode or nil
    env.PRODUCT_DIR = nil
    local unset, unset_ok = run(root, tmp .. "/unset" .. mode, env)
    assert(not unset_ok and unset:find('Test.needs host "$PRODUCT_DIR/given.txt": ' ..
      "PRODUCT_DIR is unset", 1, true) and not unset:find("read|", 1, true), unset)
    assert(not unset:find("could not be supervised", 1, true), unset)
    env.PRODUCT_DIR = root .. "/suite"
    local inside, inside_ok = run(root, tmp .. "/inside" .. mode, env)
    assert(not inside_ok and inside:find(root .. "/suite/given.txt is the tree's", 1, true),
      inside)
  end
  env.PRODUCT_DIR = product
  env.COSMIC_TEST_SANDBOX = nil
  local text, ok = run(root, tmp .. "/given", env)
  assert(not ok, text)
  if unsandboxed(text) then return end
  assert(text:find("; sandboxed)", 1, true), text)
  assert(text:find("read|given|nil|end", 1, true), text)
end

--- End to end: a process a sandboxed test starts is keyed by what its
--- module declares. Run again, the test stands; a change to a file of
--- the tree it does not declare leaves it standing; a change to one it
--- declares runs it again, and so does making one it declares that was
--- not there when it last ran; none is assumed, and none runs every
--- time. One that does not declare `store` stands too: what it starts
--- can read only the store of its closure, which its key holds.
local function test_a_process_a_sandboxed_test_starts_is_keyed_by_what_it_declares(tmp: string)
  local root = tmp .. "/root"
  suite_tree(tmp, root)
  assert(Fs.write(root .. "/suite/data.txt", "one"))
  assert(Fs.write(root .. "/suite/unrelated.txt", "one"))
  assert(Fs.write(root .. "/suite/child_test.tl", [[
local Child = require("cosmic.child")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data.txt", "suite/later.txt", "bin/probe" }, store = true }

local function test_child_reads()
  local r = assert(Child.run({ "bin/probe",
    "cat suite/data.txt; cat suite/later.txt || print |absent" },
    { stdout = "capture" }))
  local out = r.stdout or ""
  assert(r.ok and out:find("|absent", 1, true), out)
end
]]))
  assert(Fs.write(root .. "/suite/unstored_test.tl", [[
local Child = require("cosmic.child")
local Test = require("cosmic.test")

Test.needs { reads = { "bin/probe" } }

local function test_child_reads_the_closure_store()
  assert(assert(Child.run({ "bin/probe", "exit 0" })).ok)
end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- Sandboxed where it can be, whatever this run's own switch says.
  env.COSMIC_TEST_SANDBOX = nil
  local step = 0
  local function said(wanted: string, passes?: boolean): string
    step = step + 1
    local text, ok = run_again(root, tmp .. "/run" .. step, env)
    assert(ok == (passes ~= false), step .. ": " .. text)
    assert(text:find(wanted, 1, true), step .. ": " .. text)
    return text
  end
  local first = said("2 ran, 0 stood")
  if unsandboxed(first) then return end
  assert(first:find("; sandboxed)", 1, true), first)
  local again = said("0 ran, 2 stood")
  assert(not again:find("assumed", 1, true) and not again:find("every time", 1, true), again)
  assert(Fs.write(root .. "/suite/unrelated.txt", "two"))
  said("0 ran, 2 stood")
  assert(Fs.write(root .. "/suite/data.txt", "two"))
  said("1 ran, 1 stood")
  said("0 ran, 2 stood")
  -- Made since, what the child reads is there, and the test fails.
  assert(Fs.write(root .. "/suite/later.txt", "made"))
  said("FAIL  suite.child_test test_child_reads: ", false)
end

--- A sandboxed run interrupted from the terminal -- SIGINT to its
--- process group -- ends every worker it had running, each in a
--- sandbox of its own, and removes their directories.
local function test_an_interrupted_sandboxed_run_ends_its_workers(tmp: string)
  local root, temp = tmp .. "/root", assert(Fs.absolute(tmp)) .. "/temp"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(temp))
  assert(Fs.write(root .. "/suite/held_test.tl", [[
local Fs = require("cosmic.fs")
local function hold(tmp: string)
  assert(Fs.write(tmp .. "/kept", "x"))
  while true do end
end
local function test_first(tmp: string) hold(tmp) end
local function test_second(tmp: string) hold(tmp) end
]]))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- Sandboxed where it can be, whatever this run's own switch says.
  env.COSMIC_TEST_SANDBOX = nil
  env.TMPDIR = temp
  -- Each worker's directory holding the file its test wrote.
  local function held(): integer
    local count = 0
    for _, name in ipairs(Fs.list(temp) or {}) do
      if name:sub(1, 12) == "cosmic-test-" and Fs.exists(temp .. "/" .. name .. "/real/kept") then
        count = count + 1
      end
    end
    return count
  end
  local output = tmp .. "/interrupted.out"
  local fd = assert(Fs.open_write(output))
  local interrupted = this_program.program(
    { "test", "--jobs", "2", "--timeout", "60", "suite/held_test.tl" },
    { cwd = root, env = env, stdout = fd, stderr = fd, process_group = true })
  local runner, trouble = Child.start(interrupted.argv, interrupted.options)
  assert(Fs.close(fd))
  local handle <close> = assert(runner, trouble)
  local deadline = Time.monotonic_ns() + 30 * 1000 * 1000 * 1000
  while held() < 2 do
    assert(Time.monotonic_ns() < deadline, assert(Fs.read(output)))
    local done, _ = Child.wait_any({ handle }, 50)
    assert(done == nil, "the runner ended before its tests started\n" .. assert(Fs.read(output)))
  end
  local text = assert(Fs.read(output))
  if unsandboxed(text) then
    -- Unsandboxed here: build/test_isolation_tool_test.tl's case.
    assert(handle:stop(sys.SIGKILL))
    local _, _ = handle:wait(30000)
    return
  end
  assert(text:find("test: sandbox: each worker is held", 1, true), text)
  assert(handle:stop(sys.SIGINT))
  local result = assert(handle:wait(30000))
  text = assert(Fs.read(output))
  assert(not result.timed_out and result.signal == sys.SIGINT, text)
  assert(text:find("test: cancelled; every running test was ended", 1, true), text)
  local left: {string} = {}
  for _, name in ipairs((assert(Fs.list(temp)))) do
    if name:sub(1, 12) == "cosmic-test-" then left[#left + 1] = name end
  end
  assert(#left == 0, table.concat(left, ", ") .. "\n" .. text)
end
