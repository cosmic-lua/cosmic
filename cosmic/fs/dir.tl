--- Stat and directory operations for cosmic.fs (#988: split from
--- init.tl when the anglicized names landed beside their deprecated
--- aliases and the module outgrew the file-length limit).
local unix = require("cosmo.unix")
local types = require("cosmic.fs.types")
local errstr = require("cosmic.errno").format
local Stat = types.Stat
local Dir = types.Dir

-- Wrap a raw unix.Dir with __close support
local function wrap_dir(raw: unix.Dir): Dir
  local is_closed = false

  local dir: Dir = {
    -- The second return is the dirent d_type (fs.DT_DIR / DT_REG /
    -- DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it,
    -- so "is this entry a directory" needs no stat(2) call.
    read = function(_self: Dir): string, integer
      if is_closed then return nil end
      local name, kind = raw:read()
      return name, kind
    end,
    close = function(_self: Dir)
      if not is_closed then
        raw:close()
        is_closed = true
      end
    end,
    fd = function(_self: Dir): integer
      if is_closed then return -1 end
      return (raw:fd())
    end,
    rewind = function(_self: Dir)
      if not is_closed then raw:rewind() end
    end,
    tell = function(_self: Dir): integer
      if is_closed then return -1 end
      return (raw:tell())
    end,
    closed = function(_self: Dir): boolean
      return is_closed
    end,
  }

  local mt: metatable < Dir > = {
    __close = function(self: Dir)
      self:close()
    end
  }

  return setmetatable(dir, mt)
end

-- Stat operations

--- Get file metadata.
--- Follows symbolic links: stat on a symlink describes its target.
--- Use stat_link() to inspect the symlink itself.
--- @param path string Path to the file or directory
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function stat(path: string): Stat | nil, string
  local st, err = unix.stat(path)
  if not st then
    return nil, errstr(err, "stat: " .. path)
  end
  return types.wrap(st)
end

--- Get file metadata without following symbolic links (#988: was
--- `lstat`). On a symlink this describes the link itself, not its
--- target.
--- @param path string Path to the file or symlink
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function stat_link(path: string): Stat | nil, string
  local st, err = unix.stat(path, unix.AT_SYMLINK_NOFOLLOW)
  if not st then
    return nil, errstr(err, "stat_link: " .. path)
  end
  return types.wrap(st)
end

--- Get file metadata from a file descriptor (#988: was `fstat`).
--- @param fd integer File descriptor
--- @return Stat | nil File metadata, or nil on error
--- @return string Error message if failed
local function stat_fd(fd: integer): Stat | nil, string
  local st, err = unix.fstat(fd)
  if not st then
    return nil, errstr(err, "stat_fd")
  end
  return types.wrap(st)
end

-- Directory operations

--- Create a directory (#988: was `mkdir`).
--- Parent directories must exist. Use make_dirs() to create parents.
--- @param path string Path to the directory to create
--- @param mode integer Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function make_dir(path: string, mode?: integer): boolean, string
  mode = mode or tonumber("755", 8)
  local ok, err = unix.mkdir(path, mode)
  if not ok then
    return false, errstr(err, "make_dir: " .. path)
  end
  return true
end

--- Create a directory and any missing parent directories.
--- @param path string Path to the directory to create
--- @param mode integer Permission bits (default 0755)
--- @return boolean True on success
--- @return string Error message if failed
local function make_dirs(path: string, mode?: integer): boolean, string
  mode = mode or tonumber("755", 8)
  local ok, err = unix.makedirs(path, mode)
  if not ok then
    return false, errstr(err, "make_dirs: " .. path)
  end
  return true
end

--- Remove an empty directory (#988: was `rmdir`).
--- @param path string Path to the directory to remove
--- @return boolean True on success
--- @return string Error message if failed
local function remove_dir(path: string): boolean, string
  local ok, err = unix.rmdir(path)
  if not ok then
    return false, errstr(err, "remove_dir: " .. path)
  end
  return true
end

--- Change current working directory (#988: was `chdir` — the setter
--- beside cwd(), its getter).
--- @param path string Path to the new working directory
--- @return boolean True on success
--- @return string Error message if failed
local function set_cwd(path: string): boolean, string
  local ok, err = unix.chdir(path)
  if not ok then
    return false, errstr(err, "set_cwd: " .. path)
  end
  return true
end

--- Get current working directory.
--- @return string | nil Current working directory path
--- @return string Error message if failed
local function cwd(): string | nil, string
  local dir, err = unix.getcwd()
  if not dir then
    return nil, errstr(err, "cwd")
  end
  return dir
end

--- Open a directory for reading (#988: was `opendir`).
--- Call dir:read() to iterate entries, dir:close() when done.
--- Supports automatic cleanup with `<close>` attribute.
--- @param path string Path to the directory
--- @return Dir | nil Directory handle, or nil on error
--- @return string Error message if failed
local function open_dir(path: string): Dir | nil, string
  -- `is` is safe here since every cosmic-installed loader (dispatcher
  -- searcher, embed wrapper) resolves the unix.Dir userdata
  -- marker; explicit tl.loader() installs are unsupported.
  local raw, err = unix.opendir(path)
  if raw is unix.Dir then
    return wrap_dir(raw)
  end
  return nil, errstr(err, "open_dir: " .. path)
end

--- Open a directory from a file descriptor (#988: was `fdopendir`).
--- Supports automatic cleanup with `<close>` attribute.
--- @param fd integer File descriptor for an open directory
--- @return Dir | nil Directory handle, or nil on error
--- @return string Error message if failed
local function open_dir_fd(fd: integer): Dir | nil, string
  local raw, err = unix.fdopendir(fd)
  if raw is unix.Dir then
    return wrap_dir(raw)
  end
  return nil, errstr(err, "open_dir_fd")
end

local record FsDirModule
  stat: function(path: string): Stat | nil, string
  stat_link: function(path: string): Stat | nil, string
  stat_fd: function(fd: integer): Stat | nil, string
  make_dir: function(path: string, mode?: integer): boolean, string
  make_dirs: function(path: string, mode?: integer): boolean, string
  remove_dir: function(path: string): boolean, string
  set_cwd: function(path: string): boolean, string
  cwd: function(): string | nil, string
  open_dir: function(path: string): Dir | nil, string
  open_dir_fd: function(fd: integer): Dir | nil, string
end

local M: FsDirModule = {
  stat = stat,
  stat_link = stat_link,
  stat_fd = stat_fd,
  make_dir = make_dir,
  make_dirs = make_dirs,
  remove_dir = remove_dir,
  set_cwd = set_cwd,
  cwd = cwd,
  open_dir = open_dir,
  open_dir_fd = open_dir_fd,
}

return M
