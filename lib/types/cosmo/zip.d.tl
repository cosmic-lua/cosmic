-- type declarations for cosmo.zip

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

local record AddOptions
  --- Compression method: `"store"` or `"deflate"`
  method: string
  --- Modification time as Unix timestamp
  mtime: number
  --- Unix file mode (default 0644)
  mode: number
end

--- Reader for extracting files from a ZIP archive.
local record Reader
  --- Lists all files in the ZIP archive.
  list: function(self: Reader): {string}
  --- Gets metadata for a specific file in the archive.
  stat: function(self: Reader, name: string): Stat | nil
  --- Reads the contents of a file from the archive.
  read: function(self: Reader, name: string): string | nil, string | nil
  --- Closes the ZIP reader and releases resources.
  close: function(self: Reader)
end

--- Writer for creating new ZIP archives.
local record Writer
  --- Adds a file to the ZIP archive.
  add: function(self: Writer, name: string, content: string, options?: AddOptions): boolean | nil, string | nil
  --- Closes the ZIP archive and writes the central directory.
  close: function(self: Writer)
end

--- Writer for appending files to an existing ZIP archive.
local record Appender
  --- Adds a file to the ZIP archive.
  add: function(self: Appender, name: string, content: string, options?: AddOptions): boolean | nil, string | nil
  --- Removes a file from the ZIP archive by name.
  remove: function(self: Appender, name: string): boolean | nil, string | nil
  --- Closes the ZIP archive and writes the updated central directory.
  close: function(self: Appender)
end

local record zip
  --- Opens a ZIP archive for reading, writing, or appending.
  --- The first argument can be a file path string or a file descriptor integer.
  open: function(path: string | number, mode?: string, options?: OpenOptions): any, string | nil
  --- Opens a ZIP archive from in-memory data for reading.
  from: function(data: string, options?: OpenOptions): Reader | nil, string | nil
end

return zip
