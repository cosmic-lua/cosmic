--- ZIP archive reading and writing utilities.
--- Wraps cosmo.zip with a convenient Teal-typed interface for creating, reading, and modifying ZIP archives.
local zip = require("cosmo.zip")

--- Options for opening a ZIP archive.
local record OpenOptions
  --- Compression level 0-9 (0=none, 9=maximum). Used for "w" and "a" modes.
  level: number
  --- Maximum file size limit in bytes.
  max_file_size: number
end

--- Options for adding a file to a ZIP archive.
local record AddOptions
  --- Compression method: "store" (no compression) or "deflate" (compressed).
  method: string
  --- Modification time as Unix timestamp.
  mtime: number
  --- Unix file mode/permissions (default 0644).
  mode: number
end

--- File metadata within a ZIP archive.
local record Stat
  --- Uncompressed file size in bytes.
  size: number
  --- Compressed file size in bytes.
  compressed_size: number
  --- CRC32 checksum of uncompressed data.
  crc32: number
  --- Modification time as Unix timestamp.
  mtime: number
  --- Compression method (0=stored, 8=deflated).
  method: number
  --- Unix file mode/permissions.
  mode: number
end

--- Reader for extracting files from a ZIP archive.
local record Reader
  --- Lists all files in the ZIP archive.
  --- @return {string} List of file paths in the archive
  list: function(self: Reader): {string}

  --- Gets metadata for a specific file in the archive.
  --- @param name string The file path within the archive
  --- @return Stat? File metadata, or nil if file not found
  stat: function(self: Reader, name: string): Stat

  --- Reads the contents of a file from the archive.
  --- @param name string The file path within the archive
  --- @return string? The file contents, or nil on error
  --- @return string? Error message if reading failed
  read: function(self: Reader, name: string): string, string

  --- Closes the ZIP reader and releases resources.
  close: function(self: Reader)
end

--- Writer for creating new ZIP archives.
local record Writer
  --- Adds a file to the ZIP archive.
  --- @param name string The file path within the archive
  --- @param content string The file contents
  --- @param options AddOptions? Optional compression and metadata settings
  --- @return boolean? true on success, nil on failure
  --- @return string? Error message if adding failed
  add: function(self: Writer, name: string, content: string, options?: AddOptions): boolean, string

  --- Closes the ZIP archive and writes the central directory.
  close: function(self: Writer)
end

--- Appender for adding files to an existing ZIP archive.
local record Appender
  --- Adds a file to the ZIP archive.
  --- @param name string The file path within the archive
  --- @param content string The file contents
  --- @param options AddOptions? Optional compression and metadata settings
  --- @return boolean? true on success, nil on failure
  --- @return string? Error message if adding failed
  add: function(self: Appender, name: string, content: string, options?: AddOptions): boolean, string

  --- Closes the ZIP archive and writes the updated central directory.
  close: function(self: Appender)
end

--- Open a ZIP archive for reading, writing, or appending.
--- The mode determines the type of handle returned:
--- - "r" (default): Returns a Reader for extracting files
--- - "w": Returns a Writer for creating a new archive (overwrites existing)
--- - "a": Returns an Appender for adding files to an existing archive
--- @param path string|number File path or file descriptor
--- @param mode string? Mode: "r" (read), "w" (write), or "a" (append). Default is "r".
--- @param options OpenOptions? Compression level and size limits
--- @return any The archive handle (Reader, Writer, or Appender based on mode), or nil on error
--- @return string? Error message if opening failed
local function open(path: string | number, mode?: string, options?: OpenOptions): any, string
  local handle: any
  local err: string
  if options then
    -- Build options table to avoid nominal type conflict with cosmo.zip's OpenOptions
    local opts = {
      level = options.level,
      max_file_size = options.max_file_size,
    }
    handle, err = zip.open(path, mode, opts)
  else
    handle, err = zip.open(path, mode)
  end
  if not handle then
    return nil, err or "failed to open zip archive"
  end
  return handle
end

--- Open a ZIP archive from in-memory data for reading.
--- @param data string The ZIP archive data
--- @param options OpenOptions? Size limits
--- @return Reader? The archive reader, or nil on error
--- @return string? Error message if opening failed
local function from(data: string, options?: OpenOptions): Reader, string
  local handle: any
  local err: string
  if options then
    -- Build options table to avoid nominal type conflict with cosmo.zip's OpenOptions
    local opts = {
      level = options.level,
      max_file_size = options.max_file_size,
    }
    handle, err = zip.from(data, opts)
  else
    handle, err = zip.from(data)
  end
  if not handle then
    return nil, err or "failed to open zip from data"
  end
  return handle as Reader
end

local record ZipModule
  --- Options for opening a ZIP archive.
  type OpenOptions = OpenOptions
  --- Options for adding a file to a ZIP archive.
  type AddOptions = AddOptions
  --- File metadata within a ZIP archive.
  type Stat = Stat
  --- Reader for extracting files from a ZIP archive.
  type Reader = Reader
  --- Writer for creating new ZIP archives.
  type Writer = Writer
  --- Appender for adding files to an existing ZIP archive.
  type Appender = Appender

  open: function(path: string | number, mode?: string, options?: OpenOptions): any, string
  from: function(data: string, options?: OpenOptions): Reader, string
end

local M: ZipModule = {
  open = open,
  from = from,
}

return M
