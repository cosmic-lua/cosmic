--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): what a
--- worker is given, how what it reports is put back where the host has
--- it, and, end to end, what a test run with the switch on sees.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Time = require("cosmic.time")
local sys = require("cosmic.sys")
local declared_key = require("build.declared_key")
local confine = require("build.confine")
local observations = require("build.filesystem_observations")
local this_program = require("build.this_program")
local stand_in = require("build.stand_in")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")

--- What a worker's plan gives it of the host, the program it runs, whose
--- core the stand-in its suites' tests start is built from, and what
--- holds a run to sandboxing (`unsandboxed`).
Test.needs{
  host = { "/dev/urandom", "/proc" },
  env = { "COSMIC_SANDBOX", "COSMIC_CI_REQUIRE_SANDBOX", "COSMIC_TEST_SANDBOX" },
  tool = true,
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

--- A worker is given the tree's store, its closure's files and what its
--- module declares of the tree, each at its name under /tree; its
--- scratch directory to write, at /tmp; the host paths it declares at
--- their own names; and no network unless it declares some. A path
--- that is not there is not given: a read of it finds nothing either way.
local function test_a_plan_gives_the_tree_at_tree_and_the_scratch_at_tmp(tmp: string)
  local root, scratch, host = tmp .. "/root", tmp .. "/scratch", tmp .. "/host"
  for _, dir in ipairs({ root .. "/o", root .. "/a", root .. "/data", scratch, host }) do
    assert(Fs.mkdirs(dir))
  end
  for _, file in ipairs({ "o/cosmic.db", "a/x.tl", "data/f" }) do
    assert(Fs.write(root .. "/" .. file, "x"))
  end
  local inputs = effective({ "a/x.tl", "a/missing.tl" })
  inputs.reads = { "data/", "../outside" }
  inputs.host = { host .. "/" }
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
  -- One given at its own name beneath /tmp is kept where it is.
  assert(host:sub(1, 5) ~= "/tmp/" or holds(plan.kept, host), host)
  assert(#unveil.writes == 1 and unveil.writes[1] == scratch and unveil.at[scratch] == "/tmp")
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
  inputs.cache_paths = {}
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
  inputs.host, inputs.spelled = { host .. "/" }, {}
  assert(test_sandbox.plan(root, scratch, inputs, {}).trouble == "")
  -- Only loopback hosts: offline, its own loopback answering for them.
  -- Keyed exactly when offline: a worker keyed but online would stand
  -- on what the host's network answered.
  local offline_for: {string:boolean} = { [""] = true, ["127.0.0.1 ::1 localhost"] = true,
    ["127.0.0.1 example.com"] = false, ["example.com"] = false, ["*"] = false }
  for hosts, offline in pairs(offline_for) do
    inputs.network = {}
    for name in hosts:gmatch("%S+") do inputs.network[name] = true end
    local planned = test_sandbox.plan(root, scratch, inputs, {})
    assert(planned.sandbox.offline == offline, hosts)
    assert(declared_key.keyable(inputs) == offline, hosts)
  end
  inputs.network = { ["example.com"] = true }
  inputs.tool = true
  local online = test_sandbox.plan(root, scratch, inputs, {})
  assert(online.sandbox.offline == false)
  -- No o/bin here to give.
  assert(not holds(online.sandbox.unveil.reads, root .. "/o/bin"))
end

--- A worker's environment is the pinned variables and the ones its
--- module declares, as the runner's view has them, or all of them for
--- "*"; and TMPDIR is its scratch directory, /tmp, whatever the host's.
local function test_a_worker_is_given_only_the_variables_it_may_read()
  local view = { PATH = "/bin", DECLARED = "d", UNDECLARED = "u", TMPDIR = "/elsewhere",
    COSMIC_SANDBOX = "must" }
  local inputs = effective({})
  inputs.env = { PATH = true, TMPDIR = true, DECLARED = true }
  local env = test_sandbox.environment(view, inputs)
  assert(env.PATH == "/bin" and env.DECLARED == "d" and env.UNDECLARED == nil)
  assert(env.TMPDIR == "/tmp")
  assert(env.COSMIC_SANDBOX == nil, "only what is pinned or declared is given")
  inputs.env = { ["*"] = true }
  local all = test_sandbox.environment(view, inputs)
  assert(all.UNDECLARED == "u" and all.TMPDIR == "/tmp")
end

--- What a sandboxed worker reports it read at /tree and /tmp is put back
--- where the host has the tree and the scratch directory, in the path
--- and in an answer that is a path; every other path, a variable's name
--- and a readlink's answer are left as they are.
local function test_what_a_worker_read_is_put_back_where_the_host_has_it()
  local reads: {observations.Observation} = {
    { kind = "o", path = "/tree/a/x.tl", answer = "" },
    { kind = "s", path = "/tree", answer = "ok 1" },
    { kind = "t", path = "/tmp/tmp/link", answer = "/tmp/real/f" },
    { kind = "r", path = "/usr/lib/x", answer = "/usr/lib/y" },
    { kind = "a", path = "/tmp/tmp", answer = "ok /tmp/real" },
    { kind = "k", path = "/tree/link", answer = "ok /tree/elsewhere" },
    { kind = "e", path = "/tree", answer = "ok /tree" },
    { kind = "o", path = "/treehouse", answer = "" },
  }
  -- A path given at its own name beneath /tmp or /tree is bound over
  -- them, and a read of it is where the host has it already.
  local kept = test_sandbox.to_host({ { kind = "o", path = "/tmp/host/f", answer = "" },
    { kind = "o", path = "/tmp/hostile", answer = "" } }, "/home/me/tree", "/var/s",
    { "/tmp/host" })
  assert(kept[1].path == "/tmp/host/f" and kept[2].path == "/var/s/hostile")
  -- A stat or an lstat of a directory the sandbox made is none of the
  -- host's, and is left out; one beneath it, or a listing of it, is not.
  local made = test_sandbox.to_host({ { kind = "s", path = "/tree/a", answer = "ok 40" },
    { kind = "l", path = "/tree/a/", answer = "ok 40" },
    { kind = "s", path = "/tree/a/x.tl", answer = "ok 1" },
    { kind = "d", path = "/tree/a", answer = "ok" } }, "/home/me/tree", "/var/s", nil,
    { "/tree/a" })
  assert(#made == 2 and made[1].path == "/home/me/tree/a/x.tl" and made[2].kind == "d")
  local out = test_sandbox.to_host(reads, "/home/me/tree", "/var/s")
  local want = {
    { "o", "/home/me/tree/a/x.tl", "" },
    { "s", "/home/me/tree", "ok 1" },
    { "t", "/var/s/tmp/link", "/var/s/real/f" },
    { "r", "/usr/lib/x", "/usr/lib/y" },
    { "a", "/var/s/tmp", "ok /var/s/real" },
    { "k", "/home/me/tree/link", "ok /tree/elsewhere" },
    { "e", "/tree", "ok /tree" },
    { "o", "/treehouse", "" },
  }
  assert(#out == #want)
  for i, expected in ipairs(want) do
    local got = out[i]
    assert(got.kind == expected[1] and got.path == expected[2] and got.answer == expected[3],
      i .. ": " .. got.kind .. " " .. got.path .. " " .. got.answer)
  end
end

--- Whether a run that printed `text`, its workers sandboxed where they
--- can be, found none could be, where that is allowed. Its workers are
--- nested in this test's own sandbox, which a host may refuse them (the
--- kernel lets root nest one only two deep: core/syscalls.c's `map_ids`),
--- and a case of a sandboxed run then has nothing to check -- unless this
--- run is held to sandboxing (COSMIC_TEST_SANDBOX=1, as CI's suites set
--- it, COSMIC_SANDBOX=must or COSMIC_CI_REQUIRE_SANDBOX=1): CI's
--- unprivileged runners nest them, and there it fails.
local function unsandboxed(text: string): boolean
  if not text:find("no worker can be sandboxed here", 1, true) then return false end
  assert(not confine.held_to_sandbox(),
    "the run is held to sandboxing, but the run it started was not:\n" .. text)
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

--- End to end: by default, a test's worker runs in /tree, has its own
--- directory under /tmp, reads what its module declares of the tree
--- and nothing else of it, sees nothing of the host it was not given,
--- and reads only the variables it declares -- and so does a process it
--- starts; and the run says it was sandboxed. The same suite with the
--- switch off reads all of it, and says it shares no verdict. Where
--- this host cannot sandbox the run's workers the run says so, and runs
--- them unsandboxed, sharing none -- but with the switch on, where it
--- fails. A switch that is neither "1", "0" nor unset is refused.
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
  assert(text:find("; unsandboxed (COSMIC_TEST_SANDBOX=0), sharing no verdicts)", 1, true), text)
  assert(text:find("rerun: COSMIC_TEST_SANDBOX=0 cosmic test suite/view_test.tl:test_view", 1,
    true), text)
  local seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  local fields: {string} = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == real_root and fields[3] == "declared" and fields[4] == "undeclared" and
    fields[5] == "true" and fields[6] == "d" and fields[7] == "u" and
    fields[8] == "declaredundeclared/d/u", seen)
  env.COSMIC_TEST_SANDBOX = nil
  text, ok = run(root, tmp .. "/sandboxed", env)
  assert(not ok, text)
  if unsandboxed(text) then
    assert(text:find("; unsandboxed, as no worker can be sandboxed here, sharing no verdicts)", 1,
      true), text)
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
  assert(fields[1] == "/tree" and fields[2] == "/tmp/tmp" and fields[3] == "declared" and
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

--- A failure to start a sandbox where the kernel refuses a user
--- namespace is said plainly, naming why; any other is as it was.
local function test_a_refused_user_namespace_is_said_plainly()
  local none = test_sandbox.refusal("start: No space left on device")
  assert(none:find("allows no user namespaces", 1, true) and
    none:find("No space left on device", 1, true), none)
  for _, errno in ipairs({ "Operation not permitted", "Permission denied" }) do
    local refused = test_sandbox.refusal("start: " .. errno)
    assert(refused:find("refuses this user a user namespace", 1, true), refused)
  end
  assert(test_sandbox.refusal("start: Bad address") == "start: Bad address")
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

--- End to end: a process a sandboxed test starts is keyed by what its
--- module declares. Run again, the test stands; a change to a file of
--- the tree it does not declare leaves it standing; a change to one it
--- declares runs it again, and so does making one it declares that was
--- not there when it last ran. A module that declares a host of the
--- network, not a loopback one, has no verdict a key holds: it runs
--- every time, and none is assumed. One that does not declare `store`
--- stands too: what it starts can read only the store of its closure,
--- which its key holds.
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
  assert(Fs.write(root .. "/suite/online_test.tl", [[
local Child = require("cosmic.child")
local Test = require("cosmic.test")

Test.needs { network = { "example.com" }, store = true, reads = { "bin/probe" } }

local function test_child_could_reach_the_network()
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
  local first = said("3 ran, 0 stood")
  if unsandboxed(first) then return end
  assert(first:find("; sandboxed)", 1, true), first)
  local again = said("1 ran, 2 stood, 1 run every time (no key holds them)")
  assert(not again:find("assumed", 1, true), again)
  assert(Fs.write(root .. "/suite/unrelated.txt", "two"))
  said("1 ran, 2 stood, 1 run every time")
  assert(Fs.write(root .. "/suite/data.txt", "two"))
  said("2 ran, 1 stood, 1 run every time")
  said("1 ran, 2 stood, 1 run every time")
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
    -- Unsandboxed here: build/test_isolation_test.tl's case.
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

--- A worker that may write where this program is -- the cores a
--- portable cosmic extracts, in the `bootstrap` cache -- cannot be kept
--- from running it, by its name or through a link; one that writes
--- elsewhere can.
local function test_a_worker_that_writes_where_the_program_is_cannot_be_held(tmp: string)
  local cores = tmp .. "/cache/cores"
  assert(Fs.mkdirs(cores))
  assert(Fs.write(cores .. "/core", "c"))
  assert(Fs.symlink(cores .. "/core", tmp .. "/link"))
  assert(test_sandbox.forbiddable({ tmp .. "/elsewhere" }, { cores .. "/core" }))
  assert(test_sandbox.forbiddable({}, { cores .. "/core" }))
  assert(not test_sandbox.forbiddable({ tmp .. "/cache" }, { cores .. "/core" }))
  assert(not test_sandbox.forbiddable({ tmp .. "/cache" }, { tmp .. "/link" }))
end
