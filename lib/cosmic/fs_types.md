# fs_types

 Shared type definitions for the fs module family.

## Types

### Statfs

 Filesystem statistics.
 Returned by statfs() and fstatfs().

```teal
local record Statfs
  --  Returns filesystem type identifier.
  type: function(self: Statfs): number
  --  Returns optimal transfer block size.
  bsize: function(self: Statfs): number
  --  Returns total data blocks in filesystem.
  blocks: function(self: Statfs): number
  --  Returns free blocks in filesystem.
  bfree: function(self: Statfs): number
  --  Returns free blocks available to unprivileged user.
  bavail: function(self: Statfs): number
  --  Returns total file nodes in filesystem.
  files: function(self: Statfs): number
  --  Returns free file nodes in filesystem.
  ffree: function(self: Statfs): number
  --  Returns filesystem ID as two numbers.
  fsid: function(self: Statfs): number, number
  --  Returns maximum length of filenames.
  namelen: function(self: Statfs): number
  --  Returns fragment size.
  frsize: function(self: Statfs): number
  --  Returns mount flags.
  flags: function(self: Statfs): number
end
```

### Stat

 File or directory metadata.
 Use is_dir(), is_file(), etc. to check file type.

```teal
local record Stat
  --  Returns file size in bytes.
  size: function(self: Stat): number
  --  Returns file mode (permissions and type bits).
  mode: function(self: Stat): number
  --  Returns owner user ID.
  uid: function(self: Stat): number
  --  Returns owner group ID.
  gid: function(self: Stat): number
  --  Returns birth time as seconds, nanoseconds.
  birthtim: function(self: Stat): number, number
  --  Returns modification time as seconds, nanoseconds.
  mtim: function(self: Stat): number, number
  --  Returns access time as seconds, nanoseconds.
  atim: function(self: Stat): number, number
  --  Returns status change time as seconds, nanoseconds.
  ctim: function(self: Stat): number, number
  --  Returns number of 512-byte blocks allocated.
  blocks: function(self: Stat): number
  --  Returns number of hard links.
  nlink: function(self: Stat): number
  --  Returns device ID containing the file.
  dev: function(self: Stat): number
  --  Returns device ID for special files (0 or -1 for non-devices).
  rdev: function(self: Stat): number
end
```

### Dir

 Handle for reading directory entries.
 Supports automatic cleanup with `<close>` attribute.

```teal
local record Dir
  --  Reads next directory entry. Returns nil when done.
  read: function(self: Dir): string
  --  Closes directory handle.
  close: function(self: Dir)
  --  Returns file descriptor for this directory.
  fd: function(self: Dir): number
  --  Rewinds to beginning of directory.
  rewind: function(self: Dir)
  --  Returns current position in directory stream.
  tell: function(self: Dir): number
  --  Returns true if directory handle is closed.
  closed: function(self: Dir): boolean
end
```

### WalkStat

 File or directory metadata for walk visitor.

```teal
local record WalkStat
  mode: function(self: WalkStat): number
  size: function(self: WalkStat): number
  mtim: function(self: WalkStat): number
end
```

### FileInfo

 File information with Unix permissions.

```teal
local record FileInfo
  mode: number
end
```

### fs_types
