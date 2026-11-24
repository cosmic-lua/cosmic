--- The policy the tools are held to: what it grants, bash run under it
--- in a sandbox of its own, the commands' kept home, PATH's programs and
--- a worktree's repository. On Linux the policy nests a sandbox, so the
--- module needs a host that lets one nest. Background jobs run under it
--- too: started, read, waited for, killed, and ended with the session.

local Jobs = require("cosmic.agent.jobs")
local Clock = require("cosmic.clock")
local agent_fixture = require("build.agent_fixture")
local Fs = require("cosmic.fs")
local Policy = require("cosmic.agent.policy")
local Sandbox = require("cosmic.sandbox")
local sys = require("cosmic.sys")
local Test = require("cosmic.test")
local Tools = require("cosmic.agent.tools")

--- Whether `p` lets the agent's tools do each of `letters` at `path`, as
--- [`Sandbox.permits`] answers: r reads, w writes, c creates.
local function allows(p: Sandbox.Policy, path: string, letters: string): boolean, string
  local actions: {string: string} = { r = "read", w = "write", c = "create" }
  for letter in letters:gmatch(".") do
    local real, why = Sandbox.permits(p, path, assert(actions[letter]))
    if real == nil then return false, why end
  end
  return true, ""
end

-- The whole system: a sandbox nested in the worker builds its root of
-- what the worker holds, and a program's libraries must be there to run,
-- which a test's own grant of a program (read alone) does not give. This
-- is the agent's one module that keys the system; the others name their
-- programs.
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
  assert(allows(p, dir .. "/new/file.txt", "w"))
  assert(allows(p, "/usr/bin", "r") and not allows(p, "/usr/bin/x", "w"))
  assert(not allows(p, outside .. "/x", "w"))
  local refused = Tools.run("write", { path = outside .. "/x", content = "x" }, { cwd = dir, policy = p })
  assert(refused.is_error and refused.text:find("The sandbox does not let the agent write", 1, true) ~= nil, refused.text)
  assert(not allows(p, dir .. "/no/../../escape", "w"))
  assert(not allows(p, outside .. "/x", "r"))
  assert(not allows(p, "/proc/self/environ", "r"))
  local some = assert(Policy.of(dir, { mode = "read", network = false, grants = { { path = outside, letters = "w" } } }))
  assert(allows(some, outside, "w") and not allows(some, outside .. "/new", "wc"))
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
  assert(allows(pathed, real_prefix .. "/lib/tool.sh", "r"))
  assert(allows(pathed, real_user .. "/.local/bin", "r") and not allows(pathed, real_user .. "/.local", "r"))
  -- A PATH of /, of the home, of what holds the working directory, or into
  -- the agent's own data grants nothing; no home known, no prefix.
  local work = scratch()
  for _, d in ipairs({ work .. "/bin", work .. "/app", user .. "/data/bin" }) do
    assert(Fs.mkdirs(d))
  end
  local wild = assert(Policy.of(work .. "/app", { mode = "write", network = false, grants = {},
    path = "/:" .. user .. ":" .. work .. "/bin:" .. user .. "/data/bin", user_home = user, kept_out = { user .. "/data" } }))
  local real_work = assert(Fs.absolute(work))
  assert(not allows(wild, "/etc/shadow", "r") and not allows(wild, real_user .. "/x", "r"))
  assert(allows(wild, real_work .. "/bin", "r") and not allows(wild, real_work .. "/other", "r"))
  assert(not allows(wild, real_user .. "/data/bin", "r"))
  local homeless = assert(Policy.of(dir, { mode = "write", network = false, grants = {}, path = prefix .. "/bin" }))
  assert(allows(homeless, real_prefix .. "/bin", "r") and not allows(homeless, real_prefix .. "/lib", "r"))
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
    assert(allows(w, common .. "/HEAD", "rwc"), at)
    assert(allows(w, common .. "/objects/ab/cd", "wc"), at)
    assert(allows(w, common .. "/worktrees/wt/index", "rwc"), at)
    -- The repository's own checkout is not the worktree's.
    assert(not allows(w, repo .. "/tracked.txt", "r"), at)
    local r = assert(Policy.of(at, { mode = "read", network = false, grants = {} }))
    assert(allows(r, common .. "/HEAD", "r"), at)
    assert(not allows(r, common .. "/HEAD", "w"), at)
    assert(not allows(r, common .. "/new", "c"), at)
  end
  local function grants_none(at: string, why: string)
    local p = assert(Policy.of(at, { mode = "write", network = false, grants = {} }))
    assert(not allows(p, common .. "/HEAD", "r"), why)
    assert(not allows(p, repo .. "/tracked.txt", "r"), why)
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
  assert(allows(p, plain .. "/.git/HEAD", "w") and not allows(p, common .. "/HEAD", "r"))
end

local function test_background_jobs_run_until_read_killed_or_the_session_ends()
  local dir = scratch()
  local set = Jobs.new()
  local p = assert(Policy.of(dir, { mode = "write", network = false, grants = {} }))
  local ctx: Tools.Context = { cwd = dir, policy = p, jobs = set }
  local r = Tools.run("bash", { command = "echo started; sleep 30", background = true }, ctx)
  assert(not r.is_error and r.text:find("Started job 1", 1, true) ~= nil, r.text)
  r = Tools.run("bash", { command = "for i in $(seq 3000); do echo line$i; done; echo err >&2; exit 3",
    background = true }, ctx)
  assert(r.text:find("Started job 2", 1, true) ~= nil, r.text)
  assert(Tools.run("bash", { command = "true", background = "yes" }, ctx).is_error)
  -- Waited for: the last of its output, all of it kept, the status an error.
  r = Tools.run("jobs", { id = 2, wait = 20 }, ctx)
  assert(r.is_error and r.text:find("exited with code 3", 1, true) ~= nil, r.text)
  assert(r.text:find("err\n", 1, true) ~= nil and r.text:find("Showing the last lines", 1, true) ~= nil, r.text)
  assert((r.raw or ""):sub(1, 6) == "line1\n", r.raw)
  r = Tools.run("jobs", { id = 2 }, ctx)
  assert(r.text:find("(no new output)", 1, true) ~= nil and r.raw == nil, r.text)
  -- A command run meanwhile leaves the jobs running.
  assert(not Tools.run("bash", { command = "true" }, ctx).is_error)
  r = Tools.run("jobs", { id = 1, wait = 1 }, ctx)
  assert(not r.is_error and r.text:find("Job 1 running", 1, true) ~= nil and r.text:find("started", 1, true) ~= nil,
    r.text)
  r = Tools.run("jobs", {}, ctx)
  assert(r.text:find("job 1  running", 1, true) ~= nil and r.text:find("job 2  exited", 1, true) ~= nil, r.text)
  r = Tools.run("jobs", { id = 1, kill = true }, ctx)
  assert(not r.is_error and r.text:find("Job 1 killed", 1, true) ~= nil and r.raw ~= nil, r.text)
  -- A character half written waits for its end.
  assert(not Tools.run("bash", { command = "printf 'a\\303'; sleep 1; printf '\\251\\n'", background = true },
    ctx).is_error)
  local half = assert(Jobs.find(set, 3))
  for _ = 1, 250 do
    if Jobs.size(half) >= 2 then break end
    local _, _ = Clock.sleep(Clock.ms(20))
  end
  r = Tools.run("jobs", { id = 3 }, ctx)
  assert(r.text:find("\n\na$") ~= nil, r.text)
  r = Tools.run("jobs", { id = 3, wait = 10 }, ctx)
  assert(r.text:find("\n\n\195\169$") ~= nil, r.text)
  assert(Tools.run("jobs", { id = 9 }, ctx).is_error and Tools.run("jobs", { kill = true }, ctx).is_error)
  assert(Tools.run("jobs", {}, { cwd = dir }).is_error)
  -- The session's end ends the rest, and hands on what was not read.
  assert(not Tools.run("bash", { command = "echo unread; sleep 30", background = true }, ctx).is_error)
  local job = assert(Jobs.find(set, 4))
  -- Once it has said what it says: a sandbox takes a moment to start.
  for _ = 1, 100 do
    if Jobs.size(job) > 0 then break end
    local _, _ = Clock.sleep(Clock.ms(50))
  end
  local handed: mut {string} = {}
  Jobs.close(set, function(j: Jobs.Job, output: string)
    local entry = tostring(j.id) .. ":" .. output
    handed[#handed + 1] = entry
  end)
  assert(#handed == 1 and handed[1] == "4:unread\n" and job.result ~= nil, table.concat(handed, ","))
  assert(not assert(Fs.status(job.file)).exists)
end

--- A grant that reaches what is kept out, or holds it, is refused: no tool may change the sessions or the MCP config.
local function test_a_grant_over_what_is_kept_out_is_refused()
  local dir, kept = scratch(), scratch()
  local config = kept .. "/cosmic"
  assert(Fs.mkdirs(config, 0x1c0))
  for _, path in ipairs({ config, kept, config .. "/mcp.json" }) do
    local p, why = Policy.of(dir, { mode = "write", network = false, grants = { { path = path, letters = "rw" } },
      kept_out = { config } })
    assert(p == nil and why:find("which no tool may change", 1, true) ~= nil, path .. ": " .. why)
  end
  local beside = scratch()
  assert(Policy.of(dir, { mode = "write", network = false, grants = { { path = beside, letters = "r" } },
    kept_out = { config } }))
end

--- With --network, the user's SSL_CERT_FILE is read and given to the tools, so a proxy's own root is trusted;
--- without it, neither.
local function test_the_cert_file_goes_with_the_network()
  local dir, certs = scratch(), scratch()
  local cert = certs .. "/roots.pem"
  assert(Fs.write(cert, "-----BEGIN CERTIFICATE-----\n"))
  local real = assert(Fs.absolute(cert))
  local p = assert(Policy.of(dir, { mode = "write", network = true, grants = {}, cert_file = cert }))
  assert((p.set_env or {})["SSL_CERT_FILE"] == real)
  local granted = false
  for _, g in ipairs(p.grants or {}) do
    if g.path == real and g.letters == "r" then granted = true end
  end
  assert(granted)
  local offline = assert(Policy.of(dir, { mode = "write", network = false, grants = {}, cert_file = cert }))
  assert((offline.set_env or {})["SSL_CERT_FILE"] == nil)
  local p_missing, why = Policy.of(dir, { mode = "write", network = true, grants = {}, cert_file = certs .. "/none" })
  assert(p_missing == nil and why:find("SSL_CERT_FILE", 1, true) == 1, why)
end

--- c is asked of the directory a file is made in; a write goes to the real name it checked, never through a dangling link.
local function test_a_file_is_made_only_where_its_directory_grants_c()
  local inside, outside = scratch(), scratch()
  assert(Fs.write(inside .. "/f.txt", "old"))
  -- A grant of the file alone lets it be changed, not made again beside a file of its own.
  local file: Sandbox.Policy = { grants = { { path = inside .. "/f.txt", letters = "rw" } } }
  assert(allows(file, inside .. "/f.txt", "rw") and not allows(file, inside .. "/f.txt", "wc"))
  local dir: Sandbox.Policy = { grants = { { path = inside, letters = "rwc" } } }
  assert(allows(dir, inside .. "/new.txt", "wc") and not allows(dir, outside .. "/new.txt", "wc"))
  -- A link outside the grant, to a file in it, is written through to the real file: the link stays.
  assert(Fs.symlink(inside .. "/f.txt", outside .. "/link.txt"))
  local r = Tools.run("write", { path = outside .. "/link.txt", content = "new" }, { cwd = inside, policy = dir })
  assert(not r.is_error, r.text)
  assert(slurp(inside .. "/f.txt") == "new", slurp(inside .. "/f.txt"))
  local status = assert(Fs.status(outside .. "/link.txt"))
  assert(status.exists)
  -- A grant mapped from elsewhere grants the tools nothing, which run outside the sandbox.
  local mapped: Sandbox.Policy = { grants = { { path = "/etc", letters = "r", from = inside } } }
  assert(not allows(mapped, "/etc/hostname", "r"))
  -- A device is no file to read whole.
  local devices: Sandbox.Policy = { grants = { { path = "/dev", letters = "r" } } }
  assert(Tools.run("read", { path = "/dev/zero" }, { cwd = inside, policy = devices }).text:find("is no file", 1, true) ~= nil)
  -- A policy that is none says so.
  local unmerged, why = allows({ profiles = { "nosuch" } }, inside, "r")
  assert(not unmerged and why:find("nosuch", 1, true) ~= nil, why)
  -- A grant that makes files but writes none lets no new file be written.
  local making: Sandbox.Policy = { grants = { { path = inside, letters = "rc" } } }
  local unwritten = Tools.run("write", { path = inside .. "/made.txt", content = "x" }, { cwd = inside, policy = making })
  assert(unwritten.is_error and not assert(Fs.status(inside .. "/made.txt")).exists, unwritten.text)
  -- Each directory a write makes asks c of the one above it, not only the last.
  local deep: Sandbox.Policy = { grants = { { path = inside .. "/a/b", letters = "rwc" } } }
  local made = Tools.run("write", { path = inside .. "/a/b/c.txt", content = "x" }, { cwd = inside, policy = deep })
  assert(made.is_error and not assert(Fs.status(inside .. "/a")).exists, made.text)
  -- A dangling link is refused: a create through it would make a file out of the grant.
  assert(Fs.symlink(outside .. "/not-yet.txt", inside .. "/dangling.txt"))
  local through = Tools.run("write", { path = inside .. "/dangling.txt", content = "x" }, { cwd = inside, policy = dir })
  assert(through.is_error and not assert(Fs.status(outside .. "/not-yet.txt")).exists, through.text)
end
