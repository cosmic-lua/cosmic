--- [`Child.start`]'s `policy` with a cap ([`Sandbox.Cap`]) beneath a grant
--- that gives more (cosmic/child/hold.tl's `held_caps` and `with_caps`):
--- under `isolate` file a read-only bind over the grant's holds the cap's
--- path, for the program and for a sandbox it starts of its own; without
--- it the start is refused, since Landlock cannot take letters back. The
--- kernel's own verdict on live children: a fake
--- ([`cosmic.fake`]) started under the policy. They need a host that lets
--- a sandbox nest (`requires`); where this host gives no user namespace,
--- Landlock or seccomp each skips itself (Test.skip).

local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local ChildPolicy = require("build.child_policy_fixture")

--- The temporary directory, which a start's root is built in, and `nest`,
--- since the sandboxes this test makes are roots a worker held by a
--- Landlock ruleset cannot build.
Test.policy{
  env = { "TMPDIR" },
  grants = { { calls = "nest" } },
  requires = { "nest" },
}

--- A working directory, writable, holding a `.git` with `config` and
--- `hooks`, and the fake to run in it: the grants a writing agent's tools
--- have, with `.git` capped to `r`.
local record Place
  probe: string
  work: string
  grants: {Sandbox.Grant}
end

local function placed(tmp: string): Place
  local at = ChildPolicy.nest_placed(tmp)
  local work = at.work .. "/rw"
  assert(Fs.mkdirs(work .. "/.git/hooks"))
  assert(Fs.write(work .. "/.git/config", "[core]\n"))
  assert(Fs.write(work .. "/a", "alpha\n"))
  for _, path in ipairs({ work .. "/.git", work .. "/.git/hooks" }) do
    assert(sys.chmod(path, 0x1ff))
  end
  for _, path in ipairs({ work .. "/.git/config", work .. "/a" }) do
    assert(sys.chmod(path, 0x1b6))
  end
  return { probe = at.probe, work = work, grants = {
    { path = at.probe, letters = "rx" }, { path = work, letters = "rwxc" },
    { at_most = work .. "/.git", letters = "r" }, { calls = "nest" } } }
end

local function test_a_cap_holds_its_path_read_only(tmp: string)
  local at = placed(tmp)
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = at.grants }
  local read = ChildPolicy.under(at.probe, policy, at.work, { "cat", ".git/config" })
  assert(read.code == 0 and read.said == "[core]\n", tostring(read.code) .. ": " .. read.said)
  local wrote = ChildPolicy.under(at.probe, policy, at.work, { "create-and-cat", "b", "x" })
  assert(wrote.code == 0 and wrote.said == "x\n", tostring(wrote.code) .. ": " .. wrote.said)
  for _, case in ipairs({ { "append", ".git/config", "x" }, { "create", ".git/hooks/pre-commit", "x" },
      { "rename", ".git/config", "c" }, { "rename", "a", ".git/a" } }) do
    local refused = ChildPolicy.under(at.probe, policy, at.work, case)
    assert(refused.code ~= 0, table.concat(case, " ") .. ": " .. refused.said)
  end
  -- The cap's directory is a mount point, which no rename or remove takes.
  local moved = ChildPolicy.under(at.probe, policy, at.work, { "rename", ".git", "g" })
  assert(moved.code ~= 0, moved.said)
  assert(Fs.read(at.work .. "/.git/config")! == "[core]\n")
  assert(not Fs.status(at.work .. "/.git/hooks/pre-commit")!.exists)
end

local function test_a_cap_holds_a_sandbox_the_program_starts(tmp: string)
  local at = placed(tmp)
  local scratch = assert(sys.realpath(tmp)) .. "/scratch"
  -- The sandbox the program starts builds its root in TMPDIR.
  local grants: mut {Sandbox.Grant} = { { path = scratch, letters = "rwc" }, { calls = "fork" } }
  for _, grant in ipairs(at.grants) do grants[#grants + 1] = grant end
  local policy: Sandbox.Policy = { isolate = { "file" }, setup = { set_env = { TMPDIR = scratch } }, grants = grants }
  -- The program grants its own sandbox `.` to write: the cap's bind is
  -- part of what it binds there, and stays read-only.
  local nested = ChildPolicy.under(at.probe, policy, at.work,
    { "run-writing", at.probe, "append", ".git/config", "x" })
  assert(nested.code == 0 and nested.said:find("^exit 1\n") ~= nil, tostring(nested.code) .. ": " .. nested.said)
  local beside = ChildPolicy.under(at.probe, policy, at.work, { "run-writing", at.probe, "create", "c", "y" })
  assert(beside.code == 0 and beside.said:find("^exit 0\n") ~= nil, tostring(beside.code) .. ": " .. beside.said)
  assert(Fs.read(at.work .. "/.git/config")! == "[core]\n")
end

--- A cap that leaves `rx` beneath one that leaves `r` runs nothing: the
--- outer cap's noexec holds the inner bind too.
local function test_a_cap_beneath_a_cap_runs_nothing_it_did_not(tmp: string)
  local at = placed(tmp)
  assert(Fs.write(at.work .. "/.git/hooks/p", assert(Fs.read(at.probe))))
  assert(sys.chmod(at.work .. "/.git/hooks/p", 0x1ed))
  local grants: mut {Sandbox.Grant} = { { at_most = at.work .. "/.git/hooks", letters = "rx" }, { calls = "fork" } }
  for _, grant in ipairs(at.grants) do grants[#grants + 1] = grant end
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = grants }
  local ran = ChildPolicy.under(at.probe, policy, at.work, { "run-program", at.work .. "/.git/hooks/p", "print", "hi" })
  assert(ran.code ~= 0, ran.said)
  -- Without the cap above, the inner one runs it.
  local alone: mut {Sandbox.Grant} = {}
  for _, grant in ipairs(grants) do
    if not (grant is Sandbox.Cap and grant.letters == "r") then alone[#alone + 1] = grant end
  end
  local runs = ChildPolicy.under(at.probe, { isolate = { "file" }, grants = alone }, at.work,
    { "run-program", at.work .. "/.git/hooks/p", "print", "hi" })
  assert(runs.code == 0, tostring(runs.code) .. ": " .. runs.said)
end

local function test_a_cap_named_relatively_holds_too(tmp: string)
  local at = placed(tmp)
  local grants: mut {Sandbox.Grant} = {}
  for _, grant in ipairs(at.grants) do
    if grant is Sandbox.Cap then
      grants[#grants + 1] = { at_most = ".git", letters = "r" }
    else
      grants[#grants + 1] = grant
    end
  end
  local policy: Sandbox.Policy = { isolate = { "file" }, grants = grants }
  local refused = ChildPolicy.under(at.probe, policy, at.work, { "append", ".git/config", "x" })
  assert(refused.code ~= 0, refused.said)
  assert(Fs.read(at.work .. "/.git/config")! == "[core]\n")
end

local function test_a_live_cap_needs_isolate_file(tmp: string)
  local at = placed(tmp)
  local grants: mut {Sandbox.Grant} = {}
  for _, grant in ipairs(at.grants) do
    if not grant is Sandbox.Calls then grants[#grants + 1] = grant end
  end
  local why = ChildPolicy.refused(at.probe, { grants = grants }, at.work)
  assert(why:find("add isolate \"file\"", 1, true) ~= nil, why)
end

local function test_a_cap_through_a_link_is_refused(tmp: string)
  local at = placed(tmp)
  assert(sys.symlink(at.work .. "/.git", at.work .. "/link"))
  local grants: mut {Sandbox.Grant} = {}
  for _, grant in ipairs(at.grants) do
    if grant is Sandbox.Cap then
      grants[#grants + 1] = { at_most = at.work .. "/link", letters = "r" }
    else
      grants[#grants + 1] = grant
    end
  end
  local why = ChildPolicy.refused(at.probe, { isolate = { "file" }, grants = grants }, at.work)
  assert(why:find("is reached through a link", 1, true) ~= nil, why)
  local missing: mut {Sandbox.Grant} = {}
  for _, grant in ipairs(at.grants) do
    if grant is Sandbox.Cap then
      missing[#missing + 1] = { at_most = at.work .. "/none", letters = "r" }
    else
      missing[#missing + 1] = grant
    end
  end
  local absent = ChildPolicy.refused(at.probe, { isolate = { "file" }, grants = missing }, at.work)
  assert(absent:find("a cap names what is there", 1, true) ~= nil, absent)
end
