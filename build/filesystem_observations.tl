--- Filesystem queries whose answers may affect a test verdict.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

--- The raw process table, whose `spawn` `cosmic.child` starts every
--- child with: this module is handed it (core/store.c's `raw_modules`)
--- to note each child a test starts by standing in for that call.
local type raw_process = require("cosmic.internal.process")

local extra: any = select(2, ...)
local process: raw_process
if type(extra) == "table" then
  process = extra as raw_process
else
  process = require("cosmic.internal.process")
end

-- What placing a path asks of the process, taken when this module
-- loads -- before any test's module does -- so a test that stubs one
-- cannot bend where its own reads are keyed.
-- TODO: take the `Fs` functions a note calls (`within`, `dirname`,
-- `basename`) the same way: a test that replaces one on the shared
-- `Fs` table can still move a read in or out of the tree.
local getcwd = sys.getcwd
local realpath = sys.realpath

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
--- two reads.
function observations.resolution(path: string): string
  if path:sub(1, 1) ~= "/" then return "" end
  local missing: {string} = {}
  local at = path
  while true do
    local real, _ = realpath(at)
    if real ~= nil then
      for i = #missing, 1, -1 do
        real = (real == "/" and "" or real) .. "/" .. missing[i]
      end
      return real
    end
    local parent = Fs.dirname(at)
    if parent == at then return "" end
    missing[#missing + 1] = Fs.basename(at)
    at = parent
  end
end

--- A versioned, line-safe representation. Paths may themselves contain
--- newlines. Version 2 added "r", what a path outside the tree resolved
--- to when it was read, and "t", the same for a path under the test's
--- own directory, which alone keeps its answer: that directory is gone
--- by the time a later run could resolve the path again.
function observations.encode(found: {observations.Observation}): string
  local lines: {string} = { "filesystem-observations-v2" }
  for _, observation in ipairs(found) do
    local kind = observation.kind
    if kind == "o" or kind == "s" or kind == "d" or kind == "e" or kind == "r" or
        kind == "u" then
      lines[#lines + 1] = kind .. " " .. Codec.hex(observation.path)
    elseif kind == "t" then
      lines[#lines + 1] = kind .. " " .. Codec.hex(observation.path) .. " " ..
        Codec.hex(observation.answer)
    end
  end
  return table.concat(lines, "\n")
end

--- Marks a run whose observations changed while it ran. It must run again:
--- no single current filesystem answer can represent what that run observed.
function observations.encode_unstable(): string
  return "filesystem-observations-unstable"
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
      local kind, encoded_path, encoded_answer = line:match("^([osdertu]) ([0-9a-f]*) ?([0-9a-f]*)$")
      local path: string = nil
      local answer: string = nil
      if encoded_path ~= nil then
        local decoded, _ = Codec.unhex(encoded_path)
        path = decoded
        local decoded_answer, _ = Codec.unhex(encoded_answer)
        answer = decoded_answer
      end
      if kind == nil or path == nil or answer == nil or (kind ~= "t" and answer ~= "") then
        return nil
      end
      found[#found + 1] = { kind = kind, path = path, answer = answer }
    end
  end
  return found
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
local declaring = 0
local noting: {function(string, any, string)} = {}

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

--- Installs observers until `restore` is called. The wrappers record failed
--- queries too: absence and errors are answers a test can depend on.
---
--- A "p" (a process started, not `declared`) or an "x" (a query no key can hold: a
--- request over the network, or a relative path when the working
--- directory cannot be told) makes the run's verdict one that
--- never stands.
---
--- A relative path is noted as the absolute one it names from the
--- working directory the call was made in, asked of the process itself
--- rather than tracked: a change of directory made while the module
--- loaded, or through a reference to `sys.chdir` taken then, moves the
--- test's own reads too. A change of directory is itself noted as a
--- stat of where it went.
---
--- Given `resolving`, an absolute path an open, a stat or a listing
--- names outside its tree, or that climbs with "..", is noted a second
--- time, as an "r" (a "t" under the test's own directory, and only
--- when it leads out of it or climbs) whose answer is
--- `observations.resolution` of it then: a file of the tree may be
--- named through a link outside it, and what the link led to when the
--- test read it is what its verdict describes.
-- TODO: observe the files SQLite opens: `cosmic.sqlite` opens them in
-- C, through the VFS, where nothing here sees them, so a test that reads
-- a database under the tree (a verb run in-process by `build.invoke`
-- reading the tree's o/build.db, say) is keyed without it. The fix is a
-- VFS whose xOpen reports each path to the same notes.
-- TODO: observe every call at the syscall table's dispatch, as
-- design.md's trace point promises, rather than by replacing fields of
-- `cosmic.sys`, `cosmic.internal.process` and `cosmic.http` here: lstat, readlink, realpath and
-- getcwd are not observed, so a test whose answer turns on one of them
-- outside the tree can still stand.
local function start(resolving: observations.Resolving | nil):
                     {observations.Observation}, function()
  local found: {observations.Observation} = {}
  local open = sys.open
  local stat = sys.stat
  local readdir = sys.readdir
  local getenv = sys.getenv
  local environ = sys.environ
  local spawn = process.spawn
  local mkdtemp = sys.mkdtemp
  local mkdir = sys.mkdir
  local chdir = sys.chdir
  local http_open = Http.open
  -- A test holding a call to its argument checks may hand it a path
  -- that is no string at all, which the call itself raises for; only a
  -- path is an observation, and encoding anything else into a key would
  -- end the worker before the test could report.
  local function note(kind: string, given: any, answer: string)
    if given is string then
      local path = given
      if path:sub(1, 1) ~= "/" and
          (kind == "o" or kind == "s" or kind == "d" or kind == "m") then
        local here, _ = getcwd()
        if here == nil then
          found[#found + 1] = { kind = "x", path = path, answer = "" }
          return
        end
        path = (here == "/" and "" or here) .. "/" .. path
      end
      found[#found + 1] = { kind = kind, path = path, answer = answer }
      if resolving ~= nil and (kind == "o" or kind == "s" or kind == "d") and
          path:sub(1, 1) == "/" and (not Fs.within(path, resolving.tree) or
            ("/" .. path .. "/"):find("/%.%./") ~= nil) then
        local noted = "r"
        for _, directory in ipairs(resolving.own) do
          if Fs.within(path, directory) then noted = "t" end
        end
        -- TODO: resolve by the call itself, not beside it (the path an
        -- opened descriptor names, once cosmic.sys carries one): another
        -- process retargeting a link between the two goes unseen.
        local resolved = observations.resolution(path)
        if noted == "t" and resolved ~= "" and ("/" .. path .. "/"):find("/%.%./") == nil then
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
  end
  sys.open = function(path: string, flags: integer,
                      mode?: integer): integer | nil, string, integer
    note("o", path, "")
    return open(path, flags, mode)
  end
  sys.stat = function(path: string): sys.Stat | nil, string, integer
    local st, trouble, errno = stat(path)
    note("s", path, stat_result_answer(st, trouble, errno))
    return st, trouble, errno
  end
  sys.readdir = function(path: string): {string:string} | nil, string, integer
    local entries, trouble, errno = readdir(path)
    note("d", path, directory_result_answer(entries, trouble, errno))
    return entries, trouble, errno
  end
  sys.getenv = function(name: string): string | nil
    local value = getenv(name)
    note("e", name, getenv_answer(value))
    return value
  end
  sys.environ = function(): {string:string}
    local environment = environ()
    found[#found + 1] = { kind = "e", path = environ_path,
      answer = environ_answer(environment) }
    return environment
  end
  -- The test's own: its directory, and every directory it made for
  -- itself and that is a directory still -- one put back as a link
  -- would lead elsewhere -- which a key never holds either.
  local function test_own(): {string}
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
        local st, _ = sys.lstat(observation.path)
        if not inside and st ~= nil and st.kind == "dir" then
          own[#own + 1] = observation.path
        end
      end
    end
    return own
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
  sys.mkdtemp = function(template: string): string | nil, string, integer
    local path, trouble, errno = mkdtemp(template)
    if path ~= nil then
      note("m", path, "")
    end
    return path, trouble, errno
  end
  sys.mkdir = function(path: string, mode?: integer): boolean, string, integer
    local ok, trouble, errno = mkdir(path, mode)
    if ok then
      note("m", path, "")
    end
    return ok, trouble, errno
  end
  sys.chdir = function(path: string): boolean, string, integer
    note("s", path, stat_result_answer(stat(path)))
    return chdir(path)
  end
  -- A scripted request answers from the test's own text and connects
  -- nowhere; any other is the network's answer.
  Http.open = function(url: string, opts?: Http.Options): Http.Response | nil, string
    -- An `opts` that is no table is Http.open's own error to raise.
    local given: any = opts
    if (type(given) ~= "table" or opts.script == nil) and reaches(url) then
      note("x", url, "")
    end
    return http_open(url, opts)
  end
  noting[#noting + 1] = note
  return found, function()
    for at = #noting, 1, -1 do
      if noting[at] == note then table.remove(noting, at) break end
    end
    sys.chdir = chdir
    Http.open = http_open
    sys.open = open
    sys.stat = stat
    sys.readdir = readdir
    sys.getenv = getenv
    sys.environ = environ
    process.spawn = spawn
    sys.mkdtemp = mkdtemp
    sys.mkdir = mkdir
  end
end

--- Calls a function and restores every wrapper even when it raises. The value
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
--- `sys.getenv`'s answer for a named variable.
function observations.getenv_current(path: string): string
  if path == environ_path then
    return environ_answer(sys.environ())
  end
  return getenv_answer(sys.getenv(path))
end

--- What a path given to a confined process holds now, for its "u"
--- observation's line in a key: where it resolves to, `sys.tree_digest`
--- of it -- each file's contents where it resolves under `tree`, and
--- otherwise what `lstat` says of each entry, which a package installed
--- or a file replaced changes -- and the mode of each directory above
--- it. One that holds a socket, a FIFO or a device other than an inert
--- one answers from past the root, and its answer starts "unkeyable ".
function observations.unveiled_answer(path: string, tree: string): string
  local real, _ = realpath(path)
  if real == nil then return "missing" end
  local walked, trouble = sys.tree_digest(real, Fs.within(real, tree))
  local parts: {string} = { walked ~= nil and walked.digest or ("error " .. trouble) }
  -- The modes of the directories above it, which the root it is bound
  -- into mirrors: a program may check them, as the launcher does its
  -- cache's.
  local above = Fs.dirname(real)
  while true do
    local st, _ = sys.stat(above)
    parts[#parts + 1] = above .. "\0above\0" .. (st ~= nil and tostring(st.mode) or "missing")
    local parent = Fs.dirname(above)
    if parent == above then break end
    above = parent
  end
  return ((walked ~= nil and walked.special) and "unkeyable " or "") .. real .. " " ..
    Hash.hex_sha256(table.concat(parts, "\n"))
end

function observations.stat_answer(path: string): string
  return stat_result_answer(sys.stat(path))
end

function observations.directory_answer(path: string): string
  return directory_result_answer(sys.readdir(path))
end

return observations
