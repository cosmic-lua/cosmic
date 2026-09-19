--- Filesystem queries whose answers may affect a test verdict.

local sys = require("cosmic.sys")

local record observations
  stat_result_answer: function(sys.Stat | nil, string, integer): string
  directory_result_answer: function({string:string} | nil, string, integer): string

  record Observation
    kind: string
    path: string
    answer: string
  end
end

local function hex(data: string): string
  return (data:gsub(".", function(byte: string): string
    return string.format("%02x", string.byte(byte))
  end))
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
    lines[#lines + 1] = observation.kind .. " " .. hex(observation.path)
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
      local kind, encoded_path = line:match("^([osd]) ([0-9a-f]*)$")
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
  return found, function()
    sys.open = open
    sys.stat = stat
    sys.readdir = readdir
  end
end

--- Calls one test body and restores every wrapper even when it raises.
function observations.call(fn: function(any...): (any...), argument: any):
                           boolean, string, {observations.Observation}
  local found, restore = observations.start()
  local ok, failure = pcall(fn, argument)
  restore()
  return ok, ok and "" or tostring(failure), found
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
