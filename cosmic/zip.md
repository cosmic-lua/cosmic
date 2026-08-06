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
  open: function(path: string | integer, opts?: OpenOptions): Archive | nil, string
  create: function(path: string | integer, opts?: OpenOptions): Builder | nil, string
  append: function(path: string, opts?: OpenOptions): Appender | nil, string
  open_bytes: function(data: string, opts?: OpenOptions): Archive | nil, string
  extract: function(archive: Archive, destdir: string, opts?: ExtractOptions): boolean, string
end
```

### OpenOptions

 Options for opening a ZIP archive: compression level 0-9 (used when
 writing/appending) and max_file_size limit. The generated
 cosmo.zip.OpenOptions record.

alias of `cosmo.zip.OpenOptions` — field and method table: `cosmic --docs cosmo.zip.OpenOptions`

### AddOptions

 Options for adding a file to a ZIP archive: method ("store" or
 "deflate"), mtime, and mode. The generated cosmo.zip.AddOptions record.

alias of `cosmo.zip.AddOptions` — field and method table: `cosmic --docs cosmo.zip.AddOptions`

### Stat

 File metadata within a ZIP archive: size, compressed_size, crc32,
 mtime, method (0=stored, 8=deflated), and mode. The generated
 cosmo.zip.Stat record.

alias of `cosmo.zip.Stat` — field and method table: `cosmic --docs cosmo.zip.Stat`

### Entry

 Directory entry returned by Reader:list(): name, size, and mode. The
 generated cosmo.zip.Entry record.

alias of `cosmo.zip.Entry` — field and method table: `cosmic --docs cosmo.zip.Entry`

### Archive

 Reader for extracting files from a ZIP archive (the generated
 cosmo.zip.Reader class): list(), stat(name), read(name), close().
 Entry names come raw from the central directory: an archive built by
 another tool can contain absolute or "../" names. Validate before
 using a name as a filesystem path, or use extract().
 (api-review-8: the public type name is Archive.)

alias of `cosmo.zip.Reader` — field and method table: `cosmic --docs cosmo.zip.Reader`

### Builder

 Builder for creating new ZIP archives (the generated cosmo.zip.Writer
 class): add(name, content, opts?), close().
 (api-review-8: the public type name is Builder.)

alias of `cosmo.zip.Writer` — field and method table: `cosmic --docs cosmo.zip.Writer`

### Appender

 Appender for adding files to an existing ZIP archive (the generated
 cosmo.zip.Appender class): add(name, content, opts?), remove(name),
 close().

alias of `cosmo.zip.Appender` — field and method table: `cosmic --docs cosmo.zip.Appender`

## Functions

### open

```teal
function open(path: string | integer, opts?: OpenOptions): Archive | nil, string
```

 Open a ZIP archive for reading (api-review-8: was `reader` — `open`
 is the constructor that acquires a closeable resource, D20).

**Parameters:**

- `path` (string|integer) - File path or file descriptor
- `opts` (OpenOptions?) - Size limits

**Returns:**

- Archive - | nil The archive, or nil on error
- string? - Error message if opening failed

### create

```teal
function create(path: string | integer, opts?: OpenOptions): Builder | nil, string
```

 Create a new ZIP archive for writing (api-review-8: was `writer`).
 Any existing file is truncated.

**Parameters:**

- `path` (string|integer) - File path or file descriptor
- `opts` (OpenOptions?) - Compression level and size limits

**Returns:**

- Builder - | nil The archive builder, or nil on error
- string? - Error message if opening failed

### append

```teal
function append(path: string, opts?: OpenOptions): Appender | nil, string
```

 Open a ZIP archive for appending (api-review-8: was `appender`),
 creating it if it does not exist. Unlike open/create, a file
 descriptor is not accepted; the archive must be given as a path.

**Parameters:**

- `path` (string) - File path
- `opts` (OpenOptions?) - Compression level and size limits

**Returns:**

- Appender - | nil The archive appender, or nil on error
- string? - Error message if opening failed

### open_bytes

```teal
function open_bytes(data: string, opts?: OpenOptions): Archive | nil, string
```

 Open a ZIP archive from in-memory data for reading (api-review-8:
 was `from`; pairs with open as its bytes-not-path form).

**Parameters:**

- `data` (string) - The ZIP archive data
- `opts` (OpenOptions?) - Size limits

**Returns:**

- Archive? - The archive, or nil on error
- string? - Error message if opening failed

### extract

```teal
function extract(r: Archive, destdir: string, opts?: ExtractOptions): boolean, string
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
