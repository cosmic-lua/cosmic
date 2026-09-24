--- Filesystem queries whose answers may affect a test verdict.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Http = require("cosmic.http")
local sys = require("cosmic.sys")

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

  --- One test body's run: whether it passed, its failure as text (""
  --- when it passed), and what it read either way.
  record Run
    passed: boolean
    message: string
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
    local real, _ = sys.realpath(at)
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
    if kind == "o" or kind == "s" or kind == "d" or kind == "e" or kind == "r" then
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
      local kind, encoded_path, encoded_answer = line:match("^([osdert]) ([0-9a-f]*) ?([0-9a-f]*)$")
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

--- Every field exposed by `sys.stat`, including an error result.
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

--- Installs observers until `restore` is called. The wrappers record failed
--- queries too: absence and errors are answers a test can depend on.
---
--- A "p" (a process started) or an "x" (a query no key can hold: a
--- request over the network, or a change of working directory, after
--- which a relative path no longer names a file in the tree) makes the
--- run's verdict one that never stands.
---
--- Given `resolving`, an absolute path an open, a stat or a listing
--- names outside its tree, or that climbs with "..", is noted a second
--- time, as an "r" (a "t" under the test's own directory, and only
--- when it leads out of it or climbs) whose answer is
--- `observations.resolution` of it then: a file of the tree may be
--- named through a link outside it, and what the link led to when the
--- test read it is what its verdict describes.
-- TODO: observe every call at the syscall table's dispatch, as
-- design.md's trace point promises, rather than by replacing fields of
-- `cosmic.sys` and `cosmic.http` here: lstat, readlink, realpath and
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
  local spawn = sys.spawn
  local mkdtemp = sys.mkdtemp
  local mkdir = sys.mkdir
  local chdir = sys.chdir
  local http_open = Http.open
  -- A test holding a call to its argument checks may hand it a path
  -- that is no string at all, which the call itself raises for; only a
  -- path is an observation, and encoding anything else into a key would
  -- end the worker before the test could report.
  local function note(kind: string, path: any, answer: string)
    if path is string then
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
  sys.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                       cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                       stderr: integer | nil, process_group: boolean,
                       fds?: {integer:integer}): integer | nil, string, integer
    note("p", path, "")
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group, fds)
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
    note("x", path, "")
    return chdir(path)
  end
  -- A scripted request answers from the test's own text and connects
  -- nowhere; any other is the network's answer.
  Http.open = function(url: string, opts?: Http.Options): Http.Response | nil, string
    -- An `opts` that is no table is Http.open's own error to raise.
    local given: any = opts
    if type(given) ~= "table" or opts.script == nil then
      note("x", url, "")
    end
    return http_open(url, opts)
  end
  return found, function()
    sys.chdir = chdir
    Http.open = http_open
    sys.open = open
    sys.stat = stat
    sys.readdir = readdir
    sys.getenv = getenv
    sys.environ = environ
    sys.spawn = spawn
    sys.mkdtemp = mkdtemp
    sys.mkdir = mkdir
  end
end

--- Calls a function and restores every wrapper even when it raises. The value
--- is left intact so callers such as `require` can consume a produced table.
--- Given `resolving`, a path read outside its tree is also resolved as
--- it is read; see `start`.
function observations.capture(fn: function(any...): (any...),
                              resolving?: observations.Resolving):
                              boolean, any, {observations.Observation}
  local found, restore = start(resolving)
  local ok, produced = pcall(fn)
  restore()
  return ok, produced, found
end

--- Calls one test body and presents its failure as text to the runner,
--- beside what the body read whether it passed or not.
function observations.call(fn: function(any...): (any...), argument: any,
                           resolving?: observations.Resolving): observations.Run
  local ok, produced, found = observations.capture(function(): any
    return fn(argument)
  end, resolving)
  return { passed = ok, message = ok and "" or tostring(produced), reads = found }
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

function observations.stat_answer(path: string): string
  return stat_result_answer(sys.stat(path))
end

function observations.directory_answer(path: string): string
  return directory_result_answer(sys.readdir(path))
end

return observations
