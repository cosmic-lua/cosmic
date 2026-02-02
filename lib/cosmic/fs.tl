--- Unified filesystem module.
--- Combines path manipulation, filesystem operations, and directory walking.
local unix = require("cosmo.unix")
local cosmo_path = require("cosmo.path")

-- Path manipulation functions

--- Strip final component from path.
--- Examples: "/usr/lib" -> "/usr", "usr" -> ".", "/" -> "/"
--- @param str string The path to get the directory from
--- @return string The directory portion of the path
local function dirname(str: string): string
  return cosmo_path.dirname(str)
end

--- Return final component of path.
--- Examples: "/usr/lib" -> "lib", "/" -> "/", "." -> "."
--- @param str string The path to get the basename from
--- @return string The final component of the path
local function basename(str: string): string
  return cosmo_path.basename(str)
end

--- Concatenate path components.
--- Absolute paths in later arguments reset the result.
--- Nil arguments are skipped; exclusively nil returns nil.
--- @param ... string Path components to join
--- @return string The joined path
local function join(...: string): string
  return cosmo_path.join(...)
end

--- Check if path exists (regular file, directory, or special file).
--- Symbolic links are followed. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path exists
local function exists(p: string): boolean
  return cosmo_path.exists(p)
end

--- Check if path is a regular file.
--- Symbolic links are not followed. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a regular file
local function isfile(p: string): boolean
  return cosmo_path.isfile(p)
end

--- Check if path is a directory.
--- Symbolic links are not followed. Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a directory
local function isdir(p: string): boolean
  return cosmo_path.isdir(p)
end

--- Check if path is a symbolic link.
--- Returns false on error.
--- @param p string The path to check
--- @return boolean True if the path is a symbolic link
local function islink(p: string): boolean
  return cosmo_path.islink(p)
end

--- Normalize path by removing `.` and `..` components without filesystem access.
--- Also removes redundant slashes. Pure string manipulation.
--- Examples: "/usr/./lib" -> "/usr/lib", "/usr/lib/../bin" -> "/usr/bin"
--- @param p string The path to normalize
--- @return string The normalized path
local function normalize(p: string): string
  if p == "" then
    return "."
  end

  local is_absolute = p:sub(1, 1) == "/"

  -- Split into components, filtering empty strings (from // or trailing /)
  local parts: {string} = {}
  for part in p:gmatch("[^/]+") do
    if part == "." then
      -- skip current dir
    elseif part == ".." then
      if #parts > 0 and parts[#parts] ~= ".." then
        -- pop last component if it's not also a ..
        if is_absolute or parts[#parts] ~= ".." then
          table.remove(parts)
        else
          table.insert(parts, "..")
        end
      elseif not is_absolute then
        -- for relative paths, preserve leading ..
        table.insert(parts, "..")
      end
      -- for absolute paths starting with /.., just ignore the ..
    else
      table.insert(parts, part)
    end
  end

  if is_absolute then
    if #parts == 0 then
      return "/"
    else
      return "/" .. table.concat(parts, "/")
    end
  else
    if #parts == 0 then
      return "."
    else
      return table.concat(parts, "/")
    end
  end
end

--- Convert relative path to absolute by prepending cwd.
--- Does NOT resolve symlinks or access filesystem (except to get cwd).
--- @param p string The path to make absolute
--- @return string The absolute path
local function abspath(p: string): string
  if p == "" then
    return unix.getcwd() or "."
  end
  if p:sub(1, 1) == "/" then
    return normalize(p)
  end
  local cwd = unix.getcwd()
  if not cwd then
    return normalize(p)
  end
  return normalize(cwd .. "/" .. p)
end

--- Make path relative to another path (defaults to cwd).
--- Pure string manipulation - does not access the filesystem.
--- @param p string The path to make relative
--- @param base string The base path (defaults to cwd)
--- @return string The relative path
local function relpath(p: string, base: string): string
  -- Get absolute versions of both paths
  local abs_p = abspath(p)
  local abs_base: string
  if base then
    abs_base = abspath(base)
  else
    abs_base = unix.getcwd() or "."
  end

  -- Split into components
  local function split_path(s: string): {string}
    local path_parts: {string} = {}
    for part in s:gmatch("[^/]+") do
      table.insert(path_parts, part)
    end
    return path_parts
  end

  local p_parts = split_path(abs_p)
  local base_parts = split_path(abs_base)

  -- Find common prefix length
  local common_len = 0
  local max_common = math.min(#p_parts, #base_parts)
  for i = 1, max_common do
    if p_parts[i] == base_parts[i] then
      common_len = i
    else
      break
    end
  end

  -- Build relative path: go up from base, then down to target
  local rel_parts: {string} = {}

  -- Add ".." for each remaining component in base
  for _ = common_len + 1, #base_parts do
    table.insert(rel_parts, "..")
  end

  -- Add remaining components from target
  for i = common_len + 1, #p_parts do
    table.insert(rel_parts, p_parts[i])
  end

  if #rel_parts == 0 then
    return "."
  end

  return table.concat(rel_parts, "/")
end

--- Split path into root and extension.
--- Extension includes the dot. Handles multiple extensions by splitting at
--- the last dot in the basename. Hidden files (starting with .) have no extension.
--- Examples: "foo.txt" -> "foo", ".txt"; ".bashrc" -> ".bashrc", ""
--- @param p string The path to split
--- @return string The root portion (path without extension)
--- @return string The extension (including dot, or empty string)
local function splitext(p: string): string, string
  local base = cosmo_path.basename(p)
  local dir = cosmo_path.dirname(p)

  -- Handle hidden files: if basename starts with . and has no other dot, no extension
  if base:sub(1, 1) == "." then
    local rest = base:sub(2)
    local dot_pos = rest:find("%.")
    if not dot_pos then
      -- Hidden file with no extension
      return p, ""
    end
    -- Hidden file with extension: find last dot in the non-hidden part
    local last_dot: integer = 0
    for i = #base, 2, -1 do
      if base:sub(i, i) == "." then
        last_dot = i
        break
      end
    end
    if last_dot > 0 then
      local extension = base:sub(last_dot)
      local root_base = base:sub(1, last_dot - 1)
      if dir == "." then
        return root_base, extension
      else
        return dir .. "/" .. root_base, extension
      end
    end
    return p, ""
  end

  -- Find last dot in basename
  local last_dot: integer = 0
  for i = #base, 1, -1 do
    if base:sub(i, i) == "." then
      last_dot = i
      break
    end
  end

  if last_dot == 0 or last_dot == 1 then
    -- No dot, or dot at start (shouldn't happen since we handled hidden files)
    return p, ""
  end

  local extension = base:sub(last_dot)
  local root_base = base:sub(1, last_dot - 1)

  if dir == "." then
    return root_base, extension
  else
    return dir .. "/" .. root_base, extension
  end
end

--- Return the extension of a path.
--- Extension includes the dot. Convenience wrapper around splitext.
--- @param p string The path to get extension from
--- @return string The extension (including dot, or empty string)
local function ext(p: string): string
  local _, extension = splitext(p)
  return extension
end

-- Raw Dir type from cosmo.unix
local record RawDir
  read: function(self: RawDir): string
  close: function(self: RawDir)
  fd: function(self: RawDir): number
  rewind: function(self: RawDir)
  tell: function(self: RawDir): number
end

--- Filesystem statistics.
--- Returned by statfs() and fstatfs().
local record Statfs
  --- Returns filesystem type identifier.
  type: function(self: Statfs): number
  --- Returns optimal transfer block size.
  bsize: function(self: Statfs): number
  --- Returns total data blocks in filesystem.
  blocks: function(self: Statfs): number
  --- Returns free blocks in filesystem.
  bfree: function(self: Statfs): number
  --- Returns free blocks available to unprivileged user.
  bavail: function(self: Statfs): number
  --- Returns total file nodes in filesystem.
  files: function(self: Statfs): number
  --- Returns free file nodes in filesystem.
  ffree: function(self: Statfs): number
  --- Returns filesystem ID as two numbers.
  fsid: function(self: Statfs): number, number
  --- Returns maximum length of filenames.
  namelen: function(self: Statfs): number
  --- Returns fragment size.
  frsize: function(self: Statfs): number
  --- Returns mount flags.
  flags: function(self: Statfs): number
end

--- File or directory metadata.
--- Use is_dir(), is_file(), etc. to check file type.
local record Stat
  --- Returns file size in bytes.
  size: function(self: Stat): number
  --- Returns file mode (permissions and type bits).
  mode: function(self: Stat): number
  --- Returns owner user ID.
  uid: function(self: Stat): number
  --- Returns owner group ID.
  gid: function(self: Stat): number
  --- Returns birth time as seconds, nanoseconds.
  birthtim: function(self: Stat): number, number
  --- Returns modification time as seconds, nanoseconds.
  mtim: function(self: Stat): number, number
  --- Returns access time as seconds, nanoseconds.
  atim: function(self: Stat): number, number
  --- Returns status change time as seconds, nanoseconds.
  ctim: function(self: Stat): number, number
  --- Returns number of 512-byte blocks allocated.
  blocks: function(self: Stat): number
  --- Returns number of hard links.
  nlink: function(self: Stat): number
  --- Returns device ID containing the file.
  dev: function(self: Stat): number
  --- Returns device ID for special files (0 or -1 for non-devices).
  rdev: function(self: Stat): number
end

--- Handle for reading directory entries.
--- Supports automatic cleanup with `<close>` attribute.
local record Dir
  --- Reads next directory entry. Returns nil when done.
  read: function(self: Dir): string
  --- Closes directory handle.
  close: function(self: Dir)
  --- Returns file descriptor for this directory.
  fd: function(self: Dir): number
  --- Rewinds to beginning of directory.
  rewind: function(self: Dir)
  --- Returns current position in directory stream.
  tell: function(self: Dir): number
  --- Returns true if directory handle is closed.
  closed: function(self: Dir): boolean
end

-- Wrap a raw cosmo Dir with __close support
local function make_dir(raw: RawDir): Dir
  local is_closed = false

  local dir: Dir = {
    read = function(_self: Dir): string
      if is_closed then return nil end
      return raw:read()
    end,
    close = function(_self: Dir)
      if not is_closed then
        raw:close()
        is_closed = true
      end
    end,
    fd = function(_self: Dir): number
      if is_closed then return -1 end
      return raw:fd()
    end,
    rewind = function(_self: Dir)
      if not is_closed then raw:rewind() end
    end,
    tell = function(_self: Dir): number
      if is_closed then return -1 end
      return raw:tell()
    end,
    closed = function(_self: Dir): boolean
      return is_closed
    end,
  }

  local mt: metatable<Dir> = {
    __close = function(self: Dir)
      self:close()
    end
  }

  return setmetatable(dir, mt)
end

-- Stat operations

--- Get file metadata.
--- Follows symbolic links by default.
--- @param path string Path to the file or directory
--- @param follow_symlinks boolean Whether to follow symlinks (default true)
--- @return Stat File metadata, or nil on error
--- @return string Error message if failed
local function stat(path: string, follow_symlinks?: boolean): Stat, string
  local flags: number = nil
  if follow_symlinks == false then
    flags = unix.AT_SYMLINK_NOFOLLOW
  end
  local st = unix.stat(path, flags) as Stat
  if not st then
    return nil, "stat failed: " .. path
  end
  return st
end

--- Get file metadata from file descriptor.
--- @param fd number File descriptor
--- @return Stat File metadata, or nil on error
--- @return string Error message if failed
local function fstat(fd: number): Stat, string
  local st = unix.fstat(fd) as Stat
  if not st then
    return nil, "fstat failed"
  end
  return st
end

--- Check if mode represents a directory.
--- @param mode number File mode from stat
--- @return boolean True if directory
local function is_dir(mode: number): boolean
  return unix.S_ISDIR(mode)
end

--- Check if mode represents a regular file.
--- @param mode number File mode from stat
--- @return boolean True if regular file
local function is_file(mode: number): boolean
  return unix.S_ISREG(mode)
end

--- Check if mode represents a symbolic link.
--- @param mode number File mode from stat
--- @return boolean True if symbolic link
local function is_link(mode: number): boolean
  return unix.S_ISLNK(mode)
end

--- Check if mode represents a block device.
--- @param mode number File mode from stat
--- @return boolean True if block device
local function is_block_device(mode: number): boolean
  return unix.S_ISBLK(mode)
end

--- Check if mode represents a character device.
--- @param mode number File mode from stat
--- @return boolean True if character device
local function is_char_device(mode: number): boolean
  return unix.S_ISCHR(mode)
end

--- Check if mode represents a FIFO (named pipe).
--- @param mode number File mode from stat
--- @return boolean True if FIFO
local function is_fifo(mode: number): boolean
  return unix.S_ISFIFO(mode)
end

--- Check if mode represents a socket.
--- @param mode number File mode from stat
--- @return boolean True if socket
local function is_socket(mode: number): boolean
  return unix.S_ISSOCK(mode)
end

-- Directory operations

--- Create a directory.
--- Parent directories must exist. Use makedirs() to create parents.
--- @param path string Path to the directory to create
--- @param mode number Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function mkdir(path: string, mode?: number): boolean, string
  mode = mode or tonumber("755", 8)
  local ok = unix.mkdir(path, mode)
  if not ok then
    return false, "mkdir failed: " .. path
  end
  return true
end

--- Create a directory and any missing parent directories.
--- @param path string Path to the directory to create
--- @param mode number Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function makedirs(path: string, mode?: number): boolean, string
  mode = mode or tonumber("755", 8)
  local ok = unix.makedirs(path, mode)
  if not ok then
    return false, "makedirs failed: " .. path
  end
  return true
end

--- Remove an empty directory.
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function rmdir(path: string): boolean, string
  local ok = unix.rmdir(path)
  if not ok then
    return false, "rmdir failed: " .. path
  end
  return true
end

--- Change current working directory.
--- @param path string Path to the new working directory
--- @return boolean True on success
--- @return string Error message if failed
local function chdir(path: string): boolean, string
  local ok = unix.chdir(path)
  if not ok then
    return false, "chdir failed: " .. path
  end
  return true
end

--- Get current working directory.
--- @return string Current working directory path
--- @return string Error message if failed
local function getcwd(): string, string
  local cwd = unix.getcwd()
  if not cwd then
    return nil, "getcwd failed"
  end
  return cwd
end

--- Open a directory for reading.
--- Call dir:read() to iterate entries, dir:close() when done.
--- Supports automatic cleanup with `<close>` attribute.
--- @param path string Path to the directory
--- @return Dir Directory handle, or nil on error
--- @return string Error message if failed
local function opendir(path: string): Dir, string
  local raw = unix.opendir(path) as RawDir
  if not raw then
    return nil, "opendir failed: " .. path
  end
  return make_dir(raw)
end

--- Open a directory from a file descriptor.
--- Supports automatic cleanup with `<close>` attribute.
--- @param fd number File descriptor for an open directory
--- @return Dir Directory handle, or nil on error
--- @return string Error message if failed
local function fdopendir(fd: number): Dir, string
  local _, raw = unix.fdopendir(fd)
  if not raw then
    return nil, "fdopendir failed"
  end
  return make_dir(raw as RawDir)
end

-- File operations

--- Remove a file or symbolic link.
--- Does not remove directories; use rmdir() or rmrf() for that.
--- @param path string Path to the file to remove
--- @return boolean True on success
--- @return string Error message if failed
local function unlink(path: string): boolean, string
  local ok = unix.unlink(path)
  if not ok then
    return false, "unlink failed: " .. path
  end
  return true
end

--- Rename or move a file or directory.
--- @param oldpath string Current path
--- @param newpath string New path
--- @return boolean True on success
--- @return string Error message if failed
local function rename(oldpath: string, newpath: string): boolean, string
  local ok = unix.rename(oldpath, newpath, unix.AT_FDCWD, unix.AT_FDCWD)
  if not ok then
    return false, "rename failed: " .. oldpath .. " -> " .. newpath
  end
  return true
end

--- Create a hard link.
--- @param existingpath string Path to the existing file
--- @param newpath string Path for the new link
--- @return boolean True on success
--- @return string Error message if failed
local function link(existingpath: string, newpath: string): boolean, string
  local ok = unix.link(existingpath, newpath, 0, unix.AT_FDCWD, unix.AT_FDCWD)
  if not ok then
    return false, "link failed: " .. existingpath .. " -> " .. newpath
  end
  return true
end

--- Create a symbolic link.
--- @param target string Content of the symlink (where it points)
--- @param linkpath string Path where the symlink will be created
--- @return boolean True on success
--- @return string Error message if failed
local function symlink(target: string, linkpath: string): boolean, string
  local ok = unix.symlink(target, linkpath)
  if not ok then
    return false, "symlink failed: " .. linkpath .. " -> " .. target
  end
  return true
end

--- Read the target of a symbolic link.
--- @param path string Path to the symbolic link
--- @return string The symlink target, or nil on error
--- @return string Error message if failed
local function readlink(path: string): string, string
  local target = unix.readlink(path)
  if not target then
    return nil, "readlink failed: " .. path
  end
  return target
end

--- Get the canonical absolute path.
--- Resolves all symbolic links and removes . and .. components.
--- @param path string Path to resolve
--- @return string Canonical path, or nil on error
--- @return string Error message if failed
local function realpath(path: string): string, string
  local resolved = unix.realpath(path)
  if not resolved then
    return nil, "realpath failed: " .. path
  end
  return resolved
end

--- Recursively remove a directory and all its contents.
--- Use with caution.
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function rmrf(path: string): boolean, string
  local ok = unix.rmrf(path)
  if not ok then
    return false, "rmrf failed: " .. path
  end
  return true
end

-- Permission operations

--- Check if the current process has access to a file.
--- @param path string Path to check
--- @param mode number Access mode: F_OK (exists), R_OK, W_OK, X_OK
--- @return boolean True if access is allowed
local function access(path: string, mode: number): boolean
  return unix.access(path, mode)
end

--- Change file permissions.
--- @param path string Path to the file
--- @param mode number New permission bits (e.g., 0644)
--- @return boolean True on success
--- @return string Error message if failed
local function chmod(path: string, mode: number): boolean, string
  local ok = unix.chmod(path, mode)
  if not ok then
    return false, "chmod failed: " .. path
  end
  return true
end

--- Change file owner and group.
--- @param path string Path to the file
--- @param uid number New owner user ID
--- @param gid number New owner group ID
--- @return boolean True on success
--- @return string Error message if failed
local function chown(path: string, uid: number, gid: number): boolean, string
  local ok = unix.chown(path, uid, gid)
  if not ok then
    return false, "chown failed: " .. path
  end
  return true
end

-- Timestamp operations

--- Change file access and modification times.
--- Pass nil for either time to leave it unchanged.
--- @param path string Path to the file
--- @param atime_secs number Access time seconds (nil to keep current)
--- @param atime_nsecs number Access time nanoseconds
--- @param mtime_secs number Modification time seconds (nil to keep current)
--- @param mtime_nsecs number Modification time nanoseconds
--- @return boolean True on success
--- @return string Error message if failed
local function utimensat(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  local rc = unix.utimensat(path, atime_secs or 0, atime_nsecs or unix.UTIME_OMIT, mtime_secs or 0, mtime_nsecs or unix.UTIME_OMIT)
  if rc ~= 0 then
    return false, "utimensat failed: " .. path
  end
  return true
end

--- Change file access and modification times on a file descriptor.
--- @param fd number File descriptor
--- @param atime_secs number Access time seconds (nil to keep current)
--- @param atime_nsecs number Access time nanoseconds
--- @param mtime_secs number Modification time seconds (nil to keep current)
--- @param mtime_nsecs number Modification time nanoseconds
--- @return boolean True on success
--- @return string Error message if failed
local function futimens(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  local rc = unix.futimens(fd, atime_secs or 0, atime_nsecs or unix.UTIME_OMIT, mtime_secs or 0, mtime_nsecs or unix.UTIME_OMIT)
  if rc ~= 0 then
    return false, "futimens failed"
  end
  return true
end

-- Temporary file operations

--- Create a temporary directory.
--- The template must end with XXXXXX which will be replaced with random characters.
--- @param template string Path template ending in XXXXXX
--- @return string Path to the created directory, or nil on error
--- @return string Error message if failed
local function mkdtemp(template: string): string, string
  local path = unix.mkdtemp(template)
  if not path then
    return nil, "mkdtemp failed: " .. template
  end
  return path
end

--- Create a temporary file.
--- The template must end with XXXXXX which will be replaced with random characters.
--- Returns both the file descriptor and the path.
--- @param template string Path template ending in XXXXXX
--- @return number File descriptor, or nil on error
--- @return string Path to the created file, or error message
local function mkstemp(template: string): number, string
  local fd, path = unix.mkstemp(template)
  if not fd then
    return nil, "mkstemp failed: " .. template
  end
  return fd, path
end

--- Create a temporary file descriptor.
--- The file is automatically deleted when closed.
--- @return number File descriptor, or nil on error
--- @return string Error message if failed
local function tmpfd(): number, string
  local fd = unix.tmpfd()
  if not fd then
    return nil, "tmpfd failed"
  end
  return fd
end

-- Filesystem statistics

--- Get filesystem statistics for a path.
--- @param path string Path to any file on the filesystem
--- @return Statfs Filesystem statistics, or nil on error
--- @return string Error message if failed
local function statfs(path: string): Statfs, string
  local info = unix.statfs(path) as Statfs
  if not info then
    return nil, "statfs failed: " .. path
  end
  return info
end

--- Get filesystem statistics from a file descriptor.
--- @param fd number File descriptor
--- @return Statfs Filesystem statistics, or nil on error
--- @return string Error message if failed
local function fstatfs(fd: number): Statfs, string
  local info = unix.fstatfs(fd) as Statfs
  if not info then
    return nil, "fstatfs failed"
  end
  return info
end

-- Device number utilities

--- Extract major device number from a device ID.
--- Use with stat():dev() or stat():rdev() to identify device types.
--- @param dev number Device ID from stat
--- @return number Major device number
local function major(dev: number): number
  return unix.major(dev)
end

--- Extract minor device number from a device ID.
--- Use with stat():dev() or stat():rdev() to identify specific devices.
--- @param dev number Device ID from stat
--- @return number Minor device number
local function minor(dev: number): number
  return unix.minor(dev)
end

-- Access mode constants
local F_OK <const> = unix.F_OK
local R_OK <const> = unix.R_OK
local W_OK <const> = unix.W_OK
local X_OK <const> = unix.X_OK

-- Directory walking

--- File or directory metadata for walk visitor.
local record WalkStat
  mode: function(self): number
  size: function(self): number
  mtim: function(self): number
end

--- Handle for reading directory entries (internal).
local record WalkDirHandle
  read: function(self): string
  close: function(self)
end

--- File information with Unix permissions.
local record FileInfo
  mode: number
end

--- Visitor function type for directory traversal.
--- Return false to skip recursion into subdirectories.
--- @param full_path string The complete path to the file or directory
--- @param entry string The basename of the file or directory
--- @param stat WalkStat File metadata
--- @param ctx any User-provided context passed through the walk
--- @return boolean Return false to skip recursing into this directory
local type Visitor = function(full_path: string, entry: string, stat: WalkStat, ctx: any): boolean

--- Walk a directory tree, calling visitor for each entry.
--- Recursively traverses subdirectories unless visitor returns false.
--- @param dir string The directory to walk
--- @param visitor Visitor Function called for each file and directory
--- @param ctx T Optional context passed to visitor function
--- @return T The context object, potentially modified by visitor
local function walk<T>(dir: string, visitor: Visitor, ctx?: T): T
  ctx = ctx or {} as T
  local handle = unix.opendir(dir) as WalkDirHandle
  if not handle then return ctx end

  while true do
    local entry = handle:read()
    if not entry then break end
    if entry ~= "." and entry ~= ".." then
      local full_path = join(dir, entry)
      local st = unix.stat(full_path) as WalkStat
      if st then
        local continue = visitor(full_path, entry, st, ctx)
        if continue ~= false and unix.S_ISDIR(st:mode()) then
          walk(full_path, visitor, ctx)
        end
      end
    end
  end
  handle:close()
  return ctx
end

--- Convert a glob pattern to a Lua pattern.
--- Supports * (any chars), ? (single char), and character classes [abc].
--- @param glob string The glob pattern
--- @return string The equivalent Lua pattern
local function glob_to_pattern(glob: string): string
  local pattern = glob
    :gsub("([%.%^%$%(%)%%])", "%%%1")  -- escape special chars (except * ? [ ])
    :gsub("%*", ".*")                   -- * -> .*
    :gsub("%?", ".")                    -- ? -> .
  return "^" .. pattern .. "$"
end

--- Collect file paths matching a pattern.
--- Recursively walks directory tree and returns matching file paths.
--- @param dir string The directory to search
--- @param pattern string Glob pattern (*.lua) or Lua pattern (%.lua$)
--- @return {string} List of full paths to matching files
local function collect(dir: string, pattern: string): {string}
  -- Detect if it's a glob or Lua pattern
  -- Globs use * and ?, Lua patterns use % for escaping
  local is_glob = pattern:find("*", 1, true) or pattern:find("?", 1, true)
  local lua_pattern: string
  if is_glob then
    lua_pattern = glob_to_pattern(pattern)
  else
    lua_pattern = pattern
  end

  local results: {string} = {}
  walk(dir, function(full_path: string, entry: string, st: WalkStat, ctx: {string}): boolean
    if not unix.S_ISDIR(st:mode()) and entry:match(lua_pattern) then
      table.insert(ctx, full_path)
    end
    return true
  end, results)
  return results
end

--- Recursively collect all files with their Unix permissions.
--- Returns a map of relative paths to file information.
--- @param dir string The directory to walk
--- @return {string:FileInfo} Map of relative paths to file information
local function collect_all(dir: string): {string:FileInfo}
  local files: {string:FileInfo} = {}

  local function do_walk(base_dir: string, rel_base: string)
    local handle = unix.opendir(base_dir) as WalkDirHandle
    if not handle then return end

    while true do
      local entry = handle:read()
      if not entry then break end
      if entry ~= "." and entry ~= ".." then
        local full_path = join(base_dir, entry)
        local rel_path = rel_base == "" and entry or join(rel_base, entry)
        local st = unix.stat(full_path) as WalkStat

        if st then
          if unix.S_ISDIR(st:mode()) then
            do_walk(full_path, rel_path)
          elseif unix.S_ISREG(st:mode()) or unix.S_ISLNK(st:mode()) then
            local mode = st:mode() & 0x1ff
            files[rel_path] = { mode = mode }
          end
        end
      end
    end
    handle:close()
  end

  do_walk(dir, "")
  return files
end

--- Iterate over files matching a pattern.
--- Returns an iterator that yields file paths.
--- @param dir string The directory to search
--- @param pattern string Glob pattern (*.lua) - defaults to all files (*)
--- @return function Iterator yielding file paths
local function files(dir: string, pattern?: string): function(): string
  pattern = pattern or "*"

  -- Detect if it's a glob or Lua pattern
  local is_glob = pattern:find("*", 1, true) or pattern:find("?", 1, true)
  local lua_pattern: string
  if is_glob then
    lua_pattern = glob_to_pattern(pattern)
  else
    lua_pattern = pattern
  end

  -- Stack of (dir, handle) for depth-first traversal
  local stack: {{string, WalkDirHandle}} = {}
  local handle = unix.opendir(dir) as WalkDirHandle
  if handle then
    table.insert(stack, {dir, handle})
  end

  return function(): string
    while #stack > 0 do
      local current = stack[#stack]
      local current_dir = current[1]
      local current_handle = current[2]

      local entry = current_handle:read()
      if not entry then
        current_handle:close()
        table.remove(stack)
      elseif entry ~= "." and entry ~= ".." then
        local full_path = join(current_dir, entry)
        local st = unix.stat(full_path) as WalkStat
        if st then
          if unix.S_ISDIR(st:mode()) then
            -- Push subdirectory onto stack
            local subhandle = unix.opendir(full_path) as WalkDirHandle
            if subhandle then
              table.insert(stack, {full_path, subhandle})
            end
          elseif entry:match(lua_pattern) then
            return full_path
          end
        end
      end
    end
    return nil
  end
end

-- Example demonstrating basic fs operations
local function Example_basic()
  local fs = require("cosmic.fs")

  -- Create a temp directory
  local tmpdir = fs.mkdtemp("/tmp/fs_example_XXXXXX")
  if not tmpdir then
    print("failed to create temp dir")
    return
  end
  print("created temp dir:", tmpdir)

  -- Create a subdirectory
  local subdir = fs.join(tmpdir, "subdir")
  local ok, err = fs.mkdir(subdir)
  if not ok then
    print("mkdir failed:", err)
    fs.rmrf(tmpdir)
    return
  end

  -- Check if it exists
  local st = fs.stat(subdir)
  if st and fs.is_dir(st:mode()) then
    print("subdir is a directory")
  end

  -- Create a symlink
  local linkpath = fs.join(tmpdir, "link")
  ok, err = fs.symlink(subdir, linkpath)
  if ok then
    local target = fs.readlink(linkpath)
    print("symlink points to:", target)
  end

  -- Clean up
  fs.rmrf(tmpdir)
  print("cleaned up")

  -- Output:
  -- created temp dir:	/tmp/fs_example_XXXXXX (with random suffix)
  -- subdir is a directory
  -- symlink points to:	/tmp/fs_example_XXXXXX/subdir
  -- cleaned up
end

--- Example_normalize demonstrates path normalization
local function Example_normalize()
  local fs = require("cosmic.fs")
  print(fs.normalize("/usr/./lib"))
  print(fs.normalize("/usr/lib/../bin"))
  print(fs.normalize("a/b/../c"))
  print(fs.normalize("//usr///lib//"))
  -- Output:
  -- /usr/lib
  -- /usr/bin
  -- a/c
  -- /usr/lib
end

--- Example_splitext demonstrates extension splitting
local function Example_splitext()
  local fs = require("cosmic.fs")
  local root: string
  local extension: string
  root, extension = fs.splitext("archive.tar.gz")
  print(root, extension)
  root, extension = fs.splitext(".bashrc")
  print(root, extension)
  root, extension = fs.splitext("/path/to/file.txt")
  print(root, extension)
  -- Output:
  -- archive.tar	.gz
  -- .bashrc
  -- /path/to/file	.txt
end

--- Example_relpath demonstrates computing relative paths
local function Example_relpath()
  local fs = require("cosmic.fs")
  print(fs.relpath("/usr/lib", "/usr"))
  print(fs.relpath("/usr/lib", "/usr/bin"))
  print(fs.relpath("/foo", "/bar"))
  -- Output:
  -- lib
  -- ../lib
  -- ../foo
end

-- Suppress unused warnings for examples
local _ = {Example_basic, Example_normalize, Example_splitext, Example_relpath}

--- Module interface
local record FsModule
  -- Path manipulation
  dirname: function(str: string): string
  basename: function(str: string): string
  join: function(...: string): string
  exists: function(path: string): boolean
  isfile: function(path: string): boolean
  isdir: function(path: string): boolean
  islink: function(path: string): boolean
  normalize: function(p: string): string
  abspath: function(p: string): string
  relpath: function(p: string, base?: string): string
  splitext: function(p: string): string, string
  ext: function(p: string): string

  -- Stat operations
  stat: function(path: string, follow_symlinks?: boolean): Stat, string
  fstat: function(fd: number): Stat, string
  is_dir: function(mode: number): boolean
  is_file: function(mode: number): boolean
  is_link: function(mode: number): boolean
  is_block_device: function(mode: number): boolean
  is_char_device: function(mode: number): boolean
  is_fifo: function(mode: number): boolean
  is_socket: function(mode: number): boolean

  -- Directory operations
  mkdir: function(path: string, mode?: number): boolean, string
  makedirs: function(path: string, mode?: number): boolean, string
  rmdir: function(path: string): boolean, string
  chdir: function(path: string): boolean, string
  getcwd: function(): string, string
  opendir: function(path: string): Dir, string
  fdopendir: function(fd: number): Dir, string

  -- File operations
  unlink: function(path: string): boolean, string
  rename: function(oldpath: string, newpath: string): boolean, string
  link: function(existingpath: string, newpath: string): boolean, string
  symlink: function(target: string, linkpath: string): boolean, string
  readlink: function(path: string): string, string
  realpath: function(path: string): string, string
  rmrf: function(path: string): boolean, string

  -- Permission operations
  access: function(path: string, mode: number): boolean
  chmod: function(path: string, mode: number): boolean, string
  chown: function(path: string, uid: number, gid: number): boolean, string

  -- Timestamp operations
  utimensat: function(path: string, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string
  futimens: function(fd: number, atime_secs: number, atime_nsecs: number, mtime_secs: number, mtime_nsecs: number): boolean, string

  -- Temporary file operations
  mkdtemp: function(template: string): string, string
  mkstemp: function(template: string): number, string
  tmpfd: function(): number, string

  -- Filesystem statistics
  statfs: function(path: string): Statfs, string
  fstatfs: function(fd: number): Statfs, string

  -- Device number utilities
  major: function(dev: number): number
  minor: function(dev: number): number

  -- Directory walking
  walk: function<T>(dir: string, visitor: Visitor, ctx?: T): T
  collect: function(dir: string, pattern: string): {string}
  collect_all: function(dir: string): {string:FileInfo}
  files: function(dir: string, pattern?: string): function(): string

  -- Access mode constants
  F_OK: number
  R_OK: number
  W_OK: number
  X_OK: number
end

local M: FsModule = {
  -- Path manipulation
  dirname = dirname,
  basename = basename,
  join = join,
  exists = exists,
  isfile = isfile,
  isdir = isdir,
  islink = islink,
  normalize = normalize,
  abspath = abspath,
  relpath = relpath,
  splitext = splitext,
  ext = ext,

  -- Stat operations
  stat = stat,
  fstat = fstat,
  is_dir = is_dir,
  is_file = is_file,
  is_link = is_link,
  is_block_device = is_block_device,
  is_char_device = is_char_device,
  is_fifo = is_fifo,
  is_socket = is_socket,

  -- Directory operations
  mkdir = mkdir,
  makedirs = makedirs,
  rmdir = rmdir,
  chdir = chdir,
  getcwd = getcwd,
  opendir = opendir,
  fdopendir = fdopendir,

  -- File operations
  unlink = unlink,
  rename = rename,
  link = link,
  symlink = symlink,
  readlink = readlink,
  realpath = realpath,
  rmrf = rmrf,

  -- Permission operations
  access = access,
  chmod = chmod,
  chown = chown,

  -- Timestamp operations
  utimensat = utimensat,
  futimens = futimens,

  -- Temporary file operations
  mkdtemp = mkdtemp,
  mkstemp = mkstemp,
  tmpfd = tmpfd,

  -- Filesystem statistics
  statfs = statfs,
  fstatfs = fstatfs,

  -- Device number utilities
  major = major,
  minor = minor,

  -- Directory walking
  walk = walk,
  collect = collect,
  collect_all = collect_all,
  files = files,

  -- Access mode constants
  F_OK = F_OK,
  R_OK = R_OK,
  W_OK = W_OK,
  X_OK = X_OK,
}

return M
