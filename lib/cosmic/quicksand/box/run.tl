--- Fork / unshare / exec orchestration for cosmic.quicksand.Box:run.
---
--- Pulled in lazily by box/init.tl so that hosts using only new() /
--- merge() / close() don't load the entire sandbox plumbing on require.
---
--- Flow:
---   1. parent opens its own netns fd (if a net policy is requested) —
---      the supervisor child inherits it and hands it to the proxy as
---      upstream_ns_fd so the proxy can dial out from the outer ns.
---   2. parent fork()s the supervisor and wait()s for it.
---   3. supervisor unshares USER | NET | NS (+ UTS if hostname), writes
---      uid_map / gid_map, brings up lo, optionally calls
---      sethostname(2).
---   4. supervisor starts the allowlist proxy sidecar if net.allow is
---      set, and prepends HTTP(S)_PROXY into the workload env when
---      net.proxy_env is not explicitly false.
---   5. supervisor forks the workload. Workload does chdir, the
---      sandbox fs policy (landlock), no_new_privs, drop_privs,
---      pledge, then execvpe(argv, env).
---   6. supervisor runs become_init(workload_pid, {sidecars={proxy_pid}})
---      and os.exit()s with the returned code. parent maps wait status
---      to an exit code and returns it from run().
---
--- Setup failures are reported over a CLOEXEC error pipe (the same
--- pattern proxy.start uses for its bound port): the supervisor and the
--- pre-exec workload write the failing step there before exiting, and a
--- successful execve closes the workload's end automatically. run()
--- drains the pipe after wait() — a non-empty pipe always means setup
--- failed before the workload ran, so run() returns nil + the message
--- instead of masquerading the failure as a workload exit code.
local unix = require("cosmo.unix")
local cosmo = require("cosmo")
local netns = require("cosmic.quicksand.netns")
local qproc = require("cosmic.quicksand.proc")
local qcaps = require("cosmic.quicksand.caps")
local proxy = require("cosmic.quicksand.proxy")
local sandbox = require("cosmic.sandbox")
local pledge = require("cosmic.pledge")
local box_env = require("cosmic.quicksand.box.env")
local types = require("cosmic.quicksand.types")
local cenv = require("cosmic.env")

local type BoxOptions = types.BoxOptions

-- The CLONE_* constants are declared `number` in the binding types;
-- bitwise composition needs integers, so convert once here.
local NEWUSER < const > = unix.CLONE_NEWUSER as integer
local NEWNET < const > = unix.CLONE_NEWNET as integer
local NEWNS < const > = unix.CLONE_NEWNS as integer
local NEWUTS < const > = unix.CLONE_NEWUTS as integer
local NEWPID < const > = unix.CLONE_NEWPID as integer

local record CapsModule
  capabilities: function(): types.Capabilities
end

local function clone_flags(opts: BoxOptions): integer
  local flags = NEWUSER | NEWNET | NEWNS
  if opts and opts.hostname then
    flags = flags | NEWUTS
  end
  -- Include CLONE_NEWPID by default for PID namespace isolation, unless
  -- the caller has opted out with pid_ns = false, or the kernel lacks
  -- the capability. After unshare(CLONE_NEWPID) the supervisor stays in
  -- the old PID ns; the first forked child (proxy or workload) becomes
  -- PID 1 of the new namespace.
  if opts == nil or opts.pid_ns ~= false then
    -- Lazy require: the umbrella re-exports Box, so a top-level
    -- require here would be a cycle.
    local qs = require("cosmic.quicksand") as CapsModule
    if qs.capabilities().pid_ns then
      flags = flags | NEWPID
    end
  end
  return flags
end

local function compute_env(opts: BoxOptions): {string}
  local env_opts = opts and opts.env
  if not env_opts then
    return cenv.list()
  end
  return box_env.render(box_env.apply(env_opts, cenv.all()))
end

local function inject_proxy_env(env_list: {string}, port: integer): {string}
  local out: {string} = {}
  for _, e in ipairs(env_list) do
    local eq = e:find("=", 1, true)
    local k = eq and e:sub(1, eq - 1) or e
    if k ~= "HTTP_PROXY" and k ~= "HTTPS_PROXY"
    and k ~= "http_proxy" and k ~= "https_proxy" then
      table.insert(out, e)
    end
  end
  local url = "http://127.0.0.1:" .. tostring(port)
  table.insert(out, "HTTP_PROXY=" .. url)
  table.insert(out, "HTTPS_PROXY=" .. url)
  table.insert(out, "http_proxy=" .. url)
  table.insert(out, "https_proxy=" .. url)
  return out
end

-- Apply post-fork workload restrictions. Returns nil on success or an
-- error string so the caller can emit one consistent diagnostic and
-- exit with a well-known status (126).
local function workload_setup(opts: BoxOptions): string
  if opts and opts.cwd then
    local ok, err = unix.chdir(opts.cwd)
    if not ok then return "chdir: " .. tostring(err) end
  end
  local fs = opts and opts.fs
  if fs and (fs.ro or fs.rw or fs.exec) then
    -- The fs policy is cosmic.sandbox's Fs schema; the facade picks the
    -- mechanism (landlock here — Box is Linux-only) and its errors are
    -- already prefixed "sandbox: fs: ...".
    local ok, err = sandbox.apply({fs = fs})
    if not ok then return tostring(err) end
  end
  local pr = opts and opts.proc
  if pr and (pr.no_new_privs or pr.uid ~= nil) then
    local ok, err = qproc.no_new_privs()
    if not ok then return "no_new_privs: " .. tostring(err) end
  end
  -- Drop the capability bounding set before drop_privs: that step's
  -- capset(0,0,0) clears CAP_SETPCAP, which PR_CAPBSET_DROP requires.
  if pr and (pr.drop_caps or (pr.keep_caps and #pr.keep_caps > 0)) then
    local ok, err = qcaps.drop_bounding({keep = pr.keep_caps})
    if not ok then return "drop_caps: " .. tostring(err) end
  end
  if pr and pr.uid ~= nil then
    local gid = pr.gid
    if gid == nil then gid = pr.uid end
    local ok, err = qproc.drop_privs(pr.uid, gid)
    if not ok then return "drop_privs: " .. tostring(err) end
  end
  if pr and pr.pledge then
    local ok, err = pledge.apply(pr.pledge)
    if not ok then return "pledge: " .. tostring(err) end
  end
  return nil
end

local function exec_workload(err_fd: integer, argv: {string}, env_list: {string})
  -- execvpe only ever returns on failure (nil + error).
  local _, err = unix.execvpe(argv[1], argv, env_list)
  unix.write(err_fd, "execvpe " .. tostring(argv[1])
    .. ": " .. tostring(err))
  os.exit(127)
end

-- Supervisor child entry point. Never returns: always exits the process.
-- Setup failures are written to err_fd (run()'s error pipe) so the
-- parent surfaces them as nil + error instead of an exit code.
local function supervisor(
    parent_netns_fd: integer,
    err_fd: integer,
    opts: BoxOptions,
    argv: {string})
  local function die(msg: string)
    unix.write(err_fd, msg)
    os.exit(126)
  end
  local flags = clone_flags(opts)
  local ok, err = unix.unshare(flags)
  if not ok then
    die("unshare: " .. tostring(err))
  end

  local pr = opts and opts.proc
  local uid: integer = pr and pr.uid
  local gid: integer = pr and pr.gid
  local ok2, err2 = qproc.setup_userns_maps(uid, gid)
  if not ok2 then
    die("setup_userns_maps: " .. tostring(err2))
  end

  local ok3, err3 = netns.bring_up("lo")
  if not ok3 then
    die("bring_up lo: " .. tostring(err3))
  end

  if opts and opts.hostname then
    local ok4, err4 = unix.sethostname(opts.hostname)
    if not ok4 then
      die("sethostname: " .. tostring(err4))
    end
  end

  local sidecars: {integer} = {}
  local proxy_port: integer = nil
  local net = opts and opts.net
  if net and net.allow then
    local h, perr = proxy.start({
        bind_ip = cosmo.ParseIp("127.0.0.1") as integer,
        bind_port = 0,
        -- Box's typed NetRule and the proxy's runtime-validated
        -- ProxyRule are distinct records with the same wire shape;
        -- proxy.start's rules.validate is the checker of record here.
        allowed_hosts = net.allow as {string: proxy.ProxyRule},
        upstream_ns_fd = parent_netns_fd,
        log_level = net.log_level or "quiet",
        resolve_timeout_ms = net.resolve_timeout_ms,
      })
    if not h then
      die("proxy.start: " .. tostring(perr))
    end
    -- tl 0.24.8 does not narrow the ProxyHandle | nil union through
    -- the die() above; cast at the proven non-nil use site.
    local handle = h as proxy.ProxyHandle
    table.insert(sidecars, handle.pid)
    proxy_port = handle.port
  end

  -- Supervisor no longer needs the outer netns fd: the proxy child
  -- forked by proxy.start() inherited its own copy.
  if parent_netns_fd then
    unix.close(parent_netns_fd)
  end

  local env_list = compute_env(opts)
  if proxy_port and net.proxy_env ~= false then
    env_list = inject_proxy_env(env_list, proxy_port)
  end

  local pid, ferr = unix.fork()
  if not pid then
    die("fork workload: " .. tostring(ferr))
  end
  if pid == 0 then
    local serr = workload_setup(opts)
    if serr then
      unix.write(err_fd, serr)
      os.exit(126)
    end
    exec_workload(err_fd, argv, env_list)
    return -- unreachable
  end

  local code = qproc.become_init(pid as integer, {sidecars = sidecars})
  os.exit(code)
end

--- Fork+orchestrate a Box policy around argv. Returns an integer exit
--- code on success, or nil + string when setup failed — either before
--- the fork (e.g. couldn't open the parent netns fd) or inside the
--- supervisor / pre-exec workload (unshare, uid_map, landlock, pledge,
--- execvpe, ...), which report over the error pipe. An integer return
--- is therefore always the workload's own exit status.
local function run(opts: BoxOptions, argv: {string}): integer | nil, string
  local parent_fd: integer = nil
  local net = opts and opts.net
  if net and net.allow then
    local fd, err = netns.open(nil)
    if not fd then
      return nil, "quicksand: netns.open parent: " .. tostring(err)
    end
    parent_fd = fd
  end

  -- CLOEXEC error pipe: a successful execve closes the workload's
  -- write end automatically, so a non-empty pipe always means setup
  -- failed before the workload ran.
  local er, ew = unix.pipe(unix.O_CLOEXEC)
  if not er then
    if parent_fd then
      unix.close(parent_fd)
    end
    return nil, "quicksand: pipe: " .. tostring(ew)
  end
  local erfd = er as integer
  local ewfd = ew as integer

  local pid, ferr = unix.fork()
  if not pid then
    unix.close(erfd)
    unix.close(ewfd)
    if parent_fd then
      unix.close(parent_fd)
    end
    return nil, "quicksand: fork: " .. tostring(ferr)
  end
  if pid == 0 then
    unix.close(erfd)
    supervisor(parent_fd, ewfd, opts, argv)
    os.exit(127) -- unreachable
  end

  unix.close(ewfd)
  if parent_fd then
    unix.close(parent_fd)
  end

  local _, status = unix.wait(pid)

  -- Drain the error pipe. Every write end is closed by now — the
  -- supervisor exited, and become_init reaped the workload and sidecars
  -- before that — so this reads to EOF without blocking.
  local parts: {string} = {}
  while true do
    local chunk = unix.read(erfd, 4096)
    if not chunk or #chunk == 0 then break end
    table.insert(parts, chunk)
  end
  unix.close(erfd)
  if #parts > 0 then
    local msg = table.concat(parts):gsub("%s+$", "")
    return nil, "quicksand: " .. msg
  end

  if unix.WIFEXITED(status) then
    return unix.WEXITSTATUS(status) as integer
  end
  if unix.WIFSIGNALED(status) then
    return 128 + (unix.WTERMSIG(status) as integer)
  end
  return nil, "quicksand: unexpected wait status " .. tostring(status)
end

local record BoxRunModule
  run: function(opts: BoxOptions, argv: {string}): integer | nil, string
end

local M: BoxRunModule = {
  run = run,
}

return M
