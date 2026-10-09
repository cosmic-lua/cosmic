--- macOS policy enforcement's profile: a [`Sandbox.Policy`] as
--- default-deny SBPL and a separate table of path parameters. Compiling
--- does not restrict a process, nor read the host: [`Seatbelt.resolve`]
--- reads the paths and their kinds, and the caller applies the profile and
--- its rlimits: [`Child.start`] before exec, through a process of this
--- program that executes the child's program last, and
--- [`Sandbox.restrict`] to the running process.

local rules = require("cosmic.sandbox.policy")
local sys = require("cosmic.sys")

local record Seatbelt
  --- A grant's resolved host path. The caller obtains both fields from
  --- the filesystem, never from an untrusted program's classification.
  record Path
    --- An absolute, canonical path obtained from the host filesystem.
    path: string
    --- Whether the resolved object is a directory: only one receives a
    --- recursive subpath rule; every other kind receives a literal rule.
    directory: boolean
  end

  --- Host facts supplied to the pure compiler. `paths` is keyed by the
  --- policy's grant paths, before normalization. Missing system-profile
  --- paths do not exist on this host; every explicit grant needs an entry.
  record Options
    --- Each requested path's resolved host path and directory kind.
    paths: {string:Path}
    --- The name of this program for the "cosmic" profile, with its
    --- resolved path and kind in `paths` like an explicit grant.
    executable: string
    --- The name of the core a start of this program runs (past the
    --- launcher, which unpacks a core into a cache no profile grants), in
    --- `paths` like an explicit grant: granted `rx`. Required with the
    --- policy's `database`.
    core: string
    --- The name of the database that core runs on (`core --database <path>`),
    --- in `paths` like an explicit grant: granted `r`, and no more, since
    --- the core opens it read-only and immutable, which takes no lock, no
    --- `-wal` and no `-shm`. Required with the policy's `database`, which it
    --- names (resolved).
    database: string
    --- The resolved path of the pty slave that is the child's controlling
    --- terminal, or nil for none. With it the profile grants the slave and
    --- `/dev/tty`, and `/dev` to list, which no other profile does.
    terminal: string
    --- The port the network relay that serves the policy's `connect`
    --- listens at on the host's loopback ([`Child.start`]), which the
    --- profile lets the program connect to over TCP and nothing else of the
    --- network: Seatbelt names a host only as `localhost` or `*`, so the rule
    --- is `localhost:PORT`, which holds 127.0.0.1 and ::1 alike (the relay
    --- holds the port on both) and lets it bind and listen nowhere. Required with `connect`; a policy without
    --- `connect` is refused one.
    relay_port: integer
    --- The port of the host's loopback the network relay accepts at, for
    --- the relay's own profile; nil for any other. The relay may connect to
    --- any address and port (Seatbelt cannot name one by number, so the
    --- relay's own checks of the grants decide where it connects),
    --- accept at that port of the loopback and bind
    --- nothing (its starter binds its listeners and hands them over), look up
    --- the system's DNS configuration, the one Mach service the resolver
    --- reaches, and run no program but `core`: the rest of what it is granted
    --- `x` it may map as a library and not run. Only the start of the relay
    --- sets it.
    serves_relay: integer
  end

  --- Text to pass to sandbox_init_with_parameters, values kept outside
  --- the text, and limits the caller must apply separately.
  record Profile
    --- SBPL containing generated parameter names and no path values.
    text: string
    --- Opaque path values, passed separately to the Seatbelt API.
    parameters: {string:string}
    --- rlimit names and values to apply before exec or restriction.
    rlimits: {string:integer}
    --- The name of the parameter of the policy's `tmp` directory, `rwc`,
    --- which the caller sets, to the directory's real path, once it has made
    --- it and before it applies the profile; nil without `tmp`. Not in
    --- `parameters`.
    tmp: string
  end
end

--- The parameter a policy's `tmp` directory is granted through: the start
--- makes the directory, so its path is known only after the profile.
local TMP_PARAMETER <const> = "TMP"

local function refuse(why: string): nil, string
  return nil, "seatbelt: " .. why
end

--- An absolute, normalized path, not SBPL text. Quotes, parentheses and
--- newlines are safe in parameters; a NUL cannot cross the C API.
local function absolute(path: string): boolean
  if path:sub(1, 1) ~= "/" or path:find("\0", 1, true) then return false end
  if path ~= "/" and (path:sub(-1) == "/" or path:find("//", 1, true)) then return false end
  for part in path:gmatch("[^/]+") do
    if part == "." or part == ".." then return false end
  end
  return true
end

--- Unsupported policy fields are refused, rather than being silently
--- lost in a profile. Environment and credentials are a child's setup,
--- not Seatbelt operations; their handling remains the caller's.
local function unsupported(policy: rules.Policy): string
  if #(policy.isolate or {}) > 0 then return "isolate needs namespaces, which macOS has none of" end
  if #(policy.loopback or {}) > 0 then return "loopback needs a network namespace of its own" end
  -- A promise the profile has no rule for would be dropped from it, not
  -- held: each is named here or refused.
  for _, promise in ipairs(policy.promises or {}) do
    if promise ~= "fork" and promise ~= "jit" and promise ~= "fattr" then
      return "promises " .. tostring(promise) .. " cannot be held by Seatbelt"
    end
  end
  for _, grant in ipairs(policy.grants or {}) do
    if grant.from ~= nil then return "grant from needs isolate file" end
  end
  if policy.limits ~= nil and policy.limits.processes ~= nil then
    return "limits.processes needs a user namespace of its own"
  end
  for name in pairs(policy.set_env_digests or {}) do
    if policy.set_env == nil or policy.set_env[name] == nil then
      return "set_env_digests holds a digest, not a value to set"
    end
  end
  return ""
end

--- Appends to `text` the rules `letters` give at `at`, an SBPL path filter;
--- `fattr` adds the attribute writes a `w` or `c` then allows, and `map_only`
--- makes an `x` a library's mapping alone, never a program's run.
local function allow(text: {string}, fattr: boolean, letters: string, at: string, map_only?: boolean)
  if letters:find("r", 1, true) then text[#text + 1] = "(allow file-read* " .. at .. ")" end
  if letters:find("w", 1, true) then
    text[#text + 1] = "(allow file-write-data " .. at .. ")"
  end
  if letters:find("x", 1, true) then
    text[#text + 1] = (map_only and "(allow file-map-executable " or "(allow process-exec file-map-executable ") ..
      at .. ")"
  end
  if letters:find("c", 1, true) then
    text[#text + 1] = "(allow file-write-create file-write-unlink " .. at .. ")"
  end
  if letters:find("u", 1, true) then
    text[#text + 1] = "(allow network-outbound " .. at .. ")"
  end
  if fattr and (letters:find("w", 1, true) or letters:find("c", 1, true)) then
    text[#text + 1] = "(allow file-write-mode file-write-owner file-write-times " ..
      "file-write-flags file-write-xattr " .. at .. ")"
  end
end

--- Produces a default-deny profile without reading the host. `options`
--- carries canonical host paths and directory kinds obtained by the
--- enforcement caller. A file uses `literal`, a directory `subpath`.
--- Every path value is a parameter, including profile and socket paths;
--- none is interpolated into SBPL. The "system" profile is macOS's even
--- when compiling on another host; "cosmic" names `options.executable`,
--- unless the policy has a `database`: the program is then that core and
--- file alone, `options.core` (`rx`) and `options.database` (`r`), which the
--- policy's own `database` must be. A policy's `tmp` is granted `rwc` through
--- the parameter [`Seatbelt.Profile`]'s `tmp` names, which the caller sets.
--- A policy's `connect` is reached through the network relay alone, at
--- [`Seatbelt.Options.relay_port`] of the host's loopback.
--- Nil and why for an invalid policy, missing path or unsupported field.
---
--- The returned rlimits must be applied separately. This is preparation
--- only: on macOS [`Child.start`] applies the profile and the limits in a
--- process of this program that executes the child's program last, and
--- [`Sandbox.restrict`] in the process that calls it.
function Seatbelt.compile(policy: rules.Policy, options?: Seatbelt.Options): Seatbelt.Profile | nil, string
  local valid, why = rules.check(policy)
  if not valid then return nil, why end
  local trouble = unsupported(policy)
  if trouble ~= "" then return refuse(trouble) end
  local relay_port = options and options.relay_port
  if #(policy.connect or {}) > 0 then
    if math.type(relay_port) ~= "integer" or relay_port < 1 or relay_port > 65535 then
      return refuse("connect needs the port of the network relay that serves it")
    end
  elseif relay_port ~= nil then
    return refuse("a relay's port is given to a policy with no connect")
  end
  local grants: {rules.Grant} = {}
  local directories: {string:boolean} = {}
  local paths = options and options.paths or {}
  local function add(path: string, letters: string): string
    local held = paths[path]
    if held == nil then
      return "grant " .. string.format("%q", path) .. " has no resolved host path"
    end
    if not absolute(held.path) or type(held.directory) ~= "boolean" then
      return "grant " .. string.format("%q", path) .. " needs an absolute canonical host path and its kind"
    end
    local previous = directories[held.path]
    if previous ~= nil and previous ~= held.directory then
      return "one host path has two directory kinds"
    end
    directories[held.path] = held.directory
    grants[#grants + 1] = { path = held.path, letters = letters }
    return ""
  end
  for _, name in ipairs(policy.profiles or {}) do
    if name == "system" then
      for _, entry in ipairs(rules.system_paths("darwin")) do
        if paths[entry[1]] ~= nil then
          trouble = add(entry[1], entry[2])
          if trouble ~= "" then return refuse(trouble) end
        end
      end
    elseif name == "cosmic" and policy.database == nil then
      local executable = options and options.executable
      if executable == nil then
        return refuse("profile cosmic needs this program's executable")
      end
      trouble = add(executable, "rx")
      if trouble ~= "" then return refuse(trouble) end
    end
  end
  -- A policy's own `database` is the file its core runs on, which a start
  -- of this program names itself, so the two must be one file.
  if policy.database ~= nil then
    if options == nil or options.core == nil or options.database == nil then
      return refuse("database needs the core to run and the database it runs on")
    end
    local named, held = options.paths[policy.database.path], options.paths[options.database]
    if named == nil or held == nil or named.path ~= held.path then
      return refuse("database " .. string.format("%q", policy.database.path) ..
          " is not the database the core is run on, " .. string.format("%q", options.database))
    end
  end
  if options ~= nil and options.core ~= nil then
    trouble = add(options.core, "rx")
    if trouble ~= "" then return refuse(trouble) end
  end
  if options ~= nil and options.database ~= nil then
    trouble = add(options.database, "r")
    if trouble ~= "" then return refuse(trouble) end
  end
  for _, grant in ipairs(policy.grants or {}) do
    trouble = add(grant.path, grant.letters)
    if trouble ~= "" then return refuse(trouble) end
  end
  local merged, failure = rules.merge({ grants = grants, promises = policy.promises,
    limits = policy.limits, env = policy.env, set_env = policy.set_env,
    set_env_digests = policy.set_env_digests, user = policy.user, group = policy.group })
  if merged == nil then return nil, failure end
  local fattr = false
  -- What every program needs to start, whatever it is granted. Contents
  -- and writes stay denied; only these answers are given:
  --   file-read-metadata: stat of any path. dyld and libc stat each
  --     component of every path they open, from the root down, so a
  --     grant's own path is not enough to reach it. It shows that a path
  --     exists and its size, mode and times, never what it holds.
  --   file-read-data of the root alone: dyld reads "/" itself as a
  --     directory as it starts, and an abort follows a refusal. It lists
  --     the root's entries, and nothing below it.
  --   sysctl-read: the kernel's facts (hw.*, kern.osversion, ...) libSystem
  --     reads as it starts, which hold nothing of the user's.
  local text: {string} = { "(version 1)", "(deny default)",
    "(allow file-read-metadata)", '(allow file-read-data (literal (param "ROOT")))',
    "(allow sysctl-read)",
    "(allow signal (target self))", "(allow process-info-pidinfo (target self))" }
  for _, promise in ipairs(merged.promises) do
    if promise == "fork" then text[#text + 1] = "(allow process-fork)" end
    if promise == "jit" then text[#text + 1] = "(allow dynamic-code-generation)" end
    if promise == "fattr" then fattr = true end
  end
  local parameters: {string:string} = { ROOT = "/" }
  local serves = options and options.serves_relay
  -- The relay runs its core alone, which the start executes under the profile.
  local runs: string
  if serves ~= nil and options.core ~= nil then runs = paths[options.core].path end
  for i, grant in ipairs(merged.grants) do
    local name = "PATH_" .. i
    parameters[name] = grant.path
    allow(text, fattr, grant.letters, '(' .. (directories[grant.path] and "subpath" or "literal") ..
        ' (param "' .. name .. '"))', serves ~= nil and grant.path ~= runs)
  end
  local tmp: string
  if policy.tmp then
    tmp = TMP_PARAMETER
    allow(text, fattr, "rwc", '(subpath (param "' .. tmp .. '"))')
  end
  local terminal = options and options.terminal
  if terminal ~= nil then
    if not absolute(terminal) then return refuse("terminal needs an absolute canonical path") end
    -- Data and ioctl alone: file-write* would let a child without `fattr`
    -- chmod its slave for other users to read, or unlink /dev/tty as root.
    -- The slave answers tcgetsid and tcgetpgrp only where granted by its
    -- path, /dev/tty opens only where granted as that literal, and ttyname
    -- and tty list /dev.
    parameters.TTY = terminal
    text[#text + 1] = '(allow file-read-data file-write-data file-ioctl (literal (param "TTY")))'
    text[#text + 1] = '(allow file-read-data file-write-data file-ioctl (literal "/dev/tty"))'
    text[#text + 1] = '(allow file-read-data (literal "/dev"))'
  end
  if relay_port ~= nil then
    -- `localhost` is ::1 at the port as well: the start holds the port
    -- there too ([`cosmic.internal.relay_start`]'s `loopback_listeners`).
    text[#text + 1] = '(allow network-outbound (remote tcp "localhost:' .. relay_port .. '"))'
  end
  if serves ~= nil then
    if math.type(serves) ~= "integer" or serves < 1 or serves > 65535 then
      return refuse("serves_relay needs the port the relay accepts at")
    end
    -- What the relay connects to is any host its grants open, which a
    -- profile cannot name; it accepts at its own port of the loopback; and
    -- c-ares reads the system's name servers from configd's DNS
    -- configuration, through this one service.
    text[#text + 1] = '(allow network-outbound (remote ip "*:*"))'
    text[#text + 1] = '(allow network-inbound (local tcp "localhost:' .. serves .. '"))'
    text[#text + 1] = '(allow mach-lookup (global-name "com.apple.SystemConfiguration.DNSConfiguration"))'
  end
  local rlimits: {string:integer} = { nofile = merged.limits.open_files or 1024, core = 0 }
  rlimits.fsize, rlimits.cpu = merged.limits.file_bytes, merged.limits.cpu_seconds
  return { text = table.concat(text, "\n") .. "\n", parameters = parameters, rlimits = rlimits,
    tmp = tmp }, ""
end

--- Why a program of `merged` cannot start as the policy says where nothing
--- changes its credentials, as on macOS (Seatbelt holds a program but
--- changes no user or group): "" where it can, run as the caller, whose
--- effective `user` and `group` are given. The policy's `user` and `group`
--- must be those or left out, and the caller must not be root, whose program
--- a policy says is never root. Names only what differs.
function Seatbelt.credentials_unmet(merged: rules.Policy, user: integer, group: integer): string
  if user == 0 then
    return "this process is root, and a program of a policy never runs as root, which " ..
      "Seatbelt cannot change the user to: start as another user"
  end
  local differs: {string} = {}
  if merged.user ~= nil and merged.user ~= user then
    differs[#differs + 1] = "user " .. merged.user
  end
  if merged.group ~= nil and merged.group ~= group then
    differs[#differs + 1] = "group " .. merged.group
  end
  if #differs == 0 then return "" end
  return table.concat(differs, ", ") .. ": Seatbelt runs a program as this process's own user and " ..
    "group, " .. user .. " and " .. group .. ", and cannot change them: name those or none"
end

--- The grants `policy` gives on macOS before the host is read: its own
--- and, for the "system" profile, [`Seatbelt.compile`]'s list of macOS's
--- paths (not Linux's, which [`Sandbox.merge`] gives), each whether or not
--- this host has it. For a check of which paths a policy reaches.
function Seatbelt.grants(policy: rules.Policy): {rules.Grant}
  local out: {rules.Grant} = {}
  for _, name in ipairs(policy.profiles or {}) do
    if name == "system" then
      for _, entry in ipairs(rules.system_paths("darwin")) do
        out[#out + 1] = { path = entry[1], letters = entry[2] }
      end
    end
  end
  for _, grant in ipairs(policy.grants or {}) do out[#out + 1] = grant end
  return out
end

--- What [`Seatbelt.compile`] needs of the host for `policy`: each grant's
--- real path and kind, keyed as the policy gives the path, and, for the
--- "system" profile, each path of it this host has. A relative grant is
--- from `base`, where given. `executable` is this program's own path, for
--- the "cosmic" profile, resolved like a grant; `core` and `database` are
--- the file a start of this program runs and the one it runs on, likewise.
--- `terminal` is the pty slave's path, resolved through links for
--- [`Seatbelt.Options.terminal`]. Nil and why where a grant's path is not there.
function Seatbelt.resolve(policy: rules.Policy, base?: string, executable?: string,
                          core?: string, database?: string, terminal?: string): Seatbelt.Options | nil, string
  local paths: {string:Seatbelt.Path} = {}
  -- "" where `at` was resolved, or why not.
  local function look(name: string, at: string): string
    local real, trouble = sys.realpath(at)
    if real == nil then return trouble end
    local found, why = sys.stat(real)
    if found == nil then return why end
    paths[name] = { path = real, directory = found.kind == "dir" }
    return ""
  end
  for _, name in ipairs(policy.profiles or {}) do
    if name == "system" then
      -- A path this host lacks is one its system has none of.
      for _, entry in ipairs(rules.system_paths("darwin")) do
        local _ = look(entry[1], entry[1])
      end
    end
  end
  for _, grant in ipairs(policy.grants or {}) do
    local at = grant.path
    if base ~= nil and at:sub(1, 1) ~= "/" then at = base .. "/" .. at end
    local trouble = look(grant.path, at)
    if trouble ~= "" then
      return refuse("grant " .. string.format("%q", grant.path) .. ": " .. trouble)
    end
  end
  if executable ~= nil then
    local trouble = look(executable, executable)
    if trouble ~= "" then
      return refuse("executable " .. string.format("%q", executable) .. ": " .. trouble)
    end
  end
  for _, name in ipairs({ core or "", database or "", policy.database and policy.database.path or "" }) do
    if name ~= "" then
      local trouble = look(name, name)
      if trouble ~= "" then return refuse(string.format("%q", name) .. ": " .. trouble) end
    end
  end
  local real_terminal: string
  if terminal ~= nil then
    local real, trouble = sys.realpath(terminal)
    if real == nil then
      return refuse("terminal " .. string.format("%q", terminal) .. ": " .. trouble)
    end
    real_terminal = real
  end
  return { paths = paths, executable = executable, core = core, database = database,
    terminal = real_terminal }, ""
end

return Seatbelt
