-- type declarations for cosmo.zip
-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

local record OpenOptions
  --- Compression level 0-9 (for "w" and "a" modes)
  level: number
  --- Maximum file size limit in bytes
  max_file_size: number
end

--- File metadata within a ZIP archive.
local record Stat
  --- Uncompressed file size in bytes
  size: number
  --- Compressed file size in bytes
  compressed_size: number
  --- CRC32 checksum of uncompressed data
  crc32: number
  --- Modification time as Unix timestamp
  mtime: number
  --- Compression method (0=stored, 8=deflated)
  method: number
  --- Unix file mode/permissions
  mode: number
end

--- Directory entry returned by `zip.Reader:list`.
local record Entry
  --- Entry path within the archive
  name: string
  --- Uncompressed size in bytes
  size: number
  --- Unix file mode/permissions
  mode: number
end

local record AddOptions
  --- Compression method: `"store"` or `"deflate"`
  method: CompressionMethod
  --- Modification time as Unix timestamp
  mtime: number
  --- Unix file mode (default 0644)
  mode: number
end

--- Reader for extracting files from a ZIP archive.
local record Reader
  userdata
  --- Lists all files in the ZIP archive, in archive order. Each record
  --- carries the entry's name, uncompressed size, and mode, so bulk
  --- operations don't need a follow-up `stat` per entry.
  list: function(self: Reader): {Entry}
  --- Gets metadata for a specific file in the archive.
  stat: function(self: Reader, name: string): Stat | nil, string | nil
  --- Reads the contents of a file from the archive.
  read: function(self: Reader, name: string): string | nil, string | nil
  --- Closes the ZIP reader and releases resources.
  close: function(self: Reader)
end

--- Writer for creating new ZIP archives.
local record Writer
  userdata
  --- Adds a file to the ZIP archive.
  add: function(self: Writer, name: string, content: string, options?: AddOptions): boolean | nil, string | nil
  --- Closes the ZIP archive and writes the central directory.
  close: function(self: Writer)
end

--- Writer for appending files to an existing ZIP archive.
local record Appender
  userdata
  --- Adds a file to the ZIP archive.
  add: function(self: Appender, name: string, content: string, options?: AddOptions): boolean | nil, string | nil
  --- Removes entries by name from the archive.
  --- If `name` ends with `/`, all entries whose names start with that
  --- directory prefix are removed; otherwise the single entry whose name
  --- matches exactly is removed. Both entries already present in the
  --- archive and entries added via `add` but not yet flushed are matched.
  --- The local file data of removed existing entries remains as dead space
  --- in the archive; only the central directory reference is removed.
  --- Fails with an error if no entry matched or the appender is closed.
  remove: function(self: Appender, name: string): boolean | nil, string | nil
  --- Closes the ZIP archive and writes the updated central directory.
  close: function(self: Appender)
end

--- Archive open modes, validated by the strcmp chain in `LuaZipOpen`
--- (`tool/net/lzip.c`).
local enum OpenMode
  "r"
  "w"
  "a"
end

--- Entry compression methods (`tool/net/lzip.c`); anything else is
--- rejected with "invalid method".
local enum CompressionMethod
  "store"
  "deflate"
end

local record zip
  type OpenOptions = OpenOptions
  type Stat = Stat
  type Entry = Entry
  type AddOptions = AddOptions
  type Reader = Reader
  type Writer = Writer
  type Appender = Appender
  type OpenMode = OpenMode
  type CompressionMethod = CompressionMethod

  --- Opens a ZIP archive for reading, writing, or appending.
  --- The first argument can be a file path string or a file descriptor integer.
  open: function(path: string | number, mode?: OpenMode, options?: OpenOptions): any, string | nil
  --- Opens a ZIP archive from in-memory data for reading.
  from: function(data: string, options?: OpenOptions): Reader | nil, string | nil
  --- Creates a new ZIP archive for writing. This is equivalent to
  --- `zip.open(path, "w", options)`. Any existing file is truncated.
  create: function(path: string | number, options?: OpenOptions): Writer | nil, string | nil
  --- Opens an existing ZIP archive for appending. This is equivalent to
  --- `zip.open(path, "a", options)`. Unlike `zip.open` and `zip.create`,
  --- a file descriptor is not accepted; the archive must be given as a
  --- path.
  append: function(path: string, options?: OpenOptions): Appender | nil, string | nil
  --- Validates a ZIP entry name without adding it to an archive, applying
  --- the same rules that `add` enforces (relative path, no `..` segments,
  --- no control characters, etc.).
  validate_name: function(name: string): boolean | nil, string | nil
end

return zip
