--- Runs the checkout's CI phases from a private snapshot and CI copy.
--- [`./run-local`] loads this file standalone on the pinned library;
--- the phase driver remains the checkout's own tool, in the build
--- directory build/paths.tl names.
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Signal = require("cosmic.signal")
local Stream = require("cosmic.stream")
local sys = require("cosmic.sys")

local record Local
  --- The calls into the host that a test stands another in for: the new checker holds a library's functions
  --- fixed, so [`Local.calls`] hands out this record, which the run reads each call from. This file runs
  --- standalone on the pinned library and cannot require a module of its own project to hold them.
  record Calls
    mut child_run: function(argv: {string}, options?: Child.Options): Child.Result?, string
    mut env_all: function(): {string:string}
    mut fs_put: function(fd: integer, bytes: string): boolean, string
    mut fs_read: function(path: string): string?, string
    mut proc_user: function(name: string): Proc.User?, string
    mut signal_guard: function(): Signal.Guard?, string
    mut sys_getuid: function(): integer
    mut sys_mkdtemp: function(template: string): string?, string, integer
    mut sys_pread: function(fd: integer, count: integer, offset: integer): string?, string, integer
  end
  --- The calls in force: the library's, until a test assigns its own to a field and puts the library's back.
  calls: function(): Calls
end

local current: Local.Calls = {
  child_run = Child.run,
  env_all = Env.all,
  fs_put = Fs.put,
  fs_read = Fs.read,
  proc_user = Proc.user,
  signal_guard = Signal.guard,
  sys_getuid = sys.getuid,
  sys_mkdtemp = sys.mkdtemp,
  sys_pread = sys.pread,
}

function Local.calls(): Local.Calls
  return current
end

--- The private copy of the core a dropped user runs: its directory and the descriptor that names it. A `<close>` local of
--- it closes the descriptor, then removes the directory, however its block ends.
local class Runtime
  mut path: string
  mut fd: integer

  function __close(self)
    if self.fd >= 0 then
      local _, _ = Fs.close(self.fd)
      self.fd = -1
    end
    if self.path ~= "" then
      local _, _ = Fs.remove_tree(self.path)
      self.path = ""
    end
  end
end

--- A descriptor [`execute`] opened. A `<close>` local of it closes the descriptor however its block ends, unless
--- [`Opened.close`] has.
local class Opened
  mut fd: integer

  --- Closes the descriptor now, as [`Fs.close`] does; a second close does nothing.
  function close(self): boolean, string
    local fd = self.fd
    if fd < 0 then return true, "" end
    self.fd = -1
    return Fs.close(fd)
  end

  function __close(self)
    local _, _ = self:close()
  end
end

--- What [`execute`] answered, kept where the function that runs it under `pcall` can read it.
local record Ended
  mut status: integer
end

--- What the snapshot of the checkout is, kept where the function that makes it under `pcall` can read it.
local record Snapshot
  mut commit: string
end

local function fallback_value(values: {string:string}, name: string, fallback: string): string
  local found = values[name]
  if found == nil or found == "" then return fallback end
  return found
end

--- The user a root caller's driver runs as: `COSMIC_CI_LOCAL_USER`, else
--- the user `sudo` came from, else "nobody".
local function dropped_user(values: {string:string}): string
  local named = values["COSMIC_CI_LOCAL_USER"]
  if named ~= nil and named ~= "" then return named end
  local sudo = values["SUDO_USER"]
  if sudo ~= nil and sudo ~= "" and sudo ~= "root" then return sudo end
  return "nobody"
end

--- Adds the entries of `from` to `into`.
local function fill(into: mut {string:string}, from: {string:string})
  for name, value in pairs(from) do into[name] = value end
end

local function say(text: string)
  assert(current.fs_put(Fs.stderr, "run-local: " .. text .. "\n"))
end

local function successful(result: Child.Result, program: string)
  local signal = result.signal
  assert(result.ok, program .. ": " .. (result.stderr or "") ..
      (if signal then "signal " .. tostring(signal) else "exit " .. tostring(result.code) end))
end

local function present(path: string): boolean
  local exists, why = Fs.exists(path)
  assert(exists ~= nil, why)
  return exists
end

--- Resolve the existing prefix before appending missing components.
--- Containment checks must also hold when a parent is a symbolic link.
local function resolved(path: string): string
  local actual, _ = Fs.absolute(path)
  if actual ~= nil then return actual end
  local stat, why, errno = sys.lstat(path)
  assert(stat == nil and errno == sys.ENOENT, path .. ": " .. tostring(why))
  local parent = Fs.dirname(path)
  assert(parent ~= path, "cannot resolve " .. path)
  local base, leaf = resolved(parent), Fs.basename(path)
  if leaf == "." then return base end
  if leaf == ".." then return Fs.dirname(base) end
  return (if base == "/" then "" else base end) .. "/" .. leaf
end

local function owned_root(path: string)
  local st, why, errno = sys.lstat(path)
  assert(st == nil and errno == sys.ENOENT or st ~= nil and st.kind == "dir",
    path .. ": owned root must be a directory, never a symbolic link: " .. tostring(why))
end

local function execute(argv: {string}, program: string): integer
  local root = Fs.dirname(Fs.dirname((assert(Fs.absolute(program)))))
  local caller_env = current.env_all()
  local relaunch = assert(Proc.relaunch())
  local resolver_argv: mut {string} = {}
  local resolver_env: mut {string:string} = {}
  fill(resolver_env, caller_env)
  local resolver_fds: mut {integer:integer | string} = {}
  for _, word in ipairs(relaunch.argv) do resolver_argv[#resolver_argv + 1] = word end
  for name, value in pairs(relaunch.env) do resolver_env[name] = value end
  for number, fd in pairs(relaunch.fds) do resolver_fds[number] = fd end
  resolver_argv[#resolver_argv + 1] = "--standalone"
  resolver_argv[#resolver_argv + 1] = root .. "/build/paths.tl"
  resolver_argv[#resolver_argv + 1] = root
  local named = assert(current.child_run(resolver_argv, { env = resolver_env, fds = resolver_fds,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  successful(named, "build directory")
  local build_directory = assert((named.stdout or ""):match("^([^\n]+)\n$"),
    "build directory resolver did not print one path")
  local cosmic = build_directory .. "/bin/cosmic"
  local runnable, _ = sys.access(cosmic, sys.X_OK)
  assert(runnable, "no " .. cosmic .. "; run bin/zig build boot")
  local platform = assert(sys.uname())
  local target: string
  if platform.sysname == "Linux" and platform.machine == "x86_64" then
    target = "x86_64-linux-musl"
  elseif platform.sysname == "Linux" and platform.machine == "aarch64" then
    target = "aarch64-linux-musl"
  elseif platform.sysname == "Darwin" and platform.machine == "arm64" then
    target = "aarch64-macos"
  else
    error("unsupported host: " .. platform.sysname .. " " .. platform.machine)
  end
  local env: mut {string:string} = {}
  fill(env, caller_env)
  local uid = current.sys_getuid()
  local cache = fallback_value(env, "XDG_CACHE_HOME", (env["HOME"] or "") .. "/.cache") .. "/cosmic"
  local zig_global = fallback_value(env, "COSMIC_ZIG_GLOBAL_CACHE", cache .. "/zig-global")
  local seed = fallback_value(env, "COSMIC_ZIG_CACHE", cache .. "/zig-project")
  local git = assert(Proc.find("git"))
  local cksum = assert(Proc.find("cksum"))
  local sum = assert(current.child_run({ cksum }, { input = root, stdout = "capture", stderr = "capture" }))
  successful(sum, "cksum")
  local key = assert((sum.stdout or ""):match("^(%d+) %d+\n$"), "cksum returned an invalid checksum")
  -- TODO: prune state for checkouts that no longer exist, once each state
  -- records its source path so a later run can identify abandoned worktrees.
  local base = fallback_value(env, "TMPDIR", "/tmp") .. "/cosmic-ci-local-" .. tostring(uid)
  local state = env["COSMIC_CI_LOCAL"]
  if state == nil or state == "" then
    owned_root(base)
    base = resolved(base)
    state = base .. "/" .. key
  end
  assert(state:sub(1, 1) == "/", "COSMIC_CI_LOCAL must be absolute")
  owned_root(state)
  state = resolved(state)
  assert(state ~= "/" and not Fs.within(state, root) and not Fs.within(root, state),
    "state must be outside and not contain the checkout")
  local candidate, project = state .. "/candidate", state .. "/ci"
  local credentials: Child.Credentials? = nil
  local user = ""
  if uid == 0 then
    user = dropped_user(env)
    local account, why = current.proc_user(user)
    local reason = why
    if reason == "" then reason = "no user " .. user .. "; set COSMIC_CI_LOCAL_USER" end
    assert(account ~= nil, reason)
    assert(account.uid ~= 0 and account.gid ~= 0, "COSMIC_CI_LOCAL_USER must have nonzero user and group IDs")
    credentials = { user = account.uid, group = account.gid }
  end

  -- A dropped user cannot execute root's private cached core (0500).
  -- Grant one nonwritable copy for this run without changing that cache.
  -- Its retained descriptor must name the executing copy: startup checks
  -- both its digest against the artifact and its physical inode.
  -- Declared before any [`Opened`] of `execute`, so that it closes after them: the directory goes last.
  local runtime <close>: Runtime = { path = "", fd = -1 }
  local core_slot: integer? = nil
  if credentials then
    runtime.path = assert(current.sys_mkdtemp("/tmp/cosmic-local-runtime.XXXXXX"))
    local source <close>: Opened = { fd = -1 }
    local from: integer
    if relaunch.env["COSMIC_PORTABLE_CORE_FD"] then
      core_slot = assert(math.tointeger(tonumber(relaunch.env["COSMIC_PORTABLE_CORE_FD"])))
      from = assert(relaunch.fds[core_slot], "relaunch names no core descriptor")
    else
      local core_path = assert(relaunch.argv[1], "relaunch names no program")
      source.fd = assert(Fs.open_read(core_path))
      from = source.fd
    end
    local native = runtime.path .. "/core"
    local output <close>: Opened = { fd = assert(sys.open(native, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)) }
    local offset = 0
    while true do
      local bytes = assert(current.sys_pread(from, 65536, offset))
      if #bytes == 0 then break end
      assert(current.fs_put(output.fd, bytes))
      offset = offset + #bytes
    end
    assert(Fs.chmod(native, 0x16d))
    assert(output:close())
    local _, _ = source:close()
    runtime.fd = assert(Fs.open_read(native))
    -- Nor can it reach root's build directory, its user's alone (0700):
    -- it runs a copy of the tool beside the core.
    local tool = runtime.path .. "/cosmic"
    assert(Fs.write(tool, assert(current.fs_read(cosmic)), 0x1ed))
    cosmic = tool
    assert(Fs.chmod(runtime.path, 0x1c9))
  end
  -- Every invocation gets new tables; Proc.relaunch is cached.
  local function probe(code: string, values?: {string:string}, input?: string): Child.Result
    local words: mut {string} = {}
    for at, word in ipairs(relaunch.argv) do
      if at == 1 and runtime.fd >= 0 then
        words[#words + 1] = runtime.path .. "/core"
      else
        words[#words + 1] = word
      end
    end
    words[#words + 1] = "-e"
    words[#words + 1] = code
    local child_env: mut {string:string} = {}
    fill(child_env, values or env)
    for name, value in pairs(relaunch.env) do child_env[name] = value end
    local fds: mut {integer:integer} = {}
    for destination, given in pairs(relaunch.fds) do
      if destination == core_slot then
        fds[destination] = runtime.fd
      else
        fds[destination] = given
      end
    end
    local answer, why = current.child_run(words, { cwd = "/", env = child_env, fds = fds,
      credentials = credentials, input = input, stdout = "capture", stderr = "capture" })
    return (assert(answer, why))
  end
  local function privileged(words: {string}, options?: Child.Options): Child.Result
    local answer, why = current.child_run(words, options)
    return (assert(answer, why))
  end
  local chown: string? = nil
  if credentials then
    chown = assert(Proc.find("chown"))
    successful(probe("local s = require('cosmic.sys') assert(s.getuid() == " ..
        tostring(credentials.user) .. " and s.getgid() == " .. tostring(credentials.group) ..
        " and #assert(s.getgroups()) == 0)"), "credential preflight")
    say("running as root; the driver runs as " .. user .. " (uid " .. tostring(credentials.user) .. ")")
  end
  local function reown(path: string, recursive: boolean)
    owned_root(path)
    if credentials then
      if recursive then
        successful(privileged({ assert(chown), "-h", "-R", "-P",
          tostring(credentials.user) .. ":" .. tostring(credentials.group), path }), "chown")
      else
        assert(sys.chown(path, assert(credentials.user), assert(credentials.group)))
      end
    end
  end
  assert(Fs.mkdirs(state))
  if credentials then
    if env["COSMIC_CI_LOCAL"] == nil or env["COSMIC_CI_LOCAL"] == "" then
      assert(Fs.chmod(base, 0x1ed))
    end
    if assert(Fs.stat(state)).uid ~= credentials.user then reown(state, true) end
    for _, path in ipairs({ state .. "/home", state .. "/tmp" }) do
      owned_root(path)
      assert(Fs.mkdirs(path))
      reown(path, false)
    end
    env["HOME"], env["TMPDIR"] = state .. "/home", state .. "/tmp"
    for _, name in ipairs({ "SSL_CERT_FILE", "CURL_CA_BUNDLE", "GIT_SSL_CAINFO" }) do
      local path = env[name]
      if path ~= nil and path ~= "" and present(path) then
        local readable = probe("assert(require('cosmic.fs').open_read(" .. string.format("%q", path) .. "))")
        if not readable.ok then
          local ca = state .. "/ca"
          owned_root(ca)
          assert(Fs.mkdirs(ca))
          assert(Fs.chmod(ca, 0x1ed))
          local to = ca .. "/" .. name .. ".pem"
          assert(Fs.write(to, assert(current.fs_read(path)), 0x1a4))
          assert(Fs.chmod(to, 0x1a4))
          env[name] = to
        end
      end
    end
    local count = env["GIT_CONFIG_COUNT"] or "0"
    assert(count:match("^%d+$"), "invalid GIT_CONFIG_COUNT")
    local n = math.tointeger(tonumber(count))
    assert(n ~= nil and n >= 0 and n < math.maxinteger, "invalid GIT_CONFIG_COUNT")
    env["GIT_CONFIG_COUNT"] = tostring(n + 1)
    env["GIT_CONFIG_KEY_" .. tostring(n)] = "safe.directory"
    env["GIT_CONFIG_VALUE_" .. tostring(n)] = candidate
    successful(probe("local s = require('cosmic.sys') assert(s.access(" .. string.format("%q", state) ..
        ", s.W_OK)) assert(s.access(" .. string.format("%q", cosmic) .. ", s.X_OK)) assert(s.access(" ..
        string.format("%q", root .. "/ci/cosmic_ci/driver.tl") .. ", s.R_OK))", env), "driver access")
    if present(seed) and not probe("local s = require('cosmic.sys') assert(s.access(" ..
          string.format("%q", seed) .. ", s.R_OK | s.X_OK))", env).ok then
      say(user .. " cannot read " .. seed .. "; the candidate builds without it")
      seed = ""
    end
    local named_state = env["COSMIC_CI_LOCAL"]
    if named_state ~= nil and named_state ~= "" then
      zig_global = state .. "/zig-global"
    else
      zig_global = base .. "/zig-global-" .. tostring(credentials.user)
    end
    owned_root(zig_global)
    assert(Fs.mkdirs(zig_global))
    if assert(Fs.stat(zig_global)).uid ~= credentials.user then reown(zig_global, true) end
  end

  -- The phase project belongs to the driver, which is the checkout's own
  -- tool and so builds it in a build directory under the phases'
  -- XDG_CACHE_HOME, kept from run to run. Refresh every entry of the
  -- project, even on named-phase reruns; an o/ in ci/, where a driver
  -- older than the pinned one built it, is no input and is not copied.
  owned_root(project)
  assert(Fs.mkdirs(project))
  reown(project, false)
  successful(probe("local F = require('cosmic.fs') local p = " .. string.format("%q", project) ..
      " local old = assert(F.list(p)) for _, n in ipairs(old) do assert(F.remove_tree(p .. '/' .. n)) end " ..
      "local s = " .. string.format("%q", root .. "/ci") ..
      " local names = assert(F.list(s)) " ..
      "for _, n in ipairs(names) do if n ~= 'o' then assert(F.copy_tree(s .. '/' .. n, p .. '/' .. n)) end end", env), "CI copy")
  local phases: mut {string} = {}
  for _, word in ipairs(argv) do
    phases[#phases + 1] = word
  end
  if #phases == 0 then
    phases = { "build", "local-boundary", "declared-types", "darwin-suite", "sandbox", "assemble",
      "fixtures", "portable", "portable-boundary" }
  end
  local function git_run(words: {string}, values?: {string:string}, input?: string): string
    local args = { git, "-C", root }
    for _, word in ipairs(words) do args[#args + 1] = word end
    local environment = values or caller_env
    local result = privileged(args, { env = environment, input = input, stdout = "capture", stderr = "capture" })
    successful(result, "git")
    return ((result.stdout or ""):gsub("\n$", ""))
  end
  for _, phase in ipairs(phases) do
    assert(phase:match("^[%w_-]+$"), "invalid phase: " .. phase)
    if phase == "build" then
      local index_dir = assert(current.sys_mkdtemp(fallback_value(caller_env, "TMPDIR", "/tmp") .. "/cosmic-ci-local-index.XXXXXX"))
      local taken: Snapshot = { commit = "" }
      local worked, raised = pcall(function()
        local values: mut {string:string} = {}
        fill(values, caller_env)
        local index_file = index_dir .. "/index"
        values["GIT_INDEX_FILE"] = index_file
        -- Keep the caller's tracked set, including force-added ignored files.
        -- A blank index would silently drop them when add applies ignores.
        local original = git_run({ "rev-parse", "--git-path", "index" })
        if original:sub(1, 1) ~= "/" then original = root .. "/" .. original end
        if present(original) then
          assert(Fs.write(index_file, assert(current.fs_read(original)), 0x180))
        end
        git_run({ "add", "-A" }, values)
        local tree = git_run({ "write-tree" }, values)
        taken.commit = git_run({ "commit-tree", tree, "-p", "HEAD" }, nil, "ci/run-local snapshot\n")
      end)
      local removed, why = Fs.remove_tree(index_dir)
      if not worked then error(raised) end
      assert(removed, why)
      local snapshot = taken.commit
      owned_root(candidate)
      if present(candidate) then
        local removed_worktree = privileged({ git, "-C", root, "worktree", "remove", "--force", candidate },
          { stdout = "null", stderr = "null" })
        if not removed_worktree.ok then assert(Fs.remove_tree(candidate)) end
        git_run({ "worktree", "prune" })
      end
      assert(Fs.remove_tree(state .. "/runner"))
      git_run({ "worktree", "add", "--quiet", "--detach", candidate, snapshot })
      reown(candidate, true)
      say("candidate " .. snapshot .. " at " .. candidate)
    end
    assert(present(candidate), "no candidate; run the build phase first")
    owned_root(state .. "/runner")
    owned_root(state .. "/logs")
    successful(probe("local F = require('cosmic.fs') assert(F.mkdirs(" ..
        string.format("%q", state .. "/runner") .. ")) assert(F.mkdirs(" ..
        string.format("%q", state .. "/logs") .. "))", env), "phase directories")
    local path = state .. "/logs/" .. phase .. ".log"
    local fd, open_why = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC | sys.O_NOFOLLOW, 0x1a4)
    local log <close>: Opened = { fd = assert(fd, path .. ": " .. tostring(open_why)) }
    local values: mut {string:string} = {}
    fill(values, env)
    values["GITHUB_WORKSPACE"], values["RUNNER_TEMP"] = candidate, state .. "/runner"
    values["GITHUB_RUN_ID"], values["GITHUB_RUN_ATTEMPT"], values["COSMIC_WORKER"] = "local", "1", "local"
    values["TARGET"], values["XDG_CACHE_HOME"] = target, state .. "/cache"
    values["COSMIC_ZIG_CACHE_FROM"], values["COSMIC_ZIG_GLOBAL_CACHE"] = seed, zig_global
    local start = Clock.monotonic_ns()
    local result, why = current.child_run({ cosmic, "cosmic_ci/driver.tl", "platform", phase, "success" },
      { cwd = project, env = values, credentials = credentials, stdout = log.fd, stderr = log.fd })
    local closed, close_why = log:close()
    assert(result, why)
    assert(closed, close_why)
    local status = Child.shell_status(result)
    say(phase .. ": status " .. tostring(status) .. ", " ..
        tostring((Clock.monotonic_ns() - start) // Clock.seconds(1)) .. " s, log " .. path)
    if status ~= 0 then
      -- Diagnostics must not replace the phase status, or retain an entire
      -- build/fuzzer log in memory. Stop at an overlong line as well.
      local opened, read_why = Fs.open_read(path)
      if opened then
        local reading <close>: Opened = { fd = opened }
        local reader = Stream.lines(Stream.from_fd(opened), 65536)
        local lines = 0
        while lines < 20 do
          local line, trouble = reader:read()
          if line == nil then
            if trouble ~= "" then say("log diagnostics stopped: " .. trouble) end
            break
          end
          -- A complaint names the trouble; a failing test says FAIL.
          if line:match("^FAIL") ~= nil or line:find(" FAIL", 1, true) ~= nil or line:match("^cosmic: ") ~= nil or
              line:find("timed out", 1, true) ~= nil or line:find("error", 1, true) ~= nil then
            local _, _ = current.fs_put(Fs.stderr, line .. "\n")
            lines = lines + 1
          end
        end
        local _, _ = reading:close()
      else
        say("cannot read phase log: " .. read_why)
      end
      return status
    end
  end
  return 0
end

--- @param argv the phases to run
--- @param program this script's own path
function Local.run(argv: {string}, program: string): integer
  -- Keep cancellation caught until private-index/log cleanup completes.
  local _guard <close> = assert(current.signal_guard())
  local ended: Ended = { status = 0 }
  local ok, answer = pcall(function()
    ended.status = execute(argv, program)
  end)
  local status = ended.status
  if not ok then
    say(tostring(answer))
    status = 2
  end
  return status
end

--- The entry point: [`Local.run`] with this script's path, Lua's `arg[0]`.
function Local.main(argv: {string}): integer
  return Local.run(argv, (assert(arg[0], "run_local: no script path")))
end

return Local
