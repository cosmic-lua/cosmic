--- The policy layer cosmic.sandbox and cosmic.sandbox.seatbelt share: the types
--- of a policy, the check of its values, the profiles it names and the
--- merge of policies into one. Use [`cosmic.sandbox`], which answers all of
--- it under its own name and documents it there. Apart from cosmic.sandbox
--- only so that cosmic.sandbox.seatbelt, which cosmic.sandbox requires, can require
--- this.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local Relay = require("cosmic.relay")
local sys = require("cosmic.sys")

-- Taken at load: a test that replaces a member of the library table does not
-- change what a profile holds.
local uname <const> = sys.uname
local stat <const> = sys.stat

local record rules
  --- How far a program is isolated from the host: `file` gives it a root
  --- of its own holding only what is granted, `proc` a process space and a
  --- /proc of its own.
  enum Isolate
    "file"
    "proc"
  end

  --- A part of what a program may do beyond its basics (memory, time,
  --- threads, the descriptors it was handed, the files its grants allow,
  --- running programs): `fork` starts processes, `jit` maps executable
  --- memory that is no file's, `fattr` changes a file's mode, times,
  --- owner and attributes, `nest` builds a sandbox of its own.
  enum Promise
    "fork"
    "jit"
    "fattr"
    "nest"
  end

  --- One path a program may reach, and how.
  record Grant
    --- The path as the program sees it, relative to the directory it
    --- runs in. It must exist when the program starts.
    path: string
    --- What the program may do there, letters of "rwxcu" in that order: `r`
    --- reads files and lists directories, `w` writes and truncates files,
    --- `x` runs files, `c` creates and removes, `u` connects to the unix
    --- socket at the path (Landlock ABI 9; below it only under `isolate`
    --- file, and only where no grant is a directory or a socket not granted
    --- `u`, since nothing else tells the granted socket from the root's
    --- others). A
    --- grant on a directory reaches what is beneath it.
    letters: string
    --- The host's path, when it differs from `path`: the program sees this
    --- file or directory under another name. Needs `isolate` file.
    from: string
  end

  --- Resource limits on every process the program starts. Nil is the
  --- start's default: 1024 open files, no core dump, and under `isolate`
  --- 4096 processes where the kernel counts them per user namespace;
  --- nothing else.
  record Limits
    --- The most descriptors a process may hold open (at least 1).
    open_files: integer
    --- The most bytes a process may write to one file.
    file_bytes: integer
    --- The CPU seconds a process may spend (at least 1). Soft and hard
    --- limit are the same, so a process past it is ended by SIGKILL, with
    --- no SIGXCPU to catch first.
    cpu_seconds: integer
    --- The most processes and threads of the whole sandbox, counted by
    --- the user namespace it runs in (at least 1): a child's, with
    --- `isolate` "proc" or "file", on a Linux kernel from 5.17.
    processes: integer
  end

  --- What a program is held to; every field is optional, and what a policy
  --- leaves out it does not have.
  record Policy
    --- Named policies to join in, by [`Sandbox.merge`]: "system", "cosmic".
    profiles: {string}
    --- The paths the program reaches.
    grants: {Grant}
    --- How far it is isolated from the host. With "file", a writable grant on a tree that user does not own (`/etc`
    --- as `rwc`, say) is mounted so that it is the tree's owner there: it
    --- writes the owner's files, root's included, through that mount.
    isolate: {Isolate}
    --- The system calls it may make beyond its basics.
    promises: {Promise}
    --- The hosts it may reach, "host:port", where the host or the port is
    --- "*" for any. A host is a DNS name, an IPv4 address or an IPv6 address
    --- in brackets, and a name is read lower-case without a final dot; a
    --- pattern, an underscore and anything else the relay's readers refuse
    --- is refused here too ([`cosmic.relay.grant`]).
    connect: {string}
    --- The addresses of 127/8 it uses inside its own network.
    loopback: {string}
    --- The variables passed through from the caller's environment.
    env: {string}
    --- The variables set, by name. With `env`, the program's whole
    --- environment; a name in both is set.
    set_env: {string:string}
    --- What a decoded, encoded policy holds in place of `set_env`'s
    --- values: for each name, the SHA-256 of its value in lowercase
    --- hex. [`PolicyJson.encode`] writes these, so the text shows a value
    --- changed without showing it; a policy that holds one, and no value
    --- for the name, cannot start a program.
    set_env_digests: {string:string}
    --- Whether the program has a fresh temporary directory of its own,
    --- named by `TMPDIR`, that it may write. Under `isolate` file it is
    --- the root's own /tmp, which a grant of "/tmp" with no `from` and the
    --- letters `rwxc` lets the program run files from (`rwc`, the default,
    --- does not), and a `set_env` TMPDIR beneath /tmp is kept, for a
    --- directory the program makes there.
    tmp: boolean
    --- The resources it may spend.
    limits: Limits
    --- The user a child runs as (1 to 4294967294, never root, nor the
    --- overflow ids 65534 and 65535), in place of the one of its own a root
    --- caller's child is given from a pool ([`Sandbox.user_id`]): the same
    --- one every start, which may own the files it works on, and which
    --- may not be one of that pool's. Only a root caller chooses one; any
    --- other may name only itself, which changes nothing. On macOS no caller
    --- chooses one, since Seatbelt changes no credentials: a user other
    --- than the caller's is refused, and so is a root caller.
    ---
    --- A user named so is shared with whatever else runs as it on the
    --- host, which a pool's user never is: every process of that user,
    --- sandboxed or not, may read the child's environment (`set_env`'s
    --- values among it) and reopen its descriptors through /proc, ptrace
    --- it where the host's Yama allows, and use the directory `tmp` makes.
    --- Name a user nothing else runs as where the child holds a secret.
    ---
    --- Under `isolate` "file", a grant it cannot use but as the grant's
    --- owner is mounted so the owner's files are its own; its own files
    --- beneath, if any, then show as the owner's, reached as their mode
    --- lets everyone (and the group too where their group is the grant
    --- owner's), and stay its own on the host. Any other user's there
    --- show as owned by the overflow id: read and run as their mode lets
    --- everyone (or its group, where theirs is the owner's), never written.
    user: integer
    --- The group a child runs as, with `user`: for a root caller, `user`'s
    --- own number where it is left out; for any other, its own group. On
    --- macOS only the caller's own group is met, as for `user`.
    group: integer
    --- A database the program runs on, by its absolute path: the program
    --- is this program's core started on that database
    --- (`core --database <path>`), so what it can `require` is the
    --- modules the file holds and nothing of the tree or of this
    --- program's own file. A file [`Store.seal`] wrote, whose `main` names what runs. It
    --- is a regular file with no ".." in its path, which
    --- [`Sandbox.check`] refuses otherwise. [`Child.start`] runs
    --- only this program so, where it is a cosmic core (a host program has none), grants the
    --- file read-only and the core, and refuses a grant that reaches this
    --- program's own file, which holds modules the database leaves out.
    --- [`Sandbox.restrict`] refuses it: a running process cannot change
    --- its program. The "cosmic" profile adds nothing beside it, since its
    --- grant is of that program's file; two different databases do not
    --- merge. The "system" profile cannot be joined with it where this
    --- program is installed under a directory the profile grants (/usr):
    --- the grant reaches the program's own file, and the start fails, naming
    --- it. [`PolicyJson.encode`] writes it with the SHA-256 of the
    --- file, so the text holds what the database is and not only where.
    database: string
  end
end

--- What a failure of this module answers: nil and `why` under the name
--- "sandbox", as [`cosmic.sandbox`]'s own failures are.
local function refuse(why: string): nil, string
  return nil, "sandbox: " .. why
end

local LETTERS <const> = "rwxcu"

--- `letters` as a set in the order of "rwxcu", each letter once; nil for
--- none or a letter outside it.
local function canonical_letters(letters: string): string | nil
  local seen: {string:boolean} = {}
  for i = 1, #letters do
    local letter = letters:sub(i, i)
    if not LETTERS:find(letter, 1, true) then return nil end
    seen[letter] = true
  end
  local out: {string} = {}
  for i = 1, #LETTERS do
    local letter = LETTERS:sub(i, i)
    if seen[letter] then out[#out + 1] = letter end
  end
  if #out == 0 then return nil end
  return table.concat(out)
end

--- Whether `name` can be an environment variable's name.
local function env_name_ok(name: string): boolean
  return name ~= "" and not name:find("=", 1, true) and not name:find("\0", 1, true)
end

--- Whether `address` is of 127/8 as four decimal numbers, none with a
--- leading zero.
local function loopback_ok(address: string): boolean
  local a, b, c = address:match("^127%.(%d+)%.(%d+)%.(%d+)$")
  if a == nil then return false end
  for _, part in ipairs({ a, b, c }) do
    if #part > 1 and part:sub(1, 1) == "0" then return false end
    if tonumber(part) > 255 then return false end
  end
  return true
end

local PROFILES <const>: {string} = { "cosmic", "system" }

local function listed(name: string, names: {string}): boolean
  for _, known in ipairs(names) do
    if known == name then return true end
  end
  return false
end

--- Why the limit `name`, nil for none, is below `least`, or "".
local function below(name: string, value: integer, least: integer): string
  if value == nil or value >= least then return "" end
  return "pointer \"/limits/" .. name .. "\": a limit is at least " .. least
end

--- The first thing wrong in a policy's values, as `pointer "/grants/0/letters":
--- why`, or "" when none is: the field's types are Teal's, and these are the
--- values a type does not hold. With `exact`, a grant's letters must be
--- already in the order of "rwxcu", each once, as [`Sandbox.check`] with
--- `exact` takes them.
--- Why `loopback` and `connect` may not be held together, or "": a
--- `loopback` address is the program's own network, which `NO_PROXY` keeps
--- direct, while a `connect` target of it names the host's service, which
--- the program reaches through the relay. `NO_PROXY` is by host, so the
--- port does not tell them apart. Names the `loopback` entry's pointer.
local function loopback_conflict(loopback: {string}, connect: {string}): string
  for i, address in ipairs(loopback) do
    local target = Relay.Config.naming(connect, address)
    if target ~= "" then
      return "pointer \"/loopback/" .. (i - 1) .. "\": \"" .. address .. "\" is also the host address that " ..
        "connect \"" .. target .. "\" names, and a proxy client cannot tell the two apart by port: " ..
        "give the sandbox's own services another 127.x address (127.0.0.2, say)"
    end
  end
  return ""
end

local function invalid(p: rules.Policy, exact: boolean): string
  local function at(pointer: string, why: string): string
    return "pointer \"" .. pointer .. "\": " .. why
  end
  for i, name in ipairs(p.profiles or {}) do
    if not listed(name, PROFILES) then
      return at("/profiles/" .. (i - 1), "unknown profile \"" .. name .. "\" (known: " ..
          table.concat(PROFILES, ", ") .. ")")
    end
  end
  for i, grant in ipairs(p.grants or {}) do
    local base = "/grants/" .. (i - 1)
    if grant.path == nil or grant.path == "" or grant.path:find("\0", 1, true) then
      return at(base .. "/path", "a path is not empty and holds no NUL")
    end
    for segment in grant.path:gmatch("[^/]+") do
      if segment == ".." then
        return at(base .. "/path", "\"..\" is not allowed; name the directory itself")
      end
    end
    local canonical = grant.letters ~= nil and canonical_letters(grant.letters) or nil
    if canonical == nil then
      return at(base .. "/letters", "letters are of \"" .. LETTERS .. "\", at least one")
    end
    if exact and canonical ~= grant.letters then
      return at(base .. "/letters", "\"" .. grant.letters .. "\" is not in the order of \"" ..
          LETTERS .. "\", each letter once: \"" .. canonical .. "\"")
    end
    if grant.from ~= nil and (grant.from == "" or grant.from:find("\0", 1, true)) then
      return at(base .. "/from", "a host path is not empty and holds no NUL")
    end
  end
  for i, target in ipairs(p.connect or {}) do
    local _, why = Relay.Grant.parse(target)
    if why ~= "" then
      return at("/connect/" .. (i - 1), "\"" .. target .. "\" is not a target the relay can use: " ..
          why .. " (host:port, the host a name, an IPv4 address, an IPv6 address in " ..
          "brackets or \"*\" for any name, the port from 1 to 65535 or \"*\" for any)")
    end
  end
  for i, address in ipairs(p.loopback or {}) do
    if not loopback_ok(address) then
      return at("/loopback/" .. (i - 1), "\"" .. address .. "\" is not an address of 127/8")
    end
  end
  local conflict = loopback_conflict(p.loopback or {}, p.connect or {})
  if conflict ~= "" then return conflict end
  for i, name in ipairs(p.env or {}) do
    if not env_name_ok(name) then
      return at("/env/" .. (i - 1), "a variable's name is not empty and holds no '=' or NUL")
    end
  end
  for name, value in pairs(p.set_env or {}) do
    if not env_name_ok(name) then
      return at("/set_env", "\"" .. name .. "\" is not a variable's name: not empty, no '=' or NUL")
    end
    if value:find("\0", 1, true) then
      return at("/set_env/" .. name, "a value holds no NUL")
    end
  end
  for name, digest in pairs(p.set_env_digests or {}) do
    if not env_name_ok(name) then
      return at("/set_env_digests", "\"" .. name .. "\" is not a variable's name: not empty, " ..
          "no '=' or NUL")
    end
    if not digest:match("^%x+$") or #digest ~= 64 or digest:find("%u") then
      return at("/set_env_digests/" .. name, "a digest is 64 lowercase hex digits")
    end
  end
  for _, field in ipairs({ "user", "group" }) do
    local id = field == "user" and p.user or p.group
    if id ~= nil and (math.type(id) ~= "integer" or id < 1 or id > 4294967294) then
      return at("/" .. field, "an id is a whole number from 1 to 4294967294: never root")
    end
    if id == 65534 or id == 65535 then
      return at("/" .. field, id .. " is the overflow id, which the kernel shows for an id " ..
          "a namespace does not map: name another")
    end
  end
  if p.group ~= nil and p.user == nil then
    return at("/group", "a group is given with a user")
  end
  if p.database ~= nil then
    local path = p.database
    if path == "" or path:find("\0", 1, true) then
      return at("/database", "a path is not empty and holds no NUL")
    end
    if path:sub(1, 1) ~= "/" then
      return at("/database", "\"" .. path .. "\" is relative: the program's directory is not the " ..
          "one this is read from, so name the file by its absolute path")
    end
    for segment in path:gmatch("[^/]+") do
      if segment == ".." then
        return at("/database", "\"..\" is not allowed; name the file itself")
      end
    end
    local found, trouble = sys.stat(path)
    if found == nil then
      return at("/database", path .. ": " .. trouble)
    end
    if found.kind ~= "file" then
      return at("/database", path .. " is not a regular file")
    end
  end
  local limits = p.limits or {}
  for _, why in ipairs({
      below("open_files", limits.open_files, 1), below("cpu_seconds", limits.cpu_seconds, 1),
      below("processes", limits.processes, 1), below("file_bytes", limits.file_bytes, 0),
  }) do
    if why ~= "" then return why end
  end
  return ""
end

--- Whether the values of `p` are ones a policy may hold: [`Sandbox.check`],
--- which says how.
function rules.check(p: rules.Policy, exact?: boolean): boolean, string
  local bad = invalid(p, exact == true)
  if bad ~= "" then return false, "sandbox: " .. bad end
  return true, ""
end

--- `path` written once: no repeated or trailing "/" and no "." segment.
--- A ".." segment is not cleaned, since lexically it is not what the
--- kernel reads after a link; [`invalid`] refuses it. An empty result
--- is "." (relative) or "/".
local function clean_path(path: string): string
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part ~= "." then parts[#parts + 1] = part end
  end
  local joined = table.concat(parts, "/")
  if path:sub(1, 1) == "/" then return "/" .. joined end
  if joined == "" then return "." end
  return joined
end

--- The members of every list given, each once, in byte order.
local function sorted_set<T>(...: {T}): {T}
  local seen: {T:boolean} = {}
  local out: {T} = {}
  for _, list in ipairs({ ... }) do
    for _, item in ipairs(list) do
      if not seen[item] then
        seen[item] = true
        out[#out + 1] = item
      end
    end
  end
  table.sort(out, function(x: T, y: T): boolean return tostring(x) < tostring(y) end)
  return out
end

--- The SHA-256 of `value`, in lowercase hex. cosmic/policy.tl's `encode`
--- keeps a copy, which must answer the same digest.
local function digest_of(value: string): string
  return Codec.hex(Hash.sha256(value))
end

--- The limit `name` once `incoming` joins `held`, either nil for none:
--- the one value given. Two different values answer why.
local function join_limit(name: string, held: integer, incoming: integer): integer, string
  if incoming == nil then return held, "" end
  if held ~= nil and held ~= incoming then
    return held, "limits." .. name .. " is given two values, " .. held .. " and " .. incoming
  end
  return incoming, ""
end

local record Joined
  path: string
  from: string
  letters: {string:boolean}
end

--- The paths of the "system" profile on Linux and what each is for, read and
--- run, or read, or written, before the host's are filtered to those that exist.
local LINUX_SYSTEM_PATHS <const>: {{string}} = {
  -- The programs and libraries of the system, and the loader. Everything
  -- installed under /usr is reachable, /usr/local included; /opt, /home
  -- and /var are not. /bin and the /lib directories are links into /usr on
  -- a merged-usr host, and are granted where they are directories of their own.
  { "/usr", "rx" }, { "/bin", "rx" }, { "/lib", "rx" }, { "/lib32", "rx" },
  { "/lib64", "rx" }, { "/libx32", "rx" },
  -- What a libc reads as a program starts: the loader's cache and preload
  -- list, the name-service switch, the accounts (a program asking who it is
  -- runs as), and the time zone.
  { "/etc/ld.so.cache", "r" }, { "/etc/ld.so.preload", "r" },
  { "/etc/nsswitch.conf", "r" }, { "/etc/passwd", "r" }, { "/etc/group", "r" },
  { "/etc/localtime", "r" },
  -- The devices every program expects: the bit bucket, zeros and entropy.
  { "/dev/null", "rw" }, { "/dev/zero", "r" }, { "/dev/urandom", "r" }, { "/dev/random", "r" },
}

--- The paths of the "system" profile on macOS. Unlike Linux's this
--- includes the system frameworks and dyld's cryptexes; no Mach service
--- or network permission follows merely from reading system libraries.
local DARWIN_SYSTEM_PATHS <const>: {{string}} = {
  { "/usr", "rx" }, { "/bin", "rx" }, { "/sbin", "rx" },
  { "/System/Library", "rx" }, { "/Library/Apple/System/Library", "rx" },
  { "/System/Cryptexes/App", "rx" }, { "/System/Cryptexes/OS", "rx" },
  { "/System/Volumes/Preboot/Cryptexes/App/System", "rx" },
  { "/System/Volumes/Preboot/Cryptexes/OS", "rx" },
  { "/etc/passwd", "r" }, { "/etc/group", "r" }, { "/etc/localtime", "r" },
  { "/private/var/db/timezone", "r" },
  -- dyld's own state: it reads its closures and shared cache map from here.
  { "/private/var/db/dyld", "r" },
  -- /bin/sh reads its own selection from here.
  { "/private/var/select", "r" },
  -- No /dev/tty: as on Linux, a child opens no terminal by name, and the
  -- start gives it a session with none besides. One started with a pty
  -- is granted its slave and /dev/tty by the terminal option of the Seatbelt backend.
  { "/dev/null", "rw" }, { "/dev/dtracehelper", "rw" }, { "/dev/zero", "r" },
  { "/dev/random", "r" }, { "/dev/urandom", "r" },
}

--- The paths of the "system" profile for `host`, "darwin" or "linux",
--- whether or not this host has them: the one list [`rules.profile`] and
--- the Seatbelt backend both read, so a profile means the same raw, merged
--- or through JSON.
function rules.system_paths(host: string): {{string}}
  if host == "darwin" then return DARWIN_SYSTEM_PATHS end
  return LINUX_SYSTEM_PATHS
end

--- Whether this host is macOS.
local function on_darwin(): boolean
  local names, _ = uname()
  return names ~= nil and names.sysname == "Darwin"
end

--- The "system" profile of `host` ("darwin" or "linux"): what the host
--- gives a dynamically linked program to run. A path of that host's list is
--- granted when `exists` finds it, so the same profile fits a host with and
--- without a /lib64. Apart from [`rules.profile`], which asks this host, only
--- a test of the other host's list calls it.
function rules.system_profile(host: string, exists: function(string): boolean): rules.Policy
  local grants: {rules.Grant} = {}
  for _, entry in ipairs(rules.system_paths(host)) do
    if exists(entry[1]) then
      grants[#grants + 1] = { path = entry[1], letters = entry[2] }
    end
  end
  return { grants = grants }
end

--- Whether `path` exists on this host.
local function present(path: string): boolean
  local found, _ = stat(path)
  return found ~= nil
end

--- The "cosmic" profile: `rx` on what [`Proc.executable`] names, which is
--- the path this program is started by: under a development build or a
--- portable artifact that is the launcher (a `#!/bin/sh` script) or the
--- artifact, not the native core the launcher runs. [`Child.start`] runs
--- that path, where a policy grants it, as its core, by a relaunch, which
--- needs neither the launcher's shell nor a cache to unpack a core into;
--- a process that runs the path itself (a shell under the policy) runs
--- the launcher, which needs both.
local function cosmic_profile(): rules.Policy | nil, string
  local path, why = Proc.executable()
  if path == nil then
    return refuse("profile \"cosmic\": this process has no executable: " .. why)
  end
  return { grants = { { path = path, letters = "rx" } } }, ""
end

--- What the profile `name` holds on this host: [`Sandbox.profile`], which
--- says how.
function rules.profile(name: string): rules.Policy | nil, string
  if name == "system" then
    return rules.system_profile(on_darwin() and "darwin" or "linux", present), ""
  end
  if name == "cosmic" then return cosmic_profile() end
  return refuse("unknown profile \"" .. tostring(name) .. "\" (known: " ..
      table.concat(PROFILES, ", ") .. ")")
end

--- The SHA-256 of the database each policy was checked against
--- ([`rules.expect_digest`]), by the policy table; a merge carries it to
--- its answer. Weak, so a policy that is dropped takes its entry along.
local expected: {rules.Policy:string} = setmetatable({}, { __mode = "k" })

--- Records the digest `policy`'s database is to have:
--- [`Sandbox.expect_digest`], which says how.
function rules.expect_digest(policy: rules.Policy, digest: string)
  expected[policy] = digest
end

--- Whether the file at `path` is the database `merged` was checked
--- against: [`Sandbox.database_is`], which says how.
function rules.database_is(merged: rules.Policy, path: string): boolean, string
  local digest = expected[merged]
  if digest == nil then return true, "" end
  local bytes, why = Fs.read(path)
  if bytes == nil then return false, "database " .. why end
  if Hash.hex_sha256(bytes) ~= digest then
    return false, "database " .. path .. " is not the one its policy was checked against: " ..
      "its SHA-256 has changed since"
  end
  return true, ""
end

--- What the policies given hold together: [`Sandbox.merge`], which says
--- how.
function rules.merge(...: rules.Policy): rules.Policy | nil, string
  local flat: {rules.Policy} = {}
  local given: {rules.Policy} = { ... }
  local on_database = false
  for _, p in ipairs(given) do
    if p.database ~= nil then on_database = true end
  end
  for _, p in ipairs(given) do
    local bad = invalid(p, false)
    if bad ~= "" then return refuse(bad) end
    for _, name in ipairs(p.profiles or {}) do
      -- The program on a database is a core and that file, which a start
      -- grants: the profile's grant of this program's own file is
      -- none of it, and one a start refuses.
      if not (on_database and name == "cosmic") then
        local profile, why = rules.profile(name)
        if profile == nil then return nil, why end
        flat[#flat + 1] = profile
      end
    end
    flat[#flat + 1] = p
  end
  local joined: {string:Joined} = {}
  local order: {Joined} = {}
  local limits: rules.Limits = {}
  local set_env: {string:string} = {}
  local digests: {string:string} = {}
  local isolate: {rules.Isolate} = {}
  local promises: {rules.Promise} = {}
  local connect: {string} = {}
  local loopback: {string} = {}
  local env: {string} = {}
  local tmp = false
  local user, group: integer, integer
  local database: string
  local vouched: string
  for _, p in ipairs(flat) do
    local seen = expected[p]
    if seen ~= nil then
      if vouched ~= nil and vouched ~= seen then
        return refuse("database is checked against two digests")
      end
      vouched = seen
    end
    if p.database ~= nil then
      local at = clean_path(p.database)
      if database ~= nil and database ~= at then
        return refuse("database is given two values, " .. database .. " and " .. at)
      end
      database = at
    end
    for _, grant in ipairs(p.grants or {}) do
      local at = clean_path(grant.path)
      local key = at .. "\0" .. (grant.from or "")
      local held = joined[key]
      if held == nil then
        held = { path = at, from = grant.from, letters = {} }
        joined[key] = held
        order[#order + 1] = held
      end
      for i = 1, #grant.letters do held.letters[grant.letters:sub(i, i)] = true end
    end
    isolate = sorted_set(isolate, p.isolate or {})
    promises = sorted_set(promises, p.promises or {})
    connect = sorted_set(connect, p.connect or {})
    loopback = sorted_set(loopback, p.loopback or {})
    env = sorted_set(env, p.env or {})
    for name, value in pairs(p.set_env or {}) do
      if set_env[name] ~= nil and set_env[name] ~= value then
        return refuse("set_env \"" .. name .. "\" is given two values")
      end
      set_env[name] = value
    end
    for name, digest in pairs(p.set_env_digests or {}) do
      if digests[name] ~= nil and digests[name] ~= digest then
        return refuse("set_env_digests \"" .. name .. "\" is given two digests")
      end
      digests[name] = digest
    end
    if p.tmp then tmp = true end
    if p.user ~= nil and user ~= nil and p.user ~= user then
      return refuse("user is given two values, " .. user .. " and " .. p.user)
    end
    if p.group ~= nil and group ~= nil and p.group ~= group then
      return refuse("group is given two values, " .. group .. " and " .. p.group)
    end
    user, group = p.user or user, p.group or group
    local own = p.limits or {}
    local why: string
    limits.open_files, why = join_limit("open_files", limits.open_files, own.open_files)
    if why == "" then
      limits.file_bytes, why = join_limit("file_bytes", limits.file_bytes, own.file_bytes)
    end
    if why == "" then
      limits.cpu_seconds, why = join_limit("cpu_seconds", limits.cpu_seconds, own.cpu_seconds)
    end
    if why == "" then
      limits.processes, why = join_limit("processes", limits.processes, own.processes)
    end
    if why ~= "" then return refuse(why) end
  end
  local grants: {rules.Grant} = {}
  for _, held in ipairs(order) do
    local letters: {string} = {}
    for letter in pairs(held.letters) do letters[#letters + 1] = letter end
    grants[#grants + 1] = { path = held.path, from = held.from,
      letters = canonical_letters(table.concat(letters)) }
  end
  table.sort(grants, function(a: rules.Grant, b: rules.Grant): boolean
    if a.path ~= b.path then return a.path < b.path end
    return (a.from or "") < (b.from or "")
  end)
  -- `file` implies `proc`: written out, so the two spellings are one policy.
  local implied: rules.Isolate = "proc"
  local has_file, has_proc = false, false
  for _, kind in ipairs(isolate) do
    if kind == "file" then has_file = true end
    if kind == "proc" then has_proc = true end
  end
  if has_file and not has_proc then isolate = sorted_set(isolate, { implied }) end
  for name, value in pairs(set_env) do
    if digests[name] ~= nil and digests[name] ~= digest_of(value) then
      return refuse("set_env_digests \"" .. name .. "\" is not the digest of set_env's value")
    end
    digests[name] = nil
  end
  local conflict = loopback_conflict(loopback, connect)
  if conflict ~= "" then return refuse(conflict) end
  local result: rules.Policy = {
    grants = grants, isolate = isolate, promises = promises,
    connect = connect, loopback = loopback, env = env, set_env = set_env,
    set_env_digests = digests, tmp = tmp, limits = limits,
    user = user, group = group, database = database,
  }
  if vouched ~= nil and database ~= nil then expected[result] = vouched end
  return result, ""
end

return rules
