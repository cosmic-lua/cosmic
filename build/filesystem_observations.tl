--- Filesystem queries whose answers may affect a test verdict.

local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record observations
  stat_result_answer: function(sys.Stat | nil, string, integer): string
  directory_result_answer: function({string:string} | nil, string, integer): string
  getenv_answer: function(string | nil): string
  environ_answer: function({string:string}): string
  environ_path: string

  record Observation
    kind: string
    path: string
    answer: string
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

--- Every byte's two-digit lowercase hex, built once: `gsub` accepts this
--- table directly as its replacement, so encoding a string costs one
--- table lookup per byte instead of one closure call.
local hex_byte: {string:string} = {}
for byte = 0, 255 do
  hex_byte[string.char(byte)] = string.format("%02x", byte)
end

local function hex(data: string): string
  return (data:gsub(".", hex_byte))
end

--- One framed contribution to a verdict key.
function observations.key_part(kind: string, path: string, answer: string): string
  return kind .. " " .. hex(path) .. " " .. hex(answer)
end

local function unhex(data: string): string | nil
  if #data % 2 ~= 0 or data:find("[^0-9a-f]") ~= nil then
    return nil
  end
  return (data:gsub("..", function(byte: string): string
    return string.char(tonumber(byte, 16) or 0)
  end))
end

--- A versioned, line-safe representation. Paths may themselves contain newlines.
function observations.encode(found: {observations.Observation}): string
  local lines: {string} = { "filesystem-observations-v1" }
  for _, observation in ipairs(found) do
    local kind = observation.kind
    if kind == "o" or kind == "s" or kind == "d" or kind == "e" then
      lines[#lines + 1] = kind .. " " .. hex(observation.path)
    end
  end
  return table.concat(lines, "\n")
end

--- Marks a run whose observations changed while it ran. It must run again:
--- no single current filesystem answer can represent what that run observed.
function observations.encode_unstable(): string
  return "filesystem-observations-unstable"
end

--- Old rows described opens only, so they cannot safely produce a verdict.
function observations.decode(encoded: string): {observations.Observation} | nil
  if encoded:match("^[^\n]*") ~= "filesystem-observations-v1" then
    return nil
  end
  local found: {observations.Observation} = {}
  for line in encoded:gmatch("[^\n]+") do
    if line ~= "filesystem-observations-v1" then
      local kind, encoded_path = line:match("^([osde]) ([0-9a-f]*)$")
      local path = encoded_path ~= nil and unhex(encoded_path) or nil
      if kind == nil or path == nil then
        return nil
      end
      found[#found + 1] = { kind = kind, path = path, answer = "" }
    end
  end
  return found
end

--- Installs observers until `restore` is called. The wrappers record failed
--- queries too: absence and errors are answers a test can depend on.
function observations.start(): {observations.Observation}, function()
  local found: {observations.Observation} = {}
  local open = sys.open
  local stat = sys.stat
  local readdir = sys.readdir
  local getenv = sys.getenv
  local environ = sys.environ
  local spawn = sys.spawn
  local mkdtemp = sys.mkdtemp
  local mkdir = sys.mkdir
  sys.open = function(path: string, flags: integer,
                      mode?: integer): integer | nil, string, integer
    found[#found + 1] = { kind = "o", path = path, answer = "" }
    return open(path, flags, mode)
  end
  sys.stat = function(path: string): sys.Stat | nil, string, integer
    local st, trouble, errno = stat(path)
    found[#found + 1] = { kind = "s", path = path,
      answer = observations.stat_result_answer(st, trouble, errno) }
    return st, trouble, errno
  end
  sys.readdir = function(path: string): {string:string} | nil, string, integer
    local entries, trouble, errno = readdir(path)
    found[#found + 1] = { kind = "d", path = path,
      answer = observations.directory_result_answer(entries, trouble, errno) }
    return entries, trouble, errno
  end
  sys.getenv = function(name: string): string | nil
    local value = getenv(name)
    found[#found + 1] = { kind = "e", path = name, answer = observations.getenv_answer(value) }
    return value
  end
  sys.environ = function(): {string:string}
    local environment = environ()
    found[#found + 1] = { kind = "e", path = observations.environ_path,
      answer = observations.environ_answer(environment) }
    return environment
  end
  sys.spawn = function(path: string, argv: {string}, environment: {string:string} | nil,
                       cwd: string | nil, stdin: integer | nil, stdout: integer | nil,
                       stderr: integer | nil, process_group: boolean):
                       integer | nil, string, integer
    found[#found + 1] = { kind = "p", path = path, answer = "" }
    return spawn(path, argv, environment, cwd, stdin, stdout, stderr, process_group)
  end
  sys.mkdtemp = function(template: string): string | nil, string, integer
    local path, trouble, errno = mkdtemp(template)
    if path ~= nil then
      found[#found + 1] = { kind = "m", path = path, answer = "" }
    end
    return path, trouble, errno
  end
  sys.mkdir = function(path: string, mode?: integer): boolean, string, integer
    local ok, trouble, errno = mkdir(path, mode)
    if ok then
      found[#found + 1] = { kind = "m", path = path, answer = "" }
    end
    return ok, trouble, errno
  end
  return found, function()
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
function observations.capture(fn: function(any...): (any...)):
                              boolean, any, {observations.Observation}
  local found, restore = observations.start()
  local ok, produced = pcall(fn)
  restore()
  return ok, produced, found
end

--- Calls one test body and presents its failure as text to the runner.
function observations.call(fn: function(any...): (any...), argument: any):
                           boolean, string, {observations.Observation}
  local ok, produced, found = observations.capture(function(): any
    return fn(argument)
  end)
  return ok, ok and "" or tostring(produced), found
end

--- One environment variable's value, or a marker no real value can equal.
function observations.getenv_answer(value: string | nil): string
  if value == nil then
    return "absent"
  end
  return "ok " .. value
end

--- The whole environment, order-independent: every `NAME=VALUE` pair,
--- sorted by name, hashed together, so a `sys.environ` read is keyed on
--- the whole environment rather than on any one variable.
function observations.environ_answer(environment: {string:string}): string
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
observations.environ_path = "\0environ"

--- The current answer to an "e" observation, re-read live rather than
--- trusted from the row: `sys.environ`'s hash for `environ_path`, or
--- `sys.getenv`'s answer for a named variable.
function observations.getenv_current(path: string): string
  if path == observations.environ_path then
    return observations.environ_answer(sys.environ())
  end
  return observations.getenv_answer(sys.getenv(path))
end

--- Every field exposed by `sys.stat`, including an error result.
function observations.stat_result_answer(st: sys.Stat | nil, trouble: string,
                                         errno: integer): string
  if st == nil then
    return "error " .. hex(trouble) .. " " .. tostring(errno)
  end
  return table.concat({ "ok", tostring(st.size), tostring(st.mode), st.kind,
    tostring(st.mtime), tostring(st.mtime_ns), tostring(st.ino), tostring(st.dev),
    tostring(st.nlink), tostring(st.uid), tostring(st.gid) }, " ")
end

function observations.stat_answer(path: string): string
  return observations.stat_result_answer(sys.stat(path))
end

--- A directory answer includes names, kinds, and errors. Length-prefixing each
--- name makes this unambiguous for every name the filesystem permits.
function observations.directory_result_answer(entries: {string:string} | nil,
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

function observations.directory_answer(path: string): string
  return observations.directory_result_answer(sys.readdir(path))
end

return observations
