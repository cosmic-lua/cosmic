--- [`Child.start`]'s `policy` (cosmic/child.tl) on a live child: the kernel's
--- own verdict on the Landlock ruleset, the seccomp filter and the rlimits
--- a policy is made into. The child is a stand-in (build/stand_in.tl), a
--- static program that does what its script says, so a refusal shows as a
--- command that fails. A host whose kernel gives no Landlock or seccomp, and
--- every platform but Linux, skips the tests that start a child
--- (Test.skip); the refusals that come before a child do not.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local searchable = require("build.searchable")
local stand_in = require("build.stand_in")
local Sandbox = require("cosmic.sandbox")

--- The temporary directory and the environment the tests read.
Test.needs{ env = { "TMPDIR" } }

local DENIED <const> = "Permission denied"

--- Whether `why`, a start's failure, is the platform or the host giving no
--- Landlock or seccomp.
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

--- Runs `script` in `program` under `policy`: its output (stderr beside
--- stdout) and how it ended. Skips the test, returning nil, where the
--- host gives no sandbox; fails the test where the start is refused for
--- another reason.
local function under(program: string, policy: Sandbox.Policy, script: string, opts?: Child.Options): Outcome
  local options: Child.Options = opts or {}
  options.policy, options.stdout, options.stderr = policy, "capture", "stdout"
  local result, why = Child.run({ program, script }, options)
  if result == nil then
    assert(unsandboxable(why), "the start was refused: " .. why)
    if confine.sandbox_platform() then Test.skip(why) end
    return nil
  end
  return { code = result.code or -1, signal = result.signal or -1, said = result.stdout or "",
    timed_out = result.timed_out }
end

--- A grant of the program itself, which a child needs to run at all.
local function itself(program: string, more?: {Sandbox.Grant}): {Sandbox.Grant}
  local grants: {Sandbox.Grant} = { { path = program, letters = "rx" } }
  for _, grant in ipairs(more or {}) do grants[#grants + 1] = grant end
  return grants
end

local function test_a_granted_path_is_read_and_its_sibling_is_not(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/ro") and Fs.mkdirs(tmp .. "/other"))
  assert(Fs.write(tmp .. "/ro/a", "alpha\n") and Fs.write(tmp .. "/other/b", "beta\n"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = tmp .. "/ro", letters = "r" } }) }
  local read = under(probe, policy, "cat " .. tmp .. "/ro/a")
  if read == nil then return end
  assert(read.code == 0 and read.said == "alpha\n", read.code .. ": " .. read.said)
  local sibling = under(probe, policy, "cat " .. tmp .. "/other/b")
  assert(sibling.code == 1 and sibling.said:find(DENIED, 1, true), "refused: " .. sibling.said)
  -- Nothing is written where only read is given.
  local blind = under(probe, policy, "create " .. tmp .. "/ro/new x")
  assert(blind.code == 1 and blind.said:find(DENIED, 1, true), blind.said)
end

local function test_a_relative_grant_is_relative_to_the_childs_directory(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/work/ro") and Fs.mkdirs(tmp .. "/work/shut"))
  assert(Fs.write(tmp .. "/work/ro/a", "alpha\n") and Fs.write(tmp .. "/work/shut/b", "beta\n"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = "ro", letters = "r" } }) }
  local read = under(probe, policy, "cat ro/a", { cwd = tmp .. "/work" })
  if read == nil then return end
  assert(read.code == 0 and read.said == "alpha\n", read.code .. ": " .. read.said)
  local shut = under(probe, policy, "cat shut/b", { cwd = tmp .. "/work" })
  assert(shut.code == 1 and shut.said:find(DENIED, 1, true), shut.said)
end

local function test_a_grant_of_a_path_that_is_not_there_fails_naming_it(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = tmp .. "/absent", letters = "r" } }) }
  local result, why = Child.run({ probe, "print hi" }, { policy = policy })
  assert(result == nil)
  if unsandboxable(why) then
    if confine.sandbox_platform() then Test.skip(why) end
    return
  end
  assert(why:find("absent", 1, true), why)
end

local function test_a_program_nobody_granted_does_not_start_and_the_failure_names_the_grant(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local real = assert(sys.realpath(probe))
  local none, why = Child.start({ probe, "print hi" }, { policy = {} })
  assert(none == nil)
  assert(why:find("^child: start: sandbox: "), why)
  assert(why:find(real, 1, true) and why:find("r and x", 1, true), why)
  assert(why:find("system", 1, true) and why:find("the program", 1, true), why)
  -- Read without run names what is missing.
  local read, trouble = Child.start({ probe, "print hi" },
    { policy = { grants = { { path = probe, letters = "r" } } } })
  assert(read == nil and trouble:find("not granted x:", 1, true), trouble)
  -- A grant on the directory above gives both.
  local above = under(probe, { grants = { { path = tmp, letters = "rx" } } }, "print hi")
  if above == nil then return end
  assert(above.code == 0 and above.said == "hi\n", above.said)
end

local function test_an_interpreter_must_be_granted_too(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/scripts"))
  assert(Fs.write(tmp .. "/scripts/run", "#!" .. probe .. "\nprint scripted\n", 493))
  local policy: Sandbox.Policy = { grants = { { path = tmp .. "/scripts", letters = "rx" } } }
  local none, why = Child.start({ tmp .. "/scripts/run" }, { policy = policy })
  assert(none == nil and why:find("interpreter", 1, true) and why:find(assert(sys.realpath(probe)), 1, true), why)
  policy.grants[#policy.grants + 1] = { path = probe, letters = "rx" }
  local ran, trouble = Child.run({ tmp .. "/scripts/run" }, { policy = policy, stdout = "capture" })
  if ran == nil then
    assert(unsandboxable(trouble), trouble)
    if confine.sandbox_platform() then Test.skip(trouble) end
    return
  end
  assert(ran.stdout == "scripted\n", ran.stdout)
end

local function test_a_program_named_without_a_path_must_be_found_and_a_link_is_granted_by_what_it_leads_to(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/bin"))
  assert(Fs.symlink(probe, tmp .. "/bin/tool"))
  local none, why = Child.start({ "no-such-program-here" }, { policy = { grants = itself(probe) } })
  assert(none == nil and why:find("no-such-program-here", 1, true), why)
  -- Named through a link, the grant it needs is of what the link leads to.
  local result, trouble = Child.run({ tmp .. "/bin/tool", "print hi" },
    { policy = { grants = itself(probe) }, stdout = "capture" })
  if result == nil then
    assert(unsandboxable(trouble), trouble)
    if confine.sandbox_platform() then Test.skip(trouble) end
    return
  end
  assert(result.stdout == "hi\n", result.stdout)
end

local function test_the_environment_is_the_policys_alone(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local passed = sys.getenv("TMPDIR")
  assert(passed ~= nil, "the test has no TMPDIR to pass through")
  local hidden: string
  for name in pairs(sys.environ()) do
    if name ~= "TMPDIR" and hidden == nil then hidden = name end
  end
  local script = "env-of TMPDIR; env-of SET; env-of ABSENT; env-of " .. (hidden or "NOT_THERE")
  local policy: Sandbox.Policy = { grants = itself(probe), env = { "TMPDIR", "ABSENT" },
    set_env = { SET = "value with spaces" } }
  local out = under(probe, policy, script)
  if out == nil then return end
  assert(out.code == 0, out.said)
  local want = "TMPDIR=" .. passed .. "\nSET=value with spaces\nABSENT unset\n" ..
    (hidden or "NOT_THERE") .. " unset\n"
  assert(out.said == want, out.said)
  -- Set beats passed through, a name a start was given or not.
  local both = under(probe, { grants = itself(probe), env = { "TMPDIR" }, set_env = { TMPDIR = "mine" } },
    "env-of TMPDIR")
  assert(both.said == "TMPDIR=mine\n", both.said)
  -- With no env and no set_env the child has none at all.
  local none = under(probe, { grants = itself(probe) }, "env-of TMPDIR")
  assert(none.said == "TMPDIR unset\n", none.said)
end

local function test_env_beside_a_policy_raises(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local ok, why = pcall(Child.start, { probe }, { policy = { grants = itself(probe) }, env = {} })
  assert(not ok and tostring(why):find("policy and env exclude each other", 1, true), tostring(why))
  local other, trouble = pcall(Child.start, { probe }, { policy = {}, sandbox = { offline = true } })
  assert(not other and tostring(trouble):find("policy and sandbox", 1, true), tostring(trouble))
end

local function test_a_policy_that_is_not_met_fails_naming_the_field(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local base = itself(probe)
  local function grants(): {Sandbox.Grant}
    local copy: {Sandbox.Grant} = {}
    for i, grant in ipairs(base) do copy[i] = grant end
    return copy
  end
  local cases: {{any}} = {
    { { grants = grants(), connect = { "example.com:443" } }, 'connect "example.com:443"' },
    { { grants = grants(), set_env_digests = { X = string.rep("0", 64) } }, 'set_env_digests "X"' },
  }
  for _, case in ipairs(cases) do
    local none, why = Child.start({ probe, "print hi" }, { policy = case[1] as Sandbox.Policy })
    assert(none == nil, case[2])
    assert(why:find("^child: start: sandbox: ") and why:find(case[2] as string, 1, true), why)
    assert(why:find("not yet available", 1, true) or why:find("cannot start", 1, true), why)
  end
  local from = grants()
  from[#from + 1] = { path = "/data", letters = "r", from = "/srv/data" }
  local none, why = Child.start({ probe }, { policy = { grants = from } })
  assert(none == nil and why:find('grant "/data"', 1, true) and why:find("from", 1, true), why)
  assert(why:find('isolate "file"', 1, true), why)
end

local function test_a_policy_that_does_not_merge_fails_naming_the_field(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local none, why = Child.start({ probe }, { policy = { grants = { { path = probe, letters = "q" } } } })
  assert(none == nil and why:find("/grants/0/letters", 1, true), why)
  local profile, trouble = Child.start({ probe }, { policy = { profiles = { "bogus" } } })
  assert(profile == nil and trouble:find("bogus", 1, true), trouble)
end

local function test_tmp_is_made_writable_named_by_tmpdir_and_removed(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local policy: Sandbox.Policy = { grants = itself(probe), tmp = true }
  local out = under(probe, policy,
    "env-of TMPDIR; write $TMPDIR/note hello; cat $TMPDIR/note; mkdirs $TMPDIR/sub/deeper; create $TMPDIR/sub/deeper/f x")
  if out == nil then return end
  assert(out.code == 0, out.said)
  local dir = out.said:match("^TMPDIR=([^\n]+)\n")
  assert(dir ~= nil and out.said:find("\nhello\n", 1, true), out.said)
  assert(dir:find("cosmic-sandbox-", 1, true), dir)
  assert(Fs.exists(dir) == false, dir .. " was left behind")
  -- A sibling of it is not the child's.
  local sibling = under(probe, policy, "write " .. tmp .. "/outside x")
  assert(sibling.code == 1 and sibling.said:find(DENIED, 1, true), sibling.said)
  assert(Fs.exists(tmp .. "/outside") == false)
  -- No tmp, no TMPDIR.
  local without = under(probe, { grants = itself(probe) }, "env-of TMPDIR")
  assert(without.said == "TMPDIR unset\n", without.said)
end

--- The directories a policy's `tmp` made that are still in the temporary directory.
local function sandbox_directories(): {string}
  local found: {string} = {}
  for _, name in ipairs((assert(Fs.list(sys.getenv("TMPDIR") or "/tmp")))) do
    if name:find("^cosmic%-sandbox%-") then found[#found + 1] = name end
  end
  return found
end

local function test_tmp_is_removed_after_a_child_ended_for_its_timeout(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local policy: Sandbox.Policy = { grants = itself(probe), tmp = true }
  local handle, why = Child.start({ probe, "write $TMPDIR/f x; sleep-forever" },
    { policy = policy, stdout = "null", stderr = "null" })
  if handle == nil then
    assert(unsandboxable(why), why)
    if confine.sandbox_platform() then Test.skip(why) end
    return
  end
  assert(#sandbox_directories() == 1, "expected the child's one directory")
  local result = assert(handle:wait(200000000))
  assert(result.timed_out)
  assert(#sandbox_directories() == 0, "the directory outlived its child")
end

local function test_a_start_that_fails_leaves_no_tmp_behind(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local policy: Sandbox.Policy = { grants = itself(probe, { { path = tmp .. "/absent", letters = "r" } }), tmp = true }
  local none, why = Child.start({ probe, "print hi" }, { policy = policy })
  assert(none == nil)
  if unsandboxable(why) then
    if confine.sandbox_platform() then Test.skip(why) end
    return
  end
  assert(#sandbox_directories() == 0, "a failed start left its directory behind")
end

local function test_limits_default_and_as_given(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local script = "rlimit nofile; rlimit core; rlimit fsize; rlimit cpu"
  local default = under(probe, { grants = itself(probe) }, script)
  if default == nil then return end
  local hard = assert(sys.getrlimit(sys.RLIMIT_NOFILE)).hard
  local want = math.min(1024, hard)
  assert(default.said == ("nofile %d %d\ncore 0 0\nfsize %d %d\ncpu %d %d\n"):format(want, want,
    math.maxinteger, math.maxinteger, math.maxinteger, math.maxinteger), default.said)
  local given = under(probe, { grants = itself(probe),
    limits = { open_files = 32, file_bytes = 4096, cpu_seconds = 7 } }, script)
  assert(given.said == "nofile 32 32\ncore 0 0\nfsize 4096 4096\ncpu 7 7\n", given.said)
  -- A write past file_bytes does not complete.
  local capped = under(probe, { grants = itself(probe, { { path = searchable.share(tmp), letters = "rwc" } }),
    limits = { file_bytes = 8 } }, "write " .. tmp .. "/small abc; write " .. tmp .. "/big " .. string.rep("x", 64))
  assert(capped.code ~= 0 or capped.signal > 0, "a write of 65 bytes went through: " .. capped.said)
  assert(Fs.read(tmp .. "/small") == "abc\n")
end

local function test_a_limit_above_this_processs_hard_limit_fails_the_start(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local ceiling = 1 << 20
  local held = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  -- A hard limit of none leaves nothing to exceed: give this process one
  -- well past what any test of it opens, which only lowers it.
  if held.hard > ceiling then
    assert(sys.setrlimit(sys.RLIMIT_NOFILE, math.min(held.soft, ceiling), ceiling))
    held = assert(sys.getrlimit(sys.RLIMIT_NOFILE))
  end
  local policy: Sandbox.Policy = { grants = itself(probe), limits = { open_files = held.hard + 1 } }
  local none, why = Child.start({ probe, "print hi" }, { policy = policy })
  if none ~= nil then
    -- A process that may raise its hard limit (root) is given what it asked.
    local result = assert(none:wait())
    assert(result.ok, "the start succeeded, and the child failed")
    return
  end
  if unsandboxable(why) then
    if confine.sandbox_platform() then Test.skip(why) end
    return
  end
  assert(why:find("^child: start: ") and why:find("not permitted", 1, true), why)
end

local function test_promises_are_the_filters_and_fattr_changes_a_mode(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local file = tmp .. "/f"
  assert(Fs.write(file, "x"))
  searchable.share(file)
  local grants = itself(probe, { { path = file, letters = "rw" } })
  local without = under(probe, { grants = grants }, "chmod " .. file .. " 600")
  if without == nil then return end
  assert(without.code == 1, without.said)
  -- A root caller's child owns none of the host's files, so no promise lets
  -- it change a mode: chmod is the owner's alone.
  if sys.getuid() == 0 then return end
  local with = under(probe, { grants = grants, promises = { "fattr" } }, "chmod " .. file .. " 600")
  assert(with.code == 0, with.said)
end

local function test_only_the_descriptors_named_reach_the_program(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  assert(Fs.write(tmp .. "/f", "x"))
  local kept = assert(sys.open(tmp .. "/f", sys.O_RDONLY))
  local dropped = assert(sys.open(tmp .. "/f", sys.O_RDONLY))
  local policy: Sandbox.Policy = { grants = itself(probe) }
  local named = under(probe, policy, "fd-closed 3", { fds = { [3] = kept } })
  -- The descriptor this process has open and does not name is shut in the child.
  local unnamed = under(probe, policy, "fd-closed " .. dropped, { fds = { [3] = kept } })
  local _, _ = sys.close(kept), sys.close(dropped)
  if named == nil then return end
  -- fd-closed ends with status 1 for a descriptor that is open.
  assert(named.code == 1, "descriptor 3 should be open: " .. named.said)
  assert(dropped ~= 3 and unnamed.code == 0, "descriptor " .. dropped .. " reached the child: " .. unnamed.said)
end

local function test_a_policy_of_too_many_grants_fails_before_it_makes_anything(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  local before = #sandbox_directories()
  for _, count in ipairs({ 256, 300 }) do
    local grants = itself(probe)
    for i = #grants + 1, count do grants[i] = { path = tmp .. "/g" .. i, letters = "r" } end
    local none, why = Child.start({ probe, "print hi" }, { policy = { grants = grants, tmp = true } })
    assert(none == nil and why:find("^child: start: sandbox: grants: ") and why:find("256", 1, true), why)
    assert(#sandbox_directories() == before, count .. " grants left a directory behind")
  end
end

local function test_the_tmp_directory_is_absolute_and_usable_from_another_directory(tmp: string)
  local probe = assert(stand_in.build(searchable.open(tmp) .. "/stand-in"))
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  local out = under(probe, { grants = itself(probe), tmp = true },
    "env-of TMPDIR; write $TMPDIR/note hi; cat $TMPDIR/note", { cwd = tmp .. "/elsewhere" })
  if out == nil then return end
  assert(out.code == 0, out.said)
  assert(out.said:find("^TMPDIR=/") and out.said:find("\nhi\n", 1, true), out.said)
end
