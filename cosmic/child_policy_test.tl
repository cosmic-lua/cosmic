--- [`Child.start`]'s `policy` (cosmic/child.tl) on a live child: the kernel's
--- own verdict on the Landlock ruleset, the seccomp filter and the rlimits
--- a policy is made into. The child is a fake ([`cosmic.fake`]) of
--- build/child_policy_fake.tl, a static program whose first argument
--- names a case, so a refusal shows as a case that fails. They need a sandbox (`requires`): where the platform
--- has none they are not applicable, and where this host's kernel gives no
--- Landlock or seccomp each skips itself (Test.skip). The refusals that come
--- before a child, which hold on every platform, are in
--- cosmic/child_policy_anywhere_test.tl.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local searchable = require("build.searchable")
local Fake = require("cosmic.fake")
local _ = require("build.child_policy_fake")
local Sandbox = require("cosmic.sandbox")

--- The temporary directory and the environment the tests read.
Test.policy{ env = { "TMPDIR" }, requires = { "sandbox" } }

local DENIED <const> = "Permission denied"

--- Whether `why`, a start's failure, is the host giving no Landlock or seccomp.
local function unsandboxable(why: string): boolean
  return why:find("Landlock", 1, true) ~= nil or why:find("seccomp", 1, true) ~= nil or
    why:find("not implemented", 1, true) ~= nil
end

--- What a script left and how its program ended.
local record Outcome
  code: integer
  signal: integer
  said: string
  timed_out: boolean
end

--- Runs `program` with `args` under `policy`: its output (stderr beside
--- stdout) and how it ended. Skips the test, returning nil, where the
--- host gives no Landlock or seccomp; fails the test where the start is
--- refused for another reason.
local function under(program: string, policy: Sandbox.Policy, args: {string}, opts?: Child.Options): Outcome
  local options: Child.Options = { ...(opts or { timeout_ns = Child.FOREVER }), policy = policy, stdout = "capture", stderr = "stdout" }
  local argv: mut {string} = { program }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, why = Child.run(argv, options)
  if result == nil then
    assert(unsandboxable(tostring(why)), "the start was refused: " .. tostring(why))
    Test.skip(tostring(why))
  end
  local held = assert(result, "Test.skip ends the test where the start is refused")
  return { code = held.code or -1, signal = held.signal or -1, said = held.stdout or "",
    timed_out = held.timed_out }
end

--- A grant of the program itself, which a child needs to run at all.
local function itself(program: string, more?: {Sandbox.Grant}): {Sandbox.Grant}
  local grants: mut {Sandbox.Grant} = { { path = program, letters = "rx" } }
  for _, grant in ipairs(more or {}) do grants[#grants + 1] = grant end
  return grants
end

local function test_a_granted_path_is_read_and_its_sibling_is_not(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  assert(Fs.mkdirs(tmp .. "/ro"))
  assert(Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha\n"))
  assert(Fs.write(tmp .. "/other/b", "beta\n"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = tmp .. "/ro", letters = "r" } }) }
  local read = under(probe, policy, { "cat", tmp .. "/ro/a" })
  assert(read.code == 0 and read.said == "alpha\n", tostring(read.code) .. ": " .. read.said)
  local sibling = under(probe, policy, { "cat", tmp .. "/other/b" })
  assert(sibling.code == 1 and sibling.said:find(DENIED, 1, true) ~= nil, "refused: " .. sibling.said)
  -- Nothing is written where only read is given.
  local blind = under(probe, policy, { "create", tmp .. "/ro/new", "x" })
  assert(blind.code == 1 and blind.said:find(DENIED, 1, true) ~= nil, blind.said)
end

local function test_a_relative_grant_is_relative_to_the_childs_directory(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  assert(Fs.mkdirs(tmp .. "/work/ro"))
  assert(Fs.mkdirs(tmp .. "/work/shut"))
  assert(Fs.write(tmp .. "/work/ro/a", "alpha\n"))
  assert(Fs.write(tmp .. "/work/shut/b", "beta\n"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = "ro", letters = "r" } }) }
  local read = under(probe, policy, { "cat", "ro/a" }, { timeout_ns = Child.FOREVER, cwd = tmp .. "/work" })
  assert(read.code == 0 and read.said == "alpha\n", tostring(read.code) .. ": " .. read.said)
  local shut = under(probe, policy, { "cat", "shut/b" }, { timeout_ns = Child.FOREVER, cwd = tmp .. "/work" })
  assert(shut.code == 1 and shut.said:find(DENIED, 1, true) ~= nil, shut.said)
end

local function test_a_grant_of_a_path_that_is_not_there_fails_naming_it(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = tmp .. "/absent", letters = "r" } }) }
  local result, why = Child.run({ probe, "print", "hi" }, { timeout_ns = Child.FOREVER, policy = policy })
  assert(result == nil)
  if unsandboxable(tostring(why)) then
    Test.skip(tostring(why))
    return
  end
  assert(why.message:find("absent", 1, true), why)
end

local function test_a_grant_on_the_directory_above_a_program_gives_it_both_r_and_x(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local above = under(probe, { grants = { { path = tmp, letters = "rx" } } }, { "print", "hi" })
  assert(above.code == 0 and above.said == "hi\n", above.said)
end

local function test_an_interpreter_that_is_granted_too_runs_the_script(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  assert(Fs.mkdirs(tmp .. "/scripts"))
  assert(Fs.write(tmp .. "/scripts/run", "#!" .. probe .. "\nscripted\n", 493))
  local policy: Sandbox.Policy = { grants = { { path = tmp .. "/scripts", letters = "rx" },
    { path = probe, letters = "rx" } } }
  local ran, trouble = Child.run({ tmp .. "/scripts/run" }, { timeout_ns = Child.FOREVER, policy = policy, stdout = "capture" })
  if ran == nil then
    assert(unsandboxable(tostring(trouble)), trouble)
    Test.skip(tostring(trouble))
    return
  end
  assert(ran.stdout == "scripted\n", ran.stdout)
end

local function test_a_program_named_through_a_link_is_granted_by_what_it_leads_to(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  assert(Fs.mkdirs(tmp .. "/bin"))
  assert(Fs.symlink(probe, tmp .. "/bin/tool"))
  -- Named through a link, the grant it needs is of what the link leads to.
  local result, trouble = Child.run({ tmp .. "/bin/tool", "print", "hi" },
    { timeout_ns = Child.FOREVER, policy = { grants = itself(probe) }, stdout = "capture" })
  if result == nil then
    assert(unsandboxable(tostring(trouble)), trouble)
    Test.skip(tostring(trouble))
    return
  end
  assert(result.stdout == "hi\n", result.stdout)
end

local function test_the_environment_is_the_policys_alone(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local passed = sys.getenv("TMPDIR")
  assert(passed ~= nil, "the test has no TMPDIR to pass through")
  local hidden: string?
  for name in pairs(sys.environ()) do
    if name ~= "TMPDIR" and hidden == nil then hidden = name end
  end
  local script = { "env", "TMPDIR", "SET", "ABSENT", hidden or "NOT_THERE" }
  local policy: Sandbox.Policy = { grants = itself(probe), env = { "TMPDIR", "ABSENT" },
    set_env = { SET = "value with spaces" } }
  local out = under(probe, policy, script)
  assert(out.code == 0, out.said)
  local want = "TMPDIR=" .. passed .. "\nSET=value with spaces\nABSENT unset\n" ..
    (hidden or "NOT_THERE") .. " unset\n"
  assert(out.said == want, out.said)
  -- Set beats passed through, a name a start was given or not.
  local both = under(probe, { grants = itself(probe), env = { "TMPDIR" }, set_env = { TMPDIR = "mine" } },
    { "env", "TMPDIR" })
  assert(both.said == "TMPDIR=mine\n", both.said)
  -- With no env and no set_env the child has none at all.
  local none = under(probe, { grants = itself(probe) }, { "env", "TMPDIR" })
  assert(none.said == "TMPDIR unset\n", none.said)
end

local function test_tmp_is_made_writable_named_by_tmpdir_and_removed(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local policy: Sandbox.Policy = { grants = itself(probe), tmp = true }
  local out = under(probe, policy,
    { "use-tmp", "hello", "deep" })
  assert(out.code == 0, out.said)
  local dir = out.said:match("^TMPDIR=([^\n]+)\n")
  assert(dir ~= nil and out.said:find("\nhello\n", 1, true) ~= nil, out.said)
  assert(dir:find("cosmic-sandbox-", 1, true), dir)
  assert(not assert(Fs.status(dir)).exists, dir .. " was left behind")
  -- A sibling of it is not the child's.
  local sibling = under(probe, policy, { "write", tmp .. "/outside", "x" })
  assert(sibling.code == 1 and sibling.said:find(DENIED, 1, true) ~= nil, sibling.said)
  assert(not assert(Fs.status(tmp .. "/outside")).exists)
  -- No tmp, no TMPDIR.
  local without = under(probe, { grants = itself(probe) }, { "env", "TMPDIR" })
  assert(without.said == "TMPDIR unset\n", without.said)
end

--- The directories a policy's `tmp` made that are still in the temporary directory.
local function sandbox_directories(): {string}
  local found: mut {string} = {}
  for _, name in ipairs((assert(Fs.list(sys.getenv("TMPDIR") or "/tmp")))) do
    if name:find("^cosmic%-sandbox%-") then found[#found + 1] = name end
  end
  return found
end

local function test_tmp_is_removed_after_a_child_ended_for_its_timeout(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local policy: Sandbox.Policy = { grants = itself(probe), tmp = true }
  local handle, why = Child.start({ probe, "write-tmp-and-wait" },
    { timeout_ns = Child.FOREVER, policy = policy, stdout = "null", stderr = "null" })
  if handle == nil then
    assert(unsandboxable(tostring(why)), why)
    Test.skip(tostring(why))
    return
  end
  assert(#sandbox_directories() == 1, "expected the child's one directory")
  local result = assert(handle:wait(200000000))
  assert(result.timed_out)
  assert(#sandbox_directories() == 0, "the directory outlived its child")
end

local function test_a_start_that_fails_leaves_no_tmp_behind(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = tmp .. "/absent", letters = "r" } }), tmp = true }
  local none, why = Child.start({ probe, "print", "hi" }, { timeout_ns = Child.FOREVER, policy = policy })
  assert(none == nil)
  if unsandboxable(tostring(why)) then
    Test.skip(tostring(why))
    return
  end
  assert(#sandbox_directories() == 0, "a failed start left its directory behind")
end

local function test_limits_default_and_as_given(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local script = { "rlimits", "nofile", "core", "fsize", "cpu" }
  local default = under(probe, { grants = itself(probe) }, script)
  local hard = assert(sys.getrlimit(sys.RLIMIT_NOFILE)).hard
  local want = math.min(1024, hard)
  assert(default.said == ("nofile %d %d\ncore 0 0\nfsize %d %d\ncpu %d %d\n"):format(want, want,
    math.maxinteger, math.maxinteger, math.maxinteger, math.maxinteger), default.said)
  local given = under(probe, { grants = itself(probe),
    limits = { open_files = 32, file_bytes = 4096, cpu_seconds = 7 } }, script)
  assert(given.said == "nofile 32 32\ncore 0 0\nfsize 4096 4096\ncpu 7 7\n", given.said)
  -- A write past file_bytes does not complete.
  local capped = under(probe, { grants = itself(probe, { { path = searchable.share(tmp), letters = "rwc" } }),
    limits = { file_bytes = 8 } }, { "write", tmp .. "/small", "abc", tmp .. "/big", string.rep("x", 64) })
  assert(capped.code ~= 0 or capped.signal > 0, "a write of 65 bytes went through: " .. capped.said)
  assert(assert(Fs.read(tmp .. "/small")) == "abc\n")
end

local function test_a_limit_above_this_processs_hard_limit_fails_the_start(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local ceiling = 1 << 20
  local held = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  -- A hard limit of none leaves nothing to exceed: give this process one
  -- well past what any test of it opens, which only lowers it.
  if held.hard > ceiling then
    assert(sys.setrlimit(sys.RLIMIT_NOFILE, math.min(held.soft, ceiling), ceiling))
    held = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  end
  local policy: Sandbox.Policy = { grants = itself(probe), limits = { open_files = held.hard + 1 } }
  local none, why = Child.start({ probe, "print", "hi" }, { timeout_ns = Child.FOREVER, policy = policy })
  if none ~= nil then
    -- A process that may raise its hard limit (root) is given what it asked.
    local result = assert(none:wait())
    assert(result.ok, "the start succeeded, and the child failed")
    return
  end
  if unsandboxable(tostring(why)) then
    Test.skip(tostring(why))
    return
  end
  assert(why.message:find("^child: start: ") and why.message:find("not permitted", 1, true), why)
end

local function test_without_fattr_no_promise_lets_a_child_change_a_mode(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local file = tmp .. "/f"
  assert(Fs.write(file, "x"))
  searchable.share(file)
  local without = under(probe, { grants = itself(probe, { { path = file, letters = "rw" } }) },
    { "chmod", file, "600" })
  assert(without.code == 1, without.said)
end

--- A root caller's child owns none of the host's files, so no promise lets
--- it change a mode: chmod is the owner's alone.
local function test_fattr_lets_a_child_change_a_mode_of_its_own_file(tmp: string)
  if sys.getuid() == 0 then
    Test.skip("this process is root, whose child owns none of the host's files")
    return
  end
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  local file = tmp .. "/f"
  assert(Fs.write(file, "x"))
  searchable.share(file)
  local with = under(probe, { grants = itself(probe, { { path = file, letters = "rw" }, { calls = "fattr" } }) }, { "chmod", file, "600" })
  assert(with.code == 0, with.said)
end

local function test_only_the_descriptors_named_reach_the_program(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  assert(Fs.write(tmp .. "/f", "x"))
  local kept = assert(sys.open(tmp .. "/f", sys.O_RDONLY))
  local dropped = assert(sys.open(tmp .. "/f", sys.O_RDONLY))
  local policy: Sandbox.Policy = { grants = itself(probe) }
  local named = under(probe, policy, { "fd-closed", "3" }, { timeout_ns = Child.FOREVER, fds = { [3] = kept } })
  -- The descriptor this process has open and does not name is shut in the child.
  local unnamed = under(probe, policy, { "fd-closed", tostring(dropped) }, { timeout_ns = Child.FOREVER, fds = { [3] = kept } })
  local _, _ = sys.close(kept), sys.close(dropped)
  -- fd-closed ends with status 1 for a descriptor that is open.
  assert(named.code == 1, "descriptor 3 should be open: " .. named.said)
  assert(dropped ~= 3 and unnamed.code == 0, "descriptor " .. tostring(dropped) .. " reached the child: " .. unnamed.said)
end

local function test_the_tmp_directory_is_absolute_and_usable_from_another_directory(tmp: string)
  local probe = assert(Fake.build(searchable.open(tmp) .. "/fake", "build.child_policy_fake"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  local out = under(probe, { grants = itself(probe), tmp = true },
    { "use-tmp", "hi" }, { timeout_ns = Child.FOREVER, cwd = tmp .. "/elsewhere" })
  assert(out.code == 0, out.said)
  assert(out.said:find("^TMPDIR=/") and out.said:find("\nhi\n", 1, true), out.said)
end
