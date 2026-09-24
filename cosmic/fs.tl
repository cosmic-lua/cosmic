--- Files and directories.
---
--- Every call goes through the syscall table, so one call behaves the
--- same on Linux and on macOS. A fallible call that produces a value
--- returns `T | nil, string`: a value and `""` on success, or nil and
--- an error. A predicate uses the same contract, with false as a valid
--- answer. A call that only has an effect returns `boolean, string`.
---
--- `basename`, `dirname`, `within` and `relative` are the exception:
--- they work on a path's text alone, read nothing, and cannot fail, so
--- each answers a plain value.
---
--- The syscall table itself is `cosmic.sys`. A call this module does not
--- wrap -- `lstat`, `chdir`, `pread` and others -- is there, and
--- `cosmic docs cosmic.sys` lists every one.

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

--- The whole of a file as bytes. Use this for the common io.open/io.read or
--- io.lines case when streaming and Lua file handles are unnecessary.
function Fs.read(path: string): string | nil, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  -- A regular file says how big it is, so its bytes come in one read
  -- into one string of that size; chunks follow only for whatever it
  -- holds past that, or for a file that does not say (a pipe, /proc).
  local st = sys.fstat(fd)
  local ask = chunk_size
  if st ~= nil and st.kind == "file" and st.size > chunk_size then
    ask = st.size
  end
  local parts: {string} = {}
  while true do
    local chunk, failure = sys.read(fd, ask)
    if chunk == nil then
      sys.close(fd)
      return nil, path .. ": " .. failure
    end
    if #chunk == 0 then
      break
    end
    parts[#parts + 1] = chunk
    ask = chunk_size
  end
  sys.close(fd)
  if #parts == 1 then
    return parts[1], ""
  end
  return table.concat(parts), ""
end

local function write_all(fd: integer, data: string): boolean, string
  local at = 1
  while at <= #data do
    -- The whole string the first time, rather than a copy of it.
    local rest = at == 1 and data or data:sub(at)
    local put, trouble = sys.write(fd, rest)
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

--- Writes all bytes, replacing the path. This is the whole-file alternative
--- to io.open/io.write. Replaces a file atomically for readers, and leaves the old contents in
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

--- Metadata for a path, or nil and an error if it cannot be inspected.
function Fs.stat(path: string): sys.Stat | nil, string
  local st, trouble = sys.stat(path)
  if st == nil then
    return nil, path .. ": " .. trouble
  end
  return st, ""
end

--- Whether anything is at a path. A missing path is false, while an error
--- inspecting the path is nil.
function Fs.exists(path: string): boolean | nil, string
  local st, trouble, number = sys.stat(path)
  if st ~= nil then
    return true, ""
  end
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return false, ""
  end
  return nil, path .. ": " .. trouble
end

--- Whether a directory is at a path. A missing path or an existing
--- non-directory is false, while an error inspecting the path is nil.
function Fs.is_dir(path: string): boolean | nil, string
  local st, trouble, number = sys.stat(path)
  if st ~= nil then
    return st.kind == "dir", ""
  end
  if number == sys.ENOENT or number == sys.ENOTDIR then
    return false, ""
  end
  return nil, path .. ": " .. trouble
end

--- Creates a directory and every missing directory above it.
function Fs.mkdirs(path: string): boolean, string
  path = path:gsub("(.)/+$", "%1")
  if path == "" or path == "/" then
    return true, ""
  end
  local directory, inspection = Fs.is_dir(path)
  if directory == nil then
    return false, inspection
  end
  if directory then
    return true, ""
  end
  local parent = path:match("^(.*)/[^/]+$")
  if parent ~= nil and parent ~= "" then
    local ok, trouble = Fs.mkdirs(parent)
    if not ok then
      return false, trouble
    end
  end
  local made, why, number = sys.mkdir(path)
  if made then
    return true, ""
  end
  if number == sys.EEXIST then
    local raced, race_trouble = Fs.is_dir(path)
    if raced == nil then
      return false, race_trouble
    end
    if raced then
      return true, ""
    end
  end
  return false, path .. ": " .. why
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
  return path, ""
end

--- A directory of this user's own at `path`, made 0700 when missing:
--- one that exists owned by another user, or writable by its group or
--- by others, is refused, since whatever such a directory holds could
--- have been put there by someone else.
local function private_dir(path: string): boolean, string
  local made, why, number = sys.mkdir(path, 0x1c0)
  if not made and number ~= sys.EEXIST then
    return false, path .. ": " .. why
  end
  local st, trouble = sys.stat(path)
  if st == nil then
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "dir" then
    return false, path .. ": not a directory"
  end
  if st.uid ~= sys.getuid() then
    return false, path .. ": owned by another user"
  end
  if st.mode & 0x12 ~= 0 then
    return false, path .. ": writable by its group or others"
  end
  return true, ""
end

--- `$XDG_CACHE_HOME/cosmic/<tool>`, or `$HOME/.cache/cosmic/<tool>`
--- when `XDG_CACHE_HOME` is unset, empty or not absolute, created when
--- missing. What a tool keeps there it trusts on later runs, so there
--- is no shared fallback: with neither variable naming an absolute
--- path this is nil and an error, as it is when the base directory is
--- owned by another user (root aside), or `cosmic` or `cosmic/<tool>`
--- under it is owned by another user or writable by its group or by
--- others. The two are made 0700 when missing. `environment` is the
--- variables to read, by default the process's own.
function Fs.cache_dir(tool: string, environment?: {string:string}): string | nil, string
  local function get(name: string): string
    if environment ~= nil then
      return environment[name] or ""
    end
    return Env.get_or(name, "")
  end
  local base = get("XDG_CACHE_HOME")
  if base:sub(1, 1) ~= "/" then
    local home = get("HOME")
    if home:sub(1, 1) ~= "/" then
      return nil, "no cache directory: neither XDG_CACHE_HOME nor HOME is an absolute path"
    end
    base = home .. "/.cache"
  end
  local made, trouble = Fs.mkdirs(base)
  if not made then
    return nil, trouble
  end
  local st, strouble = Fs.stat(base)
  if st == nil then
    return nil, strouble
  end
  if st.uid ~= sys.getuid() and st.uid ~= 0 then
    return nil, base .. ": owned by another user"
  end
  local dir = base .. "/cosmic"
  for _, path in ipairs({ dir, dir .. "/" .. tool }) do
    local ok, ptrouble = private_dir(path)
    if not ok then
      return nil, ptrouble
    end
  end
  return dir .. "/" .. tool, ""
end

--- Removes a name: the path operation corresponding to os.remove. A name that
--- is already gone is not a failure.
function Fs.remove(path: string): boolean, string
  local gone, trouble, number = sys.unlink(path)
  if gone or number == sys.ENOENT or number == sys.ENOTDIR then
    return true, ""
  end
  return false, path .. ": " .. trouble
end

--- Removes a path and, when it is a directory, everything under it:
--- the `rm -rf` a scratch directory wants. A link is removed, never
--- followed, so nothing outside `path` is touched. A path that is
--- already gone is not a failure.
function Fs.remove_tree(path: string): boolean, string
  local st, trouble, number = sys.lstat(path)
  if st == nil then
    if number == sys.ENOENT or number == sys.ENOTDIR then
      return true, ""
    end
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "dir" then
    return Fs.remove(path)
  end
  local entries, list_trouble = sys.readdir(path)
  if entries == nil then
    return false, path .. ": " .. list_trouble
  end
  for name in pairs(entries) do
    local gone, why = Fs.remove_tree(path .. "/" .. name)
    if not gone then
      return false, why
    end
  end
  local removed, rmdir_trouble, rmdir_number = sys.rmdir(path)
  if not removed and rmdir_number ~= sys.ENOENT then
    return false, path .. ": " .. rmdir_trouble
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
  return sorted_names(entries), ""
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
  return found, ""
end

--- A path with no link and no `..` left in it.
function Fs.absolute(path: string): string | nil, string
  local resolved, trouble = sys.realpath(path)
  if resolved == nil then
    return nil, path .. ": " .. trouble
  end
  return resolved, ""
end

--- Moves a name, replacing the destination if it is there; this corresponds
--- to os.rename.
function Fs.rename(from: string, to: string): boolean, string
  local moved, trouble = sys.rename(from, to)
  if not moved then
    return false, from .. ": " .. trouble
  end
  return true, ""
end

--- The Lua io module and io.open handles are unavailable. This opens a file
--- for reading and returns an integer descriptor instead. Most callers want
--- `Fs.read`; use Fs.take and Fs.close when a file must be read in pieces.
function Fs.open_read(path: string): integer | nil, string
  local fd, trouble = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  return fd, ""
end

--- Opens a file for writing, creating it and emptying it, and returns an
--- integer descriptor rather than an io.open file handle. Use Fs.put and
--- Fs.close; Fs.write is safer when the whole replacement is available.
function Fs.open_write(path: string, mode?: integer): integer | nil, string
  local flags = sys.O_WRONLY | sys.O_CREAT | sys.O_TRUNC
  local fd, trouble = sys.open(path, flags, mode or 0x1a4)
  if fd == nil then
    return nil, path .. ": " .. trouble
  end
  return fd, ""
end

--- Reads up to `count` bytes from a descriptor. This is the streaming byte
--- operation in place of io.read; an empty string is the end of the file.
function Fs.take(fd: integer, count: integer): string | nil, string
  local data, trouble = sys.read(fd, count)
  if data == nil then
    return nil, trouble
  end
  return data, ""
end

--- Closes a descriptor returned by Fs.open_read or Fs.open_write; it does not
--- accept a Lua io.close file handle.
function Fs.close(fd: integer): boolean, string
  local ok, trouble = sys.close(fd)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Writes bytes to a descriptor, without a newline. Fs.stdout and Fs.stderr
--- are the standard-stream descriptors used instead of io.write/io.output.
function Fs.put(fd: integer, data: string): boolean, string
  return write_all(fd, data)
end

--- Creates a symbolic link at `path` pointing at `target`, which is
--- stored verbatim and never resolved.
function Fs.symlink(target: string, path: string): boolean, string
  local made, trouble = sys.symlink(target, path)
  if not made then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- The target of a symbolic link.
function Fs.readlink(path: string): string | nil, string
  local target, trouble = sys.readlink(path)
  if target == nil then
    return nil, path .. ": " .. trouble
  end
  return target, ""
end

--- Sets a path's access and modification times, in whole seconds since
--- the epoch. Changes the link itself, not its target.
function Fs.set_mtime(path: string, atime_s: integer, mtime_s: integer): boolean, string
  local set, trouble = sys.utimens(path, atime_s, mtime_s)
  if not set then
    return false, path .. ": " .. trouble
  end
  return true, ""
end

--- Sets a descriptor's file to exactly `length` bytes, cutting it short
--- or extending it with zero bytes. The descriptor must be open for
--- writing; a negative length raises.
function Fs.truncate(fd: integer, length: integer): boolean, string
  local ok, trouble = sys.ftruncate(fd, length)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Flushes a descriptor's data and metadata to storage.
function Fs.fsync(fd: integer): boolean, string
  local ok, trouble = sys.fsync(fd)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Copies one regular file's bytes a chunk at a time, so a large file
--- is never held in memory whole.
local function copy_bytes(from: string, to: string): boolean, string
  -- TODO: open with O_NOFOLLOW, once cosmic.sys carries it, so a source
  -- swapped for a link or a FIFO after its lstat is refused rather than
  -- followed or blocked on.
  local input, open_trouble = Fs.open_read(from)
  if input == nil then return false, open_trouble end
  -- Exclusive: a name that appeared since the target was checked, a
  -- planted link included, is refused rather than written through.
  local output, create_trouble = sys.open(to,
    sys.O_WRONLY | sys.O_CREAT | sys.O_EXCL, 0x180)
  if output == nil then
    Fs.close(input)
    return false, to .. ": " .. create_trouble
  end
  local ok, trouble = true, ""
  while true do
    local chunk, read_trouble = Fs.take(input, 1 << 20)
    if chunk == nil then
      ok, trouble = false, from .. ": " .. read_trouble
      break
    end
    if chunk == "" then break end
    local put, put_trouble = Fs.put(output, chunk)
    if not put then
      ok, trouble = false, to .. ": " .. put_trouble
      break
    end
  end
  Fs.close(input)
  local closed, close_trouble = Fs.close(output)
  if ok and not closed then return false, to .. ": " .. close_trouble end
  return ok, trouble
end

--- Copies the tree at `from` to `to`: each regular file's bytes, each
--- directory, and each symbolic link as a link to the same target, never
--- followed. Every permission bit is kept, the umask not applied, except
--- setuid and setgid: the copy belongs to whoever makes it, so they are
--- dropped. Each modification time is kept to the second. `to` must not
--- exist yet; each listing is read before its copy is made, so a tree
--- copied into itself is not copied again. Anything else in the tree (a
--- device, a socket, a named pipe) stops the copy with its path, and a
--- copy that stops leaves what it made so far in place.
-- TODO: keep what `cp -a` also keeps -- nanosecond times (once
-- sys.utimens takes them), the access time, hard links as links (Stat has
-- ino, dev and nlink), and the owner when run as root (once cosmic.sys
-- carries lchown).
function Fs.copy_tree(from: string, to: string): boolean, string
  local present, present_trouble, number = sys.lstat(to)
  if present ~= nil then
    return false, to .. ": already exists"
  elseif number ~= sys.ENOENT then
    return false, to .. ": " .. present_trouble
  end
  local function copy(source: string, target: string): boolean, string
    local st, trouble = sys.lstat(source)
    if st == nil then return false, source .. ": " .. trouble end
    local permissions = st.mode & 0x3ff
    if st.kind == "link" then
      local target_of, link_trouble = Fs.readlink(source)
      if target_of == nil then return false, link_trouble end
      local linked, symlink_trouble = Fs.symlink(target_of, target)
      if not linked then return false, symlink_trouble end
    elseif st.kind == "file" then
      local copied, copy_trouble = copy_bytes(source, target)
      if not copied then return false, copy_trouble end
      local changed, chmod_trouble = sys.chmod(target, permissions)
      if not changed then return false, target .. ": " .. chmod_trouble end
    elseif st.kind == "dir" then
      local entries, list_trouble = sys.readdir(source)
      if entries == nil then return false, source .. ": " .. list_trouble end
      local made, mkdir_trouble = sys.mkdir(target, 0x1c0)
      if not made then return false, target .. ": " .. mkdir_trouble end
      for _, name in ipairs(sorted_names(entries)) do
        local copied, why = copy(source .. "/" .. name, target .. "/" .. name)
        if not copied then return false, why end
      end
      -- The directory's own mode last, so a read-only one still took
      -- its entries.
      local changed, chmod_trouble = sys.chmod(target, permissions)
      if not changed then return false, target .. ": " .. chmod_trouble end
    else
      return false, source .. ": not a file, directory or symbolic link"
    end
    return Fs.set_mtime(target, st.mtime, st.mtime)
  end
  return copy(from, to)
end

--- `path` without its trailing slashes, scanned back from the end: a
--- pattern anchored at `$` would retry at every slash of a long run.
local function unslashed(path: string): string
  local to = #path
  while to > 0 and path:byte(to) == 47 do to = to - 1 end
  return path:sub(1, to)
end

--- The last component of a path, as basename(1) names it: trailing
--- slashes are ignored, "/" is itself, and "" stays "". Lexical: nothing
--- is read from disk.
function Fs.basename(path: string): string
  if path == "" then return "" end
  local trimmed = unslashed(path)
  if trimmed == "" then return "/" end
  local at = #trimmed
  while at > 0 and trimmed:byte(at) ~= 47 do at = at - 1 end
  return trimmed:sub(at + 1)
end

--- The directory a path names its last component in, as dirname(1)
--- answers: trailing slashes are ignored, a bare name is in ".", and
--- "/" and a component directly under it are in "/". Lexical: nothing
--- is read from disk, and "a/.." is in "a".
function Fs.dirname(path: string): string
  local trimmed = unslashed(path)
  if trimmed == "" then
    return path == "" and "." or "/"
  end
  local at = #trimmed
  while at > 0 and trimmed:byte(at) ~= 47 do at = at - 1 end
  if at == 0 then return "." end
  local directory = unslashed(trimmed:sub(1, at))
  if directory == "" then return "/" end
  return directory
end

--- Whether `path` is `directory` or lies under it, comparing the text
--- component by component: "a/bc" is not within "a/b". Trailing slashes
--- on either are ignored. Lexical, so both should be written the same
--- way (absolute, or relative to one place, with no "." or ".."); an
--- empty directory holds nothing.
function Fs.within(path: string, directory: string): boolean
  if directory == "" then return false end
  local base = unslashed(directory)
  if base == "" then return path:sub(1, 1) == "/" end
  return unslashed(path) == base or path:sub(1, #base + 1) == base .. "/"
end

--- `path` relative to `directory`, lexically: "." when they are the same,
--- the rest after the directory's "/" when `path` is within it, and nil
--- with a reason when it is not.
function Fs.relative(path: string, directory: string): string | nil, string
  if not Fs.within(path, directory) then
    return nil, path .. ": not within " .. directory
  end
  local base = unslashed(directory)
  local from = #base + 1
  while path:byte(from) == 47 do from = from + 1 end
  local rest = unslashed(path:sub(from))
  if rest == "" then return ".", "" end
  return rest, ""
end

Fs.stdin = 0
Fs.stdout = 1
Fs.stderr = 2

return Fs
