--- Filesystem queries whose answers may affect a test verdict.

local Fs = require("cosmic.fs")
-- TODO: digest over the raw hash table rather than `Hash.hex_sha256`,
-- once a build.digest raw module (a row in core/store.c's
-- `raw_modules`) hashes keys (plan 2.7): a worker then loads neither
-- cosmic.hash nor cosmic.codec, and a test that replaces
-- `Hash.hex_sha256` on the shared table cannot move a digest here.
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")
local confine = require("build.confine")
local key_parts = require("build.key_parts")

--- SQLite's table, which records the files SQLite opens in C, and the
--- syscall table's log of what its calls were asked and answered: this
--- module is handed both (core/store.c's `open_observations`) to note
--- each file SQLite reads for a test and each call of `cosmic.sys`, the
--- process table and cosmic.http it makes, by draining those records,
--- and what each process it starts was given, which the stand-in for
--- the process table's `spawn` (build.confine's `enter`) tells it. Boot
--- mode falls back to requiring them by name, which only boot's own
--- preload answers.
local type Raw = require("cosmic.internal.observations")

local extra: any = select(2, ...)
local raws: Raw
if type(extra) == "table" then
  raws = extra as Raw
else
  raws = require("cosmic.internal.observations")
end
local sqlite = raws.sqlite
local syscalls = raws.syscalls

-- What placing a path asks of the process: the calls themselves, past
-- the syscall table's log, so the observer's own questions are none of
-- the test's; and taken when this module loads -- before any test's
-- module does -- so a test cannot bend where its own reads are keyed,
-- `Fs.within` among them, which a test could otherwise replace on the
-- shared `Fs` table to move a read in or out of the tree.
local getcwd = syscalls.getcwd
local realpath = syscalls.realpath
local lstat = syscalls.lstat
local stat = syscalls.stat
local environ = syscalls.environ
local tree_digest = syscalls.tree_digest
local within = Fs.within
local hex, unhex, tree_name = key_parts.hex, key_parts.unhex, key_parts.tree_name

--- The calls the stand-in for `spawn` (build.confine's `enter`) makes
--- while a capture runs, past the log, so its questions are none of the
--- test's: `spawn` among them, since the stand-in hands what it starts
--- to the capture itself.
local past_the_log: confine.Calls = {
  getcwd = getcwd, realpath = realpath, lstat = lstat, stat = stat,
  readdir = syscalls.readdir, getenv = syscalls.getenv, environ = environ,
  spawn = syscalls.spawn,
}

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
    --- What this process's own sandbox gives it to read, every process
    --- it starts inheriting it -- `cosmic test`'s sandboxed worker
    --- (build/test_sandbox.tl) -- or nil where it runs unsandboxed. A
    --- process the test starts with no confinement of its own is held
    --- to that (build.confine's `Observer`), and noted as a confined one
    --- is: by each of these paths.
    held: {string}
    --- Why a process `held` holds is none a key holds -- the sandbox
    --- is online, say -- or nil: such a process is noted "x", by it.
    unkeyable: string
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

--- What an absolute path resolves to, links and all, when it is read:
--- `realpath` of the path, or, when it is not there (a stat or an open
--- of a missing file is a read too), of its nearest existing ancestor
--- with the missing names after it as written, "." and ".." included:
--- the first of them is missing, so nothing after it is reached, and
--- the answer is that ancestor's. "" for a relative path. Nothing is
--- remembered between calls, since a link can be retargeted between
--- two reads. The log resolves a read's path the same way as the call
--- is made (core/observed.c's `resolution`), and build.confine's
--- `resolution` the same way in Teal, which every caller but a key's
--- observations calls.
-- TODO: drop this, and `link_resolution`, for build.confine's
-- `resolution` once nothing keys a run by its observations (removing
-- the observation log, steps 4 and 5): the log's C `resolve` goes with
-- the log.
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
--- another read's; and "z", a test's declaration that it read stat's
--- times, later still, which nothing makes now (a test depends on no
--- file's times it did not make: see build/test.tl's `held_stat`) and
--- nothing encodes; and "g" and
--- "j", a `sys.tree_digest` of a path by its contents or by its stamps,
--- after that; and "y", a program a sandboxed worker's process ran, or
--- the interpreter its first line names, for the audit alone, after
--- those.
function observations.encode(found: {observations.Observation}): string
  local lines: {string} = { "filesystem-observations-v2" }
  for _, observation in ipairs(found) do
    local kind = observation.kind
    if kind == "o" or kind == "s" or kind == "d" or kind == "e" or kind == "r" or
        kind == "u" or kind == "l" or kind == "k" or kind == "a" or kind == "c" or
        kind == "b" or kind == "v" or kind == "g" or kind == "j" or
        kind == "y" then
      lines[#lines + 1] = kind .. " " .. hex(observation.path)
    elseif kind == "t" or kind == "w" then
      lines[#lines + 1] = kind .. " " .. hex(observation.path) .. " " ..
        hex(observation.answer)
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
  return "filesystem-observations-unstable\n" .. hex(identity) .. "\n" ..
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
        line:match("^([osdertulkacbvwzgjy]) ([0-9a-f]*) ?([0-9a-f]*)$")
      local path: string = nil
      local answer: string = nil
      if encoded_path ~= nil then
        local decoded, _ = unhex(encoded_path)
        path = decoded
        local decoded_answer, _ = unhex(encoded_answer)
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
  local digits, rest = encoded:match("^filesystem%-observations%-unstable\n([0-9a-f]+)\n(.*)$")
  if digits == nil then return nil end
  local identity, _ = unhex(digits)
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

--- Every field exposed by `sys.stat` but the access time and the owner,
--- including an error result: what the path is, its size and
--- permissions first, then its modification time, inode, device and
--- link count, and its change time last. A read moves the access time,
--- so keying on it would make every verdict that reads a file stale by
--- reading it. The owner is left out as `sys.tree_digest`'s stamps leave
--- it out: a change of it moves the change time, and a sandbox nested
--- in another -- a sandboxed worker's, started by a test of a sandboxed
--- run -- maps no ids, and answers it as the overflow id (65534) where
--- the host has its own.
local function stat_result_answer(st: sys.Stat | nil, trouble: string,
                                  errno: integer): string
  if st == nil then
    return "error " .. hex(trouble) .. " " .. tostring(errno)
  end
  return table.concat({ "ok", tostring(st.size), tostring(st.mode), st.kind,
    tostring(st.mtime), tostring(st.mtime_ns), tostring(st.ino), tostring(st.dev),
    tostring(st.nlink), tostring(st.ctime),
    tostring(st.ctime_ns) }, " ")
end

--- A query's answer: its value, or its error, as a stat's is told.
local function value_answer(value: string | nil, trouble: string, errno: integer): string
  if value == nil then
    return "error " .. hex(trouble) .. " " .. tostring(errno)
  end
  return "ok " .. value
end

--- What `sys.tree_digest` answered, as a "g" or "j" observation holds
--- it: its digest, and whether what it walked was special, or its
--- error.
local function digest_result_answer(walked: sys.TreeDigest | nil, trouble: string,
                                    errno: integer): string
  if walked == nil then
    return "error " .. hex(trouble) .. " " .. tostring(errno)
  end
  return "ok " .. tostring(walked.digest) .. (walked.special and " special" or "")
end

--- What a "b" observation holds of the program's own path: that the
--- query answered, and its error whole where it failed, but not where
--- the program is. What the program is, a verdict's key holds already
--- (its runtime identity, `build.work`'s `Identities`); where it is,
--- like where the tree is, is no input a test may turn on (see
--- build.key_parts' `tree_name`), so a verdict one copy of a program
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
    return "error " .. hex(trouble) .. " " .. tostring(errno)
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
  -- The one descriptor fstat refuses is the artifact's, which the spawn
  -- took only as a relaunch hands it on (core/check.h's
  -- `cosmic_checkfd`): a regular file, the program's own.
  local asked, st = pcall(sys.fstat, fd)
  if not asked then
    if tostring(st):find("retained artifact descriptor", 1, true) ~= nil then return true end
    error(st, 0)
  end
  if st == nil then return true end -- nothing there to reach
  local format = st.mode & S_IFMT
  return format == S_IFREG or format == S_IFIFO or
    (format == S_IFCHR and inert_device(st))
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
--- stat of where it went -- "b" the program's own path, keyed by
--- whether it answered (`program_answer`), not where the program is --
--- and "g" and "j" a walk of a path with `sys.tree_digest`, by its
--- files' contents or by what `lstat` says of each entry: one
--- observation of the walk, keyed by what it answers, not one of each
--- entry beneath it.
local call_kinds: {string:string} = {
  lstat = "l", readlink = "k", realpath = "a", getcwd = "c", executable = "b",
  open = "o", stat = "s", readdir = "d", getenv = "e", environ = "e", mkdir = "m",
  mkdtemp = "m", spawn = "p", http = "x", tree_digest = "g", tree_stamps = "j",
}

--- The kinds whose path is one a key places: absolute, or none at all.
local placed: {string:boolean} = {
  o = true, s = true, d = true, l = true, k = true, a = true, m = true, g = true, j = true,
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
    elseif kind == "g" or kind == "j" then
      answer = digest_result_answer(call[1] as sys.TreeDigest, call[2] as string,
        call[3] as integer)
    elseif kind == "p" and path == "" then
      path = call.call
    end
    if kind ~= "" then
      for _, note in ipairs(noting) do note(kind, path, answer, call.resolved) end
    end
  end
end

--- Drains SQLite's record and the syscall table's log into every
--- running capture. Draining allocates, and can raise on memory: a
--- drain that fails may have taken records out of C before noting them
--- all, so every capture still running is made one no key holds.
local function drain_all()
  for _, drain in ipairs({ drain_sqlite, drain_syscalls }) do
    if not pcall(drain) then
      for _, each in ipairs(noting) do
        local _ = pcall(each, "x", drain == drain_sqlite and "sqlite" or "syscalls", "")
      end
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
-- build.confine's `confine` -- its toolchain and caches given it, the
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
--- `restore` answers the first spawn `must_confine` refused meanwhile,
--- or nil.
---
--- A "p" (a process started, not `declared`) or an "x" (a query no key can hold: a
--- request over the network, or a relative path when the working
--- directory cannot be told) makes the run's verdict one that
--- never stands.
---
--- What `cosmic.sys`'s `open`, `stat`, `readdir`, `lstat`, `readlink`,
--- `realpath`, `getcwd`, `executable`, `getenv`, `environ`, `mkdir`,
--- `mkdtemp`, `chdir` and `tree_digest`, the process table's `spawn` and cosmic.http's
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
--- test's own directory; so is a tree digest's, whose walk does not
--- follow a link its path ends in.
---
--- A file SQLite opens through `cosmic.sqlite` while the capture runs
--- -- a database, its journal or WAL, an attached one, or one it only
--- asked after -- is noted an open too, as SQLite names it, when the
--- capture ends (see `drain_sqlite`). So is each one a connection
--- opened before the capture began still holds as it begins -- one a
--- module opened as it loaded, or the store attached -- which it may
--- read any page of from here on: SQLite hands them over as recording
--- turns on, and each is keyed by its bytes as a fresh open is. One a
--- runner excluded (`observations.exclude_held_files`) is not.
---
--- The process table's `spawn` alone is also stood in for
--- (build.confine's `enter`), since a process the test starts is
--- confined (build.confine's `confine`) or noted by what its own
--- sandbox gives it, which the stand-in decides and tells the capture;
--- one started past it, through a reference taken before the capture,
--- is logged and noted "p".
local function start(resolving: observations.Resolving | nil):
                     {observations.Observation}, function(): string | nil
  drain_all()
  local found: {observations.Observation} = {}
  -- The test's own: its directory, and every directory it made for
  -- itself and that is a directory still -- one put back as a link
  -- would lead elsewhere -- which a key never holds either.
  local function test_own(): {string}
    drain_all()
    local own: {string} = {}
    for _, directory in ipairs(resolving ~= nil and resolving.own or {}) do
      own[#own + 1] = directory
    end
    for _, observation in ipairs(found) do
      if observation.kind == "m" then
        local inside = false
        for _, directory in ipairs(own) do
          if within(observation.path, directory) then inside = true end
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
          kind == "a" or kind == "g" or kind == "j") and
        path:sub(1, 1) == "/" and (not within(path, resolving.tree) or
          ("/" .. path .. "/"):find("/%.%./") ~= nil) then
      if resolved == nil then
        -- The log resolved nothing for it: where it led is unknown.
        found[#found + 1] = { kind = "x", path = path, answer = "" }
        return
      end
      -- An lstat's or a readlink's is kept apart, as "v" or "w": it
      -- stops short of a link its path ends in, which a stat's of the
      -- same path follows.
      local link = kind == "l" or kind == "k" or kind == "g" or kind == "j"
      local noted = link and "v" or "r"
      for _, directory in ipairs(resolving.own) do
        if within(path, directory) then noted = link and "w" or "t" end
      end
      if (noted == "t" or noted == "w") and resolved ~= "" and ("/" .. path .. "/"):find("/%.%./") == nil then
        -- Most of a test's reads are of its own directory; only one
        -- that leads out of it, or that climbs (which only its
        -- resolution can place), is worth a line.
        for _, directory in ipairs(resolving.own) do
          if within(resolved, directory) then return end
        end
      end
      found[#found + 1] = { kind = noted, path = path, answer = resolved }
    end
  end
  --- Notes "y", in a sandboxed worker (`Resolving`'s `held`), the
  --- program a process it starts runs, and the interpreter a script's
  --- first line names: a process is noted by what its sandbox holds, not
  --- by what it ran, and the audit asks `system` of a module whose
  --- processes run the system's own (`build.test`'s `audited`). For the
  --- audit alone: the worker's key is its declared inputs', which these
  --- do not move.
  -- TODO: note what a process of this program the test starts notes in
  -- turn -- a relaunched core running a chunk that starts /bin/sh, or a
  -- nested `cosmic test` whose own worker does -- once an inner run can
  -- hand its "y" notes up to the process that started it (a file its
  -- parent names in a variable, which the inner runner appends to):
  -- today such a grandchild's program is seen by no audit, and a test
  -- that needs `system` for it fails with a bare "start: No such file or
  -- directory".
  local function note_program(given: string, cwd: string | nil)
    -- A test of spawn's argument checks may hand it no string at all,
    -- which the call itself raises for.
    local handed: any = given
    if resolving == nil or resolving.held == nil or not handed is string or given == "" then
      return
    end
    local path = given
    -- A relative program is found from where it starts.
    if path:sub(1, 1) ~= "/" then
      local from = cwd
      if from == nil then
        local here, _ = getcwd()
        from = here
      end
      if from == nil or from:sub(1, 1) ~= "/" then return end
      local names: {string} = {}
      for name in (from .. "/" .. path):gmatch("[^/]+") do
        if name == ".." then
          names[#names] = nil
        elseif name ~= "." then
          names[#names + 1] = name
        end
      end
      path = "/" .. table.concat(names, "/")
    end
    found[#found + 1] = { kind = "y", path = path, answer = "" }
    -- Its first line, read as an open the log notes too: the program
    -- is what the process was to read first. This program's own launcher
    -- is such a script (build/launcher.tl), which a test that declares
    -- `tool` may start. A regular file alone: an open of a FIFO would
    -- wait for a writer, and one of a device may do what it does.
    local st, _ = stat(path)
    if st == nil or st.kind ~= "file" then return end
    local fd, _ = sys.open(path, sys.O_RDONLY | sys.O_NONBLOCK)
    if fd == nil then return end
    local head, _ = sys.read(fd, 256)
    local _, _ = sys.close(fd)
    local interpreter = (head or ""):match("^#!%s*(/[^%s]+)")
    if interpreter ~= nil then
      found[#found + 1] = { kind = "y", path = interpreter, answer = "" }
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
        if within(given, directory) then return true end
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
      elseif within(real, "/proc") or within(real, "/sys") then
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
  -- The stand-in for `spawn`, which confines what the test starts and
  -- tells the capture what each process was given.
  local leave = confine.enter(resolving ~= nil and resolving.own[1] or nil, {
    calls = past_the_log,
    held = resolving ~= nil and resolving.held or nil,
    unkeyable = resolving ~= nil and resolving.unkeyable or nil,
    own = test_own,
    declaring = function(): boolean return declaring > 0 end,
    program = note_program,
    given = note_unveiled,
    variable = function(name: string, value: string | nil)
      note("e", name, getenv_answer(value))
    end,
    unconfined = function(program: any) note(declaring > 0 and "h" or "p", program, "") end,
    unkeyed = function(why: any) note("x", why, "") end,
  })
  noting[#noting + 1] = note
  trees[note] = resolving ~= nil and resolving.tree or nil
  syscalls.resolving(resolving_tree())
  -- A file SQLite could not hand over is one it may read unrecorded.
  local handed, _ = sqlite.observe(true)
  if not handed then note("x", "sqlite", "") end
  syscalls.observe(true)
  return found, function(): string | nil
    -- Draining can raise on memory (see `drain_all`): the stand-in is
    -- put back first.
    local refused = leave()
    drain_all()
    for at = #noting, 1, -1 do
      if noting[at] == note then table.remove(noting, at) break end
    end
    trees[note] = nil
    syscalls.resolving(resolving_tree())
    if #noting == 0 then
      -- Turned off, nothing is handed over, and nothing fails.
      local _, _ = sqlite.observe(false)
      syscalls.observe(false)
    end
    return refused
  end
end

--- Excludes every database file a `cosmic.sqlite` connection, or one
--- the store attached, holds open at this moment: no capture that
--- starts later is handed it for being held (see `start`), though one
--- that opens it again notes that open. The files, not the connections:
--- a journal or WAL one of them opens later is handed over, harmless
--- for the worker's read-only, rollback-mode o/cosmic.db. For a
--- runner's own connections, which are no input of what it captures:
--- that o/cosmic.db, which every build rewrites, would key every test
--- by all of it, when what a test's `require` loads from it is keyed by
--- its module keys.
function observations.exclude_held_files()
  sqlite.exclude_held()
end

--- Calls a function and ends the capture even when it raises. The value
--- is left intact so callers such as `require` can consume a produced table.
--- A call that had a spawn refused by `must_confine` is one that
--- failed, with that refusal as what it raised -- before what it
--- raised itself, when it raised too.
--- Given `resolving`, a path read outside its tree is also resolved as
--- it is read; see `start`.
function observations.capture(fn: function(any...): (any...),
                              resolving?: observations.Resolving): observations.Captured
  local found, restore = start(resolving)
  local ok, produced: boolean, any = pcall(fn)
  local refused = restore()
  if refused ~= nil then
    produced = ok and refused or refused .. "; and then: " .. tostring(produced)
    ok = false
  end
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
    for name, value in pairs(environment) do held[name] = tree_name(value, tree) end
    return environ_answer(held)
  end
  local value = answer:match("^ok (.*)$")
  if value == nil then return answer end
  return "ok " .. tree_name(value, tree)
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
  local inside = within(real, real_tree)
  -- Past the log, as `stat` below is: the walk is the key's, made
  -- while a capture may run, and none of the test's reads.
  local walked, trouble = tree_digest(real, inside)
  local parts: {string} = { walked ~= nil and walked.digest or ("error " .. trouble) }
  -- The modes of the directories above it, which the root it is bound
  -- into mirrors: a program may check them, as the launcher does its
  -- cache's.
  local above = Fs.dirname(real)
  while true do
    local st, _ = stat(above)
    local name = above
    if inside then
      name = within(above, real_tree) and tree_name(above, real_tree) or ""
    end
    parts[#parts + 1] = name .. "\0above\0" .. (st ~= nil and tostring(st.mode) or "missing")
    local parent = Fs.dirname(above)
    if parent == above then break end
    above = parent
  end
  return ((walked ~= nil and walked.special) and "unkeyable " or "") ..
    (inside and tree_name(real, real_tree) or real) .. " " ..
    Hash.hex_sha256(table.concat(parts, "\n"))
end

--- What `sys.tree_digest` of `path` answers now, by its files' contents
--- or, not `contents`, by what `lstat` says of each entry, as a "g" or a
--- "j" observation holds it.
function observations.digest_answer(path: string, contents: boolean): string
  return digest_result_answer(tree_digest(path, contents))
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
