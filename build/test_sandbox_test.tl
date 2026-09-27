--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): what a
--- worker is given, how what it reports is put back where the host has
--- it, and, end to end, what a test run with the switch on sees.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")
local Test = require("cosmic.test")

--- What a worker's plan gives it of the host, and the program it runs.
Test.needs{ host = { "/dev/urandom", "/etc", "/proc", "/usr/" }, tool = true }

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

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
  -- A declared cache is given to write at its own name, made first.
  inputs.cache_paths = { tmp .. "/caches/zig-global" }
  local cached = test_sandbox.plan(root, scratch, inputs, {})
  assert(cached.trouble == "", cached.trouble)
  assert(holds(cached.sandbox.unveil.writes, tmp .. "/caches/zig-global") and
    cached.sandbox.unveil.at[tmp .. "/caches/zig-global"] == nil)
  assert(Fs.exists(tmp .. "/caches/zig-global"))
  inputs.cache_paths = {}
  inputs.network = { ["127.0.0.1"] = true }
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
  assert(env.COSMIC_SANDBOX == "must", "how the test's own processes are confined is carried")
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

--- Runs `cosmic test` on `root` with `env`, answering what it printed
--- and whether it passed.
local function run(root: string, output: string, env: {string:string}): string, boolean
  local fd = assert(Fs.open_write(output))
  local result, trouble = Child.run({ assert(Proc.executable()), "test", "--all" }, {
    cwd = root, env = env, stdout = fd, stderr = fd, process_group = true, timeout_ms = 60000,
  })
  assert(Fs.close(fd))
  local text = assert(Fs.read(output))
  assert(result ~= nil, tostring(trouble) .. text)
  return text, result.ok
end

--- End to end: with the switch on, a test's worker runs in /tree, has
--- its own directory under /tmp, reads what its module declares of the
--- tree and nothing else of it, sees nothing of the host it was not
--- given, and reads only the variables it declares; and the run says it
--- was sandboxed. The same suite unsandboxed reads all of it. Where this
--- host cannot sandbox the run's workers -- the kernel refuses, or this
--- test runs as root in a sandbox already, where the kernel refuses a
--- third level -- the run says so, and runs them as it would have. A
--- switch that is neither "1" nor off is refused.
local function test_a_sandboxed_run_holds_each_worker_to_its_inputs(tmp: string)
  local root, hidden = tmp .. "/root", tmp .. "/hidden"
  assert(Fs.mkdirs(root .. "/suite"))
  assert(Fs.mkdirs(hidden))
  assert(Fs.write(root .. "/suite/data.txt", "declared"))
  assert(Fs.write(root .. "/suite/secret.txt", "undeclared"))
  assert(Fs.write(root .. "/suite/view_test.tl", string.format([[
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")

Test.needs { reads = { "suite/data.txt" }, env = { "DECLARED_VAR" } }

local function test_view(tmp: string)
  local here = assert(sys.getcwd())
  error(table.concat({ "seen", here, tmp,
    tostring((Fs.read(here .. "/suite/data.txt"))),
    tostring((Fs.read(here .. "/suite/secret.txt"))),
    tostring(sys.stat(%q) ~= nil), tostring(sys.getenv("DECLARED_VAR")),
    tostring(sys.getenv("UNDECLARED_VAR")), "end" }, "|"))
end
]], hidden)))
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  env.DECLARED_VAR = "d"
  env.UNDECLARED_VAR = "u"
  local real_root = assert(Fs.absolute(root))
  local text, ok = run(root, tmp .. "/plain", env)
  assert(not ok, text)
  local seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  local fields: {string} = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == real_root and fields[3] == "declared" and fields[4] == "undeclared" and
    fields[5] == "true" and fields[6] == "d" and fields[7] == "u", seen)
  env.COSMIC_TEST_SANDBOX = "1"
  text, ok = run(root, tmp .. "/sandboxed", env)
  assert(not ok, text)
  if text:find("no worker can be sandboxed here", 1, true) then
    assert(text:find("; unsandboxed, as no worker can be sandboxed here", 1, true), text)
    return
  end
  assert(text:find("; sandboxed", 1, true), text)
  seen = text:match("seen|([^\n]*)|end")
  assert(seen ~= nil, text)
  fields = {}
  for field in (seen .. "|"):gmatch("([^|]*)|") do fields[#fields + 1] = field end
  assert(fields[1] == "/tree" and fields[2] == "/tmp/tmp" and fields[3] == "declared" and
    fields[4] == "nil" and fields[5] == "false" and fields[6] == "d" and fields[7] == "nil", seen)
  -- Its failure names what it read undeclared, the declaration that
  -- would give it, and how to run it again sandboxed.
  assert(text:find("sandboxed, it read what its module does not declare:", 1, true), text)
  assert(text:find("reads        suite/secret.txt", 1, true), text)
  assert(text:find("env          UNDECLARED_VAR", 1, true), text)
  assert(text:find("declare: Test.needs {", 1, true), text)
  assert(text:find("rerun: COSMIC_TEST_SANDBOX=1 cosmic test suite/view_test.tl:test_view", 1, true),
    text)
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
  local env = observations.environment()
  env.COSMIC_VERDICT_CACHE = "0"
  env.COSMIC_TEST_ALL = nil
  env.COSMIC_SANDBOX = nil
  -- The program's cores stay where they are; only the caches move.
  env.COSMIC_PORTABLE_CACHE = env.COSMIC_PORTABLE_CACHE or Fs.cache_path("cores")
  env.XDG_CACHE_HOME = xdg
  env.COSMIC_ZIG_CACHE, env.COSMIC_ZIG_GLOBAL_CACHE = nil, nil
  env.COSMIC_TEST_SANDBOX = "1"
  local text, ok = run(root, tmp .. "/out", env)
  assert(not ok, text)
  if text:find("no worker can be sandboxed here", 1, true) then return end
  assert(text:find("wrote|true|false|end", 1, true), text)
  assert(Fs.read(xdg .. "/cosmic/zig-global/entry") == "cached")
  assert(not Fs.exists(xdg .. "/cosmic/bootstrap"))
end
