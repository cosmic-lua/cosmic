# zip

 ZIP archive reading and writing utilities.
 Wraps cosmo.zip with a convenient Teal-typed interface for creating,
 reading, and modifying ZIP archives. Use `reader`/`writer`/`appender`
 to open by path, `from` for in-memory data, and `extract` to safely
 unpack a reader to a directory (entry names from an archive are
 attacker-controlled; never write them to disk without `extract`'s
 zip-slip validation).

## Types

### ExtractOptions

 Options for extract().

```teal
local record ExtractOptions
  --  Refuse any entry whose declared uncompressed size exceeds this many
  --  bytes (checked before anything is read or written).
  max_file_size: integer
end
```

### ZipModule

```teal
local record ZipModule
  reader: function(path: string | integer, options?: OpenOptions): Reader | nil, string
  writer: function(path: string | integer, options?: OpenOptions): Writer | nil, string
  appender: function(path: string, options?: OpenOptions): Appender | nil, string
  from: function(data: string, options?: OpenOptions): Reader | nil, string
  extract: function(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
end
```

## Functions

### reader

```teal
function reader(path: string | integer, options?: OpenOptions): Reader | nil, string
```

 Open a ZIP archive for reading.

**Parameters:**

- `path` (string|integer) - File path or file descriptor
- `options` (OpenOptions?) - Size limits

**Returns:**

- Reader - | nil The archive reader, or nil on error
- string? - Error message if opening failed

### writer

```teal
function writer(path: string | integer, options?: OpenOptions): Writer | nil, string
```

 Create a new ZIP archive for writing. Any existing file is truncated.

**Parameters:**

- `path` (string|integer) - File path or file descriptor
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
