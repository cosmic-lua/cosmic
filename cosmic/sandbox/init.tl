--- A policy for a program held to nothing at all, and what it is built
--- from: plain typed records and pure functions. A [`Sandbox.Policy`]
--- names the paths a program reads, writes, runs and creates, the system
--- calls it makes, the environment it sees and the resources it spends;
--- what it does not name is refused. [`Child.start`] runs a child under
--- one (`Child.start(argv, { policy = p })`), and a policy is met or the
--- program does not start: there is no best-effort mode.
---
--- - [`Sandbox.merge`] joins policies into one: it resolves `profiles`,
---   joins the letters of a path, unions the lists, and refuses two values
---   for one `set_env` name or one limit.
--- - [`Sandbox.profile`] is what a named profile holds on this host:
---   "system" and "cosmic".
--- - [`Sandbox.loaders`] is what a program needs read and run to start.
--- - [`Sandbox.restrict`] holds the calling process, and what it starts,
---   to a policy for good.
--- - [`Sandbox.check`] says whether a policy's values are ones a policy
---   may hold.
---
--- A policy's JSON text, read and written, is [`cosmic.policy`]'s,
--- apart from this module so that a program that only runs a child under a
--- policy does not carry a JSON reader and a schema checker.
---
---     local policy = { grants = { { path = "data", letters = "r" } }, tmp = true }
---     local merged = assert(Sandbox.merge(policy, { promises = { "fork" } }))
---     print(merged.grants[1].path, merged.promises[1]) -- data  fork
---
--- Nothing here raises on a policy's contents: a failure answers `nil`
--- and why, under the module's name.
---
--- This is the policy's data and the host paths it names. What holds a
--- program to it is [`Child.start`]'s, or [`Sandbox.restrict`]'s for the
--- running process: Landlock for the paths (the root of `isolate` file
--- alone, under the `nest` promise, which Landlock's refusal of mounts
--- gives up), a seccomp filter for the system calls, and rlimits, and,
--- for a child, the namespaces `isolate`, `loopback`, a `u` grant and
--- `limits.processes` need. `connect` needs a network relay, which a
--- child's start runs ([`Child.start`]): in the child's own network on
--- Linux, and on macOS on the host's loopback behind a token. On macOS a
--- Seatbelt profile holds a child and the running process alike
--- ([`Seatbelt.compile`]).

local Proc = require("cosmic.proc")
local rules = require("cosmic.sandbox.policy")
local Relay = require("cosmic.sandbox.relay")
local Seatbelt = require("cosmic.sandbox.seatbelt")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
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
  --- How far a program is isolated from the host
  --- ([`rules.Isolate`]).
  type Isolate = rules.Isolate

  --- A part of what a program may do beyond its basics
  --- ([`rules.Promise`]): `fork`, `jit`, `fattr`, `nest`.
  type Promise = rules.Promise

  --- One path a program may reach, and how ([`rules.Grant`]).
  type Grant = rules.Grant

  --- Resource limits on every process the program starts
  --- ([`rules.Limits`]).
  type Limits = rules.Limits

  --- What a program is held to; every field is optional, and what a policy
  --- leaves out it does not have ([`rules.Policy`]).
  type Policy = rules.Policy

  --- What holds a program by a policy on macOS: the package's
  --- [`cosmic.sandbox.seatbelt`], whose `compile` makes a policy's Seatbelt
  --- profile, `resolve` reads the host paths it names and `grants` lists
  --- what it reaches, each documented there. [`Child.start`] holds a child
  --- by it, and [`Sandbox.restrict`] the running process.
  Seatbelt: Seatbelt

  --- What the starter of a policy's network relay reads and decides before
  --- the relay runs: the package's [`cosmic.sandbox.relay`], whose `policy`
  --- is the relay's own (`seatbelt_policy` on macOS), `plan` what a policy's `connect` targets open,
  --- `table`, `public` and `name_servers` the connectors [`Child.start`]
  --- hands the relay, and `upstream_addresses` the one lookup of the
  --- upstream proxy (`resolved_upstream` on macOS), each documented there.
  Relay: Relay

  --- What [`Sandbox.reach`] finds.
  record Reach
    --- Who gives the user its rights: "user" (its own bits, as owner or
    --- group, where it was named), "other", "owner" or "" for no one.
    by: string
    --- With no one, what its owner lacks, as words.
    lacks: string
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

Sandbox.Seatbelt = Seatbelt
Sandbox.Relay = Relay

--- What a failure of this module answers: nil and `why` under its name.
local function refuse(why: string): nil, string
  return nil, "sandbox: " .. why
end

--- Whether the values of `p` are ones a policy may hold: `true`, or
--- `false` and why, naming the field by its JSON Pointer
--- (`pointer "/grants/0/letters": ...`, arrays counted from 0). What a
--- type holds is not looked at again, only what it does not stop: an
--- unknown profile, a letter outside "rwxcu", a malformed address, a
--- ".." in a path. With `exact`, a grant's `letters` must also be in the
--- order of "rwxcu", each once, as the text [`PolicyJson.decode`] reads is;
--- [`Sandbox.merge`] takes any order and writes this one.
---
---     local ok, why = Sandbox.check({ grants = { { path = "x", letters = "xr" } } }, true)
---     print(ok, why) -- false  sandbox: pointer "/grants/0/letters": "xr" is not in the order of "rwxcu", each letter once: "rx"
function Sandbox.check(p: Sandbox.Policy, exact?: boolean): boolean, string
  return rules.check(p, exact)
end

--- What the profile `name` holds on this host, as a policy: "system"
--- grants the host's programs, libraries and the few files a libc reads to
--- start (`rx` on /usr and the library and binary directories, `r` on
--- /etc/ld.so.cache, nsswitch.conf, passwd, group and localtime, and the
--- null, zero and random devices), each only where it exists; on macOS
--- it is macOS's own list instead (/usr, /bin, /sbin, the system
--- frameworks and dyld's cryptexes and state, the accounts and time zone,
--- and the same devices), the list a policy naming "system" is held to
--- there without being merged, so the profile means the same given
--- directly, merged or through [`PolicyJson.decode`]; "cosmic"
--- grants `rx` on the path this program is started by ([`Proc.executable`]),
--- which is its launcher where it has one: what [`Child.start`] runs as
--- this program's core, by a relaunch.
--- Nil and why for a name it has not, or one this host cannot give.
---
---     local system = assert(Sandbox.profile("system"))
---     print(system.grants[1].path, system.grants[1].letters) -- /usr  rx
function Sandbox.profile(name: string): Sandbox.Policy | nil, string
  return rules.profile(name)
end

--- Records that `policy`, whose `database` was read from text naming
--- `digest` (the SHA-256 of its bytes, in hex), is to run only on a file
--- of that digest: [`Sandbox.database_is`] holds a start to it, and a merge
--- of the policy keeps it. [`PolicyJson.decode`] calls it after
--- checking the file.
---
---     local p: Sandbox.Policy = { database = "/srv/p.db" }
---     Sandbox.expect_digest(p, string.rep("0", 64))
function Sandbox.expect_digest(policy: Sandbox.Policy, digest: string)
  rules.expect_digest(policy, digest)
end

--- Whether the file at `path` (the merged policy's database, by its real
--- path) is the one `merged` was checked against: true where it hashes to
--- the digest [`Sandbox.expect_digest`] recorded for it or for a policy
--- merged into it, or where none was recorded; otherwise false and why.
--- [`Child.start`] asks just before it starts the core on the file.
---
---     print(Sandbox.database_is({}, "/nowhere")) -- true
function Sandbox.database_is(merged: Sandbox.Policy, path: string): boolean, string
  return rules.database_is(merged, path)
end

--- What the policies given hold together: each one's `profiles` resolved
--- ([`Sandbox.profile`]) and joined in before the policy's own, then
--- the grants joined by path (and `from`): the letters of one path are
--- the union of each grant's, in the order of "rwxcu", whatever order
--- they came in; each path is cleaned first ("a//b/./c/" is "a/b/c"; a
--- ".." is refused, since cleaning it could name another directory than
--- the kernel does after a link). Lists are unions, each member once, sorted; `tmp`
--- holds if any policy has it; a limit, `user` and `group` are the one
--- value given, and two different values for one are refused, as two different
--- values for one `set_env` name are (without saying them: they may be
--- secrets). Two different `database`s are refused too, and with one given
--- the "cosmic" profile resolves to nothing, since its grant is of this
--- program's own file, which a program on a database is not given. A name
--- with a value in one policy and a digest in another must have the
--- value's digest. The answer has no `profiles`, and every
--- list and table of it, empty or not, and `isolate` "file" holds "proc"
--- too, which it implies: it is what [`PolicyJson.encode`] writes and
--- [`Child.start`] meets. A value a policy's type does not stop -- an
--- unknown profile, a letter outside "rwxcu", a malformed address -- is
--- refused naming its field, as [`PolicyJson.decode`] does.
---
---     local a = { grants = { { path = "/srv", letters = "x" } }, promises = { "fork" } }
---     local b = { grants = { { path = "/srv", letters = "r" } }, promises = { "fork", "jit" } }
---     local merged = assert(Sandbox.merge(a, b))
---     print(merged.grants[1].letters, table.concat(merged.promises, ",")) -- rx  fork,jit
function Sandbox.merge(...: Sandbox.Policy): Sandbox.Policy | nil, string
  return rules.merge(...)
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

-- What the restriction calls of other modules, taken as it loads, so a
-- caller that replaces a library table's member does not change it.
local executable_path <const> = Proc.executable
local store_paths <const> = Store.paths
local store_databases <const> = Store.databases
local text_rows <const> = Sqlite.text_rows
local stat <const> = sys.stat
local uname <const> = sys.uname
local seatbelt_resolve <const> = Seatbelt.resolve
local seatbelt_compile <const> = Seatbelt.compile

--- Whether this is macOS, which holds a process by Seatbelt.
local function darwin(): boolean
  local names, _ = uname()
  return names ~= nil and names.sysname == "Darwin"
end

--- What a failure of [`Sandbox.restrict`] answers: false and `why`.
local function denied(why: string): boolean, string
  return false, "sandbox: restrict: " .. why
end

--- Why a merged policy cannot hold the running process, or "": what it
--- names that only a child can have, which is made in a namespace the
--- process is not in, or by a relay it has not.
local function not_in_process(merged: Sandbox.Policy): string
  if merged.database ~= nil then
    return "database \"" .. merged.database .. "\" is the program a child runs on, which a " ..
      "running process cannot change: start a child with Child.start and a policy instead"
  end
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
      if darwin() then
        -- TODO: hold a `u` grant on macOS, which Seatbelt.compile writes as
        -- network-outbound to the path, as a child's profile has it, once a
        -- test connects a restricted process to a granted socket and is
        -- refused another.
        return "grant \"" .. grant.path .. "\" has u, which a restriction on macOS does not " ..
          "hold yet: start a child with Child.start and a policy instead"
      end
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
  if merged.user ~= nil and (merged.user ~= sys.getuid() or
      (merged.group ~= nil and merged.group ~= sys.getgid())) then
    return "user " .. merged.user .. " is who a child runs as; a running process stays the " ..
      "user it is (" .. sys.getuid() .. ")"
  end
  return ""
end

--- Why the store keeps a restriction from holding, or "" for nothing: a
--- database of it in WAL mode, or one that cannot be read. SQLite holds a
--- WAL database's write-ahead log open for writing, though it opens the
--- database read-only, and makes the log afresh at a read after the last
--- connection closed it: a restriction can neither keep the program from
--- writing that log, which would change what the store reads, nor let
--- SQLite make it again. Each database is read once first, so that one in
--- WAL mode has its log, which is how it is told (the store's connections
--- may not ask its journal mode, and a database inside this program's own
--- file has its header at no offset a path tells).
local function store_unheld(): string
  for _, db in ipairs(store_databases()) do
    local rows, why = text_rows(db, "SELECT count(*) FROM sqlite_schema")
    if rows == nil then return "the store cannot be read: " .. why end
  end
  for _, path in ipairs(store_paths()) do
    if path:sub(-4) == "-wal" then
      local found, why, errno = stat(path)
      if found ~= nil then
        return "the store's database " .. path:sub(1, -5) .. " is in WAL mode: SQLite keeps " ..
          "its log open for writing, and makes it again once closed, which a restriction can " ..
          "neither keep from the program nor allow"
      end
      if errno ~= sys.ENOENT then
        return "whether the store's database " .. path:sub(1, -5) .. " is in WAL mode cannot " ..
          "be told: " .. path .. ": " .. why
      end
    end
  end
  return ""
end

--- What a process restricted on macOS is granted beside its policy, so
--- that the runtime still reaches its own files by path, which a profile
--- refuses like any other it does not grant (an open descriptor it does
--- not check): each file of the store ([`Store.paths`]) that is there,
--- read, and its shared-memory file read and written, as SQLite opens
--- it; and this program's own file ([`Proc.executable`]), read and run.
--- A write-ahead log is read alone, never written or made: one this
--- process could write would change what the store reads (and the
--- restriction refuses a database in WAL mode, which has one).
-- TODO: grant a portable start's unpacked core too, once its path can be
-- had without opening it: [`Proc.relaunch`] names it, but holds a descriptor
-- on it from then on, which the restriction's check of descriptors refuses.
local function runtime_grants(): {Sandbox.Grant}
  local grants: {Sandbox.Grant} = {}
  for _, path in ipairs(store_paths()) do
    local found, _ = stat(path)
    if found ~= nil then
      grants[#grants + 1] = { path = path, letters = path:sub(-4) == "-shm" and "rw" or "r" }
    end
  end
  local executable, _ = executable_path()
  if executable ~= nil then grants[#grants + 1] = { path = executable, letters = "rx" } end
  return grants
end

--- [`Sandbox.restrict`] on macOS: the policy as the profile
--- [`Seatbelt.compile`] makes of it, with [`runtime_grants`] beside its
--- own, applied to this process with its limits. `policy` is the caller's,
--- which [`not_in_process`] passed: the profile resolves "system" to
--- macOS's paths, not the Linux ones [`Sandbox.merge`] gives.
local function held_by_seatbelt(policy: Sandbox.Policy, kept: {integer}): boolean, string
  local grants: {Sandbox.Grant} = {}
  for _, grant in ipairs(policy.grants or {}) do grants[#grants + 1] = grant end
  for _, grant in ipairs(runtime_grants()) do grants[#grants + 1] = grant end
  local held: Sandbox.Policy = { profiles = policy.profiles, grants = grants,
    promises = policy.promises, limits = policy.limits, user = policy.user, group = policy.group }
  local executable, _ = executable_path()
  local options, resolve_trouble = seatbelt_resolve(held, nil, executable)
  if options == nil then return denied(resolve_trouble) end
  local profile, compile_trouble = seatbelt_compile(held, options)
  if profile == nil then return denied(compile_trouble) end
  local parameters = 0
  for _, _ in pairs(profile.parameters) do parameters = parameters + 1 end
  if parameters > raw.SEATBELT_PARAMETER_MAX then
    return denied("grants: the paths the profile holds, " .. parameters .. ", are past the " ..
        "most it takes, " .. raw.SEATBELT_PARAMETER_MAX .. "; grant a directory above them instead")
  end
  local done, why, failure = raw.restrict_self({ grants = {}, promises = {},
    rlimits = profile.rlimits, seatbelt = { profile = profile.text, parameters = profile.parameters } },
    kept)
  if not done then
    if failure == sys.ENOSYS then
      return denied("this system cannot hold a process: " .. why)
    end
    return denied(why)
  end
  return true, ""
end

--- Holds the calling process, and everything it starts, for good to the
--- policy's `grants`, `promises` and `limits`: Landlock holds the paths
--- (a process with no grant reaches no file, its own program and the
--- files it has open aside), a seccomp filter the system calls, and
--- rlimits the resources, set first, since the filter refuses setrlimit
--- to a process that holds CAP_SYS_RESOURCE.
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
--- earlier call's filter allows only to a process that cannot raise a hard
--- limit (it lacks CAP_SYS_RESOURCE, as a program started under a policy
--- does), so each call of any number may lower a limit there; where the
--- process holds the capability, give every limit in the first call.
---
--- It fails, and holds the process to nothing it was not, for what only
--- a child can be held to -- `isolate`, `connect`, `loopback`, a grant's
--- `from` or `u`, the `nest` promise, `env`, `set_env`, `tmp`, `database`
--- and `limits.processes`, each failing by its name -- and while the process
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
--- Where the kernel has Landlock's signal scope (ABI 6), which the ruleset
--- sets, the filter lets a signal call take any pid and the scope refuses
--- a target outside the process's domain, so a process it starts signals
--- itself and what it started, and nothing outside. Below ABI 6 the
--- filter's rules for signals take this process's pid, so a process
--- started afterwards, which has another, cannot signal itself, and its
--- abort() ends by SIGSEGV.
---
--- On macOS, Seatbelt holds the process instead: the policy is compiled
--- as [`Child.start`]'s is ([`Seatbelt.compile`], whose refusals it
--- answers, a promise it cannot hold among them) and applied in this
--- process after its limits, and a refused path answers EPERM. A profile
--- holds every thread, so another thread does not refuse it; a child or a
--- descriptor does, as above. Beside the policy's own grants the profile
--- grants what the runtime reaches by path: the store's files
--- ([`Store.paths`]) to read, its shared-memory file to write, and this
--- program's own file to read and run -- the file it is started by, so
--- a portable start's core, unpacked into a cache, is not granted, and
--- this program cannot be started again from a process so restricted.
--- It fails, on either platform, while a database of the store is in WAL
--- mode, whose log SQLite keeps open for writing.
--- macOS applies one profile to a process: a second call fails, and
--- so does a [`Child.start`] with a policy afterwards, since its child's
--- profile would be a second one; a child started without one is held by
--- this process's. Elsewhere it fails, saying so.
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
  local logged = store_unheld()
  if logged ~= "" then return denied(logged) end
  if darwin() then return held_by_seatbelt(policy, kept) end
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
          "which only Linux gives, or Seatbelt, which macOS does")
    end
    return denied(held)
  end
  return true, ""
end

--- How many ids a root caller's sandboxes choose their user from
--- ([`Sandbox.user_id`]).
local USER_POOL <const> = 4096

--- Whether one range of `text`, a uid_map or gid_map's lines of the first
--- id inside, the first outside and how many, holds every id from `low`
--- to `high`.
local function mapped_run(text: string, low: integer, high: integer): boolean
  for line in text:gmatch("[^\n]+") do
    local first, _, count = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    if first ~= nil then
      local from, many = math.tointeger(tonumber(first)), math.tointeger(tonumber(count))
      if from ~= nil and many ~= nil and from <= low and from + many - 1 >= high then
        return true
      end
    end
  end
  return false
end

--- Whether `text`, a uid_map or gid_map as /proc/self/uid_map reads,
--- maps `id`, so a process of the namespace can take it.
---
---     print(Sandbox.maps_id("0 0 4294967295\n", 1000)) -- true
---     print(Sandbox.maps_id("0 100000 65536\n", 70000)) -- false
function Sandbox.maps_id(text: string, id: integer): boolean
  return mapped_run(text, id, id)
end

--- The highest id `text`, a uid_map or gid_map, maps, or nil for none.
local function highest_mapped(text: string): integer | nil
  local top: integer | nil
  for line in text:gmatch("[^\n]+") do
    local first, _, count = line:match("^%s*(%d+)%s+(%d+)%s+(%d+)")
    if first ~= nil then
      local from, many = math.tointeger(tonumber(first)), math.tointeger(tonumber(count))
      if from ~= nil and many ~= nil and many > 0 and (top == nil or from + many - 1 > top) then
        top = from + many - 1
      end
    end
  end
  return top
end

--- The user and group a root caller's program runs as, which is never
--- root: one id of a pool, `serial` choosing which, from the top of what
--- the caller's user namespace (`uid_map` and `gid_map`, as
--- /proc/self/uid_map and gid_map read) maps. The pool is the 4096 ids
--- below the highest both maps hold, kept clear of the topmost two ids of
--- the host (-1 and -2 as a signed id) and of 65534 and 65535, which
--- every system gives to nobody and to the overflow id: on the host, ids
--- 4294963198 to 4294967293, which no distribution or container runtime
--- assigns to a user (systemd keeps 2147483648 and up unallocated),
--- and in a namespace that maps only 65536 ids, 61438 to 65533. A
--- sandbox is given `serial % 4096` of them, so sandboxes whose serials
--- differ get different users; two with equal serials share one, which
--- costs only what a shared user does -- the files each owns that the
--- other can reach -- since each has a pid namespace and its own user
--- namespace's process count. Nil and why where the namespace maps no
--- such run of ids.
---
---     local id = assert(Sandbox.user_id("0 0 4294967295\n", "0 0 4294967295\n", 0))
---     print(id) -- 4294963198
function Sandbox.user_id(uid_map: string, gid_map: string, serial: integer): integer | nil, string
  local uid_top, gid_top = highest_mapped(uid_map), highest_mapped(gid_map)
  if uid_top == nil or gid_top == nil then
    return refuse("this user namespace maps no user or no group")
  end
  local top = math.min(uid_top, gid_top, 4294967293)
  if top == 65534 or top == 65535 then top = 65533 end
  local first = top - USER_POOL + 1
  if first < 1 or not mapped_run(uid_map, first, top) or not mapped_run(gid_map, first, top) then
    return refuse("this user namespace maps no run of " .. USER_POOL .. " ids ending at " ..
        top .. ", from which a sandbox's own user is taken: a root caller's program never " ..
        "runs as root, so it needs a namespace that maps more ids, as a host's does")
  end
  return first + serial % USER_POOL
end

--- Whether `id` is one of the pool [`Sandbox.user_id`] takes a root
--- caller's users from, for the maps `uid_map` and `gid_map`, which a
--- policy's `user` may not name: a concurrent sandbox may be given it.
---
---     print(Sandbox.in_pool("0 0 4294967295\n", "0 0 4294967295\n", 4294963198)) -- true
---     print(Sandbox.in_pool("0 0 4294967295\n", "0 0 4294967295\n", 1000)) -- false
function Sandbox.in_pool(uid_map: string, gid_map: string, id: integer): boolean
  local first, _ = Sandbox.user_id(uid_map, gid_map, 0)
  return first ~= nil and id >= first and id < first + USER_POOL
end

--- Whether a kernel, by its release as /proc/sys/kernel/osrelease names
--- it, counts the processes of a user namespace apart from the user's in
--- the namespace it was made in, which `limits.processes` needs: Linux
--- 5.17, where the per-namespace counts were fixed. A stable kernel that
--- has the fixes under an older release is not recognized. A release this
--- cannot read is not one.
---
---     print(Sandbox.counts_per_namespace("6.1.0-generic")) -- true
---     print(Sandbox.counts_per_namespace("5.15.0")) -- false
function Sandbox.counts_per_namespace(release: string): boolean
  local major, minor = release:match("^(%d+)%.(%d+)")
  if major == nil then return false end
  local m, n = math.tointeger(tonumber(major)), math.tointeger(tonumber(minor))
  return m ~= nil and n ~= nil and (m > 5 or (m == 5 and n >= 17))
end

--- What the user of a root caller's sandbox, which has no supplementary
--- group, can do at the path `st` describes, to meet the grant letters
--- `letters`. Without `uid` it owns none of the files and is in none of
--- their groups: `"other"` when the mode's bits for everyone else give it
--- all of them, `"owner"` when only the owner's bits do (an idmapped
--- mount makes the sandbox's user the owner), and `""`, with what is
--- missing, when neither does. With `uid` and `gid`, a policy's `user`
--- and `group`, the kernel's own order holds: the owner's bits for the
--- file's owner and the group's for its group, `"user"` when they give it
--- all, the class after them not looked at. Reading needs `r`, and `x`
--- to reach what is in a directory; writing or creating needs `w`, and
--- `x` in a directory; running needs `x`; connecting to a socket needs
--- `w`; `by` names which. Only the mode is read: an access control list, a mount's flags
--- or a file system's own rules can allow or refuse more, and what is
--- beneath a directory has modes of its own.
---
---     local st = assert(sys.stat("/etc/hostname"))
---     print(Sandbox.reach("r", st).by) -- other
function Sandbox.reach(letters: string, st: sys.Stat, uid?: integer, gid?: integer): Sandbox.Reach
  local need = 0
  local isdir = st.kind == "dir"
  for i = 1, #letters do
    local letter = letters:sub(i, i)
    if letter == "r" then
      need = need | 4 | (isdir and 1 or 0)
    elseif letter == "w" or letter == "c" then
      need = need | 2 | (isdir and 1 or 0)
    elseif letter == "x" then
      need = need | 1
    elseif letter == "u" then
      need = need | 2
    end
  end
  local other = st.mode & 7
  local group = (st.mode >> 3) & 7
  local owner = (st.mode >> 6) & 7
  local function lacking(bits: integer, whom: string): Sandbox.Reach
    local names: {string} = {}
    for bit, name in ipairs({ "execute", "write", "read" }) do
      if need & (1 << (bit - 1)) ~= 0 and bits & (1 << (bit - 1)) == 0 then
        names[#names + 1] = name
      end
    end
    return { by = "", lacks = "its mode " .. string.format("%04o", st.mode & 4095) ..
        " does not give " .. whom .. " the right to " .. table.concat(names, " and ") }
  end
  if uid ~= nil and st.uid == uid then
    if owner & need == need then return { by = "user", lacks = "" } end
    return lacking(owner, "its owner, user " .. uid .. ",")
  end
  if gid ~= nil and st.gid == gid then
    if group & need == need then return { by = "user", lacks = "" } end
    if owner & need == need then return { by = "owner", lacks = "" } end
    return lacking(group, "its group, " .. gid .. ",")
  end
  if other & need == need then return { by = "other", lacks = "" } end
  if owner & need == need then return { by = "owner", lacks = "" } end
  return lacking(owner, "its owner")
end

return Sandbox
