# zip

 ZIP archive reading and writing.
 One constructor: `zip.open(path, opts?: {mode, level,
 max_file_size_bytes}) → Archive` — mode "read" (default), "write"
 (truncate/create), or "append" (add to an existing archive, or
 create it). `open_string` is its bytes-not-path sibling for
 in-memory data (always read mode). One Archive answers every
 operation and returns an error naming the mode when an operation
 does not belong to it, so callers pick a MODE, not a type.
 `extract` safely unpacks an archive — an open one, or a path —
 to a directory (entry names from an archive are
 attacker-controlled; never write them to disk without extract's
 zip-slip validation).

## Types

### OpenOptions

 Options for open()/open_string().

```teal
local record OpenOptions
  --  "read" (default), "write" (truncate or create), or "append"
  --  (add to an existing archive, creating it if absent).
  mode: Mode
  --  Compression level 0-9, for write/append.
  level: integer
  --  Refuse any member whose declared uncompressed size exceeds this
  --  many bytes.
  max_file_size_bytes: integer
end
```

### ExtractOptions

 Options for extract().

```teal
local record ExtractOptions
  --  Refuse any entry whose declared uncompressed size exceeds this many
  --  bytes (checked before anything is read or written).
  max_file_size_bytes: integer
end
```

### Archive

 An open archive, in one of three modes. Read operations (list,
 stat, read) answer only in "read" mode; add answers in "write" and
 "append"; remove in "append" alone. An operation outside the
 archive's mode fails with an error naming the mode, so the type
 carries every method and the MODE — not the type — says which
 apply.

```teal
local record Archive
  --  The mode this archive was opened in.
  mode: Mode
  --  List every entry (read mode).
  list: function(self: Archive): {Entry} | nil, string
  --  Metadata for one entry (read mode).
  stat: function(self: Archive, name: string): EntryStat | nil, string
  --  One entry's content (read mode).
  read: function(self: Archive, name: string): string | nil, string
  --  One entry decompressed straight to a file (read mode): the bytes
  --  stay in C, so no entry-sized Lua string exists. The destination
  --  is created or truncated (0644 before umask); byte-identical to
  --  read() plus a write.
  save: function(self: Archive, name: string, dest: string): boolean, string
  --  Add a member (write or append mode).
  add: function(self: Archive, name: string, content: string, opts?: AddOptions): boolean, string
  --  Add a member streamed from a file on disk (append mode): read,
  --  sized and compressed in C, so the file never exists as a Lua
  --  string. mode and mtime default from the source file; opts
  --  override, same semantics as add().
  add_file: function(self: Archive, name: string, source: string, opts?: AddOptions): boolean, string
  --  Remove a member (append mode).
  remove: function(self: Archive, name: string): boolean, string
  --  Close the archive (any mode; idempotent: a second close is a
  --  no-op that returns true). In write and append mode close is where
  --  the archive lands on disk -- the central directory and any
  --  pending adds flush here -- so `false, error` means the file is
  --  NOT a valid archive.
  close: function(self: Archive): boolean, string
end
```

### RawHandles

```teal
local record RawHandles
  reader: zip.Reader
  writer: zip.Writer
  appender: zip.Appender
end
```

### ZipModule

```teal
local record ZipModule
  open: function(path: string | integer, opts?: OpenOptions): Archive | nil, string
  open_string: function(data: string, opts?: OpenOptions): Archive | nil, string
  extract: function(archive: Archive | string, destdir: string, opts?: ExtractOptions): boolean, string
end
```

### AddOptions

 Options for adding a file to a ZIP archive: method ("store" or
 "deflate"), mtime, and mode. The generated cosmo.zip.AddOptions record.

alias of `cosmo.zip.AddOptions` — field and method table: `cosmic --docs cosmo.zip.AddOptions`

### EntryStat

 File metadata within a ZIP archive: size, compressed_size, crc32,
 mtime, method (0=stored, 8=deflated), and mode.

alias of `cosmo.zip.Stat` — field and method table: `cosmic --docs cosmo.zip.Stat`

### Entry

 Directory entry returned by Archive:list(): name, size, and mode. The
 generated cosmo.zip.Entry record.

alias of `cosmo.zip.Entry` — field and method table: `cosmic --docs cosmo.zip.Entry`

## Functions

### open

```teal
function open(path: string | integer, opts?: OpenOptions): Archive | nil, string
```

 Open a ZIP archive. Mode "read" (default) reads an existing
 archive; "write" creates (truncating any existing file); "append"
 adds to an existing archive, creating it when absent. A file
 descriptor is accepted for read and write; append requires a path
 (the binding reopens the file).

**Parameters:**

- `path` (string|integer) - File path (or fd, for read/write)
- `opts` (OpenOptions?) - mode, level, max_file_size_bytes

**Returns:**

- Archive - | nil The archive, or nil on error
- string? - Error message if opening failed

### open_string

```teal
function open_string(data: string, opts?: OpenOptions): Archive | nil, string
```

 Open a ZIP archive from in-memory data, always in read mode
 (`_string` is the bytes-not-path sibling spelling; `_bytes` is
 reserved for counts).

**Parameters:**

- `data` (string) - The ZIP archive data
- `opts` (OpenOptions?) - max_file_size_bytes (mode is always read)

**Returns:**

- Archive - | nil The archive, or nil on error
- string? - Error message if opening failed

### extract

```teal
function extract(archive: Archive | string, destdir: string,
    opts?: ExtractOptions): boolean, string
```

 Extract every entry of a read archive into destdir, refusing
 archives that attempt zip-slip. All entry names (and sizes, when
 opts.max_file_size_bytes is set) are validated before anything is
 written, so a malicious archive fails without leaving partial
 output. File modes are taken from the archive masked to 0777
 (setuid/setgid/sticky bits are stripped); entries without a mode
 default to 0644. Existing files are overwritten. An archive passed
 as a handle is left open; a path is opened read-mode and closed.

**Parameters:**

- `archive` (Archive|string) - An open read archive, or a path to one
- `destdir` (string) - Directory to extract into (created if needed)
- `opts` (ExtractOptions?) - Per-entry size limit

**Returns:**

- boolean - true when every entry was written
- string? - Error message if validation or writing failed

### a:list

```teal
function a:list(): {Entry} | nil, string
```

### a:stat

```teal
function a:stat(name: string): EntryStat | nil, string
```

### a:read

```teal
function a:read(name: string): string | nil, string
```

### a:save

```teal
function a:save(name: string, dest: string): boolean, string
```

### a:add

```teal
function a:add(name: string, content: string, opts?: AddOptions): boolean, string
```

### a:add_file

```teal
function a:add_file(name: string, source: string, opts?: AddOptions): boolean, string
```

### a:remove

```teal
function a:remove(name: string): boolean, string
```

### a:close

```teal
function a:close(): boolean, string
```
