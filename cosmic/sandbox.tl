--- A policy for a program held to nothing at all, and what it is built
--- from: plain typed records and pure functions. A [`Sandbox.Policy`]
--- names the paths a program reads, writes, runs and creates, the system
--- calls it makes, the environment it sees and the resources it spends;
--- what it does not name is refused. [`Child.start`] runs a child under
--- one (`Child.start(argv, { policy = p })`), and a policy is met or the
--- program does not start: there is no best-effort mode.
---
--- - [`Sandbox.decode`] reads a policy from JSON, strictly: a key it does
---   not know, a value of the wrong type or a letter outside "rwxcu" is
---   refused, naming the field by its JSON Pointer.
--- - [`Sandbox.merge`] joins policies into one: it resolves `profiles`,
---   joins the letters of a path, unions the lists, and refuses two values
---   for one `set_env` name or one limit.
--- - [`Sandbox.encode`] writes a merged policy as canonical JSON, the
---   same text for the same policy, with `set_env`'s values as digests.
--- - [`Sandbox.profile`] is what a named profile holds on this host:
---   "system" and "cosmic".
--- - [`Sandbox.loaders`] is what a program needs read and run to start.
--- - [`Sandbox.restrict`] holds the calling process, and what it starts,
---   to a policy for good.
---
---     local policy = assert(Sandbox.decode('{"grants":[{"path":"data","letters":"r"}],"tmp":true}'))
---     local merged = assert(Sandbox.merge(policy, { promises = { "fork" } }))
---     print(merged.grants[1].path, merged.promises[1]) -- data  fork
---
--- Nothing here raises on a policy's contents but [`Sandbox.encode`],
--- which takes a merged one: a failure answers `nil` and why, under the
--- module's name.
---
--- This is the policy's data and the host paths it names. What holds a
--- program to it is [`Child.start`]'s, or [`Sandbox.restrict`]'s for the
--- running process: Landlock for the paths, a seccomp filter for the
--- system calls, and rlimits. `isolate`, `connect`,
--- `loopback` and the `from`, `nest` and `processes` that need a
--- namespace are part of the policy but not yet met by it: a start under
--- one fails, saying so.

local Codec = require("cosmic.codec")
local Hash = require("cosmic.hash")
local Json = require("cosmic.json")
local Proc = require("cosmic.proc")
local Shape = require("cosmic.shape")
local sys = require("cosmic.sys")

-- What holds the running process lives in the raw process table, under
-- the reserved `cosmic.internal.` namespace -- see cosmic/store.tl for
-- why: its restriction takes the checks (threads, descriptors) with it.
local type raw_process = require("cosmic.internal.process")

local handed: any = select(2, ...)
local raw: raw_process
if type(handed) == "table" then
  raw = handed as raw_process
else
  raw = require("cosmic.internal.process")
end

local record Sandbox
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
    --- socket at the path. A grant on a directory reaches what is beneath
    --- it.
    letters: string
    --- The host's path, when it differs from `path`: the program sees this
    --- file or directory under another name. Needs `isolate` file.
    from: string
  end

  --- Resource limits on every process the program starts. Nil is the
  --- start's default: 1024 open files, no core dump, nothing else.
  record Limits
    --- The most descriptors a process may hold open (at least 1).
    open_files: integer
    --- The most bytes a process may write to one file.
    file_bytes: integer
    --- The CPU seconds a process may spend (at least 1). Soft and hard
    --- limit are the same, so a process past it is ended by SIGKILL, with
    --- no SIGXCPU to catch first.
    cpu_seconds: integer
    --- The most processes of the whole sandbox, counted by a user
    --- namespace (at least 1).
    processes: integer
  end

  --- What a program is held to; every field is optional, and what a policy
  --- leaves out it does not have.
  record Policy
    --- Named policies to join in, by [`Sandbox.merge`]: "system", "cosmic".
    profiles: {string}
    --- The paths the program reaches.
    grants: {Grant}
    --- How far it is isolated from the host.
    isolate: {Isolate}
    --- The system calls it may make beyond its basics.
    promises: {Promise}
    --- The hosts it may reach, "host:port", where the host or the port is
    --- "*" for any.
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
    --- hex. [`Sandbox.encode`] writes these, so the text shows a value
    --- changed without showing it; a policy that holds one, and no value
    --- for the name, cannot start a program.
    set_env_digests: {string:string}
    --- Whether the program has a fresh temporary directory of its own,
    --- named by `TMPDIR`, that it may write.
    tmp: boolean
    --- The resources it may spend.
    limits: Limits
  end

  --- What [`Sandbox.restrict`] takes beside the policy.
  record RestrictOptions
    --- The descriptors above 2 the process keeps open. Any other one it
    --- holds, bar the runtime's own, makes the call fail, since a
    --- restriction does not close a descriptor and what one names is
    --- reached whatever the grants say.
    fds: {integer}
  end
end

--- What a failure of this module answers: nil and `why` under its name.
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

--- Whether `target` is "host:port": a host that is not empty and holds
--- no blank or NUL, then "*" or a port from 1 to 65535.
local function connect_ok(target: string): boolean
  local host, port = target:match("^(.+):([^:]+)$")
  if host == nil or host:find("[%s%z]") then return false end
  if port == "*" then return true end
  if not port:match("^[1-9]%d*$") or #port > 5 then return false end
  local number = tonumber(port)
  return number >= 1 and number <= 65535
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
--- already in the order of "rwxcu", each once, as [`Sandbox.decode`] takes
--- them.
local function invalid(p: Sandbox.Policy, exact: boolean): string
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
    if not connect_ok(target) then
      return at("/connect/" .. (i - 1), "\"" .. target .. "\" is not host:port, the host or " ..
          "the port \"*\" for any")
    end
  end
  for i, address in ipairs(p.loopback or {}) do
    if not loopback_ok(address) then
      return at("/loopback/" .. (i - 1), "\"" .. address .. "\" is not an address of 127/8")
    end
  end
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
  local limits = p.limits or {}
  for _, why in ipairs({
      below("open_files", limits.open_files, 1), below("cpu_seconds", limits.cpu_seconds, 1),
      below("processes", limits.processes, 1), below("file_bytes", limits.file_bytes, 0),
  }) do
    if why ~= "" then return why end
  end
  return ""
end

local LIMITS_SPEC <const> = Shape.strict_record({
  open_files = Shape.optional(Shape.integer),
  file_bytes = Shape.optional(Shape.integer),
  cpu_seconds = Shape.optional(Shape.integer),
  processes = Shape.optional(Shape.integer),
})

local GRANT_SPEC <const> = Shape.strict_record({
  path = Shape.string,
  letters = Shape.string,
  from = Shape.optional(Shape.string),
})

local POLICY_SPEC <const> = Shape.strict_record({
  profiles = Shape.optional(Shape.list(Shape.string)),
  grants = Shape.optional(Shape.list(GRANT_SPEC)),
  isolate = Shape.optional(Shape.list(Shape.one_of("file", "proc"))),
  promises = Shape.optional(Shape.list(Shape.one_of("fork", "jit", "fattr", "nest"))),
  connect = Shape.optional(Shape.list(Shape.string)),
  loopback = Shape.optional(Shape.list(Shape.string)),
  env = Shape.optional(Shape.list(Shape.string)),
  set_env = Shape.optional(Shape.map(Shape.string)),
  set_env_digests = Shape.optional(Shape.map(Shape.string)),
  tmp = Shape.optional(Shape.boolean),
  limits = Shape.optional(LIMITS_SPEC),
})

--- The policy `json` holds. Strict: a key this module does not know, a
--- value of the wrong type, an `isolate` or a promise it does not name,
--- a profile it has not, and a grant whose `letters` are not in the order
--- of "rwxcu", each once, are refused, naming the field by its JSON
--- Pointer (`pointer "/grants/0/letters": ...`, arrays counted from 0).
--- A hand-built [`Sandbox.Policy`] is judged by [`Sandbox.merge`]
--- instead, which takes any order of letters and writes them in this one.
---
---     local policy = assert(Sandbox.decode('{"env":["HOME"],"tmp":true}'))
---     print(policy.env[1], policy.tmp) -- HOME  true
---     local bad, why = Sandbox.decode('{"grants":[{"path":"x","letters":"xr"}]}')
---     print(why) -- sandbox: pointer "/grants/0/letters": "xr" is not in the order of "rwxcu", each letter once: "rx"
function Sandbox.decode(json: string): Sandbox.Policy | nil, string
  local policy, why: Sandbox.Policy | nil, string = Shape.decode_into(json, POLICY_SPEC)
  if policy == nil then return refuse(why) end
  local bad = invalid(policy, true)
  if bad ~= "" then return refuse(bad) end
  return policy, ""
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

--- The SHA-256 of `value`, in lowercase hex.
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

--- The paths of the "system" profile and what each is for, read and
--- run, or read, or written: the host's, filtered to those that exist.
local SYSTEM_PATHS <const>: {{string}} = {
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

--- The "system" profile: what the host gives a dynamically linked program
--- to run. A path of `SYSTEM_PATHS` is granted when it exists here, so the
--- same profile fits a host with and without a /lib64.
local function system_profile(): Sandbox.Policy
  local grants: {Sandbox.Grant} = {}
  for _, entry in ipairs(SYSTEM_PATHS) do
    local found, _ = sys.stat(entry[1])
    if found ~= nil then
      grants[#grants + 1] = { path = entry[1], letters = entry[2] }
    end
  end
  return { grants = grants }
end

--- The "cosmic" profile: `rx` on what [`Proc.executable`] names, which is
--- the path this program is started by: under a development build or a
--- portable artifact that is the launcher (a `#!/bin/sh` script) or the
--- artifact, not the native core the launcher runs. It is the grant a
--- policy needs to start that path, and not enough for the core to run.
-- TODO: grant what the core needs to run past its launcher -- the native
-- core, the core cache it unpacks to, the descriptors Proc.relaunch hands
-- it, and the shell and libraries the launcher itself runs -- once the
-- test harness starts its workers under a policy and needs a child of
-- this program to run: today a child of the launcher under "system" and
-- "cosmic" cannot fork or find its cache.
local function cosmic_profile(): Sandbox.Policy | nil, string
  local path, why = Proc.executable()
  if path == nil then
    return refuse("profile \"cosmic\": this process has no executable: " .. why)
  end
  return { grants = { { path = path, letters = "rx" } } }, ""
end

--- What the profile `name` holds on this host, as a policy: "system"
--- grants the host's programs, libraries and the few files a libc reads to
--- start (`rx` on /usr and the library and binary directories, `r` on
--- /etc/ld.so.cache, nsswitch.conf, passwd, group and localtime, and the
--- null, zero and random devices), each only where it exists; "cosmic"
--- grants `rx` on the path this program is started by ([`Proc.executable`]),
--- which is its launcher where it has one, so a child of this program
--- needs more than the profile gives.
--- Nil and why for a name it has not, or one this host cannot give.
---
---     local system = assert(Sandbox.profile("system"))
---     print(system.grants[1].path, system.grants[1].letters) -- /usr  rx
function Sandbox.profile(name: string): Sandbox.Policy | nil, string
  if name == "system" then return system_profile(), "" end
  if name == "cosmic" then return cosmic_profile() end
  return refuse("unknown profile \"" .. tostring(name) .. "\" (known: " ..
      table.concat(PROFILES, ", ") .. ")")
end

--- What the policies given hold together: each one's `profiles` resolved
--- ([`Sandbox.profile`]) and joined in before the policy's own, then
--- the grants joined by path (and `from`): the letters of one path are
--- the union of each grant's, in the order of "rwxcu", whatever order
--- they came in; each path is cleaned first ("a//b/./c/" is "a/b/c"; a
--- ".." is refused, since cleaning it could name another directory than
--- the kernel does after a link). Lists are unions, each member once, sorted; `tmp`
--- holds if any policy has it; a limit is the one value given, and
--- two different values for one limit are refused, as two different
--- values for one `set_env` name are (without saying them: they may be
--- secrets). A name with a value in one policy and a digest in another
--- must have the value's digest. The answer has no `profiles`, and every
--- list and table of it, empty or not, and `isolate` "file" holds "proc"
--- too, which it implies: it is what [`Sandbox.encode`] writes and
--- [`Child.start`] meets. A value a policy's type does not stop -- an
--- unknown profile, a letter outside "rwxcu", a malformed address -- is
--- refused naming its field, as [`Sandbox.decode`] does.
---
---     local a = { grants = { { path = "/srv", letters = "x" } }, promises = { "fork" } }
---     local b = { grants = { { path = "/srv", letters = "r" } }, promises = { "fork", "jit" } }
---     local merged = assert(Sandbox.merge(a, b))
---     print(merged.grants[1].letters, table.concat(merged.promises, ",")) -- rx  fork,jit
function Sandbox.merge(...: Sandbox.Policy): Sandbox.Policy | nil, string
  local flat: {Sandbox.Policy} = {}
  for _, p in ipairs({ ... }) do
    local bad = invalid(p, false)
    if bad ~= "" then return refuse(bad) end
    for _, name in ipairs(p.profiles or {}) do
      local profile, why = Sandbox.profile(name)
      if profile == nil then return nil, why end
      flat[#flat + 1] = profile
    end
    flat[#flat + 1] = p
  end
  local joined: {string:Joined} = {}
  local order: {Joined} = {}
  local limits: Sandbox.Limits = {}
  local set_env: {string:string} = {}
  local digests: {string:string} = {}
  local isolate: {Sandbox.Isolate} = {}
  local promises: {Sandbox.Promise} = {}
  local connect: {string} = {}
  local loopback: {string} = {}
  local env: {string} = {}
  local tmp = false
  for _, p in ipairs(flat) do
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
  local grants: {Sandbox.Grant} = {}
  for _, held in ipairs(order) do
    local letters: {string} = {}
    for letter in pairs(held.letters) do letters[#letters + 1] = letter end
    grants[#grants + 1] = { path = held.path, from = held.from,
      letters = canonical_letters(table.concat(letters)) }
  end
  table.sort(grants, function(a: Sandbox.Grant, b: Sandbox.Grant): boolean
    if a.path ~= b.path then return a.path < b.path end
    return (a.from or "") < (b.from or "")
  end)
  -- `file` implies `proc`: written out, so the two spellings are one policy.
  local implied: Sandbox.Isolate = "proc"
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
  return {
    grants = grants, isolate = isolate, promises = promises,
    connect = connect, loopback = loopback, env = env, set_env = set_env,
    set_env_digests = digests, tmp = tmp, limits = limits,
  }, ""
end

--- A merged policy as canonical JSON: keys in byte order, lists sorted,
--- a field with nothing in it left out, `profiles` resolved away, and
--- `set_env`'s values written as `set_env_digests`, so the text names a
--- variable and shows its value changed without showing it. The same
--- policy is the same text, and [`Sandbox.decode`] reads it back to a
--- policy that encodes to the same text again. A digest is the SHA-256 of
--- the value, unsalted: one of a value that can be guessed (a short
--- password, a flag) can be found by trying guesses, so a printed policy
--- keeps a value's change from view, not a secret from a reader who can
--- guess it. What a profile names is a path of this host, so an encoding
--- that resolved one is one host's. Raises for a policy that
--- is not merged -- one with `profiles`, or [`Sandbox.merge`] would refuse
--- -- since text cannot say what was dropped.
---
---     local text = Sandbox.encode(assert(Sandbox.merge({ tmp = true, set_env = { MODE = "fast" } })))
---     print(text) -- {"set_env_digests":{"MODE":"..."},"tmp":true}
function Sandbox.encode(p: Sandbox.Policy): string
  if p.profiles ~= nil and #p.profiles > 0 then
    error("sandbox: encode takes a merged policy: resolve profiles with Sandbox.merge first", 2)
  end
  local made, why = Sandbox.merge(p)
  if made == nil then error(why, 2) end
  local merged: Sandbox.Policy = made
  local digests: {string:string} = {}
  for name, digest in pairs(merged.set_env_digests) do digests[name] = digest end
  for name, value in pairs(merged.set_env) do digests[name] = digest_of(value) end
  local fields: {string:any} = {}
  local function put(name: string, list: {any})
    if #list > 0 then fields[name] = list end
  end
  put("isolate", merged.isolate)
  put("promises", merged.promises)
  put("connect", merged.connect)
  put("loopback", merged.loopback)
  put("env", merged.env)
  local grants: {{string:string}} = {}
  for _, grant in ipairs(merged.grants) do
    grants[#grants + 1] = { path = grant.path, letters = grant.letters, from = grant.from }
  end
  put("grants", grants)
  if next(digests) ~= nil then fields.set_env_digests = digests end
  if merged.tmp then fields.tmp = true end
  local limits = merged.limits
  if limits.open_files ~= nil or limits.file_bytes ~= nil or limits.cpu_seconds ~= nil or
      limits.processes ~= nil then
    fields.limits = limits
  end
  return (assert(Json.encode(fields)))
end

--- How deep a chain of `#!` interpreters [`Sandbox.loaders`] follows,
--- as the kernel does (it follows four).
local MAX_CHAIN <const> = 4

--- How much of a program's start is read for its `#!` line or its ELF
--- header and program headers.
local HEAD <const> = 4096

local PT_INTERP <const> = 3

--- The unsigned integer of `width` bytes at `position` of `bytes`, written
--- little-endian where `little` and big-endian otherwise.
local function unsigned(bytes: string, position: integer, width: integer, little: boolean): integer
  local value = 0
  for i = 0, width - 1 do
    local byte = bytes:byte(little and position + width - 1 - i or position + i)
    value = value << 8 | byte
  end
  return value
end

--- The ELF interpreter `head` (the start of the file `fd` is open on) names,
--- from its PT_INTERP segment; nil for a file that is not an ELF, has none,
--- or whose segment this cannot read.
local function elf_interpreter(fd: integer, head: string): string | nil
  if head:sub(1, 4) ~= "\127ELF" or #head < 64 then return nil end
  local class, data = head:byte(5), head:byte(6)
  if (class ~= 1 and class ~= 2) or (data ~= 1 and data ~= 2) then return nil end
  local little = data == 1
  local wide = class == 2
  local offset = wide and unsigned(head, 33, 8, little) or unsigned(head, 29, 4, little)
  local size = unsigned(head, wide and 55 or 43, 2, little)
  local count = unsigned(head, wide and 57 or 45, 2, little)
  if size < 32 or count > 256 then return nil end
  for i = 0, count - 1 do
    local entry, _ = sys.pread(fd, size, offset + i * size)
    if entry == nil or #entry < size then return nil end
    if unsigned(entry, 1, 4, little) == PT_INTERP then
      local at = wide and unsigned(entry, 9, 8, little) or unsigned(entry, 5, 4, little)
      local length = wide and unsigned(entry, 33, 8, little) or unsigned(entry, 17, 4, little)
      if length < 2 or length > 4096 then return nil end
      local name, _ = sys.pread(fd, length, at)
      if name == nil then return nil end
      return (name:match("^[^%z]+"))
    end
  end
  return nil
end

--- `path` made absolute against `cwd` (the process's own when nil).
local function absolute(path: string, cwd?: string): string | nil, string
  if path:sub(1, 1) == "/" then return path end
  local base = cwd
  if base == nil then
    local got, why = sys.getcwd()
    if got == nil then return nil, why end
    base = got
  end
  return base .. "/" .. path
end

--- The file the kernel reads to start a program, past its own bytes: the
--- `#!` interpreter or the ELF interpreter it names, as written.
local function interpreter_of(path: string): string | nil
  local fd, _ = sys.open(path, sys.O_RDONLY)
  if fd == nil then return nil end
  local head, _ = sys.read(fd, HEAD)
  local found: string | nil
  if head ~= nil then
    found = head:match("^#!%s*([^%s]+)") or elf_interpreter(fd, head)
  end
  local _, _ = sys.close(fd)
  return found
end

--- What the program at `path` needs to start, as real paths with no link
--- left in them: the program itself first, then the interpreter its `#!`
--- line or its ELF header (PT_INTERP) names, then that one's, as far as the
--- kernel follows. The files a policy must grant `r` and `x` for the
--- program to start at all. `path` is relative to `cwd` (this process's
--- directory when nil). Nil and why when the program or an interpreter it
--- names does not exist.
---
--- A script that starts with `#!/usr/bin/env python3` names /usr/bin/env;
--- the program env then finds is its own start, which this cannot know.
-- TODO: name the program `env` finds, searching the policy's own PATH
-- (`set_env` or the caller's `env`), for a `#!/usr/bin/env` script, so a
-- policy that omits it fails the start rather than the script's run,
-- once a start knows the environment the program will run in.
---
---     local files = assert(Sandbox.loaders("/bin/sh"))
---     print(#files >= 1) -- true
function Sandbox.loaders(path: string, cwd?: string): {string} | nil, string
  local files: {string} = {}
  local seen: {string:boolean} = {}
  local at = path
  for _ = 0, MAX_CHAIN do
    local whole, why = absolute(at, cwd)
    if whole == nil then return refuse(why) end
    local real, trouble = sys.realpath(whole)
    if real == nil then return refuse(whole .. ": " .. trouble) end
    if seen[real] then break end
    seen[real] = true
    files[#files + 1] = real
    local next_file = interpreter_of(real)
    if next_file == nil then break end
    at = next_file
  end
  return files, ""
end

--- The most open files a restricted process may hold, unless a policy's
--- `open_files` says: what [`Child.start`] gives a child.
local DEFAULT_OPEN_FILES <const> = 1024

--- What a failure of [`Sandbox.restrict`] answers: false and `why`.
local function denied(why: string): boolean, string
  return false, "sandbox: restrict: " .. why
end

--- Why a merged policy cannot hold the running process, or "": what it
--- names that only a child can have, which is made in a namespace the
--- process is not in, or by a relay it has not.
local function not_in_process(merged: Sandbox.Policy): string
  if #merged.isolate > 0 then
    return "isolate \"" .. merged.isolate[1] .. "\" needs a namespace of its own: start " ..
      "a child with Child.start and a policy instead"
  end
  if #merged.connect > 0 then
    return "connect \"" .. merged.connect[1] .. "\" needs a relay in a network namespace of " ..
      "its own: start a child with Child.start and a policy instead"
  end
  if #merged.loopback > 0 then
    return "loopback \"" .. merged.loopback[1] .. "\" needs a network namespace of its own: " ..
      "start a child with Child.start and a policy instead"
  end
  for _, promise in ipairs(merged.promises) do
    if promise == "nest" then
      return "promises \"nest\" needs isolate file, which only a child can have"
    end
  end
  for _, grant in ipairs(merged.grants) do
    if grant.from ~= nil then
      return "grant \"" .. grant.path .. "\" has from, which needs isolate file, which only a " ..
        "child can have"
    end
    if grant.letters:find("u", 1, true) then
      -- The filter refuses socket(), so a grant to connect to a unix
      -- socket by path could not be used by the process that holds it.
      return "grant \"" .. grant.path .. "\" has u, which needs the network isolated and " ..
        "a socket the filter allows: start a child with Child.start and a policy instead"
    end
  end
  if next(merged.env) ~= nil then
    return "env \"" .. merged.env[1] .. "\" is the environment of a child, which a running " ..
      "process already has"
  end
  for name, _ in pairs(merged.set_env) do
    return "set_env \"" .. name .. "\" is the environment of a child, which a running " ..
      "process already has"
  end
  for name, _ in pairs(merged.set_env_digests) do
    return "set_env_digests \"" .. name .. "\" holds a digest, not a value to set"
  end
  if merged.tmp then
    return "tmp is a directory made for a child, which a running process makes for itself"
  end
  if merged.limits.processes ~= nil then
    return "limits.processes counts the processes of a user namespace of its own, which only " ..
      "a child has"
  end
  return ""
end

--- Holds the calling process, and everything it starts, for good to the
--- policy's `grants`, `promises` and `limits`: Landlock holds the paths
--- (a process with no grant reaches no file, its own program and the
--- files it has open aside), a seccomp filter the system calls, and
--- rlimits the resources, set first, since the filter refuses setrlimit.
--- Nothing lifts it, and the process cannot start a program its grants
--- do not let run. The policy is merged first ([`Sandbox.merge`]), so it
--- may name `profiles`, and its limits have a child's defaults: no core
--- dump and 1024 open files; a limit is only ever lowered, never
--- raised. `cpu_seconds` is RLIMIT_CPU, which counts the CPU time the
--- process has already spent: lowering it below that on a process that has
--- run long ends it by SIGKILL at once.
---
--- Called again, it narrows: the kernel holds the process to every
--- ruleset and every filter made, so what a later call grants beyond
--- an earlier one's has no effect. Its limits narrow likewise, but a
--- limit lower than the process already has needs `setrlimit`, which an
--- earlier call's filter refuses: give every limit in the first call.
---
--- It fails, and holds the process to nothing it was not, for what only
--- a child can be held to -- `isolate`, `connect`, `loopback`, a grant's
--- `from` or `u`, the `nest` promise, `env`, `set_env`, `tmp` and
--- `limits.processes`, each failing by its name -- and while the process
--- has another thread (a restriction binds the thread that makes it), a
--- child not yet waited for, or a descriptor above 2 that `fds` does not
--- name, bar the ones the runtime keeps itself: this program's own
--- artifact and the databases of its store. A restriction does not
--- close a descriptor, and what one names is reached whatever the grants
--- say, so a caller names the ones it keeps. The runtime's own descriptors
--- stay open and read-only, so a restricted process still reads the whole
--- store through them, the modules a test's closure leaves out among them.
--- A failure from the kernel's own calls, which come after those checks,
--- can leave the limits it lowered, and its ruleset if the filter is what
--- failed; its message then ends "the process is now partly restricted".
---
--- The filter's rules for signals take this process's pid, so a process
--- started afterwards, which has another, cannot signal itself, and its
--- abort() ends by SIGSEGV, until Landlock's signal scope (ABI 6, which
--- the ruleset sets where the kernel has it) holds signals instead.
--- Linux only; elsewhere it fails, saying so (Seatbelt waits for the
--- design's phase 8).
-- TODO: hold a process by Seatbelt on macOS, once the design's phase 8
-- lands.
function Sandbox.restrict(policy: Sandbox.Policy, options?: Sandbox.RestrictOptions): boolean, string
  local merged, why = Sandbox.merge(policy)
  if merged == nil then return false, why end
  local trouble = not_in_process(merged)
  if trouble ~= "" then return denied(trouble) end
  local kept: {integer} = {}
  for _, fd in ipairs(options and options.fds or {}) do
    if math.type(fd) ~= "integer" or fd < 3 then
      return denied("fds names " .. tostring(fd) .. ", which is not a descriptor above 2")
    end
    kept[#kept + 1] = fd
  end
  local grants: {raw_process.Grant} = {}
  for _, grant in ipairs(merged.grants) do
    grants[#grants + 1] = { path = grant.path, access = grant.letters }
  end
  local rlimits: {string:integer} = { nofile = merged.limits.open_files or DEFAULT_OPEN_FILES,
    core = 0 }
  rlimits.fsize = merged.limits.file_bytes
  rlimits.cpu = merged.limits.cpu_seconds
  local promises: {string} = {}
  for _, promise in ipairs(merged.promises) do promises[#promises + 1] = promise end
  local done, held, failure = raw.restrict_self({ grants = grants, promises = promises,
    rlimits = rlimits }, kept)
  if not done then
    if failure == sys.ENOSYS then
      return denied("this system cannot hold a process: it needs Landlock and seccomp, " ..
          "which only Linux gives")
    end
    return denied(held)
  end
  return true, ""
end

return Sandbox
