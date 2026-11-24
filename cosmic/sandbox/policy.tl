--- The policy layer cosmic.sandbox and cosmic.sandbox.seatbelt share: the types
--- of a policy, the check of its values, the profiles it names and the
--- merge of policies into one. Use [`cosmic.sandbox`], which answers all of
--- it under its own name and documents it there. Apart from cosmic.sandbox
--- only so that cosmic.sandbox.seatbelt, which cosmic.sandbox requires, can require
--- this.

local FieldPath = require("cosmic.internal.field_path")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Loopback = require("cosmic.internal.loopback")
local Proc = require("cosmic.proc")
local Grant = require("cosmic.relay.grant")
local RelayConfig = require("cosmic.internal.relay_config")
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
    --- reads files and lists directories, `w` writes and truncates files
    --- (a truncation that opens no descriptor to write, as truncate(2)
    --- does, needs Landlock ABI 3, and is refused below it and under
    --- `nest`), `x` runs files, `c` creates and removes, `u` connects to
    --- the unix socket at the path (Landlock ABI 9; below it only under
    --- `isolate` file, and only where no grant is a directory or a socket
    --- not granted `u`, since nothing else tells the granted socket from
    --- the root's others). A grant on a directory reaches what is beneath
    --- it.
    letters: string
    --- The host's path, when it differs from `path`: the program sees this
    --- file or directory under another name. Needs `isolate` file.
    from?: string
  end

  --- Resource limits on every process the program starts. Nil is the
  --- start's default: 1024 open files, no core dump, and under `isolate`
  --- 4096 processes where the kernel counts them per user namespace;
  --- nothing else.
  record Limits
    --- The most descriptors a process may hold open (at least 1).
    mut open_files?: integer
    --- The most bytes a process may write to one file.
    mut file_bytes?: integer
    --- The CPU seconds a process may spend (at least 1). Soft and hard
    --- limit are the same, so a process past it is ended by SIGKILL, with
    --- no SIGXCPU to catch first.
    mut cpu_seconds?: integer
    --- The most processes and threads of the whole sandbox, counted by
    --- the user namespace it runs in (at least 1): a child's, with
    --- `isolate` "proc" or "file", on a Linux kernel from 5.17.
    mut processes?: integer
  end

  --- What a program is held to; every field is optional, and what a policy
  --- leaves out it does not have.
  record Policy
    --- Named policies to join in, by [`Sandbox.union`]: "system", "programs", "cosmic", "proc".
    profiles?: {string}
    --- The paths the program reaches.
    grants?: {Grant}
    --- How far it is isolated from the host. With "file", a writable grant on a tree that user does not own (`/etc`
    --- as `rwc`, say) is mounted so that it is the tree's owner there: it
    --- writes the owner's files, root's included, through that mount.
    isolate?: {Isolate}
    --- The system calls it may make beyond its basics.
    promises?: {Promise}
    --- The hosts it may reach, "host:port", where the host or the port is
    --- "*" for any. A host is a DNS name, an IPv4 address or an IPv6 address
    --- in brackets, and a name is read lower-case without a final dot; a
    --- pattern, an underscore and anything else the relay's readers refuse
    --- is refused here too ([`cosmic.relay.grant`]). A target may name
    --- nodes of the machine's tailnet instead: `tag:db:5432` grants every
    --- address of each peer tagged `tag:db`, and `user:will@example.com:*`
    --- of each untagged peer that user owns, as tailscaled lists them when
    --- the sandbox starts ([`cosmic.sandbox.tailnet`]).
    connect?: {string}
    --- The addresses of 127/8 it uses inside its own network.
    loopback?: {string}
    --- The variables passed through from the caller's environment.
    env?: {string}
    --- The variables set, by name. With `env`, the program's whole
    --- environment; a name in both is set.
    set_env?: {string:string}
    --- What a decoded, encoded policy holds in place of `set_env`'s
    --- values: for each name, the SHA-256 of its value in lowercase
    --- hex. [`PolicyJson.encode`] writes these, so the text shows a value
    --- changed without showing it; a policy that holds one, and no value
    --- for the name, cannot start a program.
    set_env_digests?: {string:string}
    --- Whether the program has a fresh temporary directory of its own,
    --- named by `TMPDIR`, that it may write. Under `isolate` file it is
    --- the root's own /tmp, which a grant of "/tmp" with no `from` and the
    --- letters `rwxc` lets the program run files from (`rwc`, the default,
    --- does not), and a `set_env` TMPDIR beneath /tmp is kept, for a
    --- directory the program makes there.
    tmp?: boolean
    --- The resources it may spend.
    limits?: Limits
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
    user?: integer
    --- The group a child runs as, with `user`: for a root caller, `user`'s
    --- own number where it is left out; for any other, its own group. On
    --- macOS only the caller's own group is met, as for `user`.
    group?: integer
    --- A database the program runs on, by its absolute path ([`rules.Database`]): the program
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
    --- it. With a `sha256`, [`Child.start`] runs the program only on a
    --- file of that digest, and [`PolicyJson.encode`] writes it, so the
    --- text holds what the database is and not only where; merging keeps
    --- it.
    database?: rules.Database
  end
  --- A database a policy names: its absolute `path`, and the SHA-256 of
  --- its bytes (`sha256`, 64 lowercase hex digits) where the policy is to
  --- run only on a file of that digest. The two travel together through
  --- copies, [`Sandbox.union`] and [`PolicyJson.encode`], so a digest is never
  --- apart from the path it was taken at. With no `sha256` the policy
  --- names a file and not its content: [`Sandbox.database`] takes the
  --- digest of one now.
  record Database
    --- The file's absolute path, with no "..".
    path: string
    --- The SHA-256 of the file's bytes, in lowercase hex; nil for a path alone.
    sha256?: string
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
local function canonical_letters(letters: string): string?
  local seen: mut {string:boolean} = {}
  for i = 1, #letters do
    local letter = letters:sub(i, i)
    if not LETTERS:find(letter, 1, true) then return nil end
    seen[letter] = true
  end
  local out: mut {string} = {}
  for i = 1, #LETTERS do
    local letter = LETTERS:sub(i, i)
    if seen[letter] == true then out[#out + 1] = letter end
  end
  if #out == 0 then return nil end
  return table.concat(out)
end

--- Whether `name` can be an environment variable's name.
local function env_name_ok(name: string): boolean
  return name ~= "" and not name:find("=", 1, true) and not name:find("\0", 1, true)
end

local PROFILES <const>: {string} = { "cosmic", "proc", "programs", "system" }

local function listed(name: string, names: {string}): boolean
  for _, known in ipairs(names) do
    if known == name then return true end
  end
  return false
end

--- The path of the value `steps` name from the root: a string is a member, an
--- integer a list element by its Lua index.
local function path_of(steps: {string | integer}): string
  local path = FieldPath.root
  for _, step in ipairs(steps) do
    path = if step is string then FieldPath.field(path, step) else FieldPath.index(path, step) end
  end
  return path
end

--- Why the limit `name`, nil for none, is below `least`, or "".
local function below(name: string, value: integer?, least: integer): string
  if value == nil or value >= least then return "" end
  return path_of({ "limits", name }) .. ": a limit is at least " .. tostring(least)
end

--- Why `loopback` and `connect` may not be held together, or "": a
--- `loopback` address is the program's own network, which `NO_PROXY` keeps
--- direct, while a `connect` target of it names the host's service, which
--- the program reaches through the relay. `NO_PROXY` is by host, so the
--- port does not tell them apart. Names the `loopback` entry's path; in a merged policy, whose lists
--- hold each address once, sorted, it is the entry of the merged list.
local function loopback_conflict(loopback: {string}, connect: {string}, joined: boolean): string
  for i, address in ipairs(loopback) do
    local target = RelayConfig.naming(connect, address)
    if target ~= "" then
      return path_of({ "loopback", i }) .. ": " .. (if joined then "in the merged policy, " else "" end) .. "\"" .. address .. "\" is also the host address that " ..
        "connect \"" .. target .. "\" names, and a proxy client cannot tell the two apart by port: " ..
        "give the sandbox's own services another 127.x address (127.0.0.2, say)"
    end
  end
  return ""
end

--- The first thing wrong in a policy's values, as `$.grants[0].letters:
--- why`, or "" when none is: the field's types are Teal's, and these are the
--- values a type does not hold. With `exact`, a grant's letters must be
--- already in the order of "rwxcu", each once, as [`Sandbox.check`] with
--- `exact` takes them.
local function invalid(p: rules.Policy, exact: boolean): string
  local function at(steps: {string | integer}, why: string): string
    return path_of(steps) .. ": " .. why
  end
  for i, name in ipairs(p.profiles or {}) do
    if not listed(name, PROFILES) then
      return at({ "profiles", i }, "unknown profile \"" .. name .. "\" (known: " ..
          table.concat(PROFILES, ", ") .. ")")
    end
  end
  for i, grant in ipairs(p.grants or {}) do
    if grant.path == nil or grant.path == "" or grant.path:find("\0", 1, true) ~= nil then -- checked: compare_disjoint
      return at({ "grants", i, "path" }, "a path is not empty and holds no NUL")
    end
    for segment in grant.path:gmatch("[^/]+") do
      if segment == ".." then
        return at({ "grants", i, "path" }, "\"..\" is not allowed; name the directory itself")
      end
    end
    local canonical = if grant.letters ~= nil then canonical_letters(grant.letters) else nil end -- checked: compare_disjoint
    if canonical == nil then
      return at({ "grants", i, "letters" }, "letters are of \"" .. LETTERS .. "\", at least one")
    end
    if exact and canonical ~= grant.letters then
      return at({ "grants", i, "letters" }, "\"" .. grant.letters .. "\" is not in the order of \"" ..
          LETTERS .. "\", each letter once: \"" .. canonical .. "\"")
    end
    local from = grant.from
    if from ~= nil and (from == "" or from:find("\0", 1, true) ~= nil) then
      return at({ "grants", i, "from" }, "a host path is not empty and holds no NUL")
    end
  end
  for i, target in ipairs(p.connect or {}) do
    local tailnet, wrong = Grant.tailnet(target)
    if tailnet == nil and wrong ~= "" then
      return at({ "connect", i }, "\"" .. target .. "\" is not a tailnet target: " .. wrong ..
          " (tag:<tag>:<port> or user:<login>:<port>, the port from 1 to 65535 or \"*\" for any)")
    end
    local why = ""
    if tailnet == nil then
      local _, wrong_target = Grant.parse(target)
      why = wrong_target
    end
    if why ~= "" then
      return at({ "connect", i }, "\"" .. target .. "\" is not a target the relay can use: " ..
          why .. " (host:port, the host a name, an IPv4 address, an IPv6 address in " ..
          "brackets or \"*\" for any name, the port from 1 to 65535 or \"*\" for any)")
    end
  end
  for i, address in ipairs(p.loopback or {}) do
    if not Loopback.ipv4(address) then
      return at({ "loopback", i }, "\"" .. address .. "\" is not an address of 127/8")
    end
  end
  local conflict = loopback_conflict(p.loopback or {}, p.connect or {}, false)
  if conflict ~= "" then return conflict end
  for i, name in ipairs(p.env or {}) do
    if not env_name_ok(name) then
      return at({ "env", i }, "a variable's name is not empty and holds no '=' or NUL")
    end
  end
  for name, value in pairs(p.set_env or {}) do
    if not env_name_ok(name) then
      return at({ "set_env", name }, "\"" .. name .. "\" is not a variable's name: not empty, no '=' or NUL")
    end
    if value:find("\0", 1, true) then
      return at({ "set_env", name }, "a value holds no NUL")
    end
  end
  for name, digest in pairs(p.set_env_digests or {}) do
    if not env_name_ok(name) then
      return at({ "set_env_digests", name }, "\"" .. name .. "\" is not a variable's name: not empty, " ..
          "no '=' or NUL")
    end
    if not digest:match("^%x+$") or #digest ~= 64 or digest:find("%u") ~= nil then
      return at({ "set_env_digests", name }, "a digest is 64 lowercase hex digits")
    end
  end
  for _, field in ipairs({ "user", "group" }) do
    local id = field == "user" and p.user or p.group -- checked: and_ternary
    if id ~= nil and (math.type(id) ~= "integer" or id < 1 or id > 4294967294) then
      return at({ field }, "an id is a whole number from 1 to 4294967294: never root")
    end
    if id == 65534 or id == 65535 then
      return at({ field }, tostring(id) .. " is the overflow id, which the kernel shows for an id " ..
          "a namespace does not map: name another")
    end
  end
  if p.group ~= nil and p.user == nil then
    return at({ "group" }, "a group is given with a user")
  end
  local given = p.database
  if given ~= nil then
    local path = given.path
    if path == "" or path:find("\0", 1, true) ~= nil then
      return at({ "database", "path" }, "a path is not empty and holds no NUL")
    end
    if path:sub(1, 1) ~= "/" then
      return at({ "database", "path" }, "\"" .. path .. "\" is relative: the program's directory is not the " ..
          "one this is read from, so name the file by its absolute path")
    end
    for segment in path:gmatch("[^/]+") do
      if segment == ".." then
        return at({ "database", "path" }, "\"..\" is not allowed; name the file itself")
      end
    end
    local digest = given.sha256
    if digest ~= nil and not (digest:find("^%x+$") ~= nil and #digest == 64 and digest:lower() == digest) then
      return at({ "database", "sha256" }, "a digest is 64 lowercase hex digits")
    end
    local found, trouble = sys.stat(path)
    if found == nil then
      return at({ "database", "path" }, path .. ": " .. trouble)
    end
    if found.kind ~= "file" then
      return at({ "database", "path" }, path .. " is not a regular file")
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
  local parts: mut {string} = {}
  for part in path:gmatch("[^/]+") do
    if part ~= "." then parts[#parts + 1] = part end
  end
  local joined = table.concat(parts, "/")
  if path:sub(1, 1) == "/" then return "/" .. joined end
  if joined == "" then return "." end
  return joined
end

--- The members of every list given, each once, in byte order.
local function sorted_set<T is Key>(...: {T}): {T}
  local seen: mut {T:boolean} = {}
  local out: mut {T} = {}
  for _, list in ipairs({ ... }) do
    for _, item in ipairs(list) do
      if seen[item] ~= true then
        seen[item] = true
        out[#out + 1] = item
      end
    end
  end
  table.sort(out, function(x: T, y: T): boolean return tostring(x) < tostring(y) end)
  return out
end

--- Why `held` and `incoming`, two values for the limit `name` (either nil
--- for none), disagree, or "" when they do not.
local function limit_conflict(name: string, held: integer?, incoming: integer?): string
  if held ~= nil and incoming ~= nil and held ~= incoming then
    return path_of({ "limits", name }) .. ": given two values, " .. tostring(held) .. " and " .. tostring(incoming)
  end
  return ""
end

local record Joined
  path: string
  from?: string
  letters: mut {string:boolean}
end

--- The paths of the "system" profile on Linux and what each is for, read and
--- run, or read, or written, before the host's are filtered to those that exist.
local LINUX_SYSTEM_PATHS <const>: {{string}} = {
  -- The programs and libraries of the system, read: a library is mapped
  -- by the loader, which needs no `x`, and a program a policy runs is
  -- granted by the start ([`Child.start`]) or by a grant naming it. No
  -- `x` stops an execve, not code run by mapping what is read (the ELF
  -- loader runs any program it can read).
  -- Everything installed under /usr is reachable, /usr/local included;
  -- /opt, /home and /var are not. /bin and the /lib directories are links into /usr on
  -- a merged-usr host, and are granted where they are directories of their own.
  { "/usr", "r" }, { "/bin", "r" }, { "/lib", "r" }, { "/lib32", "r" },
  { "/lib64", "r" }, { "/libx32", "r" },
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
  { "/usr", "r" }, { "/bin", "r" }, { "/sbin", "r" },
  { "/System/Library", "r" }, { "/Library/Apple/System/Library", "r" },
  { "/System/Cryptexes/App", "r" }, { "/System/Cryptexes/OS", "r" },
  { "/System/Volumes/Preboot/Cryptexes/App/System", "r" },
  { "/System/Volumes/Preboot/Cryptexes/OS", "r" },
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

--- The paths of the "programs" profile on Linux: the host's programs and
--- the loader they start by, run. "system" reads them; this runs them.
local LINUX_PROGRAM_PATHS <const>: {{string}} = {
  { "/usr", "rx" }, { "/bin", "rx" }, { "/sbin", "rx" }, { "/lib", "rx" }, { "/lib32", "rx" },
  { "/lib64", "rx" }, { "/libx32", "rx" },
}

--- The paths of the "programs" profile on macOS: the host's programs, run.
local DARWIN_PROGRAM_PATHS <const>: {{string}} = {
  { "/usr", "rx" }, { "/bin", "rx" }, { "/sbin", "rx" },
}

--- The paths of the profile `name`, "system" or "programs", for `host`,
--- "darwin" or "linux", whether or not this host has them; nil for
--- another name, whose grants are not a list of host paths.
function rules.profile_paths(name: string, host: string): {{string}}?
  if name == "programs" then
    return if host == "darwin" then DARWIN_PROGRAM_PATHS else LINUX_PROGRAM_PATHS end
  end
  if name == "system" then return rules.system_paths(host) end
  return nil
end

--- The paths of the "system" profile for `host`, "darwin" or "linux",
--- whether or not this host has them: the one list [`rules.profile`] and
--- the Seatbelt backend both read, so a profile means the same raw, merged
--- or through JSON.
function rules.system_paths(host: string): {{string}}
  if host == "darwin" then return DARWIN_SYSTEM_PATHS end
  return LINUX_SYSTEM_PATHS
end

--- Whether this host is macOS, which holds a process by Seatbelt and
--- has neither Landlock, seccomp nor namespaces.
function rules.on_macos(): boolean
  local names, _ = uname()
  return names ~= nil and names.sysname == "Darwin"
end

--- The "system" profile of `host` ("darwin" or "linux"): what the host
--- gives a dynamically linked program to run. A path of that host's list is
--- granted when `exists` finds it, so the same profile fits a host with and
--- without a /lib64. Apart from [`rules.profile`], which asks this host, only
--- a test of the other host's list calls it.
function rules.system_profile(host: string, exists: function(string): boolean, name?: string): rules.Policy
  local grants: mut {rules.Grant} = {}
  for _, entry in ipairs(rules.profile_paths(name or "system", host) or {}) do
    local path = assert(entry[1], "a system path entry names its path")
    local letters = assert(entry[2], "a system path entry names its letters")
    if exists(path) then
      grants[#grants + 1] = { path = path, letters = letters }
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
local function cosmic_profile(): rules.Policy?, string
  local path, why = Proc.executable()
  if path == nil then
    return refuse("profile \"cosmic\": this process has no executable: " .. tostring(why))
  end
  return { grants = { { path = path, letters = "rx" } } }, ""
end

--- The "proc" profile: `r` on the host's /proc where there is one (Linux),
--- the kernel's process information, and nothing on macOS, where sysctl
--- answers with no file to grant. As the "system" profile does, it grants
--- only a path the host has, so a Linux host with no /proc mounted gets none.
local function proc_profile(): rules.Policy
  if rules.on_macos() or not present("/proc") then return {} end
  return { grants = { { path = "/proc", letters = "r" } } }
end

--- What the profile `name` holds on this host: [`Sandbox.profile`], which
--- says how.
function rules.profile(name: string): rules.Policy?, string
  if name == "proc" then return proc_profile(), "" end
  if name == "system" or name == "programs" then
    return rules.system_profile(if rules.on_macos() then "darwin" else "linux" end, present, name), ""
  end
  if name == "cosmic" then return cosmic_profile() end
  return refuse("unknown profile \"" .. tostring(name) .. "\" (known: " ..
      table.concat(PROFILES, ", ") .. ")")
end

--- The database at `path`, with the SHA-256 of its bytes now:
--- [`Sandbox.database`], which says how.
function rules.database(path: string): rules.Database?, string
  local bytes, why = Fs.read(path)
  if bytes == nil then return refuse("database " .. tostring(why)) end
  return { path = path, sha256 = Hash.hex_sha256(bytes) }, ""
end

--- What the policies given hold together: [`Sandbox.union`], which says
--- how.
function rules.merge(...: rules.Policy): rules.Policy?, string
  local flat: mut {rules.Policy} = {}
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
  local joined: mut {string:Joined} = {}
  local order: mut {Joined} = {}
  local limits: rules.Limits = {}
  local set_env: mut {string:string} = {}
  local digests: mut {string:string} = {}
  local isolate: {rules.Isolate} = {}
  local promises: {rules.Promise} = {}
  local connect: {string} = {}
  local loopback: {string} = {}
  local env: {string} = {}
  local tmp = false
  local user, group: integer?, integer?
  local database: rules.Database? = nil
  for _, p in ipairs(flat) do
    local named = p.database
    if named ~= nil then
      local at = clean_path(named.path)
      local digest = named.sha256
      if database ~= nil and database.path ~= at then
        return refuse(path_of({ "database", "path" }) .. ": given two values, " .. database.path .. " and " .. at)
      end
      local database_sha256 = database and database.sha256
      if database ~= nil and digest ~= nil and database_sha256 ~= nil and database_sha256 ~= digest then
        return refuse(path_of({ "database", "sha256" }) .. ": given two digests for " .. at .. ", " .. database_sha256 ..
            " and " .. digest)
      end
      database = { path = at, sha256 = digest or (database and database.sha256) }
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
        return refuse(path_of({ "set_env", name }) .. ": given two values")
      end
      set_env[name] = value
    end
    for name, digest in pairs(p.set_env_digests or {}) do
      if digests[name] ~= nil and digests[name] ~= digest then
        return refuse(path_of({ "set_env_digests", name }) .. ": given two digests")
      end
      digests[name] = digest
    end
    if p.tmp == true then tmp = true end
    local p_user = p.user
    if p_user ~= nil and user ~= nil and p_user ~= user then
      return refuse(path_of({ "user" }) .. ": given two values, " .. tostring(user) .. " and " .. tostring(p_user))
    end
    local p_group = p.group
    if p_group ~= nil and group ~= nil and p_group ~= group then
      return refuse(path_of({ "group" }) .. ": given two values, " .. tostring(group) .. " and " .. tostring(p_group))
    end
    user, group = p.user or user, p.group or group
    local own = p.limits or {}
    local why = limit_conflict("open_files", limits.open_files, own.open_files)
    if why == "" then why = limit_conflict("file_bytes", limits.file_bytes, own.file_bytes) end
    if why == "" then why = limit_conflict("cpu_seconds", limits.cpu_seconds, own.cpu_seconds) end
    if why == "" then why = limit_conflict("processes", limits.processes, own.processes) end
    limits.open_files = own.open_files or limits.open_files
    limits.file_bytes = own.file_bytes or limits.file_bytes
    limits.cpu_seconds = own.cpu_seconds or limits.cpu_seconds
    limits.processes = own.processes or limits.processes
    if why ~= "" then return refuse(why) end
  end
  local grants: mut {rules.Grant} = {}
  for _, held in ipairs(order) do
    local letters: mut {string} = {}
    for letter in pairs(held.letters) do letters[#letters + 1] = letter end
    -- Each policy was checked above, so every grant holds a letter of LETTERS.
    local canonical = canonical_letters(table.concat(letters))
    if canonical == nil then
      return refuse(path_of({ "grants" }) .. ": the grant of " .. held.path .. " holds no letter of \"" .. LETTERS .. "\"")
    end
    grants[#grants + 1] = { path = held.path, from = held.from, letters = canonical }
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
    if digests[name] ~= nil and digests[name] ~= Hash.hex_sha256(value) then
      return refuse(path_of({ "set_env_digests", name }) .. ": not the digest of set_env's value")
    end
    digests[name] = nil
  end
  local conflict = loopback_conflict(loopback, connect, true)
  if conflict ~= "" then return refuse(conflict) end
  local result: rules.Policy = {
    grants = grants, isolate = isolate, promises = promises,
    connect = connect, loopback = loopback, env = env, set_env = set_env,
    set_env_digests = digests, tmp = tmp, limits = limits,
    user = user, group = group, database = database,
  }
  return result, ""
end

--- The most open files a process under a policy may hold unless its
--- `open_files` says.
local DEFAULT_OPEN_FILES <const> = 1024

--- Whether `inner` is `outer` or a path beneath it, both cleaned: an
--- absolute path is never beneath a relative one, nor one beneath the
--- other.
local function within(inner: string, outer: string): boolean
  if inner == outer or outer == "/" and inner:sub(1, 1) == "/" then return true end
  if outer == "." then return inner:sub(1, 1) ~= "/" end
  return inner:sub(1, #outer + 1) == outer .. "/"
end

--- The letters of "rwxcu" both `a` and `b` hold, in that order; "" for none.
local function common_letters(a: string, b: string): string
  local out: mut {string} = {}
  for i = 1, #LETTERS do
    local letter = LETTERS:sub(i, i)
    if a:find(letter, 1, true) and b:find(letter, 1, true) then out[#out + 1] = letter end
  end
  return table.concat(out)
end

--- The members of `a` that `b` holds too, in `a`'s order.
local function common<T is Key>(a: {T}, b: {T}): {T}
  local in_b: mut {T:boolean} = {}
  for _, item in ipairs(b) do in_b[item] = true end
  local out: mut {T} = {}
  for _, item in ipairs(a) do
    if in_b[item] == true then out[#out + 1] = item end
  end
  return out
end

--- A `connect` target read for a meet: its kind ("any", "name", "ipv4",
--- "ipv6", or "tag" and "user" for the tailnet's), its host in canonical
--- form, and its port, 0 for any. Nil for a target neither reader takes,
--- which [`rules.merge`] has already refused.
local record Reach
  kind: string
  host: string
  port: integer
end

local function reach_of(target: string): Reach?
  local node, _ = Grant.tailnet(target)
  if node ~= nil then return { kind = node.kind, host = node.name, port = node.port } end
  local read, _ = Grant.parse(target)
  if read == nil then return nil end
  return { kind = read.kind, host = read.host, port = read.port }
end

--- `reach` written as a `connect` target again, canonical.
local function target_of(reach: Reach): string
  local port = if reach.port == 0 then "*" else tostring(reach.port) end
  if reach.kind == "user" then return "user:" .. reach.host .. ":" .. port end
  if reach.kind == "ipv6" then return "[" .. reach.host .. "]:" .. port end
  return reach.host .. ":" .. port
end

--- What two `connect` targets both reach, as the relay reads them, or nil
--- for nothing: a "*" host reaches every name and never an address or a
--- tailnet's node ([`cosmic.relay.grant`]), so it meets a name and leaves
--- the rest; any other host meets only itself, compared canonical; a port
--- of 0 (any) meets every port.
local function meet_targets(a: string, b: string): string?
  local ra, rb = reach_of(a), reach_of(b)
  if ra == nil or rb == nil then return nil end
  local host: Reach? = nil
  if ra.kind == "any" and (rb.kind == "any" or rb.kind == "name") then
    host = rb
  elseif rb.kind == "any" and ra.kind == "name" then
    host = ra
  elseif ra.kind == rb.kind and ra.host == rb.host then
    host = ra
  end
  if host == nil then return nil end
  local port = if ra.port == 0 then rb.port elseif rb.port == 0 or ra.port == rb.port then ra.port else -1 end
  if port < 0 then return nil end
  return target_of({ kind = host.kind, host = host.host, port = port })
end

--- The lower of two limits, either nil for none.
local function lower(a: integer?, b: integer?): integer?
  if a == nil then return b end
  if b == nil then return a end
  return math.min(a, b)
end

--- Why two values of a field that is not a right, either nil, disagree,
--- or "": a layer's `user`, `group` or `database` is what the start sets
--- up, so stacked layers must name the same one.
local function setup_conflict(name: string, a: string?, b: string?): string
  if a ~= nil and b ~= nil and a ~= b then
    return path_of({ name }) .. ": layers give two values, " .. a .. " and " .. b ..
      ", and a layer cannot narrow what the start sets up"
  end
  return ""
end

--- What two merged policies hold stacked: what both allow.
local function intersect_two(a: rules.Policy, b: rules.Policy): rules.Policy?, string
  local grants: mut {rules.Grant} = {}
  for _, ga in ipairs(a.grants or {}) do
    for _, gb in ipairs(b.grants or {}) do
      if ga.from ~= nil or gb.from ~= nil then
        if ga.path == gb.path and ga.from ~= gb.from then
          return refuse(path_of({ "grants" }) .. ": " .. ga.path .. " is mapped from two host paths, " ..
              tostring(ga.from or ga.path) .. " and " .. tostring(gb.from or gb.path))
        end
        if ga.path == gb.path then
          local letters = common_letters(ga.letters, gb.letters)
          if letters ~= "" then
            grants[#grants + 1] = { path = ga.path, from = ga.from, letters = letters }
          end
        elseif within(ga.path, gb.path) or within(gb.path, ga.path) then
          return refuse(path_of({ "grants" }) .. ": " .. ga.path .. " and " .. gb.path .. " nest, and one is mapped " ..
              "by from, which layers cannot intersect: give the mapped path in each layer")
        end
      else
        local deeper = if within(ga.path, gb.path) then ga.path elseif within(gb.path, ga.path) then gb.path else nil end
        if deeper ~= nil then
          local letters = common_letters(ga.letters, gb.letters)
          if letters ~= "" then grants[#grants + 1] = { path = deeper, letters = letters } end
        end
      end
    end
  end
  local connect: mut {string} = {}
  for _, ta in ipairs(a.connect or {}) do
    for _, tb in ipairs(b.connect or {}) do
      local met = meet_targets(ta, tb)
      if met ~= nil then connect[#connect + 1] = met end
    end
  end
  local function shown(value: integer?): string?
    if value == nil then return nil end
    return tostring(value)
  end
  local function path_of_database(database: rules.Database?): string?
    if database == nil then return nil end
    return database.path
  end
  local why = setup_conflict("user", shown(a.user), shown(b.user))
  if why == "" then why = setup_conflict("group", shown(a.group), shown(b.group)) end
  if why == "" then
    why = setup_conflict("database", path_of_database(a.database), path_of_database(b.database))
  end
  if why ~= "" then return refuse(why) end
  local la, lb = a.limits or {}, b.limits or {}
  local limits: rules.Limits = {
    -- A start holds a layer with no `open_files` to the default, so the
    -- lower of the two is taken against it.
    open_files = if la.open_files == nil and lb.open_files == nil then nil
      else lower(la.open_files or DEFAULT_OPEN_FILES, lb.open_files or DEFAULT_OPEN_FILES) end, file_bytes = lower(la.file_bytes, lb.file_bytes),
    cpu_seconds = lower(la.cpu_seconds, lb.cpu_seconds), processes = lower(la.processes, lb.processes),
  }
  -- What is not a right joins as a merge joins it: the variables set, and
  -- one user, group and database, refused where the two disagree.
  local result: rules.Policy = {
    grants = grants, isolate = sorted_set(a.isolate or {}, b.isolate or {}),
    promises = common(a.promises or {}, b.promises or {}), connect = connect,
    loopback = common(a.loopback or {}, b.loopback or {}), env = common(a.env or {}, b.env or {}),
    set_env = a.set_env, set_env_digests = a.set_env_digests, limits = limits,
    tmp = a.tmp == true and b.tmp == true, user = a.user or b.user, group = a.group or b.group,
    database = a.database or b.database,
  }
  local setup: rules.Policy = { set_env = b.set_env, set_env_digests = b.set_env_digests, database = b.database }
  return rules.merge(result, setup)
end

--- [`Sandbox.intersect`]: what the layers given hold stacked, merged.
function rules.intersect(...: rules.Policy): rules.Policy?, string
  local layers: {rules.Policy} = { ... }
  if #layers == 0 then return refuse("intersect needs a layer") end
  local held: rules.Policy? = nil
  for _, layer in ipairs(layers) do
    local merged, why = rules.merge(layer)
    if merged == nil then return nil, why end
    if held == nil then
      held = merged
    else
      local joined, joined_why = intersect_two(held, merged)
      if joined == nil then return nil, joined_why end
      held = joined
    end
  end
  return held, ""
end

--- [`Sandbox.allows`] of a policy already merged.
function rules.allows(p: rules.Policy, path: string, letters: string): boolean, string
  if letters == "" or letters:find("[^" .. LETTERS .. "]") ~= nil then
    return false, "sandbox: letters are of \"" .. LETTERS .. "\", at least one: " .. string.format("%q", letters)
  end
  local at = clean_path(path)
  local missing = letters
  for _, grant in ipairs(p.grants or {}) do
    if within(at, clean_path(grant.path)) then
      missing = missing:gsub("[" .. grant.letters .. "]", "")
    end
  end
  if missing == "" then return true, "" end
  return false, "sandbox: no grant gives " .. missing .. " on " .. at
end

--- `p` with `connect` in place of its own: what [`Child.start`] runs a
--- merged policy as once its tailnet targets are resolved
--- ([`cosmic.sandbox.tailnet`]).
function rules.with_connect(p: rules.Policy, connect: {string}): rules.Policy
  local result: rules.Policy = {
    grants = p.grants, isolate = p.isolate, promises = p.promises,
    connect = connect, loopback = p.loopback, env = p.env, set_env = p.set_env,
    set_env_digests = p.set_env_digests, tmp = p.tmp, limits = p.limits,
    user = p.user, group = p.group, database = p.database, profiles = p.profiles,
  }
  return result
end

--- The rlimits `limits` hold a process to, by the names spawn and
--- restriction take: `nofile` its `open_files`, or 1024 -- lowered to this
--- process's own hard limit, since a default is no reason to fail -- `core`
--- 0, so no core is dumped, and `fsize` and `cpu` where it gives them.
--- `processes` is the caller's to count.
function rules.rlimits(limits?: rules.Limits): mut {string:integer}
  local given = limits or {}
  local open_files = given.open_files
  if open_files == nil then
    open_files = DEFAULT_OPEN_FILES
    local held, _ = sys.getrlimit(sys.RLIMIT_NOFILE)
    if held ~= nil and held.hard < open_files then open_files = held.hard end
  end
  local rlimits: mut {string:integer} = { nofile = open_files, core = 0 }
  local file_bytes, cpu_seconds = given.file_bytes, given.cpu_seconds
  if file_bytes ~= nil then rlimits["fsize"] = file_bytes end
  if cpu_seconds ~= nil then rlimits["cpu"] = cpu_seconds end
  return rlimits
end

return rules
