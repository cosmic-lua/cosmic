# zip

 ZIP archive reading and writing utilities.
 Wraps cosmo.zip with a convenient Teal-typed interface for creating,
 reading, and modifying ZIP archives. Use `reader`/`writer`/`appender`
 to open by path, `from` for in-memory data, and `extract` to safely
 unpack a reader to a directory (entry names from an archive are
 attacker-controlled; never write them to disk without `extract`'s
 zip-slip validation).

## Types

### OpenOptions

 Options for opening a ZIP archive.

```teal
local record OpenOptions
  --  Compression level 0-9 (0=none, 9=maximum). Used when writing/appending.
  level: number
  --  Maximum file size limit in bytes.
  max_file_size: number
end
```

### AddOptions

 Options for adding a file to a ZIP archive.

```teal
local record AddOptions
  --  Compression method: "store" (no compression) or "deflate" (compressed).
  method: string
  --  Modification time as Unix timestamp.
  mtime: number
  --  Unix file mode/permissions (default 0644).
  mode: number
end
```

### Stat

 File metadata within a ZIP archive.

```teal
local record Stat
  --  Uncompressed file size in bytes.
  size: number
  --  Compressed file size in bytes.
  compressed_size: number
  --  CRC32 checksum of uncompressed data.
  crc32: number
  --  Modification time as Unix timestamp.
  mtime: number
  --  Compression method (0=stored, 8=deflated).
  method: number
  --  Unix file mode/permissions.
  mode: number
end
```

### Reader

 Reader for extracting files from a ZIP archive.

```teal
local record Reader
  --  Lists all files in the ZIP archive.
  --  Entry names come raw from the central directory: an archive built by
  --  another tool can contain absolute or "../" names. Validate before
  --  using a name as a filesystem path, or use extract().
  list: function(self: Reader): {string}
  --  Gets metadata for a specific file in the archive.
  stat: function(self: Reader, name: string): Stat | nil
  --  Reads the contents of a file from the archive.
  read: function(self: Reader, name: string): string | nil, string
  --  Closes the ZIP reader and releases resources.
  close: function(self: Reader)
end
```

### Writer

 Writer for creating new ZIP archives.

```teal
local record Writer
  --  Adds a file to the ZIP archive.
  add: function(self: Writer, name: string, content: string, options?: AddOptions): boolean | nil, string
  --  Closes the ZIP archive and writes the central directory.
  close: function(self: Writer)
end
```

### Appender

 Appender for adding files to an existing ZIP archive.

```teal
local record Appender
  --  Adds a file to the ZIP archive.
  add: function(self: Appender, name: string, content: string, options?: AddOptions): boolean | nil, string
  --  Removes a file from the ZIP archive by name.
  remove: function(self: Appender, name: string): boolean | nil, string
  --  Closes the ZIP archive and writes the updated central directory.
  close: function(self: Appender)
end
```

### ExtractOptions

 Options for extract().

```teal
local record ExtractOptions
  --  Refuse any entry whose declared uncompressed size exceeds this many
  --  bytes (checked before anything is read or written).
  max_file_size: number
end
```

### ZipModule

```teal
local record ZipModule
  reader: function(path: string | number, options?: OpenOptions): Reader | nil, string
  writer: function(path: string | number, options?: OpenOptions): Writer | nil, string
  appender: function(path: string, options?: OpenOptions): Appender | nil, string
  from: function(data: string, options?: OpenOptions): Reader | nil, string
  extract: function(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
end
```

## Functions

### reader

```teal
function reader(path: string | number, options?: OpenOptions): Reader | nil, string
```

 Open a ZIP archive for reading.

**Parameters:**

- `path` (string|number) - File path or file descriptor
- `options` (OpenOptions?) - Size limits

**Returns:**

- Reader - | nil The archive reader, or nil on error
- string? - Error message if opening failed

### writer

```teal
function writer(path: string | number, options?: OpenOptions): Writer | nil, string
```

 Create a new ZIP archive for writing. Any existing file is truncated.

**Parameters:**

- `path` (string|number) - File path or file descriptor
- `options` (OpenOptions?) - Compression level and size limits

**Returns:**

- Writer - | nil The archive writer, or nil on error
- string? - Error message if opening failed

### appender

```teal
function appender(path: string, options?: OpenOptions): Appender | nil, string
```

 Open a ZIP archive for appending, creating it if it does not exist.
 Unlike reader/writer, a file descriptor is not accepted; the archive
 must be given as a path.

**Parameters:**

- `path` (string) - File path
- `options` (OpenOptions?) - Compression level and size limits

**Returns:**

- Appender - | nil The archive appender, or nil on error
- string? - Error message if opening failed

### from

```teal
function from(data: string, options?: OpenOptions): Reader | nil, string
```

 Open a ZIP archive from in-memory data for reading.

**Parameters:**

- `data` (string) - The ZIP archive data
- `options` (OpenOptions?) - Size limits

**Returns:**

- Reader? - The archive reader, or nil on error
- string? - Error message if opening failed

### extract

```teal
function extract(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
```

 Extract every entry of an open reader into destdir, refusing archives
 that attempt zip-slip. All entry names (and sizes, when
 opts.max_file_size is set) are validated before anything is written, so
 a malicious archive fails without leaving partial output. File modes
 are taken from the archive masked to 0777 (setuid/setgid/sticky bits
 are stripped); entries without a mode default to 0644. Existing files
 are overwritten. The reader is left open.

**Parameters:**

- `r` (Reader) - An open archive reader (from reader() or from())
- `destdir` (string) - Directory to extract into (created if needed)
- `opts` (ExtractOptions?) - Per-entry size limit

**Returns:**

- boolean - true when every entry was written
- string? - Error message if validation or writing failed
