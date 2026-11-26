--- @public
--- What `cosmic agent`'s tools are held to: a [`cosmic.sandbox`] policy, made
--- from the working directory and the user's flags. run's worker runs under
--- it, as this program, needing no grant of it, and is refused the nest
--- promise (`cosmic docs cosmic.agent.worker`); so does what Host.bash runs,
--- with --commands.
---
---     local p = assert(Policy.of("/work", { mode = "write", network = false, grants = {} }))
---     assert(Sandbox.permits(p, "/work/a.txt", "write"))
---
--- The tools run in a sandbox (cosmic.sandbox), unless --sandbox off.
--- `cosmic agent policy` prints the one they would run under here, path by
--- path, with the same flags:
---
---     --sandbox write   the default: the working directory and the
---                       sandbox's home (below) are read, written and run
---                       in; the host's programs are read and run;
---                       nothing else is there
---     --sandbox read    the working directory and the home are read and
---                       run in alone
---     --sandbox off     no sandbox: the tools have your user's rights,
---                       and --network, --connect and --grant are refused
---     --network         snippets may reach the network (none by
---                       default): public addresses alone
---     --connect host:port   one more target, given again for each: an
---                       address written out may be loopback or private
---                       (`127.0.0.1:8123`), a name reaches public
---                       addresses alone, and a port of `*` opens every
---                       port
---     --grant path[:rwxc]   one more path, read alone unless the letters
---                       say more: w writes, x runs, c creates and removes;
---                       given again for each path
---
--- The host's programs are the system's (/usr, /bin, /lib and the
--- files a libc reads) and those of each directory on PATH, read and
--- run in. A bin or sbin brings the prefix that holds it (/usr/local,
--- /opt/homebrew, /opt/node22), where its programs find their
--- libraries, if the prefix is two levels deep or more, outside your
--- home, and does not hold the working directory; else the bin comes
--- alone (~/.local/bin). A directory that is or holds the working
--- directory or your home (/, $HOME), or lies in the agent's own data or
--- cache, is not granted, whatever PATH says. A Nix profile brings
--- /nix/store. What a program needs beside its bin in your home
--- (~/.rustup for rustup's cargo) takes a --grant. A command's PATH is
--- yours with each directory by its real name, since a link to one
--- (/opt/maven) is not there. Programs may map memory to run (the jit
--- promise), as node, java and other JIT compilers do.
---
--- Snippets run under the policy: on Linux in a root of its own, where
--- what was not granted is not there, in its own pid namespace, with at
--- most 512 processes; on macOS under Seatbelt. TMPDIR is a fresh
--- temporary directory, and the environment holds PATH, LANG, LC_ALL
--- and TERM alone (JAVA_HOME and the like are not passed), so no key
--- of yours reaches a command; with --network, SSL_CERT_FILE too, and
--- the file it names is read; on Linux USER
--- and LOGNAME are agent.
---
--- The commands have a home of their own, not yours, kept from one
--- session to the next ($XDG_CACHE_HOME/cosmic/agent/home,
--- or ~/.cache/cosmic/agent/home). It is their HOME, and its .cache their
--- XDG_CACHE_HOME, so what tools keep under a home outlives a command:
--- cosmic's binary, pip's and go's caches and modules, npm's, cargo's.
--- It is held to your user (0700), and read and run in alone under
--- --sandbox read. The first download needs --network; later runs find
--- it there. Every session in every directory shares the home, and
--- what one session's commands leave there another's may run, its
--- dotfiles too (a ~/.gitconfig alias, a .bashrc, an .npmrc), even
--- under --sandbox read: keep nothing secret in it, trust it no more
--- than the least trusted repository the agent writes in, and `cosmic agent
--- policy clear-home` to start clean. `cosmic agent policy` makes the home
--- where it is not there. Where there is no cache directory, HOME is the
--- sandbox's fresh /tmp on Linux, and unset on macOS.
---
--- On Linux, commands may hold what they run to less (the nest
--- promise), so a test runner that sandboxes its tests runs. The price:
--- the root of its own alone holds files, not Landlock as well, and a
--- command may make namespaces and mounts of its own. macOS has no
--- nest: there a command that sandboxes itself again is refused. On
--- both, a command may make no unix socket.
---
--- In a git worktree, whose .git is a file ("gitdir: path"), the
--- gitdir it names and the common git dir that gitdir's commondir
--- names are granted as the working directory is, so git status, diff
--- and stash work as in a plain checkout (read alone under --sandbox
--- read). Each is granted only as git links them: the gitdir is
--- <common>/worktrees/<name>, and its gitdir file names this .git
--- back; anything else grants nothing.
---
--- A command's process group ends when it ends, times out, or the turn
--- is stopped; on Linux, so does what it started outside the group,
--- and in a root of its own nothing outlives it.

local Fs = require("cosmic.fs")
local Sandbox = require("cosmic.sandbox")

local record Policy
  --- What the user asked for.
  record Config
    --- "write" (the default): the working directory read and written;
    --- "read": read alone; "off": no sandbox.
    mode: string
    --- Whether snippets may reach the network: every name, by the grant `*:*`.
    network: boolean
    --- More `connect` targets, `host:port` ([`cosmic.relay.grant`]): an
    --- address written out here, loopback or private too, may be reached,
    --- as `--connect 127.0.0.1:8123` lets a local server be; a name
    --- reaches public addresses alone.
    connect?: {string}
    --- More paths, each with its letters of "rwxc".
    grants: {Sandbox.Path}
    --- A home of the sandbox's own, kept from one session to the next:
    --- the commands' HOME, its .cache their XDG_CACHE_HOME, so a tool's
    --- downloads and builds (cosmic's, pip's, go's, npm's) outlive a
    --- command. Read, written and run in (read and run in alone in mode
    --- read); made where it is not there, and held to its owner (0700).
    --- Nil for none: then HOME is the sandbox's fresh /tmp on Linux.
    home?: string
    --- The PATH the commands are given: each absolute directory of it is
    --- read and run in, so the host's programs run where they were put
    --- (/usr/local, /opt/homebrew, a Nix profile), not only the system's.
    path?: string
    --- The user's own home, of which only PATH's own directories are
    --- granted, not what holds them.
    user_home?: string
    --- Directories no PATH entry and no grant may reach, and the working
    --- directory may not hold: the agent's data and cache, and its MCP
    --- config's.
    kept_out?: {string}
    --- The user's $SSL_CERT_FILE: with `network`, the tools read it and
    --- are given it, so a request through a proxy that signs with its
    --- own root (as a company's does) is trusted as the user's are. It
    --- must be a file, outside `kept_out`; one not there is not given.
    cert_file?: string
  end

  --- What the agent's own process needs beside what it starts, for
  --- [`Policy.session`].
  record Session
    --- Directories it keeps in, read, written and made in: its sessions
    --- database's and its cache's. Each must be there.
    keeps: {string}
    --- Files it reads: the instructions files over the working directory,
    --- the MCP config, the identity token's file, the certificates.
    reads: {string}
    --- What it reaches: the API's host and port, and the MCP servers'
    --- at a url.
    connect: {string}
    --- The variables passed on to it, by name.
    env: {string}
    --- What each MCP server it starts over stdio is held to.
    servers: {Sandbox.Policy}
  end
end

--- The modes, as --sandbox names them.
local MODES <const>: {string: boolean} = { write = true, read = true, off = true }
--- The most processes and threads one snippet's worker may run at once.
local PROCESSES <const> = 512

-- What most programs read beyond the system profile, where the host has it.
local READS <const>: {string} = { "/etc/ssl", "/etc/ca-certificates", "/etc/pki", "/etc/resolv.conf", "/etc/hosts",
  "/etc/gitconfig", "/usr/share/zoneinfo" }

local darwin <const> = Sandbox.on_macos

--- Whether a directory is at `path`; false where nothing is, or it cannot be looked at.
local function is_dir(path: string): boolean
  local status, _ = Fs.status(path)
  return status ~= nil and status.is_dir
end

--- The first line of `text`, its surrounding space trimmed.
local function first_line(text: string): string
  local line = text:match("^[^\r\n]*") or ""
  return line:match("^%s*(.-)%s*$") or ""
end

--- The real name of the git directory `named` in the file `file`: a
--- relative name is relative to the directory holding the file. Nil
--- where it is not a directory that is there and holds a HEAD, as git
--- asks of one, so a stray name ("/", a home) is not granted.
local function directory_in(file: string, named: string): string?
  if named == "" or named:find("\0", 1, true) ~= nil then return nil end
  local path = if named:sub(1, 1) == "/" then named else Fs.dirname(file) .. "/" .. named end
  local real, _ = Fs.absolute(path)
  if real == nil then return nil end
  if not is_dir(real) then return nil end
  local head, _ = Fs.status(real .. "/HEAD")
  if head == nil or not head.exists then return nil end
  return real
end

--- Where the git worktree checked out at `root` keeps its repository:
--- the gitdir its .git file names and the common git dir that gitdir's
--- commondir names, each as its real name. Both are trusted only as git
--- links them, since the sandbox can write `root/.git` and the gitdir:
--- the gitdir is <common>/worktrees/<name>, and its own gitdir file
--- names `root/.git` back. Empty otherwise, and where .git is a
--- directory (a plain checkout's, in `root` already).
local function worktree_dirs(root: string): {string}
  local none: {string} = {}
  local dotgit = root .. "/.git"
  if is_dir(dotgit) then return none end
  local text, _ = Fs.read(dotgit)
  if text == nil then return none end
  local named = first_line(text):match("^gitdir:%s*(.-)$")
  if named == nil then return none end
  local gitdir = directory_in(dotgit, named)
  if gitdir == nil then return none end
  local common_text, _ = Fs.read(gitdir .. "/commondir")
  if common_text == nil then return none end
  local common = directory_in(gitdir .. "/commondir", first_line(common_text))
  if common == nil or Fs.dirname(gitdir) ~= common .. "/worktrees" then return none end
  local back_text, _ = Fs.read(gitdir .. "/gitdir")
  if back_text == nil then return none end
  local back = first_line(back_text)
  if back == "" then return none end
  local back_real, _ = Fs.absolute(if back:sub(1, 1) == "/" then back else gitdir .. "/" .. back end)
  local here, _ = Fs.absolute(dotgit)
  if back_real == nil or back_real ~= here then return none end
  return { gitdir, common }
end

--- What the sandbox's commands are given, past the variables passed on:
--- a home of their own, not the user's (the kept `home`, else on Linux
--- its fresh /tmp), and on Linux a name, so user lookups
--- (getpass.getuser) work; and `path`, PATH as its directories' real
--- names, which the sandbox shows where a link to one (/opt/maven) is
--- not there.
local function env_of(linux: boolean, home?: string, path?: string, cert?: string): {string: string}?
  local out: mut {string: string} = {}
  if path ~= nil then out["PATH"] = path end
  if cert ~= nil then out["SSL_CERT_FILE"] = cert end
  if linux then out["HOME"], out["USER"], out["LOGNAME"] = "/tmp", "agent", "agent" end
  if home ~= nil then out["HOME"], out["XDG_CACHE_HOME"] = home, home .. "/.cache" end
  if next(out) == nil then return nil end
  return out
end

--- `path`, each absolute directory of it by its real name.
local function real_path(path: string): string
  local out: mut {string} = {}
  for entry in path:gmatch("[^:]+") do
    local real: string? = nil
    if entry:sub(1, 1) == "/" then
      local found, _ = Fs.absolute(entry)
      real = found
    end
    out[#out + 1] = real or entry
  end
  return table.concat(out, ":")
end

--- Where the programs of the PATH `path` live, each by its real name,
--- once. A directory named bin or sbin brings its prefix (/usr/local,
--- /opt/homebrew, /opt/node22), where programs find their libraries and
--- links lead, where the prefix is two levels deep or more, outside
--- `user_home`, and holds nothing `guarded`; else the directory alone.
--- A directory that is or holds one of `guarded` (the working
--- directory, the user's home), or lies in one of `kept_out` (the agent's
--- data and cache), is not granted at all, so a PATH of / or $HOME
--- grants nothing. A Nix profile's links lead into /nix/store, which
--- comes with it. Where the user's home is not known, no prefix comes.
local function program_dirs(path: string, user_home: string?, guarded: {string}, kept_out: {string}): {string}
  local out: mut {string} = {}
  local seen: mut {string: boolean} = {}
  local function add(dir: string)
    if seen[dir] == true then return end
    seen[dir] = true
    out[#out + 1] = dir
  end
  local home: string? = nil
  if user_home ~= nil and user_home ~= "" then
    local real, _ = Fs.absolute(user_home)
    home = real
  end
  local held: mut {string} = {}
  for _, g in ipairs(guarded) do held[#held + 1] = g end
  if home ~= nil then held[#held + 1] = home end
  local out_of: mut {string} = {}
  for _, k in ipairs(kept_out) do
    local real, _ = Fs.absolute(k)
    out_of[#out_of + 1] = real or k
  end
  --- Whether `dir` may be granted: it holds nothing held and lies in nothing kept out.
  local function grantable(dir: string): boolean
    for _, g in ipairs(held) do
      if Fs.within(g, dir) then return false end
    end
    for _, k in ipairs(out_of) do
      if Fs.within(dir, k) then return false end
    end
    return true
  end
  for entry in path:gmatch("[^:]+") do
    local real, _ = Fs.absolute(entry)
    if entry:sub(1, 1) == "/" and real ~= nil and is_dir(real) and grantable(real) then
      local dir = real
      local name, prefix = Fs.basename(real), Fs.dirname(real)
      local deep = prefix:match("^/[^/]+/.") ~= nil
      if (name == "bin" or name == "sbin") and deep and home ~= nil and not Fs.within(prefix, home) and
          grantable(prefix) then
        dir = prefix
      end
      add(dir)
      if Fs.within(real, "/nix") or Fs.within(entry, "/nix") then
        local store, _ = Fs.absolute("/nix/store")
        if store ~= nil then add(store) end
      end
    end
  end
  -- What the system grants already, or another of these holds, is left out.
  local kept: mut {string} = {}
  for _, dir in ipairs(out) do
    local inside = Fs.within(dir, "/usr") or Fs.within(dir, "/bin")
    for _, other in ipairs(out) do
      if other ~= dir and Fs.within(dir, other) then inside = true end
    end
    if not inside then kept[#kept + 1] = dir end
  end
  return kept
end

--- The `connect` targets `config` grants: `*:*` for network, then its
--- own.
local function connect_of(config: Policy.Config): {string}
  local out: mut {string} = {}
  if config.network then out[#out + 1] = "*:*" end
  for _, target in ipairs(config.connect or {}) do out[#out + 1] = target end
  return out
end

--- The policy `config` asks for in `cwd`: nil and "" for mode off, or
--- nil and why where it cannot be made.
function Policy.of(cwd: string, config: Policy.Config): Sandbox.Policy?, string
  if MODES[config.mode] ~= true then return nil, "--sandbox is write, read or off" end
  if config.mode == "off" then return nil, "" end
  -- Each by its real name, which Seatbelt matches (macOS's /etc is /private/etc).
  local root, root_why = Fs.absolute(cwd)
  if root == nil then return nil, tostring(root_why) end
  -- The working directory is granted whole, so one that holds what is kept
  -- out would hand the tools every session kept and the commands' home.
  for _, kept in ipairs(config.kept_out or {}) do
    local real, _ = Fs.absolute(kept)
    local held = real or kept
    if held == root or held:sub(1, #root + 1) == root .. "/" or root == "/" then
      return nil, "the working directory " .. root .. " holds " .. held ..
        ", where the agent keeps its sessions or its MCP config; run it in a project's directory, or with --sandbox off"
    end
  end
  local letters = if config.mode == "write" then "rwxc" else "rx" end
  local grants: mut {Sandbox.Grant} = { { path = root, letters = letters } }
  -- A worktree reaches its repository as a plain checkout reaches its .git.
  for _, dir in ipairs(worktree_dirs(root)) do
    grants[#grants + 1] = { path = dir, letters = letters }
  end
  for _, path in ipairs(READS) do
    local real, _ = Fs.absolute(path)
    if real ~= nil then grants[#grants + 1] = { path = real, letters = "r" } end
  end
  for _, g in ipairs(config.grants) do
    for _, kept in ipairs(config.kept_out or {}) do
      local real, _ = Fs.absolute(kept)
      local held = real or kept
      if Fs.within(held, g.path) or Fs.within(g.path, held) then
        return nil, "--grant " .. g.path .. " reaches " .. held .. ", where the agent keeps its sessions or its MCP " ..
          "config, which no tool may change"
      end
    end
    grants[#grants + 1] = g
  end
  local guarded: mut {string} = { root }
  for _, dir in ipairs(program_dirs(config.path or "", config.user_home, guarded, config.kept_out or {})) do
    grants[#grants + 1] = { path = dir, letters = "rx" }
  end
  local cert: string? = nil
  local cert_file = config.cert_file
  -- One that is not there, or is not a file, is given as none: a stale variable does not refuse each run.
  local real_cert: string? = nil
  if (config.network or #(config.connect or {}) > 0) and cert_file ~= nil and cert_file ~= "" then
    local found, _ = Fs.absolute(cert_file)
    real_cert = found
  end
  if cert_file ~= nil and real_cert ~= nil then
    local status, _ = Fs.status(real_cert)
    local st = status and status.stat
    if st == nil or st.kind ~= "file" then real_cert = nil end
  end
  if cert_file ~= nil and real_cert ~= nil then
    for _, kept in ipairs(config.kept_out or {}) do
      local real_kept, _ = Fs.absolute(kept)
      if Fs.within(real_cert, real_kept or kept) then
        return nil, "SSL_CERT_FILE " .. cert_file .. " is where the agent keeps its sessions or its MCP config, " ..
          "which no tool may read"
      end
    end
    cert = real_cert
    grants[#grants + 1] = { path = real_cert, letters = "r" }
  end
  local home = config.home
  if home ~= nil then
    local made, made_why = Fs.mkdirs(home .. "/.cache", 0x1c0)
    if not made then return nil, "the sandbox's home: " .. tostring(made_why) end
    -- Refused where another user owns it; closed to others where it was open.
    local held, held_why = Fs.chmod(home, 0x1c0)
    if not held then return nil, "the sandbox's home: " .. tostring(held_why) end
    local real, real_why = Fs.absolute(home)
    if real == nil then return nil, "the sandbox's home: " .. tostring(real_why) end
    home = real
    grants[#grants + 1] = { path = real, letters = letters }
  end
  local linux = not darwin()
  -- The kernel counts a sandbox's processes from Linux 5.17 on.
  local release, _ = Fs.read("/proc/sys/kernel/osrelease")
  local counts = linux and release ~= nil and Sandbox.counts_per_namespace((release:gsub("%s+$", "")))
  -- calls nest: a command may hold what it runs to less (cosmic test does).
  -- It needs a root of its own, so Linux alone, and gives up Landlock:
  -- files are then held by that root alone.
  local calls: {Sandbox.Promise} = if linux then { "fork", "fattr", "jit", "nest" } else { "fork", "fattr", "jit" } end
  for _, promise in ipairs(calls) do grants[#grants + 1] = { calls = promise } end
  for _, target in ipairs(connect_of(config)) do grants[#grants + 1] = { connect = target } end
  for _, name in ipairs({ "system", "programs", "proc" }) do
    grants[#grants + 1] = { profile = name }
  end
  local passed: {string} = if config.path ~= nil then { "LANG", "LC_ALL", "TERM" } else { "PATH", "LANG", "LC_ALL", "TERM" } end
  for _, name in ipairs(passed) do grants[#grants + 1] = { env = name } end
  local own: Sandbox.Policy = {
    grants = grants,
    setup = { tmp = true, set_env = env_of(linux, home, if config.path ~= nil then real_path(config.path) else nil end, cert) },
    -- On Linux a root of its own: what it was not granted is not there,
    -- and it owns what it was, whoever runs the agent. macOS has no
    -- namespaces to give it one.
    isolate = if linux then { "file" } else nil end,
    limits = if counts then { processes = PROCESSES } else nil end,
  }
  local merged, why = Sandbox.union(own)
  if merged == nil then return nil, tostring(why) end
  return merged, ""
end

--- What the agent's own process is held to on Linux, around `tools`,
--- the policy its tools run under: a root of its own holding what the
--- tools and the MCP servers it starts are granted (a child is held to
--- what holds its parent too), what it keeps and reads, the calls they
--- may make, and nest, so it builds their roots; it reaches the API and
--- what they reach. `COSMIC_AGENT_HELD` is set, so it does not hold
--- itself again.
---
---     local tools = assert(Policy.of("/work", { mode = "write", network = false, grants = {} }))
---     local p = assert(Policy.session(tools, { keeps = {}, reads = {}, connect = { "api.anthropic.com:443" },
---       env = { "HOME" }, servers = {} }))
---     assert(Sandbox.permits(p, "/work/a.txt", "write"))
function Policy.session(tools: Sandbox.Policy, session: Policy.Session): Sandbox.Policy?, string
  local held: {Sandbox.Policy} = { tools, table.unpack(session.servers) }
  local grants: mut {Sandbox.Grant} = { { profile = "system" }, { profile = "proc" } }
  for _, policy in ipairs(held) do
    for _, g in ipairs(Sandbox.paths(policy)) do
      -- What a grant with `from` shows is the host's `from`, which the
      -- agent's root holds at its own name.
      grants[#grants + 1] = { path = g.from or g.path, letters = g.letters }
    end
    for _, promise in ipairs(Sandbox.calls(policy)) do grants[#grants + 1] = { calls = promise } end
    for _, target in ipairs(Sandbox.connects(policy)) do
      grants[#grants + 1] = { connect = target }
    end
    for _, profile in ipairs(Sandbox.profiles(policy)) do
      grants[#grants + 1] = { profile = profile }
    end
  end
  for _, dir in ipairs(session.keeps) do grants[#grants + 1] = { path = dir, letters = "rwc" } end
  for _, file in ipairs(session.reads) do grants[#grants + 1] = { path = file, letters = "r" } end
  for _, target in ipairs(session.connect) do grants[#grants + 1] = { connect = target } end
  grants[#grants + 1] = { calls = "fork" }
  grants[#grants + 1] = { calls = "nest" }
  for _, name in ipairs(session.env) do grants[#grants + 1] = { env = name } end
  local session_policy, why = Sandbox.union({ grants = grants, isolate = { "file" },
    setup = { tmp = true, set_env = { COSMIC_AGENT_HELD = "1" } } })
  if session_policy == nil then return nil, tostring(why) end
  return session_policy, ""
end

--- The bytes the files under `dir` hold, links not followed.
local function size_of(dir: string): integer
  local files, _ = Fs.walk(dir)
  local total = 0
  for _, f in ipairs(files or {}) do
    local st, _ = Fs.stat(dir .. "/" .. f)
    if st ~= nil then total = total + st.size end
  end
  return total
end

--- `n` bytes, as a person reads them.
local function bytes(n: integer): string
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  if n < 1024 * 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
  return string.format("%.1f GB", n / (1024 * 1024 * 1024))
end

--- What the merged policy `p` lets the tools reach, a line each, for
--- `cosmic agent policy`; `home` is the sandbox's kept home, shown with
--- what it holds.
function Policy.describe(p: Sandbox.Policy, home?: string): {string}
  local out: mut {string} = {}
  local setup = p.setup or {}
  local set = setup.set_env or {}
  local kept = set["HOME"]
  if home ~= nil and kept ~= nil then
    local real, _ = Fs.absolute(home)
    if real == kept then
      out[#out + 1] = string.format("home: %s, kept between sessions, %s (cosmic agent policy clear-home empties it)", kept,
        bytes(size_of(kept)))
    end
  end
  local connect = Sandbox.connects(p)
  out[#out + 1] = "network: " .. (if #connect > 0 then table.concat(connect, " ") else "none" end)
  out[#out + 1] = "grants (r reads, w writes, x runs, c creates and removes):"
  local grants: mut {Sandbox.Path} = {}
  for _, g in ipairs(Sandbox.paths(p)) do grants[#grants + 1] = g end
  table.sort(grants, function(a: Sandbox.Path, b: Sandbox.Path): boolean
    return a.path < b.path
  end)
  for _, g in ipairs(grants) do out[#out + 1] = string.format("  %-5s %s", g.letters, g.path) end
  local profiles = Sandbox.profiles(p)
  if #profiles > 0 then out[#out + 1] = "profiles: " .. table.concat(profiles, " ") end
  if setup.tmp == true then
    out[#out + 1] = "tmp: a fresh /tmp for each command, removed after it"
  end
  out[#out + 1] = "calls: " .. table.concat(Sandbox.calls(p), " ")
  out[#out + 1] = "isolate: " .. (if p.isolate ~= nil then table.concat(p.isolate, " ") else "none" end)
  local limits = p.limits
  if limits ~= nil and limits.processes ~= nil then
    out[#out + 1] = "processes: at most " .. tostring(limits.processes)
  end
  out[#out + 1] = "env passed on: " .. table.concat(Sandbox.env(p), " ")
  local names: mut {string} = {}
  for k, _ in pairs(set) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do out[#out + 1] = string.format("env set: %s=%s", k, set[k]) end
  return out
end

return Policy
