--- The policy the tools are held to: what it grants, bash run under it
--- in a sandbox of its own, the commands' kept home, PATH's programs and
--- a worktree's repository. On Linux the policy nests a sandbox, so the
--- module needs a host that lets one nest.

local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Policy = require("cosmic.agent.policy")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

Test.policy{ profiles = { "system" }, env = { "PATH", "TMPDIR" }, promises = { "nest" }, requires = { "nest" } }

local slurp = agent_fixture.slurp
local scratch = agent_fixture.scratch

local function test_the_sandbox_holds_the_tools()
  local dir, outside = scratch(), scratch()
  local p = assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))
  local names, _ = sys.uname()
  assert(names ~= nil, "uname")
  local env = p.set_env
  if names.sysname == "Darwin" then
    assert(env == nil)
  else
    assert(env ~= nil, "Linux sets an environment")
    assert(env["USER"] == "agent" and env["LOGNAME"] == "agent" and env["HOME"] == "/tmp")
  end
  assert(Policy.allows(p, dir .. "/new/file.txt", "w"))
  assert(Policy.allows(p, "/usr/bin", "r") and not Policy.allows(p, "/usr/bin/x", "w"))
  local ok, why = Policy.allows(p, outside .. "/x", "w")
  assert(not ok and why:find("cosmic docs cosmic.agent.policy", 1, true) ~= nil, why)
  assert(not Policy.allows(p, dir .. "/no/../../escape", "w"))
  assert(not Policy.allows(p, outside .. "/x", "r"))
  assert(not Policy.allows(p, "/proc/self/environ", "r"))
  local some = assert(Policy.of(dir, { mode = "read", network = false, grants = { { path = outside, letters = "w" } } }))
  assert(Policy.allows(some, outside, "w") and not Policy.allows(some, outside .. "/new", "wc"))
  local ctx: Tools.Context = { cwd = dir, policy = p }
  assert(Tools.run("write", { path = outside .. "/x", content = "no" }, ctx).is_error)
  assert(Tools.run("write", { path = "in.txt", content = "yes" }, ctx).is_error == false)
  assert(Tools.run("read", { path = outside .. "/x" }, ctx).is_error)
  assert(Tools.run("edit", { path = outside .. "/x", edits = { { oldText = "a", newText = "b" } } }, ctx).is_error)
  -- bash runs under the policy: the directory is its own, and nothing else is.
  local r = Tools.run("bash", { command = "cat in.txt; echo more > made.txt; echo x > " .. outside .. "/x" }, ctx)
  assert(r.is_error and r.text:find("yes", 1, true) ~= nil and slurp(dir .. "/made.txt") == "more\n", r.text)
  assert(slurp(outside .. "/x") == "", r.text)
  -- read: nothing of the directory changes.
  local reading = assert(Policy.of(dir, { mode = "read", network = false, grants = { { path = outside, letters = "rwc" } } }))
  ctx = { cwd = dir, policy = reading }
  assert(Tools.run("write", { path = "in.txt", content = "changed" }, ctx).is_error)
  r = Tools.run("bash", { command = "echo changed > in.txt; echo there > " .. outside .. "/y" }, ctx)
  assert(r.text:find("Read-only", 1, true) ~= nil and slurp(dir .. "/in.txt") == "yes", r.text)
  assert(slurp(outside .. "/y") == "there\n", r.text)
  -- The commands' own home: made, theirs to write and run in, kept from one command to the next.
  local home = scratch() .. "/home"
  local homed = assert(Policy.of(dir, { mode = "write", network = false, grants = {}, home = home }))
  r = Tools.run("bash", { command = "echo kept > ~/x && echo cached > \"$XDG_CACHE_HOME/y\" && cat ~/x" },
    { cwd = dir, policy = homed })
  assert(not r.is_error and r.text == "kept" and slurp(home .. "/x") == "kept\n", r.text)
  assert(slurp(home .. "/.cache/y") == "cached\n", r.text)
  -- Held to its owner, and read alone under --sandbox read.
  assert(assert(Fs.chmod(home, 0x1ff)))
  local looked = assert(Policy.of(dir, { mode = "read", network = false, grants = {}, home = home }))
  assert(assert(Fs.stat(home)).mode & 0x3f == 0)
  r = Tools.run("bash", { command = "cat ~/x; echo no > ~/x" }, { cwd = dir, policy = looked })
  assert(r.text:find("kept", 1, true) ~= nil and r.text:find("Read-only", 1, true) ~= nil, r.text)
  assert(slurp(home .. "/x") == "kept\n")
  -- PATH's programs run where they were put: a bin brings its prefix,
  -- but of the user's home the bin alone.
  local prefix, user = scratch(), scratch()
  for _, d in ipairs({ prefix .. "/bin", prefix .. "/lib", user .. "/.local/bin" }) do
    assert(Fs.mkdirs(d))
  end
  assert(Fs.write(prefix .. "/lib/tool.sh", "echo from-lib\n"))
  assert(Fs.write(prefix .. "/bin/tool", "#!/bin/sh\nexec sh \"$(dirname \"$0\")/../lib/tool.sh\"\n"))
  assert(assert(Fs.chmod(prefix .. "/bin/tool", 0x1ed)))
  local pathed = assert(Policy.of(dir, { mode = "write", network = false, grants = {},
    path = prefix .. "/bin:" .. user .. "/.local/bin:relative/bin:/no/such/bin:/usr/bin:/bin", user_home = user }))
  local real_prefix, real_user = assert(Fs.absolute(prefix)), assert(Fs.absolute(user))
  assert(Policy.allows(pathed, real_prefix .. "/lib/tool.sh", "r"))
  assert(Policy.allows(pathed, real_user .. "/.local/bin", "r") and not Policy.allows(pathed, real_user .. "/.local", "r"))
  -- A PATH of /, of the home, of what holds the working directory, or into
  -- the agent's own data grants nothing; no home known, no prefix.
  local work = scratch()
  for _, d in ipairs({ work .. "/bin", work .. "/app", user .. "/data/bin" }) do
    assert(Fs.mkdirs(d))
  end
  local wild = assert(Policy.of(work .. "/app", { mode = "write", network = false, grants = {},
    path = "/:" .. user .. ":" .. work .. "/bin:" .. user .. "/data/bin", user_home = user, kept_out = { user .. "/data" } }))
  local real_work = assert(Fs.absolute(work))
  assert(not Policy.allows(wild, "/etc/shadow", "r") and not Policy.allows(wild, real_user .. "/x", "r"))
  assert(Policy.allows(wild, real_work .. "/bin", "r") and not Policy.allows(wild, real_work .. "/other", "r"))
  assert(not Policy.allows(wild, real_user .. "/data/bin", "r"))
  local homeless = assert(Policy.of(dir, { mode = "write", network = false, grants = {}, path = prefix .. "/bin" }))
  assert(Policy.allows(homeless, real_prefix .. "/bin", "r") and not Policy.allows(homeless, real_prefix .. "/lib", "r"))
  r = Tools.run("bash", { command = prefix .. "/bin/tool" }, { cwd = dir, policy = pathed })
  assert(not r.is_error and r.text == "from-lib", r.text)
  local shown = table.concat(Policy.describe(homed, home), "\n")
  assert(shown:find("home: " .. assert(Fs.absolute(home)), 1, true) ~= nil and shown:find("rwxc  ", 1, true) ~= nil, shown)
  local off, off_why = Policy.of(dir, { mode = "off", network = false, grants = {} })
  assert(off == nil and off_why == "")
  local bad, bad_why = Policy.of(dir, { mode = "loose", network = false, grants = {} })
  assert(bad == nil and bad_why:find("write, read or off", 1, true) ~= nil)
end

local function test_a_worktree_reaches_its_repository()
  -- The repository, its .git directory holding the worktrees' gitdirs, as git links them.
  local repo = scratch()
  local common = repo .. "/.git"
  assert(Fs.write(repo .. "/tracked.txt", "x"))
  assert(Fs.mkdirs(common))
  assert(Fs.write(common .. "/HEAD", "ref: refs/heads/main\n"))
  local function worktree(name: string, dotgit_text?: string): string
    local at = scratch()
    local gitdir = common .. "/worktrees/" .. name
    assert(Fs.mkdirs(gitdir))
    assert(Fs.write(gitdir .. "/HEAD", "ref: refs/heads/" .. name .. "\n"))
    assert(Fs.write(gitdir .. "/commondir", "../..\n"))
    assert(Fs.write(gitdir .. "/gitdir", assert(Fs.absolute(at)) .. "/.git\n"))
    assert(Fs.write(at .. "/.git", dotgit_text or ("gitdir: " .. gitdir .. "\n")))
    return at
  end
  local tree = worktree("wt")
  local rel = worktree("rel", "gitdir: ../" .. Fs.basename(repo) .. "/.git/worktrees/rel\n")
  for _, at in ipairs({ tree, rel }) do
    local w = assert(Policy.of(at, { mode = "write", network = false, grants = {} }))
    assert(Policy.allows(w, common .. "/HEAD", "rwc"), at)
    assert(Policy.allows(w, common .. "/objects/ab/cd", "wc"), at)
    assert(Policy.allows(w, common .. "/worktrees/wt/index", "rwc"), at)
    -- The repository's own checkout is not the worktree's.
    assert(not Policy.allows(w, repo .. "/tracked.txt", "r"), at)
    local r = assert(Policy.of(at, { mode = "read", network = false, grants = {} }))
    assert(Policy.allows(r, common .. "/HEAD", "r"), at)
    assert(not Policy.allows(r, common .. "/HEAD", "w"), at)
    assert(not Policy.allows(r, common .. "/new", "c"), at)
  end
  local function grants_none(at: string, why: string)
    local p = assert(Policy.of(at, { mode = "write", network = false, grants = {} }))
    assert(not Policy.allows(p, common .. "/HEAD", "r"), why)
    assert(not Policy.allows(p, repo .. "/tracked.txt", "r"), why)
  end
  -- A .git that names another worktree's gitdir: its gitdir file names that worktree, not this one.
  local thief = scratch()
  assert(Fs.write(thief .. "/.git", "gitdir: " .. common .. "/worktrees/wt\n"))
  grants_none(thief, "another worktree's gitdir")
  -- A gitdir whose commondir points elsewhere, or that is not in <common>/worktrees.
  local odd = worktree("odd")
  assert(Fs.write(common .. "/worktrees/odd/commondir", "/\n"))
  grants_none(odd, "commondir /")
  local stray = scratch()
  local loose = stray .. "/loose"
  assert(Fs.mkdirs(loose))
  assert(Fs.write(loose .. "/HEAD", "ref: refs/heads/x\n"))
  assert(Fs.write(loose .. "/commondir", common .. "\n"))
  assert(Fs.write(loose .. "/gitdir", assert(Fs.absolute(stray)) .. "/.git\n"))
  assert(Fs.write(stray .. "/.git", "gitdir: " .. loose .. "\n"))
  grants_none(stray, "a gitdir outside <common>/worktrees")
  -- No gitdir back-pointer.
  local lone = worktree("lone")
  assert(Fs.remove(common .. "/worktrees/lone/gitdir"))
  grants_none(lone, "no gitdir file")
  -- What is malformed, or no git directory, grants nothing.
  local bad = scratch()
  for _, text in ipairs({ "", "gitdir:", "gitdir: /no/such/dir", "nonsense " .. common,
      "gitdir: " .. repo .. "/tracked.txt", "gitdir: " .. repo, "gitdir: " .. common }) do
    assert(Fs.write(bad .. "/.git", text))
    grants_none(bad, text)
  end
  -- A plain checkout's .git is a directory in it, and nothing is added.
  local plain = scratch()
  assert(Fs.mkdirs(plain .. "/.git"))
  local p = assert(Policy.of(plain, { mode = "write", network = false, grants = {} }))
  assert(Policy.allows(p, plain .. "/.git/HEAD", "w") and not Policy.allows(p, common .. "/HEAD", "r"))
end
