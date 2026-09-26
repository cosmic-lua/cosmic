--- Filesystem queries whose answers may affect a test verdict.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- The raw process table, whose `spawn` `cosmic.child` starts every
--- child with; SQLite's, which records the files SQLite opens in C;
--- and the syscall table's log of what its calls were asked and
--- answered: this module is handed all three (core/store.c's
--- `open_observations`) to confine each child a test starts, by
--- standing in for that call, and to note each file SQLite reads for it
--- and each call of `cosmic.sys`, the process table and cosmic.http it
--- makes, by draining those records. Boot mode falls back to requiring
--- them by name, which only boot's own preload answers.
local type raw_process = require("cosmic.internal.process")
local type Raw = require("cosmic.internal.observations")

local extra: any = select(2, ...)
local raws: Raw
if type(extra) == "table" then
  raws = extra as Raw
else
  raws = require("cosmic.internal.observations")
end
local process = raws.process
local sqlite = raws.sqlite
local syscalls = raws.syscalls

-- What placing a path asks of the process: the calls themselves, past
-- the syscall table's log, so the observer's own questions are none of
-- the test's; and taken when this module loads -- before any test's
-- module does -- so a test cannot bend where its own reads are keyed.
-- TODO: take `Fs.within`, which a note calls, the same way (a path's
-- resolution is the log's own, in C): a test that replaces it on the
-- shared `Fs` table can still move a read in or out of the tree.
local getcwd = syscalls.getcwd
local realpath = syscalls.realpath
local lstat = syscalls.lstat
local stat = syscalls.stat
local getenv = syscalls.getenv
local environ = syscalls.environ

--- The process table's own `spawn`, which logs a process it starts as
--- one no key holds, and the same call past the log, which the stand-in
--- for it (see `start`) starts one with once it has noted it itself.
local logged_spawn = process.spawn
local unlogged_spawn = syscalls.spawn

local record observations
  record Observation
    kind: string
    path: string
    answer: string
  end

  --- Which reads are resolved as they are made: every absolute one
  --- outside `tree` or climbing with "..", noted "r", or "t" when it is
  --- under one of `own`, the test's own directory as it may be spelled,
  --- and leads out of it or climbs.
  record Resolving
    tree: string
    own: {string}
  end

  --- What a test declares the processes it starts need, beyond the
  --- system's own files (see `confine`) and its own directory:
  --- the paths they read, and the ones they change too.
  record Confinement
    reads: {string}
    writes: {string}
  end

  --- A run no key could hold, as `encode_unstable` marks it: what it
  --- was compiled from and ran under, and what it read.
  record Unstable
    identity: string
    reads: {Observation}
  end

  --- One test body's run: whether it passed, its failure as text (""
  --- when it passed), and what it read either way.
  record Run
    passed: boolean
    message: string
    reads: {Observation}
  end
  --- What `capture` saw: whether the call returned, its first result
  --- or what it raised, and what it read.
  record Captured
    ok: boolean
    produced: any
    reads: {Observation}
  end
end

--- Returns both lists in observation order, without changing either input.
--- Repeated identical observations carry no more information, but different
--- answers to the same query are both retained so callers can reject a run
--- whose filesystem changed underneath it.
function observations.join(first: {observations.Observation},
                           second: {observations.Observation}): {observations.Observation}
  local joined: {observations.Observation} = {}
  local seen: {string:{string:{string:boolean}}} = {}
  local function append(found: {observations.Observation})
    for _, observation in ipairs(found) do
      local by_path = seen[observation.kind]
      if by_path == nil then
        by_path = {}
        seen[observation.kind] = by_path
      end
      local by_answer = by_path[observation.path]
      if by_answer == nil then
        by_answer = {}
        by_path[observation.path] = by_answer
      end
      if not by_answer[observation.answer] then
        by_answer[observation.answer] = true
        joined[#joined + 1] = observation
      end
    end
  end
  append(first)
  append(second)
  return joined
end

--- One framed contribution to a verdict key.
function observations.key_part(kind: string, path: string, answer: string): string
  return kind .. " " .. Codec.hex(path) .. " " .. Codec.hex(answer)
end

--- What an absolute path resolves to, links and all, when it is read:
--- `realpath` of the path, or, when it is not there (a stat or an open
--- of a missing file is a read too), of its nearest existing ancestor
--- with the missing names after it as written, "." and ".." included:
--- the first of them is missing, so nothing after it is reached, and
--- the answer is that ancestor's. "" for a relative path. Nothing is
--- remembered between calls, since a link can be retargeted between
--- two reads. The log resolves a read's path the same way as the call
--- is made (core/observed.c's `resolution`).
function observations.resolution(path: string): string
  return syscalls.resolve(path)
end

--- What a path names without following a link at its end, as `lstat`
--- and `readlink` read it: `observations.resolution` of the directory
--- it is in, with its last name after it as written. That of the whole
--- path for one whose last name is "." or "..", or that ends in "/",
--- which the call follows. "" for a relative path.
function observations.link_resolution(path: string): string
  return syscalls.resolve(path, true)
end

--- A versioned, line-safe representation. Paths may themselves contain
--- newlines. Version 2 added "r", what a path outside the tree resolved
--- to when it was read, and "t", the same for a path under the test's
--- own directory, which alone keeps its answer: that directory is gone
--- by the time a later run could resolve the path again. The syscall
--- table's queries (see `start`) came later, each a kind no earlier
--- reader decodes: "l" an lstat, "k" a readlink, "a" a realpath, "c"
--- the working directory and "b" the program's own path, and "v" and
--- "w", an lstat's or a readlink's resolution, as "r" and "t" are
--- another read's.
function observations.encode(found: {observations.Observation}): string
  local lines: {string} = { "filesystem-observations-v2" }
  for _, observation in ipairs(found) do
    local kind = observation.kind
    if kind == "o" or kind == "s" or kind == "d" or kind == "e" or kind == "r" or
        kind == "u" or kind == "l" or kind == "k" or kind == "a" or kind == "c" or
        kind == "b" or kind == "v" then
      lines[#lines + 1] = kind .. " " .. Codec.hex(observation.path)
    elseif kind == "t" or kind == "w" then
      lines[#lines + 1] = kind .. " " .. Codec.hex(observation.path) .. " " ..
        Codec.hex(observation.answer)
    end
  end
  return table.concat(lines, "\n")
end

--- Marks a run whose observations changed while it ran, or that read
--- what no key can hold. It must run again -- no single current
--- filesystem answer can represent what that run observed -- unless its
--- `identity` (what it was compiled from and ran under) still holds and
--- the caller lets it be assumed.
function observations.encode_unstable(identity?: string,
                                      found?: {observations.Observation}): string
  if identity == nil then return "filesystem-observations-unstable" end
  return "filesystem-observations-unstable\n" .. Codec.hex(identity) .. "\n" ..
    observations.encode(found or {})
end

--- Old rows described opens only, or no resolutions, so they cannot
--- safely produce a verdict.
function observations.decode(encoded: string): {observations.Observation} | nil
  if encoded:match("^[^\n]*") ~= "filesystem-observations-v2" then
    return nil
  end
  local found: {observations.Observation} = {}
  for line in encoded:gmatch("[^\n]+") do
    if line ~= "filesystem-observations-v2" then
      local kind, encoded_path, encoded_answer =
        line:match("^([osdertulkacbvw]) ([0-9a-f]*) ?([0-9a-f]*)$")
      local path: string = nil
      local answer: string = nil
      if encoded_path ~= nil then
        local decoded, _ = Codec.unhex(encoded_path)
        path = decoded
        local decoded_answer, _ = Codec.unhex(encoded_answer)
        answer = decoded_answer
      end
      if kind == nil or path == nil or answer == nil or (kind ~= "t" and kind ~= "w" and answer ~= "") then
        return nil
      end
      found[#found + 1] = { kind = kind, path = path, answer = answer }
    end
  end
  return found
end

--- The identity and observations `encode_unstable` was given, or nil
--- when it was given none or `encoded` is no such mark.
function observations.decode_unstable(encoded: string): observations.Unstable | nil
  local hex, rest = encoded:match("^filesystem%-observations%-unstable\n([0-9a-f]+)\n(.*)$")
  if hex == nil then return nil end
  local identity, _ = Codec.unhex(hex)
  local found = observations.decode(rest)
  if identity == nil or found == nil then return nil end
  return { identity = identity, reads = found }
end

--- One environment variable's value, or a marker no real value can equal.
local function getenv_answer(value: string | nil): string
  if value == nil then
    return "absent"
  end
  return "ok " .. value
end

--- The whole environment, order-independent: every `NAME=VALUE` pair,
--- sorted by name, hashed together, so a `sys.environ` read is keyed on
--- the whole environment rather than on any one variable.
local function environ_answer(environment: {string:string}): string
  local names: {string} = {}
  for name in pairs(environment) do names[#names + 1] = name end
  table.sort(names)
  local parts: {string} = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = name .. "=" .. environment[name]
  end
  return Hash.hex_sha256(table.concat(parts, "\n"))
end

--- The path an "e" observation of the whole environment carries: a
--- NUL can't start a variable name, so it never collides with one --
--- not even `getenv("")`.
local environ_path = "\0environ"

--- Every field exposed by `sys.stat` but the access time, including an
--- error result: a read moves `atime`, so keying on it would make every
--- verdict that reads a file stale by reading it.
local function stat_result_answer(st: sys.Stat | nil, trouble: string,
                                  errno: integer): string
  if st == nil then
    return "error " .. Codec.hex(trouble) .. " " .. tostring(errno)
  end
  return table.concat({ "ok", tostring(st.size), tostring(st.mode), st.kind,
    tostring(st.mtime), tostring(st.mtime_ns), tostring(st.ino), tostring(st.dev),
    tostring(st.nlink), tostring(st.uid), tostring(st.gid) }, " ")
end

--- A query's answer: its value, or its error, as a stat's is told.
local function value_answer(value: string | nil, trouble: string, errno: integer): string
  if value == nil then
    return "error " .. Codec.hex(trouble) .. " " .. tostring(errno)
  end
  return "ok " .. value
end

--- What a "b" observation holds of the program's own path: that the
--- query answered, and its error whole where it failed, but not where
--- the program is. What the program is, a verdict's key holds already
--- (its runtime identity, `build.work`'s `Identities`); where it is,
--- like where the tree is, is no input a test may turn on (see
--- `observations.tree_name`), so a verdict one copy of a program
--- reached stands under another at another path -- another artifact
--- over the same core and basis, a release beside the tree's own.
local function program_answer(value: string | nil, trouble: string, errno: integer): string
  if value == nil then return value_answer(value, trouble, errno) end
  return "ok"
end

--- A directory answer includes names, kinds, and errors. Length-prefixing each
--- name makes this unambiguous for every name the filesystem permits.
local function directory_result_answer(entries: {string:string} | nil,
                                       trouble: string,
                                       errno: integer): string
  if entries == nil then
    return "error " .. Codec.hex(trouble) .. " " .. tostring(errno)
  end
  local names: {string} = {}
  for name in pairs(entries) do names[#names + 1] = name end
  table.sort(names)
  local parts: {string} = { "ok" }
  for _, name in ipairs(names) do
    parts[#parts + 1] = tostring(#name) .. ":" .. name .. ":" .. entries[name]
  end
  return table.concat(parts, "")
end

--- What a confined process has without its test naming it: the
--- system's programs and libraries, its configuration, the devices a
--- program takes for granted, and /proc, where a program finds itself
--- (`/proc/self/exe`) and its descriptors (`/dev/fd`) -- each where
--- this host has it. /proc alone does not enter a key.
-- TODO: a /proc of the process's own, a fresh one in a pid namespace,
-- once `process.spawn` can start a program in one (core/syscalls.c's
-- `unveil`): the host's, given here, shows every other process and the
-- host's state, which a confined process can read without it entering
-- the key.
local system: {string} = { "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32",
  "/etc", "/dev/null", "/dev/zero", "/dev/urandom", "/proc" }

--- What the running test declared its processes need, or nil: see
--- `observations.confine`.
local confinement: observations.Confinement | nil = nil

--- Declares what every process the calling test starts from here on
--- needs: `declared.reads`, read-only, and `declared.writes`, which it
--- may change, beside `system` and the test's own
--- directory and every directory it made, which it may change too. Each is held to that by the
--- kernel -- a root of its own holding those paths and nothing else,
--- and no network (the process table's `Sandbox`, `unveil` and `offline`) -- so what
--- it read is known, and a test whose processes all ran confined can
--- stand: every path it was given enters the verdict key, one under
--- the tree by its contents and any other by a walk of what `lstat`
--- says of it and everything beneath it. A process started with a
--- sandbox of its own is not confined further, and where the kernel
--- cannot confine one it starts as it would have, and the run never
--- stands. A process given no directory to start in starts in the
--- test's own, since the one the test runs in, the tree's root, is not
--- its to read; one has a /tmp of its own, and one that inherits a
--- TMPDIR it may not change has the test's own directory for it. Called at a test module's top level, it holds for each
--- of its tests; called in a test, for the rest of that test. A
--- relative path is taken from the directory this is called in. Nil
--- ends the declaration: a process started after it is not confined.
function observations.confine(declared: observations.Confinement | nil)
  if declared == nil then
    confinement = nil
    return
  end
  local wanted: observations.Confinement = declared
  local here, _ = getcwd()
  local function absolute(path: string): string
    if path:sub(1, 1) == "/" or here == nil then return path end
    return (here == "/" and "" or here) .. "/" .. path
  end
  local reads: {string} = {}
  local writes: {string} = {}
  for _, path in ipairs(wanted.reads or {}) do reads[#reads + 1] = absolute(path) end
  for _, path in ipairs(wanted.writes or {}) do writes[#writes + 1] = absolute(path) end
  confinement = { reads = reads, writes = writes }
end

--- What a confined process of this very program needs to start, for a
--- test's `confine`: the program, and the core its launcher runs it on
--- where it is a portable artifact.
function observations.itself(): {string}
  local program: {string} = {}
  local executable, _ = Proc.executable()
  if executable ~= nil then program[#program + 1] = executable end
  local launched, _ = Proc.relaunch()
  if launched ~= nil then program[#program + 1] = launched.argv[1] end
  return program
end

--- The errnos a confined spawn fails with where the kernel cannot
--- confine a process at all: no user namespaces, or none for this user.
-- TODO: fall back only on a failure of the sandbox's own setup, once
-- `process.spawn` says which step failed (the status pipe carrying it beside
-- the errno): an EACCES or EINVAL from exec, or an unreadable path
-- declared, falls back unconfined too, and the test runs uncached where
-- it should fail.
local unconfinable: {integer:boolean} = {
  [sys.ENOSYS] = true, [sys.EPERM] = true, [sys.EACCES] = true, [sys.EINVAL] = true,
  [sys.ENOSPC] = true,
}

--- Whether a request for `url` could reach past this process: all but
--- one naming a scheme other than http and https, which core/http.c
--- does not let curl speak. curl takes a URL with no scheme for http,
--- and makes a host of what follows "http:" however many slashes lead
--- it, so nothing short of the scheme says a request cannot connect.
local function reaches(url: string): boolean
  local scheme = url:match("^%s*(%a[%w+.-]*):")
  if scheme == nil then return true end
  scheme = scheme:lower()
  return scheme == "http" or scheme == "https"
end

--- A list of strings as the core reads one, raw: its entries from 1 on,
--- by rawget, to the first nil; nil when it holds anything else, which
--- the core refuses.
local function raw_strings(list: any): {string} | nil
  local out: {string} = {}
  if list == nil then return out end
  if not list is {any:any} then return nil end
  local at = 1
  while true do
    local value = rawget(list, at)
    if value == nil then return out end
    if not value is string then return nil end
    out[#out + 1] = value
    at = at + 1
  end
end

--- `sandbox` as the core reads it -- raw, with no metamethod answering
--- for a field -- in a plain table of its own; nil when a field holds
--- what the core would refuse, for the core to refuse.
local function plain_sandbox(sandbox: raw_process.Sandbox): raw_process.Sandbox | nil
  local raw = sandbox as {string:any}
  local plain: raw_process.Sandbox = {}
  local ruleset = rawget(raw, "ruleset")
  if ruleset is integer then plain.ruleset = ruleset elseif ruleset ~= nil then return nil end
  local unveil = rawget(raw, "unveil")
  if unveil is {any:any} then
    local reads, writes = raw_strings(rawget(unveil, "reads")), raw_strings(rawget(unveil, "writes"))
    if reads == nil or writes == nil then return nil end
    plain.unveil = { reads = reads, writes = writes }
  elseif unveil ~= nil then
    return nil
  end
  plain.offline = rawget(raw, "offline") == true
  local pledge = rawget(raw, "pledge")
  if pledge ~= nil then
    local promises = raw_strings(pledge)
    if promises == nil then return nil end
    plain.pledge = promises
  end
  return plain
end

--- The file types `lstat` and `fstat` tell apart by their mode's type
--- bits, which `sys.Stat`'s `kind` folds into "other".
local S_IFMT <const> = 0xf000
local S_IFREG <const> = 0x8000
local S_IFIFO <const> = 0x1000
local S_IFCHR <const> = 0x2000

--- Whether a device is one whose every answer is the same, or random,
--- and so no input: /dev/null, /dev/zero or /dev/urandom.
local function inert_device(st: sys.Stat): boolean
  for _, name in ipairs({ "/dev/null", "/dev/zero", "/dev/urandom" }) do
    local device, _ = sys.stat(name)
    if device ~= nil and device.ino == st.ino and device.dev == st.dev then return true end
  end
  return false
end

--- Whether a descriptor a confined process is handed reaches nothing
--- past its root but what the test itself opened and read: a file, a
--- pipe, or an inert device -- not a directory, whose files it could
--- read, nor a socket, onto the network.
local function contained(fd: integer): boolean
  local st, _ = sys.fstat(fd)
  if st == nil then return true end -- nothing there to reach
  local format = st.mode & S_IFMT
  return format == S_IFREG or format == S_IFIFO or
    (format == S_IFCHR and inert_device(st))
end

--- The most paths a sandbox unveils (core/syscalls.c's UNVEIL_MAX).
local UNVEIL_MAX <const> = 64

--- Whether a process can run confined to `reads` and `writes`: few
--- enough of them, and its program among them -- where the system's
--- own shell lives elsewhere (/nix/store), it starts unconfined.
local function confinable(program: string, reads: {string}, writes: {string}): boolean
  if #reads + #writes > UNVEIL_MAX then return false end
  local real, _ = realpath(program)
  if real == nil then return true end -- its own failure to report
  for _, list in ipairs({ reads, writes }) do
    for _, given in ipairs(list) do
      local where, _ = realpath(given)
      if where ~= nil and Fs.within(real, where) then return true end
    end
  end
  return false
end

--- While a `declared` call runs, a process it starts is noted "h", not
--- "p". `noting` holds every running capture's own `note` -- one wraps
--- another when a test captures its own calls -- for a declaration that
--- did not hold, which each of them must hear.
local type Note = function(kind: string, given: any, answer: string, resolved?: string)
local declaring = 0
local noting: {Note} = {}

--- Notes each file SQLite opened or asked after since the last drain as
--- an open by every running capture: it read them in C, through
--- `cosmic.sqlite`'s VFS, past every binding of the syscall table. What a
--- capture that began later read is noted by it and by those around it;
--- what none was running for is dropped. Each is resolved as it is
--- drained, not as SQLite opened it.
-- TODO: resolve a file SQLite opens as it opens it, beside its record
-- in the VFS (core/sqlite.c's `observe_path`, through the resolution
-- core/observed.c keeps a syscall's path with): SQLite names a file
-- with its links resolved as it opens it, but a directory on its path
-- replaced by a link before the drain moves where the read is keyed.
local function drain_sqlite()
  for _, path in ipairs(sqlite.observed()) do
    local resolved = observations.resolution(path)
    for _, note in ipairs(noting) do note("o", path, "", resolved) end
  end
end

--- The kind each call the syscall table logs is noted as: "o" an
--- open, "s" a stat, "d" a listing, "l" an lstat, "k" a readlink and
--- "a" a realpath, each of its path; "e" a variable read by name, or,
--- as `environ_path`, the whole environment; "m" a directory made,
--- the test's own; "p" a process started past the stand-in for `spawn`
--- -- through a reference to the process table's own taken before the
--- capture began -- which nothing confined or judged; "x" a request
--- that could reach the network (see `reaches`); "c" the working
--- directory the run started in, whatever it answered -- what a test's
--- own change of directory made it answer is noted as that change, a
--- stat of where it went -- and "b" the program's own path, keyed by
--- whether it answered (`program_answer`), not where the program is.
local call_kinds: {string:string} = {
  lstat = "l", readlink = "k", realpath = "a", getcwd = "c", executable = "b",
  open = "o", stat = "s", readdir = "d", getenv = "e", environ = "e", mkdir = "m",
  mkdtemp = "m", spawn = "p", http = "x",
}

--- The kinds whose path is one a key places: absolute, or none at all.
local placed: {string:boolean} = {
  o = true, s = true, d = true, l = true, k = true, a = true, m = true,
}

--- Notes each call the syscall table logged since the last drain by
--- every running capture, as `drain_sqlite` does SQLite's files: it
--- logs them in C, in each of those bindings, whoever made the call --
--- a module that took it before the capture began, as `local stat =
--- sys.stat`, or a Teal function over it -- with what it answered and,
--- where the capture asked for it, what its path resolved to as it was
--- made. One whose answer the log could not hold, or whose relative
--- path's working directory could not be told, is noted "x".
local function drain_syscalls()
  for _, call in ipairs(syscalls.observed()) do
    local kind = call_kinds[call.call] or "x"
    local path = call.path or ""
    local answer = ""
    if call.call == "http" and not reaches(path) then
      kind = ""
    elseif call.partial or kind == "x" or (placed[kind] and path:sub(1, 1) ~= "/") then
      kind = "x"
      if path == "" then path = call.call end
    elseif kind == "l" or kind == "s" then
      answer = stat_result_answer(call[1] as sys.Stat, call[2] as string, call[3] as integer)
    elseif kind == "d" then
      answer = directory_result_answer(call[1] as {string:string}, call[2] as string,
        call[3] as integer)
    elseif call.call == "getenv" then
      answer = getenv_answer(call[1] as string)
    elseif call.call == "environ" then
      path = environ_path
      answer = environ_answer(call[1] as {string:string})
    elseif kind == "b" then
      answer = program_answer(call[1] as string, call[2] as string, call[3] as integer)
    elseif kind == "k" or kind == "a" then
      answer = value_answer(call[1] as string, call[2] as string, call[3] as integer)
    elseif kind == "p" and path == "" then
      path = call.call
    end
    if kind ~= "" then
      for _, note in ipairs(noting) do note(kind, path, answer, call.resolved) end
    end
  end
end

--- Calls `fn`, which starts processes whose every input it has read
--- itself, through the calls observed here: a process started meanwhile
--- is noted "h", a declared one, which a key can hold, rather than "p".
--- `fn` answers whether its declaration held -- whether it could read
--- everything each process read -- and when it did not, the run is noted
--- "x" and never stands. Outside a capture this only calls `fn`. `fn`
--- must not yield: a coroutine never resumed would leave its processes'
--- successors declared.
-- TODO: move the one declared process, build/c/init.tl's zig, onto
-- `observations.confine` -- its toolchain and caches given it, the
-- toolchain keyed like any other path outside the tree -- and retire
-- `declared`, which trusts its caller to have named what a process
-- reads rather than having the kernel hold it to that.
function observations.declared(what: string, fn: function(): boolean)
  declaring = declaring + 1
  local ok, held = pcall(fn)
  declaring = declaring - 1
  if not ok then error(held, 0) end
  if not held then
    for _, note in ipairs(noting) do note("x", what, "") end
  end
end

--- The tree each running capture resolves paths outside of, by its
--- `note`: none for one given no `resolving`.
local trees: {any:string} = {}

--- Which paths the log resolves as the calls are made (the syscall
--- table's `resolving`): those outside the tree every running capture
--- that resolves shares, every absolute one ("") when they share none,
--- and none (nil) when no capture resolves.
local function resolving_tree(): string | nil
  local tree: string = nil
  for _, each in ipairs(noting) do
    local mine = trees[each]
    if mine ~= nil and tree == nil then
      tree = mine
    elseif mine ~= nil and mine ~= tree then
      return ""
    end
  end
  return tree
end

--- Observes the calls a test makes until `restore` is called, failed
--- ones too: absence and errors are answers a test can depend on.
---
--- A "p" (a process started, not `declared`) or an "x" (a query no key can hold: a
--- request over the network, or a relative path when the working
--- directory cannot be told) makes the run's verdict one that
--- never stands.
---
--- What `cosmic.sys`'s `open`, `stat`, `readdir`, `lstat`, `readlink`,
--- `realpath`, `getcwd`, `executable`, `getenv`, `environ`, `mkdir`,
--- `mkdtemp` and `chdir`, the process table's `spawn` and cosmic.http's
--- `open` are asked and answer while the capture runs is logged by each
--- of those bindings itself (core/observed.h), whoever calls it -- a
--- module that took one before the capture began, as `local stat =
--- sys.stat`, included -- and noted when the capture ends, or before a
--- process starts (see `drain_syscalls`). A relative path is noted as
--- the absolute one it names from the working directory the call was
--- made in, asked of the process itself rather than tracked: a change
--- of directory made while the module loaded moves the test's own
--- reads too. A change of directory is itself noted as a stat of where
--- it went.
---
--- Given `resolving`, an absolute path an open, a stat, a listing, a
--- realpath, an lstat or a readlink names outside its tree, or that
--- climbs with "..", is noted a second time, as an "r" (a "t" under the
--- test's own directory, and only when it leads out of it or climbs)
--- whose answer is what the log resolved it to as the call was made
--- (`observations.resolution`): a file of the tree may be named through
--- a link outside it, and what the link led to when the test read it
--- is what its verdict describes. An lstat's and a readlink's is
--- resolved only as far as its last name
--- (`observations.link_resolution`) and noted "v", or "w" under the
--- test's own directory.
---
--- A file SQLite opens through `cosmic.sqlite` while the capture runs
--- -- a database, its journal or WAL, an attached one, or one it only
--- asked after -- is noted an open too, as SQLite names it, when the
--- capture ends (see `drain_sqlite`). What a connection opened before
--- the capture began reads during it is not: SQLite opened its file
--- before anything here was watching.
-- TODO: note the files of every `cosmic.sqlite` connection still open
-- when a capture starts too (the VFS can keep the path of each file it
-- holds open, and hand them over as `observed` does): today a
-- connection a module opens as it loads, read only by a test's own
-- call, keys that call without the database; so does one the store
-- attached before the capture (the worker's o/cosmic.db, whose reads a
-- test's `require` makes are held by its module keys instead).
---
--- The process table's `spawn` alone is also stood in for, since a
--- process the test starts is confined (`observations.confine`) or
--- noted by what its own sandbox gives it, which the stand-in decides;
--- one started past it, through a reference taken before the capture,
--- is logged and noted "p".
local function start(resolving: observations.Resolving | nil):
                     {observations.Observation}, function()
  drain_sqlite()
  drain_syscalls()
  local found: {observations.Observation} = {}
  -- The call the stand-in wraps: what `spawn` was as the capture
  -- began, past the log when it is the process table's own, since the
  -- stand-in notes what it starts itself.
  local spawn = process.spawn
  if spawn == logged_spawn then spawn = unlogged_spawn end
  -- Once the capture ends, a reference to the stand-in taken while it
  -- ran starts a process as the process table's own does, logged for
  -- whichever capture runs then.
  local ended = false
  -- The test's own: its directory, and every directory it made for
  -- itself and that is a directory still -- one put back as a link
  -- would lead elsewhere -- which a key never holds either.
  local function test_own(): {string}
    drain_syscalls()
    local own: {string} = {}
    for _, directory in ipairs(resolving ~= nil and resolving.own or {}) do
      own[#own + 1] = directory
    end
    for _, observation in ipairs(found) do
      if observation.kind == "m" then
        local inside = false
        for _, directory in ipairs(own) do
          if Fs.within(observation.path, directory) then inside = true end
        end
        local st, _ = lstat(observation.path)
        if not inside and st ~= nil and st.kind == "dir" then
          own[#own + 1] = observation.path
        end
      end
    end
    return own
  end
  -- A test holding a call to its argument checks may hand it a path
  -- that is no string at all, which the call itself raises for; only a
  -- path is an observation, and encoding anything else into a key would
  -- end the worker before the test could report. `resolved` is what the
  -- log resolved the path to as the call was made.
  local function note(kind: string, given: any, answer: string, resolved?: string)
    if not given is string then return end
    local path = given
    found[#found + 1] = { kind = kind, path = path, answer = answer }
    if resolving ~= nil and
        (kind == "o" or kind == "s" or kind == "d" or kind == "l" or kind == "k" or
          kind == "a") and
        path:sub(1, 1) == "/" and (not Fs.within(path, resolving.tree) or
          ("/" .. path .. "/"):find("/%.%./") ~= nil) then
      if resolved == nil then
        -- The log resolved nothing for it: where it led is unknown.
        found[#found + 1] = { kind = "x", path = path, answer = "" }
        return
      end
      -- An lstat's or a readlink's is kept apart, as "v" or "w": it
      -- stops short of a link its path ends in, which a stat's of the
      -- same path follows.
      local link = kind == "l" or kind == "k"
      local noted = link and "v" or "r"
      for _, directory in ipairs(resolving.own) do
        if Fs.within(path, directory) then noted = link and "w" or "t" end
      end
      if (noted == "t" or noted == "w") and resolved ~= "" and ("/" .. path .. "/"):find("/%.%./") == nil then
        -- Most of a test's reads are of its own directory; only one
        -- that leads out of it, or that climbs (which only its
        -- resolution can place), is worth a line.
        for _, directory in ipairs(resolving.own) do
          if Fs.within(resolved, directory) then return end
        end
      end
      found[#found + 1] = { kind = noted, path = path, answer = resolved }
    end
  end
  --- Notes what a process started unveiled and offline had: each path
  --- it read, unless the test's own; each it could change beyond the
  --- test's own, which no key holds; the environment it inherited; and
  --- each descriptor it was handed that reaches past its root.
  local function note_unveiled(reads: {string}, writes: {string}, own: {string},
                               environment: {string:string} | nil, stdin: integer | nil,
                               stdout: integer | nil, stderr: integer | nil,
                               fds: {integer:integer} | nil)
    local function owned(given: string): boolean
      for _, directory in ipairs(own) do
        if Fs.within(given, directory) then return true end
      end
      return false
    end
    for _, given in ipairs(reads) do
      -- Judged by where it leads, as the sandbox binds it: /proc is the
      -- system's own, and any other path in it, or in /sys, is the
      -- host's state, which no key holds.
      -- realpath keeps a leading "//", which POSIX lets a system give a
      -- meaning of its own; Linux gives it none.
      local resolved, _ = realpath(given)
      local real = (resolved or given):gsub("//+", "/")
      if real == "/proc" then
        -- The system's own.
      elseif Fs.within(real, "/proc") or Fs.within(real, "/sys") then
        note("x", given, "")
      elseif not owned(given) then
        note("u", given, "")
      end
    end
    for _, given in ipairs(writes) do
      if not owned(given) then note("x", given, "") end
    end
    if environment == nil then
      found[#found + 1] = { kind = "e", path = environ_path, answer = environ_answer(environ()) }
    end
    local handed: {integer} = {
      stdin == nil and 0 or stdin, stdout == nil and 1 or stdout, stderr == nil and 2 or stderr }
    for _, fd in pairs(fds or {}) do handed[#handed + 1] = fd end
    for _, fd in ipairs(handed) do
      if not contained(fd) then note("x", "fd " .. tostring(fd), "") end
    end
  end
  process.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                           cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                           stderr: integer | nil, process_group: boolean,
                           fds?: {integer:integer}, sandbox?: raw_process.Sandbox):
                           integer | nil, string, integer
    if ended then
      return logged_spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group,
        fds, sandbox)
    end
    -- A sandbox of its own that unveils and takes the network holds a
    -- process as a confinement does, and is noted the same. It is read
    -- as the core reads it, raw, and a plain copy is what the core is
    -- given, so what is noted is what holds the process.
    local plain = sandbox ~= nil and plain_sandbox(sandbox) or nil
    if plain ~= nil and plain.unveil ~= nil and plain.offline == true and declaring == 0 then
      local own = test_own()
      local pid, trouble, errno = spawn(path, argv, environment, cwd, stdin, stdout, stderr,
        process_group, fds, plain)
      if pid ~= nil or not unconfinable[errno] then
        note_unveiled(plain.unveil.reads, plain.unveil.writes, own, environment,
          stdin, stdout, stderr, fds)
      else
        -- Nothing ran; what the test does now turns on the host.
        note("x", path, "")
      end
      return pid, trouble, errno
    end
    if sandbox == nil and confinement ~= nil and declaring == 0 then
      local declared: observations.Confinement = confinement
      local own = test_own()
      local reads: {string} = {}
      for _, given in ipairs(system) do
        local there, _ = stat(given)
        if there ~= nil then reads[#reads + 1] = given end
      end
      for _, given in ipairs(declared.reads) do reads[#reads + 1] = given end
      local writes: {string} = {}
      for _, given in ipairs(own) do
        local there, _ = stat(given)
        if there ~= nil then writes[#writes + 1] = given end
      end
      for _, given in ipairs(declared.writes) do writes[#writes + 1] = given end
      -- The directory a test runs in is the tree's root, which a confined
      -- process does not have: one given no directory starts in the
      -- test's own, confined or not, so it runs the same either way.
      local start_in = cwd
      if start_in == nil then start_in = writes[1] or "/" end
      if confinable(path, reads, writes) then
        -- A program takes a directory it can make temporary files in for
        -- granted, as it does /dev/null. Without a TMPDIR it has a /tmp
        -- of its own; one that inherits a TMPDIR it may not change --
        -- the host's, rather than one its test chose -- is given the
        -- test's own directory for it.
        local given_environment = environment
        local inherited = getenv("TMPDIR")
        local temporary = inherited
        if environment ~= nil then
          temporary = environment.TMPDIR
          -- Whether its TMPDIR is replaced turns on the worker's own,
          -- which an environment given whole does not otherwise key.
          note("e", "TMPDIR", getenv_answer(inherited))
        end
        local replace = temporary ~= nil and temporary == inherited
        for _, given in ipairs(writes) do
          if replace and Fs.within(temporary, given) then replace = false end
        end
        if replace and writes[1] ~= nil then
          given_environment = {}
          for name, value in pairs(environment or environ()) do given_environment[name] = value end
          given_environment.TMPDIR = writes[1]
        end
        local pid, trouble, errno = spawn(path, argv, given_environment, start_in, stdin, stdout,
          stderr, process_group, fds, { unveil = { reads = reads, writes = writes },
            offline = true })
        if pid ~= nil or not unconfinable[errno] then
          note_unveiled(reads, declared.writes, own, environment, stdin, stdout, stderr, fds)
          return pid, trouble, errno
        end
      end
      cwd = start_in
    end
    note(declaring > 0 and "h" or "p", path, "")
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds,
      sandbox)
  end
  noting[#noting + 1] = note
  trees[note] = resolving ~= nil and resolving.tree or nil
  syscalls.resolving(resolving_tree())
  sqlite.observe(true)
  syscalls.observe(true)
  return found, function()
    ended = true
    process.spawn = spawn == unlogged_spawn and logged_spawn or spawn
    -- Draining allocates, and can raise on memory: the stand-in is put
    -- back first. A drain that fails may have taken records out of C
    -- before noting them all, so every capture still running -- this one
    -- and each that encloses it -- is made one no key holds.
    for _, drain in ipairs({ drain_sqlite, drain_syscalls }) do
      if not pcall(drain) then
        for _, each in ipairs(noting) do
          local _ = pcall(each, "x", drain == drain_sqlite and "sqlite" or "syscalls", "")
        end
      end
    end
    for at = #noting, 1, -1 do
      if noting[at] == note then table.remove(noting, at) break end
    end
    trees[note] = nil
    syscalls.resolving(resolving_tree())
    if #noting == 0 then
      sqlite.observe(false)
      syscalls.observe(false)
    end
  end
end

--- Calls a function and ends the capture even when it raises. The value
--- is left intact so callers such as `require` can consume a produced table.
--- Given `resolving`, a path read outside its tree is also resolved as
--- it is read; see `start`.
function observations.capture(fn: function(any...): (any...),
                              resolving?: observations.Resolving): observations.Captured
  local found, restore = start(resolving)
  local ok, produced = pcall(fn)
  restore()
  return { ok = ok, produced = produced, reads = found }
end

--- Calls one test body and presents its failure as text to the runner,
--- beside what the body read whether it passed or not.
function observations.call(fn: function(any...): (any...), argument: any,
                           resolving?: observations.Resolving): observations.Run
  local c = observations.capture(function(): any
    return fn(argument)
  end, resolving)
  return { passed = c.ok, message = c.ok and "" or tostring(c.produced), reads = c.reads }
end

--- The current answer to an "e" observation, re-read live rather than
--- trusted from the row: `sys.environ`'s hash for `environ_path`, or
--- `sys.getenv`'s answer for a named variable -- or, given
--- `environment`, what it answers, for the environment of a process
--- other than this one.
function observations.getenv_current(path: string, environment?: {string:string}): string
  if path == environ_path then
    return environ_answer(environment or sys.environ())
  end
  if environment ~= nil then return getenv_answer(environment[path]) end
  return getenv_answer(sys.getenv(path))
end

--- What names the tree's own root in `tree_name`: a NUL, which no
--- path holds, so no path outside the tree is ever named as one inside.
local tree_marker <const> = "\0tree"

--- A path as a key names it, the same in every checkout of one tree:
--- one under `tree` -- as written, not climbing with ".." -- by its name
--- below it after a marker no path holds, and any other as it is. The
--- tree's own location is no input to what a test does there, so two
--- checkouts of the same content key the same read alike.
---
--- That is a rule, not an accident of keying: a test may not turn on
--- where the tree is -- a path length limit, a name it prints and
--- compares. The answers that name it which a capture observes (the
--- working directory, a realpath, a readlink, a path under the tree
--- read or given) are keyed by `tree_name` in the shared key and whole
--- only in a checkout's own; one it does not (the artifact path
--- `Proc.relaunch` and the process table's `relaunch` answer) is keyed
--- nowhere. The same rule holds of where the running program is: what
--- `Proc.executable` answered is keyed nowhere (`program_answer`), only
--- that it answered. Nothing here can see a test break either rule;
--- CI enforces both by moving its checkout, and the tool it runs,
--- o/bin/cosmic, with it, to a path the commit and the leg choose, a
--- new one each commit (.github/scripts/place-tree.sh). That catches a
--- test that breaks one only on a run that runs the test: every run
--- while CI stands only on what it runs itself, and once it stands on
--- shared verdicts, only a run where the test's key changed.
function observations.tree_name(path: string, tree: string): string
  if ("/" .. path .. "/"):find("/%.%./") ~= nil then return path end
  local rest, _ = Fs.relative(path, tree)
  if rest == nil then return path end
  if rest == "." then return tree_marker end
  return tree_marker .. "/" .. rest
end

--- `observations.tree_name` undone: the path a name it gave stands for
--- under `tree`, which may be another checkout's than the one it came
--- from.
function observations.tree_path(name: string, tree: string): string
  if name == tree_marker then return tree end
  if name:sub(1, #tree_marker + 1) == tree_marker .. "/" then
    return tree .. name:sub(#tree_marker + 1)
  end
  return name
end

--- An "e" observation's answer as a key holds it, the same in every
--- checkout of `tree`: a value that is a path under it -- the working
--- directory in PWD, which a shell sets -- named by `tree_name`, in a
--- variable read by name, or throughout the whole environment for a
--- read of all of it, which `environment` (what the reading process
--- had) answers.
-- TODO: hold a path under the tree among others in one value, as a
-- PATH entry of the checkout's own o/bin is, by its name there too:
-- today such a value keys the checkout's location, and a test that reads
-- the whole environment stands only in the checkout that ran it.
function observations.held_variable(path: string, answer: string,
                                    environment: {string:string}, tree: string): string
  if path == environ_path then
    local held: {string:string} = {}
    for name, value in pairs(environment) do held[name] = observations.tree_name(value, tree) end
    return environ_answer(held)
  end
  local value = answer:match("^ok (.*)$")
  if value == nil then return answer end
  return "ok " .. observations.tree_name(value, tree)
end

--- What a path given to a confined process holds now, for its "u"
--- observation's line in a key: where it resolves to, `sys.tree_digest`
--- of it -- each file's contents where it resolves under `tree`, and
--- otherwise what `lstat` says of each entry, which a package installed
--- or a file replaced changes -- and the mode of each directory above
--- it. One that holds a socket, a FIFO or a device other than an inert
--- one answers from past the root, and its answer starts "unkeyable ".
--- Under the tree, where it resolves and each directory between it and
--- the tree are named by `tree_name`, and each directory above the tree
--- by its mode alone, so every checkout of the tree answers alike.
function observations.unveiled_answer(path: string, tree: string): string
  local real, _ = realpath(path)
  if real == nil then return "missing" end
  local real_tree, _ = realpath(tree)
  real_tree = real_tree or tree
  local inside = Fs.within(real, real_tree)
  local walked, trouble = sys.tree_digest(real, inside)
  local parts: {string} = { walked ~= nil and walked.digest or ("error " .. trouble) }
  -- The modes of the directories above it, which the root it is bound
  -- into mirrors: a program may check them, as the launcher does its
  -- cache's.
  local above = Fs.dirname(real)
  while true do
    local st, _ = sys.stat(above)
    local name = above
    if inside then
      name = Fs.within(above, real_tree) and observations.tree_name(above, real_tree) or ""
    end
    parts[#parts + 1] = name .. "\0above\0" .. (st ~= nil and tostring(st.mode) or "missing")
    local parent = Fs.dirname(above)
    if parent == above then break end
    above = parent
  end
  return ((walked ~= nil and walked.special) and "unkeyable " or "") ..
    (inside and observations.tree_name(real, real_tree) or real) .. " " ..
    Hash.hex_sha256(table.concat(parts, "\n"))
end

function observations.stat_answer(path: string): string
  return stat_result_answer(sys.stat(path))
end

--- What `lstat` of `path` answers now, as an "l" observation holds it.
function observations.lstat_answer(path: string): string
  return stat_result_answer(lstat(path))
end

--- What `readlink` of `path` answers now, as a "k" observation holds it.
function observations.readlink_answer(path: string): string
  return value_answer(syscalls.readlink(path))
end

--- What `realpath` of `path` answers now, as an "a" observation holds it.
function observations.realpath_answer(path: string): string
  return value_answer(realpath(path))
end

--- What `getcwd` answers now, as a "c" observation holds it.
function observations.cwd_answer(): string
  return value_answer(getcwd())
end

--- What `executable` answers now, as a "b" observation holds it.
function observations.executable_answer(): string
  return program_answer(syscalls.executable())
end

function observations.directory_answer(path: string): string
  return directory_result_answer(sys.readdir(path))
end

return observations
