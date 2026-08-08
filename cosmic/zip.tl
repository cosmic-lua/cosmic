--- ZIP archive reading and writing utilities.
--- Wraps cosmo.zip with a convenient Teal-typed interface for creating,
--- reading, and modifying ZIP archives. Use `reader`/`writer`/`appender`
--- to open by path, `from` for in-memory data, and `extract` to safely
--- unpack a reader to a directory (entry names from an archive are
--- attacker-controlled; never write them to disk without `extract`'s
--- zip-slip validation).
local zip = require("cosmo.zip")
local fs = require("cosmic.fs")

--- Options for opening a ZIP archive: compression level 0-9 (used when
--- writing/appending) and max_file_size limit. The generated
--- cosmo.zip.OpenOptions record.
local type OpenOptions = zip.OpenOptions

--- Options for adding a file to a ZIP archive: method ("store" or
--- "deflate"), mtime, and mode. The generated cosmo.zip.AddOptions record.
local type AddOptions = zip.AddOptions

--- File metadata within a ZIP archive: size, compressed_size, crc32,
--- mtime, method (0=stored, 8=deflated), and mode. The generated
--- cosmo.zip.Stat record.
local type Stat = zip.Stat

--- Directory entry returned by Reader:list(): name, size, and mode. The
--- generated cosmo.zip.Entry record.
local type Entry = zip.Entry

--- Reader for extracting files from a ZIP archive (the generated
--- cosmo.zip.Reader class): list(), stat(name), read(name), close().
--- Entry names come raw from the central directory: an archive built by
--- another tool can contain absolute or "../" names. Validate before
--- using a name as a filesystem path, or use extract().
--- (api-review-8: the public type name is Archive.)
local type Archive = zip.Reader

--- Builder for creating new ZIP archives (the generated cosmo.zip.Writer
--- class): add(name, content, opts?), close().
--- (api-review-8: the public type name is Builder.)
local type Builder = zip.Writer

--- Appender for adding files to an existing ZIP archive (the generated
--- cosmo.zip.Appender class): add(name, content, opts?), remove(name),
--- close().
local type Appender = zip.Appender

--- Options for extract().
local record ExtractOptions
  --- Refuse any entry whose declared uncompressed size exceeds this many
  --- bytes (checked before anything is read or written).
  max_file_size: integer
end

--- Open a ZIP archive for reading (api-review-8: was `reader` — `open`
--- is the constructor that acquires a closeable resource, D20).
--- @param path string|integer File path or file descriptor
--- @param opts OpenOptions? Size limits
--- @return Archive | nil The archive, or nil on error
--- @return string? Error message if opening failed
local function open(path: string | integer, opts?: OpenOptions): Archive | nil, string
  local handle: any
  local err: string
  if opts then
    handle, err = zip.open(path, "r", opts)
  else
    handle, err = zip.open(path, "r")
  end
  if not handle then
    return nil, err or "failed to open zip archive"
  end
  return handle as Archive -- cast: from any
end

--- Create a new ZIP archive for writing (api-review-8: was `writer`).
--- Any existing file is truncated.
--- @param path string|integer File path or file descriptor
--- @param opts OpenOptions? Compression level and size limits
--- @return Builder | nil The archive builder, or nil on error
--- @return string? Error message if opening failed
local function create(path: string | integer, opts?: OpenOptions): Builder | nil, string
  local handle: Builder
  local err: string
  if opts then
    handle, err = zip.create(path, opts)
  else
    handle, err = zip.create(path)
  end
  if not handle then
    return nil, err or "failed to create zip archive"
  end
  return handle
end

--- Open a ZIP archive for appending (api-review-8: was `appender`),
--- creating it if it does not exist. Unlike open/create, a file
--- descriptor is not accepted; the archive must be given as a path.
--- @param path string File path
--- @param opts OpenOptions? Compression level and size limits
--- @return Appender | nil The archive appender, or nil on error
--- @return string? Error message if opening failed
local function append(path: string, opts?: OpenOptions): Appender | nil, string
  local handle: Appender
  local err: string
  if opts then
    handle, err = zip.append(path, opts)
  else
    handle, err = zip.append(path)
  end
  if not handle then
    return nil, err or "failed to open zip archive for appending"
  end
  return handle
end

--- Open a ZIP archive from in-memory data for reading (api-review-8:
--- was `from`; pairs with open as its bytes-not-path form).
--- @param data string The ZIP archive data
--- @param opts OpenOptions? Size limits
--- @return Archive? The archive, or nil on error
--- @return string? Error message if opening failed
local function open_bytes(data: string, opts?: OpenOptions): Archive | nil, string
  local handle: Archive
  local err: string
  if opts then
    handle, err = zip.from(data, opts)
  else
    handle, err = zip.from(data)
  end
  if not handle then
    return nil, err or "failed to open zip from data"
  end
  return handle
end

--- Report whether a zip entry name would escape the extraction root
--- (zip-slip). Rejects absolute paths — POSIX (`/x`), Windows/UNC
--- (`\x`, `\\server\share`), and drive-letter (`C:\x`, `C:/x`, `C:x`) —
--- and any `..` traversal component. Both `/` and `\` are treated as
--- separators, since cosmic executables also run on Windows where a
--- `..\evil` entry would otherwise slip past a POSIX-only guard.
---
--- Control characters too, which is not about escaping the root: a name
--- travels onward into line-oriented records, and `_make/fetch.tl`'s
--- unpack manifest is one line per product. A member called `a\nb.txt`
--- extracts fine, records as two names neither of which exists, and
--- makes every later fetch decide the pin needs repair — forever,
--- silently. `cosmic.tar` and `cosmic.embed` refuse the same class at
--- the same point; the three guards protect one operation, so they do
--- not get to disagree.
-- THE guard is fs.unsafe_entry_name — one definition for zip, tar and
-- embed, which protect the same operation and do not get to disagree.
local unsafe_entry = fs.unsafe_entry_name

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
local function extract(r: Archive, destdir: string, opts?: ExtractOptions): boolean, string
  local entries = r:list()

  -- Validate everything up front: a single bad entry rejects the whole
  -- archive before any bytes hit the filesystem. list() entries carry
  -- size and mode, so no per-entry stat is needed.
  for _, entry in ipairs(entries) do
    if unsafe_entry(entry.name) then
      return false, "unsafe path in archive: " .. entry.name
    end
    if opts and opts.max_file_size and entry.size > opts.max_file_size then
      return false, "entry exceeds max_file_size: " .. entry.name
    end
  end

  local made_dirs: {string: boolean} = {}
  local function ensure_dir(dir: string): boolean, string
    if made_dirs[dir] then return true end
    local ok, err = fs.make_dirs(dir)
    if not ok then
      return false, "cannot create directory '" .. dir .. "': " .. (err or "unknown error")
    end
    made_dirs[dir] = true
    return true
  end

  local ok, err = ensure_dir(destdir)
  if not ok then return false, err end

  for _, entry in ipairs(entries) do
    local name = entry.name
    if name:sub(-1) == "/" then
      ok, err = ensure_dir(fs.join(destdir, name))
      if not ok then return false, err end
    else
      local filepath = fs.join(destdir, name)
      ok, err = ensure_dir(fs.dirname(filepath))
      if not ok then return false, err end

      -- Sane-masked mode from the archive: permission bits only.
      local file_mode = tonumber("644", 8)
      local mode = entry.mode & tonumber("777", 8)
      if mode > 0 then
        file_mode = mode
      end

      -- save() decompresses and CRC-checks in C and writes straight to
      -- the file — the entry's bytes never exist as a Lua string
      -- (whilp/cosmopolitan#238). Dot-form through a cast rather than
      -- r:save(...): cosmic.zip sits in the type generator's import
      -- closure (gentype reads the runtime archive through it), so this
      -- file must compile against the DRIVING binary's bundled types,
      -- which always predate a zip surface it is adding.
      -- cast: zip surface newer than the bootstrap types
      local save_fn = (r as {string: any})["save"] as
      function(Archive, string, string): (boolean, string)
      local save_ok, save_err = save_fn(r, name, filepath)
      if not save_ok then
        return false, "cannot extract '" .. name .. "' to '" .. filepath ..
        "': " .. (save_err or "unknown error")
      end
      -- save creates with 0644; force the entry's mode, as the write
      -- path always did for overwrites.
      local _ok, _err = fs.chmod(filepath, file_mode)
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
  --- Directory entry returned by Archive:list().
  type Entry = Entry
  --- Archive open for reading.
  type Archive = Archive
  --- Builder for creating new ZIP archives.
  type Builder = Builder
  --- Appender for adding files to an existing ZIP archive.
  type Appender = Appender

  open: function(path: string | integer, opts?: OpenOptions): Archive | nil, string
  create: function(path: string | integer, opts?: OpenOptions): Builder | nil, string
  append: function(path: string, opts?: OpenOptions): Appender | nil, string
  open_bytes: function(data: string, opts?: OpenOptions): Archive | nil, string
  extract: function(archive: Archive, destdir: string, opts?: ExtractOptions): boolean, string
end

local M: ZipModule = {
  open = open,
  create = create,
  append = append,
  open_bytes = open_bytes,
  extract = extract,
}

return M
