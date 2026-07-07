# types

 Shared type definitions for the fs module family, plus the runtime
 wrapper that puts type predicates on Stat values.

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
 Use the is_dir()/is_file()/is_link()/... methods to check file type.

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
  --  Returns true if this is a directory.
  is_dir: function(self: Stat): boolean
  --  Returns true if this is a regular file.
  is_file: function(self: Stat): boolean
  --  Returns true if this is a symbolic link (only lstat can see one).
  is_link: function(self: Stat): boolean
  --  Returns true if this is a block device.
  is_block_device: function(self: Stat): boolean
  --  Returns true if this is a character device.
  is_char_device: function(self: Stat): boolean
  --  Returns true if this is a FIFO (named pipe).
  is_fifo: function(self: Stat): boolean
  --  Returns true if this is a socket.
  is_socket: function(self: Stat): boolean
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

### FileInfo

 File information with Unix permissions.

```teal
local record FileInfo
  mode: number
end
```

### fs_types

```teal
local record fs_types
  --  Wrap a raw cosmo.unix Stat so it carries the type predicates.
  wrap: function(raw: unix.Stat): Stat
end
```

### Wrapped

 Wrapper table: holds the raw stat userdata; a shared metatable
 delegates the accessors and implements the predicates, so wrapping
 costs one small table per stat call.

```teal
local record Wrapped
  raw: unix.Stat
end
```
