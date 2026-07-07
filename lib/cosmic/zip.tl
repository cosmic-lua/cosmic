--- ZIP archive reading and writing utilities.
--- Wraps cosmo.zip with a convenient Teal-typed interface for creating,
--- reading, and modifying ZIP archives. Use `reader`/`writer`/`appender`
--- to open by path, `from` for in-memory data, and `extract` to safely
--- unpack a reader to a directory (entry names from an archive are
--- attacker-controlled; never write them to disk without `extract`'s
--- zip-slip validation).
local zip = require("cosmo.zip")
local fs = require("cosmic.fs")

--- Options for opening a ZIP archive.
local record OpenOptions
  --- Compression level 0-9 (0=none, 9=maximum). Used when writing/appending.
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
  --- Entry names come raw from the central directory: an archive built by
  --- another tool can contain absolute or "../" names. Validate before
  --- using a name as a filesystem path, or use extract().
  --- @return {string} List of file paths in the archive
  list: function(self: Reader): {string}

  --- Gets metadata for a specific file in the archive.
  --- @param name string The file path within the archive
  --- @return Stat? File metadata, or nil if file not found
  stat: function(self: Reader, name: string): Stat | nil

  --- Reads the contents of a file from the archive.
  --- @param name string The file path within the archive
  --- @return string? The file contents, or nil on error
  --- @return string? Error message if reading failed
  read: function(self: Reader, name: string): string | nil, string

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
  add: function(self: Writer, name: string, content: string, options?: AddOptions): boolean | nil, string

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
  add: function(self: Appender, name: string, content: string, options?: AddOptions): boolean | nil, string

  --- Removes a file from the ZIP archive by name.
  --- @param name string The file path within the archive to remove
  --- @return boolean? true on success, nil on failure
  --- @return string? Error message if removal failed
  remove: function(self: Appender, name: string): boolean | nil, string

  --- Closes the ZIP archive and writes the updated central directory.
  close: function(self: Appender)
end

--- Options for extract().
local record ExtractOptions
  --- Refuse any entry whose declared uncompressed size exceeds this many
  --- bytes (checked before anything is read or written).
  max_file_size: number
end

-- Build a plain options table so the nominal cosmo.zip.OpenOptions record
-- doesn't conflict with this module's OpenOptions.
local function raw_options(options: OpenOptions): {string: number}
  return {
    level = options.level,
    max_file_size = options.max_file_size,
  }
end

--- Open a ZIP archive for reading.
--- @param path string|number File path or file descriptor
--- @param options OpenOptions? Size limits
--- @return Reader | nil The archive reader, or nil on error
--- @return string? Error message if opening failed
local function reader(path: string | number, options?: OpenOptions): Reader | nil, string
  local handle: any
  local err: string
  if options then
    handle, err = zip.open(path, "r", raw_options(options) as zip.OpenOptions)
  else
    handle, err = zip.open(path, "r")
  end
  if not handle then
    return nil, err or "failed to open zip archive"
  end
  return handle as Reader
end

--- Create a new ZIP archive for writing. Any existing file is truncated.
--- @param path string|number File path or file descriptor
--- @param options OpenOptions? Compression level and size limits
--- @return Writer | nil The archive writer, or nil on error
--- @return string? Error message if opening failed
local function writer(path: string | number, options?: OpenOptions): Writer | nil, string
  local handle: any
  local err: string
  if options then
    handle, err = zip.create(path, raw_options(options) as zip.OpenOptions)
  else
    handle, err = zip.create(path)
  end
  if not handle then
    return nil, err or "failed to create zip archive"
  end
  return handle as Writer
end

--- Open a ZIP archive for appending, creating it if it does not exist.
--- Unlike reader/writer, a file descriptor is not accepted; the archive
--- must be given as a path.
--- @param path string File path
--- @param options OpenOptions? Compression level and size limits
--- @return Appender | nil The archive appender, or nil on error
--- @return string? Error message if opening failed
local function appender(path: string, options?: OpenOptions): Appender | nil, string
  local handle: any
  local err: string
  if options then
    handle, err = zip.append(path, raw_options(options) as zip.OpenOptions)
  else
    handle, err = zip.append(path)
  end
  if not handle then
    return nil, err or "failed to open zip archive for appending"
  end
  return handle as Appender
end

--- Open a ZIP archive from in-memory data for reading.
--- @param data string The ZIP archive data
--- @param options OpenOptions? Size limits
--- @return Reader? The archive reader, or nil on error
--- @return string? Error message if opening failed
local function from(data: string, options?: OpenOptions): Reader | nil, string
  local handle: any
  local err: string
  if options then
    handle, err = zip.from(data, raw_options(options) as zip.OpenOptions)
  else
    handle, err = zip.from(data)
  end
  if not handle then
    return nil, err or "failed to open zip from data"
  end
  return handle as Reader
end

--- Report whether a zip entry name would escape the extraction root
--- (zip-slip). Rejects absolute paths — POSIX (`/x`), Windows/UNC
--- (`\x`, `\\server\share`), and drive-letter (`C:\x`, `C:/x`, `C:x`) —
--- and any `..` traversal component. Both `/` and `\` are treated as
--- separators, since cosmic executables also run on Windows where a
--- `..\evil` entry would otherwise slip past a POSIX-only guard.
local function unsafe_entry(name: string): boolean
  if name == "" then return true end
  -- Absolute roots escape the destination directory.
  if name:sub(1, 1) == "/" or name:sub(1, 1) == "\\" then return true end
  if name:match("^%a:") then return true end
  -- Normalize backslashes so ".." traversal is caught on either
  -- separator ("..\evil" like "../evil").
  local slashed = name:gsub("\\", "/")
  if slashed == ".." or slashed:match("^%.%./") or slashed:match("/%.%./")
  or slashed:match("/%.%.$") then
    return true
  end
  return false
end

--- Extract every entry of an open reader into destdir, refusing archives
--- that attempt zip-slip. All entry names (and sizes, when
--- opts.max_file_size is set) are validated before anything is written, so
--- a malicious archive fails without leaving partial output. File modes
--- are taken from the archive masked to 0777 (setuid/setgid/sticky bits
--- are stripped); entries without a mode default to 0644. Existing files
--- are overwritten. The reader is left open.
--- @param r Reader An open archive reader (from reader() or from())
--- @param destdir string Directory to extract into (created if needed)
--- @param opts ExtractOptions? Per-entry size limit
--- @return boolean true when every entry was written
--- @return string? Error message if validation or writing failed
local function extract(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
  local entries = r:list()

  -- Validate everything up front: a single bad entry rejects the whole
  -- archive before any bytes hit the filesystem.
  for _, name in ipairs(entries) do
    if unsafe_entry(name) then
      return false, "unsafe path in archive: " .. name
    end
    if opts and opts.max_file_size then
      local st = r:stat(name)
      if st and (st as Stat).size > opts.max_file_size then
        return false, "entry exceeds max_file_size: " .. name
      end
    end
  end

  local made_dirs: {string: boolean} = {}
  local function ensure_dir(dir: string): boolean, string
    if made_dirs[dir] then return true end
    local ok, err = fs.makedirs(dir)
    if not ok then
      return false, "cannot create directory '" .. dir .. "': " .. (err or "unknown error")
    end
    made_dirs[dir] = true
    return true
  end

  local ok, err = ensure_dir(destdir)
  if not ok then return false, err end

  for _, name in ipairs(entries) do
    if name:sub(-1) == "/" then
      ok, err = ensure_dir(fs.join(destdir, name))
      if not ok then return false, err end
    else
      local content, read_err = r:read(name)
      if not content then
        return false, "cannot read '" .. name .. "' from archive: " .. (read_err or "unknown error")
      end
      local filepath = fs.join(destdir, name)
      ok, err = ensure_dir(fs.dirname(filepath))
      if not ok then return false, err end

      -- Sane-masked mode from the archive: permission bits only.
      local file_mode = tonumber("644", 8)
      local st = r:stat(name)
      if st then
        local mode = (st as Stat).mode & tonumber("777", 8)
        if mode > 0 then
          file_mode = mode
        end
      end

      local write_ok, write_err = fs.write(filepath, content, file_mode)
      if not write_ok then
        return false, "cannot write '" .. filepath .. "': " .. (write_err or "unknown error")
      end
      -- barf's mode only applies on create; force it for overwrites.
      fs.chmod(filepath, file_mode)
    end
  end
  return true
end

local record ZipModule
  --- Options for opening a ZIP archive.
  type OpenOptions = OpenOptions
  --- Options for adding a file to a ZIP archive.
  type AddOptions = AddOptions
  --- Options for extract().
  type ExtractOptions = ExtractOptions
  --- File metadata within a ZIP archive.
  type Stat = Stat
  --- Reader for extracting files from a ZIP archive.
  type Reader = Reader
  --- Writer for creating new ZIP archives.
  type Writer = Writer
  --- Appender for adding files to an existing ZIP archive.
  type Appender = Appender

  reader: function(path: string | number, options?: OpenOptions): Reader | nil, string
  writer: function(path: string | number, options?: OpenOptions): Writer | nil, string
  appender: function(path: string, options?: OpenOptions): Appender | nil, string
  from: function(data: string, options?: OpenOptions): Reader | nil, string
  extract: function(r: Reader, destdir: string, opts?: ExtractOptions): boolean, string
end

local M: ZipModule = {
  reader = reader,
  writer = writer,
  appender = appender,
  from = from,
  extract = extract,
}

return M
