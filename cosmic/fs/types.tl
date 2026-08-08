--- Shared type definitions for the fs module family, plus the runtime
--- wrapper that puts type predicates on Stat values.
local unix = require("cosmo.unix")

local record fs_types

  --- One timestamp: whole seconds plus optional nanoseconds (default 0
  --- — a bare secs value always means a literal stamp, never "now").
  --- nsecs may be unix.UTIME_NOW/UTIME_OMIT when a caller wants that
  --- raw kernel behavior.
  record Timespec
    secs: integer
    nsecs: integer
  end

  --- The timestamps set_times/set_times_fd apply — and the record
  --- Stat:times() returns, so `set_times(dst, stat(src):times())`
  --- round-trips (#988). Omit a field to leave that timestamp exactly
  --- as it is.
  record Times
    atime: Timespec
    mtime: Timespec
  end

  --- Filesystem statistics.
  --- Returned by statfs() and statfs_fd(). Spelled methods with units
  --- (#988, rule 1); the raw C abbreviations remain as DEPRECATED
  --- aliases until the pin advance.
  record Statfs
    --- Returns filesystem type identifier.
    type: function(self: Statfs): integer
    --- Returns the optimal transfer block size in bytes.
    block_size_bytes: function(self: Statfs): integer
    --- Returns the fragment size in bytes.
    fragment_size_bytes: function(self: Statfs): integer
    --- Returns total data blocks in the filesystem.
    total_blocks: function(self: Statfs): integer
    --- Returns free blocks in the filesystem.
    free_blocks: function(self: Statfs): integer
    --- Returns free blocks available to an unprivileged user.
    available_blocks: function(self: Statfs): integer
    --- Returns total file nodes in the filesystem.
    total_files: function(self: Statfs): integer
    --- Returns free file nodes in the filesystem.
    free_files: function(self: Statfs): integer
    --- Returns the filesystem ID as two integers.
    id: function(self: Statfs): integer, integer
    --- Returns the maximum filename length in bytes.
    max_name_bytes: function(self: Statfs): integer
    --- Returns mount flags.
    flags: function(self: Statfs): integer

    --- DEPRECATED raw abbreviations (#988); deleted at pin advance.
    bsize: function(self: Statfs): integer
    blocks: function(self: Statfs): integer
    bfree: function(self: Statfs): integer
    bavail: function(self: Statfs): integer
    files: function(self: Statfs): integer
    ffree: function(self: Statfs): integer
    fsid: function(self: Statfs): integer, integer
    namelen: function(self: Statfs): integer
    frsize: function(self: Statfs): integer
  end

  --- File or directory metadata.
  --- Use the is_dir()/is_file()/is_link()/... methods to check file type.
  --- ONE representation: always the
  --- raw cosmo.unix stat userdata, with the is_* predicates installed
  --- once on the binding's shared metatable — so `st is fs.Stat`
  --- narrows correctly and no wrapper table is ever allocated.
  record Stat
    userdata
    --- Returns file size in bytes.
    size: function(self: Stat): integer
    --- Returns file mode (permissions and type bits).
    mode: function(self: Stat): integer
    --- Returns owner user ID.
    uid: function(self: Stat): integer
    --- Returns owner group ID.
    gid: function(self: Stat): integer
    --- Returns the modification time as a Timespec (#988: was `mtim`,
    --- a bare tuple).
    modify_time: function(self: Stat): Timespec
    --- Returns the access time as a Timespec (#988: was `atim`).
    access_time: function(self: Stat): Timespec
    --- Returns the status-change time as a Timespec (#988: was `ctim`).
    change_time: function(self: Stat): Timespec
    --- Returns the birth time as a Timespec (#988: was `birthtim`).
    birth_time: function(self: Stat): Timespec
    --- Returns {atime, mtime} ready for set_times, so
    --- `set_times(dst, stat(src):times())` round-trips.
    times: function(self: Stat): Times

    --- DEPRECATED bare-tuple times (#988); deleted at pin advance.
    birthtim: function(self: Stat): integer, integer
    mtim: function(self: Stat): integer, integer
    atim: function(self: Stat): integer, integer
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
    read: function(self): string | nil, integer
    --- Closes directory handle.
    close: function(self)
  end

  --- Handle for reading directory entries.
  --- Supports automatic cleanup with `<close>` attribute.
  record Dir
    metamethod __close: function(self: Dir)
    --- Reads next directory entry. Returns nil when done — and the
    --- type says so. The second return is the dirent d_type (fs.DT_DIR
    --- / DT_REG / DT_LNK / ... / DT_UNKNOWN where the filesystem does
    --- not expose it), so callers can classify entries without a
    --- stat(2) per entry.
    read: function(self: Dir): string | nil, integer
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

  --- One visited entry, as cosmic.fs.visit hands to its visitor: the
  --- full path (already complete — never join it with name), the
  --- basename, the entry's Stat, and its depth (entries directly under
  --- the walk root are depth 1).
  record Entry
    path: string
    name: string
    stat: Stat
    depth: integer
  end

  --- Wrap a raw cosmo.unix Stat so it carries the type predicates.
  --- Fallible only in the one way the unification allows: a runtime
  --- whose stat metatable cannot take the predicates is refused, not
  --- papered over with a second representation.
  wrap: function(raw: unix.Stat): Stat | nil, string

  --- Install the spelled Statfs methods on a raw statfs userdata's
  --- metatable (same lazy metatable-extension mechanism as wrap()).
  --- Used by statfs()/statfs_fd(); returns the value typed as Statfs.
  wrap_statfs: function(raw: any): Statfs | nil, string

end

--- Predicates for the raw stat userdata, installed once on the shared
--- metatable every cosmo.unix Stat carries. After installation wrap()
--- returns the userdata unchanged — no per-call allocation, which
--- matters on walk-heavy paths where every visited entry is wrapped
--- (measured at ~+13-17% on fs_walk_tree/fs_stat_tree).
local function timespec_of(secs: integer, nsecs: integer): fs_types.Timespec
  return {secs = secs, nsecs = nsecs}
end

local raw_predicates: {string: any} = {
  is_dir = function(self: unix.Stat): boolean return unix.S_ISDIR(self:mode()) end,
  is_file = function(self: unix.Stat): boolean return unix.S_ISREG(self:mode()) end,
  is_link = function(self: unix.Stat): boolean return unix.S_ISLNK(self:mode()) end,
  is_block_device = function(self: unix.Stat): boolean return unix.S_ISBLK(self:mode()) end,
  is_char_device = function(self: unix.Stat): boolean return unix.S_ISCHR(self:mode()) end,
  is_fifo = function(self: unix.Stat): boolean return unix.S_ISFIFO(self:mode()) end,
  is_socket = function(self: unix.Stat): boolean return unix.S_ISSOCK(self:mode()) end,
  -- Spelled time methods (#988): Timespec records over the raw tuples,
  -- so a stat's times feed set_times without hand-packing.
  modify_time = function(self: unix.Stat): fs_types.Timespec
    return timespec_of(self:mtim())
  end,
  access_time = function(self: unix.Stat): fs_types.Timespec
    return timespec_of(self:atim())
  end,
  change_time = function(self: unix.Stat): fs_types.Timespec
    return timespec_of(self:ctim())
  end,
  birth_time = function(self: unix.Stat): fs_types.Timespec
    return timespec_of(self:birthtim())
  end,
  times = function(self: unix.Stat): fs_types.Times
    return {atime = timespec_of(self:atim()), mtime = timespec_of(self:mtim())}
  end,
}

-- Spelled Statfs methods (#988, rule 1) over the raw C abbreviations.
-- Each delegates, so the values stay whatever the binding reports.
local statfs_methods: {string: any} = {
  block_size_bytes = function(self: any): integer
    return (self as fs_types.Statfs):bsize() -- cast: userdata boundary
  end,
  fragment_size_bytes = function(self: any): integer
    return (self as fs_types.Statfs):frsize() -- cast: userdata boundary
  end,
  total_blocks = function(self: any): integer
    return (self as fs_types.Statfs):blocks() -- cast: userdata boundary
  end,
  free_blocks = function(self: any): integer
    return (self as fs_types.Statfs):bfree() -- cast: userdata boundary
  end,
  available_blocks = function(self: any): integer
    return (self as fs_types.Statfs):bavail() -- cast: userdata boundary
  end,
  total_files = function(self: any): integer
    return (self as fs_types.Statfs):files() -- cast: userdata boundary
  end,
  free_files = function(self: any): integer
    return (self as fs_types.Statfs):ffree() -- cast: userdata boundary
  end,
  id = function(self: any): integer, integer
    return (self as fs_types.Statfs):fsid() -- cast: userdata boundary
  end,
  max_name_bytes = function(self: any): integer
    return (self as fs_types.Statfs):namelen() -- cast: userdata boundary
  end,
}

--- Install methods on a raw userdata's shared metatable. Lazy — uses
--- the first value a wrapper sees, so module load never needs a
--- syscall (which a sandbox could deny). Returns false if the
--- metatable is not an extensible Lua table.
local function extend_metatable(raw: any, extra: {string: any}): boolean
  local mt = getmetatable(raw)
  if type(mt) ~= "table" then
    return false
  end
  local idx = (mt as {string: any}).__index -- cast: from any
  if type(idx) ~= "table" then
    return false
  end
  local methods = idx as {string: any} -- cast: from any
  for name, fn in pairs(extra) do
    methods[name] = fn
  end
  return true
end

local function install_predicates(raw: unix.Stat): boolean
  return extend_metatable(raw as any, raw_predicates) -- cast: userdata boundary
end

-- "unknown" until the first wrap probes; then "direct" or
-- "unsupported". There is no wrapper-table fallback any more
-- (the Stat unification): two representations made `is`
-- unusable and put a justified cast at every Stat use site, to cover a
-- runtime shape the pinned cosmos has never had. A sealed metatable is
-- now an honest error from stat/lstat/fstat instead of a silent switch
-- to a second representation.
local wrap_mode: string = "unknown"

fs_types.wrap = function(raw: unix.Stat): fs_types.Stat | nil, string
  if wrap_mode == "unknown" then
    wrap_mode = install_predicates(raw) and "direct" or "unsupported"
  end
  if wrap_mode == "direct" then
    return raw as fs_types.Stat -- cast: userdata boundary
  end
  return nil, "stat: this runtime's Stat metatable is sealed; " ..
  "cosmic.fs requires the pinned cosmos runtime"
end

-- Same lazy one-shot for the statfs userdata's metatable.
local statfs_mode: string = "unknown"

fs_types.wrap_statfs = function(raw: any): fs_types.Statfs | nil, string
  if statfs_mode == "unknown" then
    statfs_mode = extend_metatable(raw, statfs_methods) and "direct" or "unsupported"
  end
  if statfs_mode == "direct" then
    return raw as fs_types.Statfs -- cast: userdata boundary
  end
  return nil, "statfs: this runtime's Statfs metatable is sealed; " ..
  "cosmic.fs requires the pinned cosmos runtime"
end

return fs_types
