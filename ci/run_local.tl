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
end

local record Descriptor
  metamethod __close: function(Descriptor)
  fd: integer
end

local descriptor_mt: metatable<Descriptor> = {
  __close = function(self: Descriptor)
    if self.fd >= 0 then
      local _, _ = Fs.close(self.fd)
      self.fd = -1
    end
  end,
}

local record Runtime
  metamethod __close: function(Runtime)
  path: string
  fd: integer
end

local runtime_mt: metatable<Runtime> = {
  __close = function(self: Runtime)
    if self.fd >= 0 then
      local _, _ = Fs.close(self.fd)
      self.fd = -1
    end
    if self.path ~= "" then
      local _, _ = Fs.remove_tree(self.path)
      self.path = ""
    end
  end,
}

local function fallback_value(values: {string:string}, name: string, fallback: string): string
  local found = values[name]
  return found ~= nil and found ~= "" and found or fallback
end

local function copy(values: {string:string}): {string:string}
  local out: {string:string} = {}
  for name, value in pairs(values) do out[name] = value end
  return out
end

local function say(text: string)
  assert(Fs.put(Fs.stderr, "run-local: " .. text .. "\n"))
end

local function successful(result: Child.Result, program: string)
  assert(result.ok, program .. ": " .. (result.stderr or "") ..
      (result.signal and "signal " .. tostring(result.signal) or "exit " .. tostring(result.code)))
end

local function present(path: string): boolean
  local exists, why = Fs.exists(path)
  assert(exists ~= nil, why)
  return exists
end

--- Resolve the existing prefix before appending missing components.
--- Containment checks must also hold when a parent is a symbolic link.
local function resolved(path: string): string
  local actual = Fs.absolute(path)
  if actual then return actual end
  local stat, why, errno = sys.lstat(path)
  assert(stat == nil and errno == sys.ENOENT, path .. ": " .. tostring(why))
  local parent = Fs.dirname(path)
  assert(parent ~= path, "cannot resolve " .. path)
  local base, leaf = resolved(parent), Fs.basename(path)
  if leaf == "." then return base end
  if leaf == ".." then return Fs.dirname(base) end
  return (base == "/" and "" or base) .. "/" .. leaf
end

local function owned_root(path: string)
  local st, why, errno = sys.lstat(path)
  assert(st == nil and errno == sys.ENOENT or st ~= nil and st.kind == "dir",
    path .. ": owned root must be a directory, never a symbolic link: " .. tostring(why))
end

local function execute(argv: {integer:string}): integer
  local root = Fs.dirname(Fs.dirname((assert(Fs.absolute(argv[0])))))
  local caller_env = Env.all()
  local relaunch = assert(Proc.relaunch())
  local resolver_argv: {string} = {}
  local resolver_env = copy(caller_env)
  local resolver_fds: {integer:integer | string} = {}
  for _, word in ipairs(relaunch.argv) do resolver_argv[#resolver_argv + 1] = word end
  for name, value in pairs(relaunch.env) do resolver_env[name] = value end
  for number, fd in pairs(relaunch.fds) do resolver_fds[number] = fd end
  resolver_argv[#resolver_argv + 1], resolver_argv[#resolver_argv + 2], resolver_argv[#resolver_argv + 3] = "--standalone", root .. "/build/paths.tl", root
  local named = assert(Child.run(resolver_argv, { env = resolver_env, fds = resolver_fds,
    stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(30) }))
  successful(named, "build directory")
  local build_directory = assert((named.stdout or ""):match("^([^\n]+)\n$"),
    "build directory resolver did not print one path")
  local cosmic = build_directory .. "/bin/cosmic"
  assert(sys.access(cosmic, sys.X_OK), "no " .. cosmic .. "; run bin/zig build boot")
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
  local env = copy(caller_env)
  local uid = sys.getuid()
  local cache = fallback_value(env, "XDG_CACHE_HOME", (env.HOME or "") .. "/.cache") .. "/cosmic"
  local zig_global = fallback_value(env, "COSMIC_ZIG_GLOBAL_CACHE", cache .. "/zig-global")
  local seed = fallback_value(env, "COSMIC_ZIG_CACHE", cache .. "/zig-project")
  local git = assert(Proc.find("git"))
  local cksum = assert(Proc.find("cksum"))
  local sum = assert(Child.run({ cksum }, { input = root, stdout = "capture", stderr = "capture" }))
  successful(sum, "cksum")
  local key = assert((sum.stdout or ""):match("^(%d+) %d+\n$"), "cksum returned an invalid checksum")
  -- TODO: prune state for checkouts that no longer exist, once each state
  -- records its source path so a later run can identify abandoned worktrees.
  local base = fallback_value(env, "TMPDIR", "/tmp") .. "/cosmic-ci-local-" .. tostring(uid)
  local state = env.COSMIC_CI_LOCAL
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
  local credentials: Child.Credentials | nil = nil
  local user: string | nil = nil
  if uid == 0 then
    user = env.COSMIC_CI_LOCAL_USER
    if user == nil or user == "" then
      user = env.SUDO_USER
      if user == nil or user == "" or user == "root" then user = "nobody" end
    end
    local account, why = Proc.user(user)
    assert(account ~= nil, why ~= "" and why or "no user " .. user .. "; set COSMIC_CI_LOCAL_USER")
    assert(account.uid ~= 0 and account.gid ~= 0, "COSMIC_CI_LOCAL_USER must have nonzero user and group IDs")
    credentials = { user = account.uid, group = account.gid }
  end

  -- A dropped user cannot execute root's private cached core (0500).
  -- Grant one nonwritable copy for this run without changing that cache.
  -- Its retained descriptor must name the executing copy: startup checks
  -- both its digest against the artifact and its physical inode.
  local runtime <close>: Runtime = setmetatable({ path = "", fd = -1 }, runtime_mt)
  local core_slot: integer | nil = nil
  if credentials then
    runtime.path = assert(sys.mkdtemp("/tmp/cosmic-local-runtime.XXXXXX"))
    local source <close>: Descriptor = setmetatable({ fd = -1 }, descriptor_mt)
    local from: integer
    if relaunch.env.COSMIC_PORTABLE_CORE_FD then
      core_slot = assert(math.tointeger(tonumber(relaunch.env.COSMIC_PORTABLE_CORE_FD)))
      from = assert(relaunch.fds[core_slot], "relaunch names no core descriptor")
    else
      source.fd = assert(Fs.open_read(relaunch.argv[1]))
      from = source.fd
    end
    local native = runtime.path .. "/core"
    local output <close>: Descriptor = setmetatable({ fd = -1 }, descriptor_mt)
    output.fd = assert(sys.open(native, sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180))
    local offset = 0
    while true do
      local bytes = assert(sys.pread(from, 65536, offset))
      if #bytes == 0 then break end
      assert(Fs.put(output.fd, bytes))
      offset = offset + #bytes
    end
    assert(Fs.chmod(native, 0x16d))
    local written = output.fd
    output.fd = -1
    assert(Fs.close(written))
    runtime.fd = assert(Fs.open_read(native))
    -- Nor can it reach root's build directory, its user's alone (0700):
    -- it runs a copy of the tool beside the core.
    local tool = runtime.path .. "/cosmic"
    assert(Fs.write(tool, assert(Fs.read(cosmic)), 0x1ed))
    cosmic = tool
    assert(Fs.chmod(runtime.path, 0x1c9))
  end
  -- Every invocation gets new tables; Proc.relaunch is cached.
  local function probe(code: string, values?: {string:string}, input?: string): Child.Result
    local words: {string} = {}
    for _, word in ipairs(relaunch.argv) do words[#words + 1] = word end
    if runtime.fd >= 0 then words[1] = runtime.path .. "/core" end
    words[#words + 1] = "-e"
    words[#words + 1] = code
    local child_env = copy(values or env)
    for name, value in pairs(relaunch.env) do child_env[name] = value end
    local fds: {integer:integer} = {}
    for destination, source in pairs(relaunch.fds) do
      fds[destination] = destination == core_slot and runtime.fd or source
    end
    local answer, why = Child.run(words, { cwd = "/", env = child_env, fds = fds,
      credentials = credentials, input = input, stdout = "capture", stderr = "capture" })
    return (assert(answer, why))
  end
  local function privileged(words: {string}, options?: Child.Options): Child.Result
    local answer, why = Child.run(words, options)
    return (assert(answer, why))
  end
  local chown: string | nil = nil
  if credentials then
    chown = assert(Proc.find("chown"))
    successful(probe("local s=require('cosmic.sys'); assert(s.getuid()==" ..
        tostring(credentials.user) .. " and s.getgid()==" .. tostring(credentials.group) ..
        " and #assert(s.getgroups())==0)"), "credential preflight")
    say("running as root; the driver runs as " .. user .. " (uid " .. tostring(credentials.user) .. ")")
  end
  local function reown(path: string, recursive: boolean)
    owned_root(path)
    if credentials then
      if recursive then
        successful(privileged({ assert(chown), "-h", "-R", "-P",
          tostring(credentials.user) .. ":" .. tostring(credentials.group), path }), "chown")
      else
        assert(sys.chown(path, credentials.user, credentials.group))
      end
    end
  end
  assert(Fs.mkdirs(state))
  if credentials then
    if env.COSMIC_CI_LOCAL == nil or env.COSMIC_CI_LOCAL == "" then
      assert(Fs.chmod(base, 0x1ed))
    end
    if assert(Fs.stat(state)).uid ~= credentials.user then reown(state, true) end
    for _, path in ipairs({ state .. "/home", state .. "/tmp" }) do
      owned_root(path)
      assert(Fs.mkdirs(path))
      reown(path, false)
    end
    env.HOME, env.TMPDIR = state .. "/home", state .. "/tmp"
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
          assert(Fs.write(to, assert(Fs.read(path)), 0x1a4))
          assert(Fs.chmod(to, 0x1a4))
          env[name] = to
        end
      end
    end
    local count = env.GIT_CONFIG_COUNT or "0"
    assert(count:match("^%d+$"), "invalid GIT_CONFIG_COUNT")
    local n = math.tointeger(tonumber(count))
    assert(n and n >= 0 and n < math.maxinteger, "invalid GIT_CONFIG_COUNT")
    env.GIT_CONFIG_COUNT = tostring(n + 1)
    env["GIT_CONFIG_KEY_" .. tostring(n)] = "safe.directory"
    env["GIT_CONFIG_VALUE_" .. tostring(n)] = candidate
    successful(probe("local s=require('cosmic.sys'); assert(s.access(" .. string.format("%q", state) ..
        ",s.W_OK)); assert(s.access(" .. string.format("%q", cosmic) .. ",s.X_OK)); assert(s.access(" ..
        string.format("%q", root .. "/ci/cosmic_ci/driver.tl") .. ",s.R_OK))", env), "driver access")
    if present(seed) and not probe("local s=require('cosmic.sys'); assert(s.access(" ..
          string.format("%q", seed) .. ",s.R_OK|s.X_OK))", env).ok then
      say(user .. " cannot read " .. seed .. "; the candidate builds without it")
      seed = ""
    end
    zig_global = env.COSMIC_CI_LOCAL and env.COSMIC_CI_LOCAL ~= "" and state .. "/zig-global" or
      base .. "/zig-global-" .. tostring(credentials.user)
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
  successful(probe("local F=require('cosmic.fs'); local p=" .. string.format("%q", project) ..
      "; for _,n in ipairs(assert(F.list(p))) do assert(F.remove_tree(p..'/'..n)) end; " ..
      "local s=" .. string.format("%q", root .. "/ci") ..
      "; for _,n in ipairs(assert(F.list(s))) do if n~='o' then assert(F.copy_tree(s..'/'..n,p..'/'..n)) end end", env), "CI copy")
  local phases: {string} = {}
  local at = 1
  while argv[at] ~= nil do
    phases[#phases + 1] = argv[at]
    at = at + 1
  end
  if #phases == 0 then
    phases = { "build", "local-boundary", "darwin-suite", "sandbox", "assemble",
      "portable", "portable-boundary", "fixtures" }
  end
  local function git_run(words: {string}, values?: {string:string}, input?: string): string
    local args = { git, "-C", root }
    for _, word in ipairs(words) do args[#args + 1] = word end
    local result = privileged(args, { env = values or caller_env, input = input, stdout = "capture", stderr = "capture" })
    successful(result, "git")
    return ((result.stdout or ""):gsub("\n$", ""))
  end
  for _, phase in ipairs(phases) do
    assert(phase:match("^[%w_-]+$"), "invalid phase: " .. phase)
    if phase == "build" then
      local index_dir = assert(sys.mkdtemp(fallback_value(caller_env, "TMPDIR", "/tmp") .. "/cosmic-ci-local-index.XXXXXX"))
      local worked, snapshot = pcall(function(): string
        local values = copy(caller_env)
        values.GIT_INDEX_FILE = index_dir .. "/index"
        -- Keep the caller's tracked set, including force-added ignored files.
        -- A blank index would silently drop them when add applies ignores.
        local original = git_run({ "rev-parse", "--git-path", "index" })
        if original:sub(1, 1) ~= "/" then original = root .. "/" .. original end
        if present(original) then
          assert(Fs.write(values.GIT_INDEX_FILE, assert(Fs.read(original)), 0x180))
        end
        git_run({ "add", "-A" }, values)
        local tree = git_run({ "write-tree" }, values)
        return git_run({ "commit-tree", tree, "-p", "HEAD" }, nil, "ci/run-local snapshot\n")
      end)
      local removed, why = Fs.remove_tree(index_dir)
      if not worked then error(snapshot) end
      assert(removed, why)
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
    successful(probe("local F=require('cosmic.fs'); assert(F.mkdirs(" ..
        string.format("%q", state .. "/runner") .. ")); assert(F.mkdirs(" ..
        string.format("%q", state .. "/logs") .. "))", env), "phase directories")
    local path = state .. "/logs/" .. phase .. ".log"
    local file <close>: Descriptor = setmetatable({ fd = -1 }, descriptor_mt)
    local fd, open_why = sys.open(path, sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC | sys.O_NOFOLLOW, 0x1a4)
    file.fd = assert(fd, path .. ": " .. tostring(open_why))
    local values = copy(env)
    values.GITHUB_WORKSPACE, values.RUNNER_TEMP = candidate, state .. "/runner"
    values.GITHUB_RUN_ID, values.GITHUB_RUN_ATTEMPT, values.COSMIC_WORKER = "local", "1", "local"
    values.TARGET, values.XDG_CACHE_HOME = target, state .. "/cache"
    values.COSMIC_ZIG_CACHE_FROM, values.COSMIC_ZIG_GLOBAL_CACHE = seed, zig_global
    local start = Clock.monotonic_ns()
    local result, why = Child.run({ cosmic, "cosmic_ci/driver.tl", "platform", phase, "success" },
      { cwd = project, env = values, credentials = credentials, stdout = file.fd, stderr = file.fd })
    local log = file.fd
    file.fd = -1
    local closed, close_why = Fs.close(log)
    assert(result, why)
    assert(closed, close_why)
    local status = Child.shell_status(result)
    say(phase .. ": status " .. tostring(status) .. ", " ..
        tostring((Clock.monotonic_ns() - start) // Clock.seconds(1)) .. " s, log " .. path)
    if status ~= 0 then
      -- Diagnostics must not replace the phase status, or retain an entire
      -- build/fuzzer log in memory. Stop at an overlong line as well.
      local input <close>: Descriptor = setmetatable({ fd = -1 }, descriptor_mt)
      local opened, read_why = Fs.open_read(path)
      if opened then
        input.fd = opened
        local reader = Stream.lines(Stream.from_fd(opened), 65536)
        local lines = 0
        while lines < 20 do
          local line, trouble = reader:read()
          if line == nil then
            if trouble ~= "" then say("log diagnostics stopped: " .. trouble) end
            break
          end
          if line:match("^FAIL") or line:find(" FAIL", 1, true) or
              line:find("timed out", 1, true) or line:find("error", 1, true) then
            Fs.put(Fs.stderr, line .. "\n")
            lines = lines + 1
          end
        end
      else
        say("cannot read phase log: " .. read_why)
      end
      return status
    end
  end
  return 0
end

function Local.main(argv: {integer:string}): integer
  -- Keep cancellation caught until private-index/log cleanup completes.
  local _guard <close> = assert(Signal.guard())
  local ok, answer = pcall(execute, argv)
  if not ok then
    say(tostring(answer))
    return 2
  end
  return answer
end

return Local
