--- Files and directories.
---
--- Every call goes through the syscall table, so one call behaves the
--- same on Linux and on macOS. A call that produces a value returns
--- `T | nil, string`; a call that only has an effect returns
--- `boolean, string`.

local Env = require("cosmic.env")
local sys = require("cosmic.sys")

local record Fs
  --- What a path is and what it holds.
  Stat: sys.Stat

  stdin: integer
  stdout: integer
  stderr: integer
end

local chunk_size = 1 << 16

--- The whole of a file.
function Fs.read(path: string): string | nil, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  local parts: {string} = {}
  while true do
    local chunk, failure = sys.read(fd, chunk_size)
    if chunk == nil then
      sys.close(fd)
      return nil, path .. ": " .. failure
    end
    if #chunk == 0 then
      break
    end
    parts[#parts + 1] = chunk
  end
  sys.close(fd)
  return table.concat(parts)
end

local function write_all(fd: integer, data: string): boolean, string
  local at = 1
  while at <= #data do
    local put, trouble = sys.write(fd, data:sub(at))
    if put == nil then
      return false, trouble
    end
    if put == 0 then
      return false, "write made no progress"
    end
    at = at + put
  end
  return true, ""
end

--- Replaces a file atomically for readers, and leaves the old contents in
--- place if anything before the rename fails. This provides atomic visibility,
--- not crash durability: neither the file nor its directory is synchronized.
function Fs.write(path: string, data: string, mode?: integer): boolean, string
  local temporary, trouble = sys.open_temporary(path, mode or 0x1a4)
  if temporary == nil then
    return false, path .. ": " .. trouble
  end
  local ok, failure = write_all(temporary.fd, data)
  if not ok then
    sys.close(temporary.fd)
    sys.unlink(temporary.path)
    return false, temporary.path .. ": " .. failure
  end
  local closed, close_failure = sys.close(temporary.fd)
  if not closed then
    sys.unlink(temporary.path)
    return false, temporary.path .. ": " .. close_failure
  end
  local moved, why = sys.rename(temporary.path, path)
  if not moved then
    sys.unlink(temporary.path)
    return false, path .. ": " .. why
  end
  return true, ""
end

--- What a path is, or nil when there is nothing there.
function Fs.stat(path: string): sys.Stat | nil, string
  local st, trouble = sys.stat(path)
  if st == nil then
    return nil, path .. ": " .. trouble
  end
  return st
end

--- Whether anything is at a path.
function Fs.exists(path: string): boolean
  return sys.stat(path) ~= nil
end

--- Whether a directory is at a path.
function Fs.is_dir(path: string): boolean
  local st = sys.stat(path)
  return st ~= nil and st.kind == "dir"
end

--- Creates a directory and every missing directory above it.
function Fs.mkdirs(path: string): boolean, string
  if path == "" or path == "/" then
    return true, ""
  end
  if Fs.is_dir(path) then
    return true, ""
  end
  local parent = path:match("^(.*)/[^/]+$")
  if parent ~= nil and parent ~= "" then
    local ok, trouble = Fs.mkdirs(parent)
    if not ok then
      return false, trouble
    end
  end
  local made, why = sys.mkdir(path)
  if not made and not Fs.is_dir(path) then
    return false, path .. ": " .. why
  end
  return true, ""
end

--- A fresh, empty directory under the system temp directory, named with
--- `prefix` and a random suffix. `TMPDIR` picks the temp directory when
--- it is set, and `/tmp` otherwise.
function Fs.mkdtemp(prefix: string): string | nil, string
  local base = Env.get_or("TMPDIR", "/tmp")
  local template = base .. "/" .. prefix .. "XXXXXX"
  local path, trouble = sys.mkdtemp(template)
  if path == nil then
    return nil, template .. ": " .. trouble
  end
  return path
end

--- Removes a name. A name that is already gone is not a failure.
function Fs.remove(path: string): boolean, string
  local gone, trouble = sys.unlink(path)
  if not gone and sys.stat(path) ~= nil then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- The names in a directory, sorted, without `.` and `..`.
local function sorted_names(entries: {string:string}): {string}
  local names: {string} = {}
  for name in pairs(entries) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- The entries of a directory, sorted, without `.` and `..`.
function Fs.list(path: string): {string} | nil, string
  local entries, trouble = sys.readdir(path)
  if entries == nil then
    return nil, path .. ": " .. trouble
  end
  return sorted_names(entries)
end

--- Every file under a root, sorted, as paths relative to that root.
--- `skip` is asked about each entry's relative path, and its bare name
--- second, and may refuse a whole directory. The listing says what
--- each entry is, so nothing here is stat'd.
function Fs.walk(root: string,
                 skip?: function(string, string): boolean): {string} | nil, string
  local found: {string} = {}
  local pending: {string} = { "" }
  while #pending > 0 do
    local relative = table.remove(pending)
    local directory = relative == "" and root or (root .. "/" .. relative)
    local entries, trouble = sys.readdir(directory)
    if entries == nil then
      return nil, directory .. ": " .. trouble
    end
    for _, name in ipairs(sorted_names(entries)) do
      local entry = relative == "" and name or (relative .. "/" .. name)
      if skip == nil or not skip(entry, name) then
        local kind = entries[name]
        if kind == "dir" then
          pending[#pending + 1] = entry
        elseif kind == "file" then
          found[#found + 1] = entry
        end
      end
    end
  end
  table.sort(found)
  return found
end

--- A path with no link and no `..` left in it.
function Fs.absolute(path: string): string | nil, string
  local resolved, trouble = sys.realpath(path)
  if resolved == nil then
    return nil, path .. ": " .. trouble
  end
  return resolved
end

--- Moves a name, replacing the destination if it is there.
function Fs.rename(from: string, to: string): boolean, string
  local moved, trouble = sys.rename(from, to)
  if not moved then
    return false, from .. ": " .. trouble
  end
  return true, ""
end

--- Opens a file for reading and returns its descriptor. Most callers
--- want `read` instead; this is for one that reads in pieces.
function Fs.open_read(path: string): integer | nil, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  return fd
end

--- Opens a file for writing, creating it and emptying it.
function Fs.open_write(path: string, mode?: integer): integer | nil, string
  local flags = sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC
  local fd, trouble = sys.open(path, flags, mode or 0x1a4)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  return fd
end

--- Reads up to `count` bytes from a descriptor. An empty string is the
--- end of the file.
function Fs.take(fd: integer, count: integer): string | nil, string
  local data, trouble = sys.read(fd, count)
  if data == nil then
    return nil, trouble
  end
  return data
end

--- Closes a descriptor.
function Fs.close(fd: integer): boolean, string
  local ok, trouble = sys.close(fd)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Writes bytes to a stream, without a newline.
function Fs.put(fd: integer, data: string): boolean, string
  return write_all(fd, data)
end

Fs.stdin = 0
Fs.stdout = 1
Fs.stderr = 2

return Fs
