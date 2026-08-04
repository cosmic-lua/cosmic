--- Shared type definitions for the fs module family, plus the runtime
--- wrapper that puts type predicates on Stat values.
local unix = require("cosmo.unix")

local record fs_types

  --- Filesystem statistics.
  --- Returned by statfs() and fstatfs().
  record Statfs
    --- Returns filesystem type identifier.
    type: function(self: Statfs): integer
    --- Returns optimal transfer block size.
    bsize: function(self: Statfs): integer
    --- Returns total data blocks in filesystem.
    blocks: function(self: Statfs): integer
    --- Returns free blocks in filesystem.
    bfree: function(self: Statfs): integer
    --- Returns free blocks available to unprivileged user.
    bavail: function(self: Statfs): integer
    --- Returns total file nodes in filesystem.
    files: function(self: Statfs): integer
    --- Returns free file nodes in filesystem.
    ffree: function(self: Statfs): integer
    --- Returns filesystem ID as two integers.
    fsid: function(self: Statfs): integer, integer
    --- Returns maximum length of filenames.
    namelen: function(self: Statfs): integer
    --- Returns fragment size.
    frsize: function(self: Statfs): integer
    --- Returns mount flags.
    flags: function(self: Statfs): integer
  end

  --- File or directory metadata.
  --- Use the is_dir()/is_file()/is_link()/... methods to check file type.
  record Stat
    --- Returns file size in bytes.
    size: function(self: Stat): integer
    --- Returns file mode (permissions and type bits).
    mode: function(self: Stat): integer
    --- Returns owner user ID.
    uid: function(self: Stat): integer
    --- Returns owner group ID.
    gid: function(self: Stat): integer
    --- Returns birth time as seconds, nanoseconds.
    birthtim: function(self: Stat): integer, integer
    --- Returns modification time as seconds, nanoseconds.
    mtim: function(self: Stat): integer, integer
    --- Returns access time as seconds, nanoseconds.
    atim: function(self: Stat): integer, integer
    --- Returns status change time as seconds, nanoseconds.
    ctim: function(self: Stat): integer, integer
    --- Returns number of 512-byte blocks allocated.
    blocks: function(self: Stat): integer
    --- Returns number of hard links.
    nlink: function(self: Stat): integer
    --- Returns device ID containing the file.
    dev: function(self: Stat): integer
    --- Returns device ID for special files (0 or -1 for non-devices).
    rdev: function(self: Stat): integer
    --- Returns true if this is a directory.
    is_dir: function(self: Stat): boolean
    --- Returns true if this is a regular file.
    is_file: function(self: Stat): boolean
    --- Returns true if this is a symbolic link (only lstat can see one).
    is_link: function(self: Stat): boolean
    --- Returns true if this is a block device.
    is_block_device: function(self: Stat): boolean
    --- Returns true if this is a character device.
    is_char_device: function(self: Stat): boolean
    --- Returns true if this is a FIFO (named pipe).
    is_fifo: function(self: Stat): boolean
    --- Returns true if this is a socket.
    is_socket: function(self: Stat): boolean
  end

  --- Stat passed to walk visitors: the same wrapped Stat.
  type WalkStat = Stat

  --- Minimal read+close view of a raw `unix.Dir`, for internal
  --- directory-traversal code (cosmic.fs.walk, cosmic.fs.tree,
  --- cosmic.embed) that casts opendir()'s result across the userdata
  --- boundary and only ever calls these two methods. `Dir` below is the
  --- richer, publicly wrapped handle callers of cosmic.fs get back.
  record DirHandle
    --- Reads next directory entry. Returns nil when done. The second
    --- return is the dirent d_type (unix.DT_DIR / DT_REG / DT_LNK / ... /
    --- DT_UNKNOWN where the filesystem does not expose it).
    read: function(self): string, integer
    --- Closes directory handle.
    close: function(self)
  end

  --- Handle for reading directory entries.
  --- Supports automatic cleanup with `<close>` attribute.
  record Dir
    metamethod __close: function(self: Dir)
    --- Reads next directory entry. Returns nil when done. The second
    --- return is the dirent d_type (fs.DT_DIR / DT_REG / DT_LNK / ... /
    --- DT_UNKNOWN where the filesystem does not expose it), so callers
    --- can classify entries without a stat(2) per entry.
    read: function(self: Dir): string, integer
    --- Closes directory handle.
    close: function(self: Dir)
    --- Returns file descriptor for this directory.
    fd: function(self: Dir): integer
    --- Rewinds to beginning of directory.
    rewind: function(self: Dir)
    --- Returns current position in directory stream.
    tell: function(self: Dir): integer
    --- Returns true if directory handle is closed.
    closed: function(self: Dir): boolean
  end

  --- File information with Unix permissions.
  record FileInfo
    mode: integer
  end

  --- Wrap a raw cosmo.unix Stat so it carries the type predicates.
  wrap: function(raw: unix.Stat): Stat

end

--- Predicates for the raw stat userdata, installed once on the shared
--- metatable every cosmo.unix Stat carries. After installation wrap()
--- returns the userdata unchanged — no per-call allocation, which
--- matters on walk-heavy paths where every visited entry is wrapped
--- (measured at ~+13-17% on fs_walk_tree/fs_stat_tree).
local raw_predicates: {string: any} = {
  is_dir = function(self: unix.Stat): boolean return unix.S_ISDIR(self:mode()) end,
  is_file = function(self: unix.Stat): boolean return unix.S_ISREG(self:mode()) end,
  is_link = function(self: unix.Stat): boolean return unix.S_ISLNK(self:mode()) end,
  is_block_device = function(self: unix.Stat): boolean return unix.S_ISBLK(self:mode()) end,
  is_char_device = function(self: unix.Stat): boolean return unix.S_ISCHR(self:mode()) end,
  is_fifo = function(self: unix.Stat): boolean return unix.S_ISFIFO(self:mode()) end,
  is_socket = function(self: unix.Stat): boolean return unix.S_ISSOCK(self:mode()) end,
}

--- Install the predicates on the raw stat's metatable. Lazy — uses the
--- first stat wrap() sees, so module load never needs a stat(2) call
--- (which a sandbox could deny). Returns false if the metatable is not
--- an extensible Lua table, in which case wrap() falls back to the
--- per-call wrapper table below.
local function install_predicates(raw: unix.Stat): boolean
  local mt = getmetatable(raw as any) -- cast: userdata boundary
  if type(mt) ~= "table" then
    return false
  end
  local idx = (mt as {string: any}).__index -- cast: from any
  if type(idx) ~= "table" then
    return false
  end
  local methods = idx as {string: any} -- cast: from any
  for name, fn in pairs(raw_predicates) do
    methods[name] = fn
  end
  return true
end

--- Fallback wrapper table: holds the raw stat userdata; a shared
--- metatable delegates the accessors and implements the predicates, so
--- wrapping costs one small table per stat call.
local record Wrapped
  raw: unix.Stat
end

local stat_methods: {string: any} = {
  size = function(self: Wrapped): integer return self.raw:size() end,
  mode = function(self: Wrapped): integer return self.raw:mode() end,
  uid = function(self: Wrapped): integer return self.raw:uid() end,
  gid = function(self: Wrapped): integer return self.raw:gid() end,
  birthtim = function(self: Wrapped): integer, integer return self.raw:birthtim() end,
  mtim = function(self: Wrapped): integer, integer return self.raw:mtim() end,
  atim = function(self: Wrapped): integer, integer return self.raw:atim() end,
  ctim = function(self: Wrapped): integer, integer return self.raw:ctim() end,
  blocks = function(self: Wrapped): integer return self.raw:blocks() end,
  nlink = function(self: Wrapped): integer return self.raw:nlink() end,
  dev = function(self: Wrapped): integer return self.raw:dev() end,
  rdev = function(self: Wrapped): integer return self.raw:rdev() end,
  is_dir = function(self: Wrapped): boolean return unix.S_ISDIR(self.raw:mode()) end,
  is_file = function(self: Wrapped): boolean return unix.S_ISREG(self.raw:mode()) end,
  is_link = function(self: Wrapped): boolean return unix.S_ISLNK(self.raw:mode()) end,
  is_block_device = function(self: Wrapped): boolean return unix.S_ISBLK(self.raw:mode()) end,
  is_char_device = function(self: Wrapped): boolean return unix.S_ISCHR(self.raw:mode()) end,
  is_fifo = function(self: Wrapped): boolean return unix.S_ISFIFO(self.raw:mode()) end,
  is_socket = function(self: Wrapped): boolean return unix.S_ISSOCK(self.raw:mode()) end,
}

local stat_mt: metatable < Wrapped > = {
  __index = stat_methods,
}

local wrap_mode: string = "unknown"

fs_types.wrap = function(raw: unix.Stat): fs_types.Stat
  if wrap_mode == "unknown" then
    wrap_mode = install_predicates(raw) and "direct" or "fallback"
  end
  if wrap_mode == "direct" then
    return raw as fs_types.Stat -- cast: mixed-representation Stat
  end
  local wrapped: Wrapped = setmetatable({raw = raw}, stat_mt)
  return wrapped as fs_types.Stat -- cast: mixed-representation Stat
end

return fs_types
