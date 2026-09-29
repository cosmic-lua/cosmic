--- `cosmic test`'s sandboxed worker (build/test_sandbox.tl): what a
--- worker is given, and how what it reports is put back where the host
--- has it. A worker's whole plan, which reads the program it gives, and
--- what a test run with the switch on sees, end to end, are in
--- build/test_sandbox_tool_test.tl.

local Fs = require("cosmic.fs")
local observations = require("build.filesystem_observations")
local test_inputs = require("build.test_inputs")
local test_sandbox = require("build.test_sandbox")

--- An `Effective` holding `files` of the tree and nothing else declared.
local function effective(files: {string}): test_inputs.Effective
  local out: test_inputs.Effective = { files = {}, reads = {}, host = {}, env = {}, network = {},
    processes = false, tool = false, store = false }
  for _, file in ipairs(files) do out.files[file] = true end
  return out
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

--- A failure to start a sandbox where the kernel refuses a user
--- namespace is said plainly, naming why; any other is as it was.
local function test_a_refused_user_namespace_is_said_plainly()
  local none = test_sandbox.refusal("start: No space left on device")
  assert(none:find("allows no user namespaces", 1, true) and
    none:find("No space left on device", 1, true), none)
  for _, errno in ipairs({ "Operation not permitted", "Permission denied" }) do
    local refused = test_sandbox.refusal("start: " .. errno)
    assert(refused:find("refuses this user a user namespace", 1, true), refused)
    -- A Landlock domain, which a test worker's process may be held by,
    -- refuses a mount EPERM alone.
    assert((refused:find("held by a Landlock ruleset: declare `nests = true` in the " ..
      "starting test's Test.needs", 1, true) ~= nil) == (errno == "Operation not permitted"),
      refused)
  end
  assert(test_sandbox.refusal("start: Bad address") == "start: Bad address")
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
