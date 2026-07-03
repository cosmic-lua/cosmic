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
---   5. supervisor forks the workload. Workload does chdir, landlock,
---      no_new_privs, drop_privs, pledge, then execvpe(argv, env).
---   6. supervisor runs become_init(workload_pid, {sidecars={proxy_pid}})
---      and os.exit()s with the returned code. parent maps wait status
---      to an exit code and returns it from run().
local unix = require("cosmo.unix")
local cosmo = require("cosmo")
local netns = require("cosmic.quicksand.netns")
local qproc = require("cosmic.quicksand.proc")
local qcaps = require("cosmic.quicksand.caps")
local proxy = require("cosmic.quicksand.proxy")
local landlock = require("cosmic.landlock")
local pledge = require("cosmic.pledge")
local box_fs = require("cosmic.quicksand.box.fs")
local box_env = require("cosmic.quicksand.box.env")
local cenv = require("cosmic.env")

local u = unix as {string: any}

-- Cast the typed-record helpers to `any`-accepting shapes so we can
-- thread raw {string: any} opt tables through without duplicating every
-- record definition here.
local plan_landlock = box_fs.plan_landlock as function(any): any
local env_apply = box_env.apply as function(any, {string: string}): {string: string}
local ll_restrict = landlock.restrict as function(any): boolean, string
local proxy_start = proxy.start as function(any): {string: any}, string

local record CapsModule
  capabilities: function(): {string: boolean}
end

local function clone_flags(opts: {string: any}): integer
  local flags = (u.CLONE_NEWUSER as integer)
  | (u.CLONE_NEWNET as integer)
  | (u.CLONE_NEWNS as integer)
  if opts and opts.hostname then
    flags = flags | (u.CLONE_NEWUTS as integer)
  end
  -- Include CLONE_NEWPID by default for PID namespace isolation, unless
  -- the caller has opted out with pid_ns = false, or the kernel lacks
  -- the capability. After unshare(CLONE_NEWPID) the supervisor stays in
  -- the old PID ns; the first forked child (proxy or workload) becomes
  -- PID 1 of the new namespace.
  if opts == nil or opts.pid_ns ~= false then
    local qs = require("cosmic.quicksand") as CapsModule
    local c = qs.capabilities()
    if (c as {string: boolean}).pid_ns then
      flags = flags | (u.CLONE_NEWPID as integer)
    end
  end
  return flags
end

local function compute_env(opts: {string: any}): {string}
  local env_opts = opts and opts.env
  if not env_opts then
    return cenv.list()
  end
  return box_env.render(env_apply(env_opts, cenv.all()))
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
local function workload_setup(opts: {string: any}): string
  if opts and opts.cwd then
    local ok, err = (u.chdir as function(string): boolean, any)(opts.cwd as string)
    if not ok then return "chdir: " .. tostring(err) end
  end
  local fs = opts and opts.fs as {string: any}
  if fs and (fs.ro or fs.rw or fs.exec) then
    local plan = plan_landlock(fs)
    local ok, err = ll_restrict(plan)
    if not ok then return "landlock: " .. tostring(err) end
  end
  local pr = opts and opts.proc as {string: any}
  if pr and (pr.no_new_privs or pr.uid ~= nil) then
    local ok, err = qproc.no_new_privs()
    if not ok then return "no_new_privs: " .. tostring(err) end
  end
  -- Drop the capability bounding set before drop_privs: that step's
  -- capset(0,0,0) clears CAP_SETPCAP, which PR_CAPBSET_DROP requires.
  if pr and (pr.drop_caps or (pr.keep_caps and #(pr.keep_caps as {string}) > 0)) then
    local ok, err = qcaps.drop_bounding({keep = pr.keep_caps as {string}})
    if not ok then return "drop_caps: " .. tostring(err) end
  end
  if pr and pr.uid ~= nil then
    local gid = pr.gid
    if gid == nil then gid = pr.uid end
    local ok, err = qproc.drop_privs(pr.uid as integer, gid as integer)
    if not ok then return "drop_privs: " .. tostring(err) end
  end
  if pr and pr.pledge then
    local ok, err = pledge.apply(pr.pledge as string, nil, nil)
    if not ok then return "pledge: " .. tostring(err) end
  end
  return nil
end

local function exec_workload(argv: {string}, env_list: {string})
  local ok, err = (u.execvpe as function(string, {string}, {string}): boolean, any)(
    argv[1], argv, env_list)
  if not ok then
    io.stderr:write("quicksand: execvpe " .. tostring(argv[1])
      .. ": " .. tostring(err) .. "\n")
  end
  os.exit(127)
end

-- Supervisor child entry point. Never returns: always exits the process.
local function supervisor(
    parent_netns_fd: integer,
    opts: {string: any},
    argv: {string})
  local flags = clone_flags(opts)
  local ok, err = (u.unshare as function(integer): boolean, any)(flags)
  if not ok then
    io.stderr:write("quicksand: unshare: " .. tostring(err) .. "\n")
    os.exit(126)
  end

  local pr = opts and opts.proc as {string: any}
  local uid: integer = pr and pr.uid as integer
  local gid: integer = pr and pr.gid as integer
  local ok2, err2 = qproc.setup_userns_maps(uid, gid)
  if not ok2 then
    io.stderr:write("quicksand: setup_userns_maps: "
      .. tostring(err2) .. "\n")
    os.exit(126)
  end

  local ok3, err3 = netns.bring_up("lo")
  if not ok3 then
    io.stderr:write("quicksand: bring_up lo: " .. tostring(err3) .. "\n")
    os.exit(126)
  end

  if opts and opts.hostname then
    local ok4, err4 = (u.sethostname as function(string): boolean, any)(
      opts.hostname as string)
    if not ok4 then
      io.stderr:write("quicksand: sethostname: " .. tostring(err4) .. "\n")
      os.exit(126)
    end
  end

  local sidecars: {integer} = {}
  local proxy_port: integer = nil
  local net = opts and opts.net as {string: any}
  if net and net.allow then
    local popts = {
      bind_ip = cosmo.ParseIp("127.0.0.1") as integer,
      bind_port = 0,
      allowed_hosts = net.allow,
      upstream_ns_fd = parent_netns_fd,
      log_level = (net.log_level as string) or "quiet",
      resolve_timeout_ms = net.resolve_timeout_ms as integer,
    }
    local h, perr = proxy_start(popts)
    if not h then
      io.stderr:write("quicksand: proxy.start: "
        .. tostring(perr) .. "\n")
      os.exit(126)
    end
    table.insert(sidecars, h.pid as integer)
    proxy_port = h.port as integer
  end

  -- Supervisor no longer needs the outer netns fd: the proxy child
  -- forked by proxy.start() inherited its own copy.
  if parent_netns_fd then
    (u.close as function(integer): boolean)(parent_netns_fd)
  end

  local env_list = compute_env(opts)
  if proxy_port and net.proxy_env ~= false then
    env_list = inject_proxy_env(env_list, proxy_port)
  end

  local pid, ferr = (u.fork as function(): integer, any)()
  if not pid then
    io.stderr:write("quicksand: fork workload: "
      .. tostring(ferr) .. "\n")
    os.exit(126)
  end
  if pid == 0 then
    local serr = workload_setup(opts)
    if serr then
      io.stderr:write("quicksand: " .. serr .. "\n")
      os.exit(126)
    end
    exec_workload(argv, env_list)
    return -- unreachable
  end

  local code = qproc.become_init(pid as integer, {sidecars = sidecars})
  os.exit(code)
end

--- Fork+orchestrate a Box policy around argv. Returns an integer exit
--- code on success, or nil + string when setup itself failed before the
--- fork (e.g. couldn't open the parent netns fd).
local function run(opts: {string: any}, argv: {string}): integer, string
  local parent_fd: integer = nil
  local net = opts and opts.net as {string: any}
  if net and net.allow then
    local fd, err = netns.open(nil)
    if not fd then
      return nil, "quicksand: netns.open parent: " .. tostring(err)
    end
    parent_fd = fd
  end

  local pid, ferr = (u.fork as function(): integer, any)()
  if not pid then
    if parent_fd then
      (u.close as function(integer): boolean)(parent_fd)
    end
    return nil, "quicksand: fork: " .. tostring(ferr)
  end
  if pid == 0 then
    supervisor(parent_fd, opts, argv)
    os.exit(127) -- unreachable
  end

  if parent_fd then
    (u.close as function(integer): boolean)(parent_fd)
  end

  local _, status = (u.wait as function(integer): integer, integer)(pid as integer)
  if (u.WIFEXITED as function(integer): boolean)(status) then
    return (u.WEXITSTATUS as function(integer): integer)(status)
  end
  if (u.WIFSIGNALED as function(integer): boolean)(status) then
    return 128 + (u.WTERMSIG as function(integer): integer)(status)
  end
  return nil, "quicksand: unexpected wait status " .. tostring(status)
end

local record BoxRunModule
  run: function(opts: {string: any}, argv: {string}): integer, string
end

local M: BoxRunModule = {
  run = run,
}

return M
