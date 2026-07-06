# zip

 ZIP archive reading and writing utilities.
 Wraps cosmo.zip with a convenient Teal-typed interface for creating, reading, and modifying ZIP archives.

## Types

### OpenOptions

 Options for opening a ZIP archive.

```teal
local record OpenOptions
  --  Compression level 0-9 (0=none, 9=maximum). Used for "w" and "a" modes.
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

### ZipModule

```teal
local record ZipModule
  open: function(path: string | number, mode?: string, options?: OpenOptions): any, string
  from: function(data: string, options?: OpenOptions): Reader | nil, string
end
```

## Functions

### open

```teal
function open(path: string | number, mode?: string, options?: OpenOptions): any, string
```

 Open a ZIP archive for reading, writing, or appending.
 The mode determines the type of handle returned:
 - "r" (default): Returns a Reader for extracting files
 - "w": Returns a Writer for creating a new archive (overwrites existing)
 - "a": Returns an Appender for adding files to an existing archive

**Parameters:**

- `path` (string|number) - File path or file descriptor
- `mode` (string?) - Mode: "r" (read), "w" (write), or "a" (append). Default is "r".
- `options` (OpenOptions?) - Compression level and size limits

**Returns:**

- any - The archive handle (Reader, Writer, or Appender based on mode), or nil on error
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
