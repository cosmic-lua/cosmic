--- Files and directories.
---
--- Every call goes through the syscall table, so one call behaves the
--- same on Linux and on macOS. A call that produces a value returns
--- `T | nil, string`; a call that only has an effect returns
--- `boolean, string`.

local sys = require("cosmic.syscalls")

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
    at = at + put
  end
  return true, ""
end

--- Replaces a file's contents, and leaves the old contents in place if
--- anything fails: the bytes go to a neighbouring name first and the
--- rename is what the reader sees.
function Fs.write(path: string, data: string, mode?: integer): boolean, string
  local temporary = path .. ".writing"
  local flags = sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC
  local fd, trouble = sys.open(temporary, flags, mode or 0x1a4)
  if fd == nil then
    return false, temporary .. ": " .. trouble
  end
  local ok, failure = write_all(fd, data)
  sys.close(fd)
  if not ok then
    sys.unlink(temporary)
    return false, temporary .. ": " .. failure
  end
  local moved, why = sys.rename(temporary, path)
  if not moved then
    sys.unlink(temporary)
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

--- Removes a name. A name that is already gone is not a failure.
function Fs.remove(path: string): boolean, string
  local gone, trouble = sys.unlink(path)
  if not gone and sys.stat(path) ~= nil then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- The entries of a directory, sorted, without `.` and `..`.
function Fs.list(path: string): {string} | nil, string
  local names, trouble = sys.readdir(path)
  if names == nil then
    return nil, path .. ": " .. trouble
  end
  table.sort(names)
  return names
end

--- Every file under a root, sorted, as paths relative to that root.
--- `skip` is asked about each entry's relative path and may refuse a
--- whole directory.
function Fs.walk(root: string, skip?: function(string): boolean): {string} | nil, string
  local found: {string} = {}
  local pending: {string} = { "" }
  while #pending > 0 do
    local relative = table.remove(pending)
    local directory = relative == "" and root or (root .. "/" .. relative)
    local names, trouble = Fs.list(directory)
    if names == nil then
      return nil, trouble
    end
    for _, name in ipairs(names) do
      local entry = relative == "" and name or (relative .. "/" .. name)
      if skip == nil or not skip(entry) then
        local st = sys.stat(directory .. "/" .. name)
        if st ~= nil then
          if st.kind == "dir" then
            pending[#pending + 1] = entry
          elseif st.kind == "file" then
            found[#found + 1] = entry
          end
        end
      end
    end
  end
  table.sort(found)
  return found
end

--- Writes bytes to a stream, without a newline.
function Fs.put(fd: integer, data: string): boolean, string
  return write_all(fd, data)
end

Fs.stdin = 0
Fs.stdout = 1
Fs.stderr = 2

return Fs
