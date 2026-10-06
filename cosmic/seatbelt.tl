--- The pure part of macOS policy enforcement: a [`Sandbox.Policy`] as
--- default-deny SBPL and a separate table of path parameters. Compiling
--- does not restrict a process. The caller resolves paths and their kinds
--- before compiling, then applies the profile and its rlimits before exec.

local Sandbox = require("cosmic.sandbox")

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
  end
end

--- Paths a macOS "system" program needs. Unlike the Linux profile this
--- includes the system frameworks and dyld's cryptexes; no Mach service
--- or network permission follows merely from reading system libraries.
local SYSTEM <const>: {{string}} = {
  { "/usr", "rx" }, { "/bin", "rx" }, { "/sbin", "rx" },
  { "/System/Library", "rx" }, { "/Library/Apple/System/Library", "rx" },
  { "/System/Cryptexes/App", "rx" }, { "/System/Cryptexes/OS", "rx" },
  { "/System/Volumes/Preboot/Cryptexes/App/System", "rx" },
  { "/System/Volumes/Preboot/Cryptexes/OS", "rx" },
  { "/etc/passwd", "r" }, { "/etc/group", "r" }, { "/etc/localtime", "r" },
  { "/private/var/db/timezone", "r" },
  { "/dev/null", "rw" }, { "/dev/zero", "r" },
  { "/dev/random", "r" }, { "/dev/urandom", "r" },
}

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
local function unsupported(policy: Sandbox.Policy): string
  if #(policy.isolate or {}) > 0 then return "isolate needs namespaces, which macOS has none of" end
  if #(policy.connect or {}) > 0 then return "connect needs the network relay" end
  if #(policy.loopback or {}) > 0 then return "loopback needs a network namespace of its own" end
  for _, promise in ipairs(policy.promises or {}) do
    if promise == "nest" then return "promises nest cannot be held by Seatbelt" end
  end
  for _, grant in ipairs(policy.grants or {}) do
    if grant.from ~= nil then return "grant from needs isolate file" end
  end
  if policy.limits ~= nil and policy.limits.processes ~= nil then
    return "limits.processes needs a user namespace of its own"
  end
  -- TODO: take the prepared temporary directory and sealed database
  -- grants once Child.start applies Seatbelt before exec.
  if policy.tmp then return "tmp needs a prepared temporary directory" end
  if policy.database ~= nil then return "database needs a prepared core and database" end
  for name in pairs(policy.set_env_digests or {}) do
    if policy.set_env == nil or policy.set_env[name] == nil then
      return "set_env_digests holds a digest, not a value to set"
    end
  end
  return ""
end

--- Produces a default-deny profile without reading the host. `options`
--- carries canonical host paths and directory kinds obtained by the
--- enforcement caller. A file uses `literal`, a directory `subpath`.
--- Every path value is a parameter, including profile and socket paths;
--- none is interpolated into SBPL. The "system" profile is macOS's even
--- when compiling on another host; "cosmic" names `options.executable`.
--- Nil and why for an invalid policy, missing path or unsupported field.
---
--- The returned rlimits must be applied separately. This is preparation
--- only: Child.start and Sandbox.restrict still refuse macOS enforcement.
-- TODO: apply through one C function wrapping sandbox_init_with_parameters
-- once the macOS enforcement binding lands. Keep sandbox-exec fallback
-- there: the private API supports both restrict and spawn, without another
-- executable or profile text in argv; never retry a policy refusal.
function Seatbelt.compile(policy: Sandbox.Policy, options?: Seatbelt.Options): Seatbelt.Profile | nil, string
  -- Sandbox.check verifies a database by reading it; this pure compiler
  -- refuses one before that call, until the child hands it prepared grants.
  if policy.database ~= nil then return refuse("database needs a prepared core and database") end
  local valid, why = Sandbox.check(policy)
  if not valid then return nil, why end
  local trouble = unsupported(policy)
  if trouble ~= "" then return refuse(trouble) end
  local grants: {Sandbox.Grant} = {}
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
      for _, entry in ipairs(SYSTEM) do
        if paths[entry[1]] ~= nil then
          trouble = add(entry[1], entry[2])
          if trouble ~= "" then return refuse(trouble) end
        end
      end
    elseif name == "cosmic" then
      local executable = options and options.executable
      if executable == nil then
        return refuse("profile cosmic needs this program's executable")
      end
      trouble = add(executable, "rx")
      if trouble ~= "" then return refuse(trouble) end
    end
  end
  for _, grant in ipairs(policy.grants or {}) do
    trouble = add(grant.path, grant.letters)
    if trouble ~= "" then return refuse(trouble) end
  end
  local merged, failure = Sandbox.merge({ grants = grants, promises = policy.promises,
    limits = policy.limits, env = policy.env, set_env = policy.set_env,
    set_env_digests = policy.set_env_digests, user = policy.user, group = policy.group })
  if merged == nil then return nil, failure end
  local fattr = false
  local text: {string} = { "(version 1)", "(deny default)",
    "(allow signal (target self))", "(allow process-info-pidinfo (target self))" }
  for _, promise in ipairs(merged.promises) do
    if promise == "fork" then text[#text + 1] = "(allow process-fork)" end
    if promise == "jit" then text[#text + 1] = "(allow dynamic-code-generation)" end
    if promise == "fattr" then fattr = true end
  end
  local parameters: {string:string} = {}
  for i, grant in ipairs(merged.grants) do
    local name = "PATH_" .. i
    parameters[name] = grant.path
    local at = '(' .. (directories[grant.path] and "subpath" or "literal") .. ' (param "' .. name .. '"))'
    if grant.letters:find("r", 1, true) then text[#text + 1] = "(allow file-read* " .. at .. ")" end
    if grant.letters:find("w", 1, true) then
      text[#text + 1] = "(allow file-write-data " .. at .. ")"
    end
    if grant.letters:find("x", 1, true) then
      text[#text + 1] = "(allow process-exec file-map-executable " .. at .. ")"
    end
    if grant.letters:find("c", 1, true) then
      text[#text + 1] = "(allow file-write-create file-write-unlink " .. at .. ")"
    end
    if grant.letters:find("u", 1, true) then
      text[#text + 1] = "(allow network-outbound " .. at .. ")"
    end
    if fattr and (grant.letters:find("w", 1, true) or grant.letters:find("c", 1, true)) then
      text[#text + 1] = "(allow file-write-mode file-write-owner file-write-times " ..
        "file-write-flags file-write-xattr " .. at .. ")"
    end
  end
  local rlimits: {string:integer} = { nofile = merged.limits.open_files or 1024, core = 0 }
  rlimits.fsize, rlimits.cpu = merged.limits.file_bytes, merged.limits.cpu_seconds
  return { text = table.concat(text, "\n") .. "\n", parameters = parameters, rlimits = rlimits }, ""
end

return Seatbelt
