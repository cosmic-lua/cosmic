--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): a worker's
--- whole plan, made and read without starting a worker, and the one
--- `host` path a run refuses before it starts any. These declare `tool`:
--- a plan reads this program, since it gives a worker the program's own
--- paths and so stats them (build.confine's `worker_unveil`), and the run
--- that refuses a path starts it. They need no sandbox, so they run
--- wherever the program does; what a run of workers under one sees is in
--- `test_sandbox_run_tool_test.tl`.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")
local this_program = require("build.this_program")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local fixture = require("build.test_sandbox_fixture")
local Test = require("cosmic.test")

--- What a worker's plan gives it of the host, the program the run that
--- refuses a path starts, and roots of their own for the workers of that
--- run (`nests`), which a host that refuses them runs unsandboxed.
Test.policy{
  profiles = { "cosmic" },
  grants = { { path = "o/bin", letters = "rx" } },
  promises = { "nest" },
}

--- An `Effective` holding `files` of the tree and nothing else declared.
local function effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
end

--- Makes `tmp`/scratch, a scratch directory laid out as build.test's
--- `scratch` lays one out -- `real`, and `tmp` a link to it -- and
--- answers it. A plan takes that layout as given: where it runs its
--- worker as a user of its own, it hands it and `real` to that user.
local function scratch_in(tmp: string): string
  local scratch = tmp .. "/scratch"
  assert(Fs.mkdirs(scratch .. "/real"))
  assert(Fs.symlink("real", scratch .. "/tmp"))
  return scratch
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
  local root, scratch, dir = tmp .. "/root", scratch_in(tmp), tmp .. "/host"
  for _, made in ipairs({ root .. "/o", root .. "/data", dir, tmp .. "/elsewhere" }) do
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
  local other, tree, scratch = tmp .. "/other", tmp .. "/tree", scratch_in(tmp)
  for _, made in ipairs({ other .. "/o/bin", tree .. "/o/bin" }) do
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
--- scratch directory to write, at [`test_sandbox.scratch`]; the host
--- files it declares at their own names; and no network but its own
--- loopback. A path that is not there is not given: a read of it finds
--- nothing either way.
local function test_a_plan_gives_the_tree_at_tree_and_the_scratch_at_its_padded_name(tmp: string)
  local root, scratch, dir = tmp .. "/root", scratch_in(tmp), tmp .. "/host"
  for _, made in ipairs({ root .. "/o", root .. "/a", root .. "/data", dir }) do
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
  assert(#unveil.writes == 1 and unveil.writes[1] == scratch and
      unveil.at[scratch] == test_sandbox.scratch)
  assert(plan.trouble == "", plan.trouble)
  -- The runtime's own paths (/dev/null: a path that is not there is not
  -- given), but not the system's own, which it is not given undeclared,
  -- nor the host's /proc, which a policy's sandbox has one of its own for.
  assert(holds(unveil.reads, "/dev/null") and not holds(unveil.reads, "/proc"))
  assert(not holds(unveil.reads, "/usr"))
  -- Declaring `system` gives the system's own paths too: see
  -- build/test_sandbox_system_test.tl, whose worker has them to give.
  -- Given the store of its closure, a worker has it at o/cosmic.db in
  -- the projection's place, which it has nowhere; declaring `store`
  -- keeps the projection.
  assert(Fs.mkdirs(root .. "/o/stores"))
  local closure_store = root .. "/o/stores/closure.db"
  assert(Fs.write(closure_store, "c"))
  local closed = test_sandbox.plan(root, scratch, inputs, {}, closure_store)
  assert(closed.sandbox.unveil.at[closure_store] == "/tree/o/cosmic.db" and
      not holds(closed.sandbox.unveil.reads, root .. "/o/cosmic.db"))
  inputs.store = true
  local whole = test_sandbox.plan(root, scratch, inputs, {}, closure_store)
  assert(whole.sandbox.unveil.at[root .. "/o/cosmic.db"] == "/tree/o/cosmic.db" and
      not holds(whole.sandbox.unveil.reads, closure_store))
  inputs.store = false
  -- A declared path not there yet is given nothing.
  inputs.reads = { "data/", "later/x" }
  local later = test_sandbox.plan(root, scratch, inputs, {})
  assert(not holds(later.sandbox.unveil.reads, root .. "/later/x"))
  inputs.reads = { "data/", "../outside" }
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
  -- cores directory the `bootstrap` cache is).
  local stamp = tmp .. "/caches/cores/.verified-core"
  assert(Fs.mkdirs(tmp .. "/caches/cores"))
  assert(Fs.write(stamp, "s"))
  inputs.host = { stamp }
  inputs.cache_paths = { tmp .. "/caches/cores" }
  local nested = test_sandbox.plan(root, scratch, inputs, {})
  assert(nested.trouble == "", nested.trouble)
  assert(holds(nested.sandbox.unveil.writes, tmp .. "/caches/cores") and
      not holds(nested.sandbox.unveil.reads, stamp))
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
  -- is named as declared.
  for _, own in ipairs({ scratch .. "/x", tmp, "/tmp", "/tree", "/" }) do
    inputs.host = { own }
    local refused = test_sandbox.plan(root, scratch, inputs, {})
    assert(refused.trouble:find(string.format("Test.policy grant of the host path %q: ", own),
      1, true) and
        refused.trouble:find("is where its sandbox has", 1, true), own .. ": " .. refused.trouble)
  end
  -- And by where it resolves: a link to the scratch directory.
  assert(Fs.symlink(scratch, tmp .. "/to-scratch"))
  inputs.host = { tmp .. "/to-scratch" }
  local linked = test_sandbox.plan(root, scratch, inputs, {})
  assert(linked.trouble:find("is where its sandbox has its scratch directory", 1, true),
    linked.trouble)
  inputs.host = { host }
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

--- Runs `cosmic test --all` on `root` with `env`, answering what it
--- printed and whether it passed.
local function run(root: string, output: string, env: {string:string}): string, boolean
  local ran = fixture.run(root, output, env)
  return ran.text, ran.ok
end

--- End to end: a `host` path that is the tree's fails each of its tests
--- before it starts, naming it, sandboxed or not.
local function test_a_host_path_that_is_the_trees_is_refused_in_either_mode(tmp: string)
  local base = assert(Fs.absolute(tmp))
  local root, product = base .. "/root", base .. "/product"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(product))
  assert(Fs.write(product .. "/given.txt", "given"))
  assert(Fs.write(product .. "/sibling.txt", "sibling"))
  local env = this_program.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.COSMIC_TEST_SANDBOX = nil
  -- The tree's: refused before the test starts, in either mode.
  fixture.host_test(root, product, root .. "/suite/given.txt")
  for _, mode in ipairs({ "0", "" }) do
    env.COSMIC_TEST_SANDBOX = mode ~= "" and mode or nil
    local inside, inside_ok = run(root, tmp .. "/inside" .. mode, env)
    assert(not inside_ok and inside:find(root .. "/suite/given.txt is the tree's", 1, true) and
        not inside:find("read|", 1, true), inside)
    assert(not inside:find("could not be supervised", 1, true), inside)
  end
end
