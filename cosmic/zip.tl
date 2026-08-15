--- ZIP archive reading and writing.
--- One constructor: `zip.open(path, opts?: {mode, level,
--- max_file_size_bytes}) → Archive` — mode "read" (default), "write"
--- (truncate/create), or "append" (add to an existing archive, or
--- create it). `open_string` is its bytes-not-path sibling for
--- in-memory data (always read mode). One Archive answers every
--- operation and returns an error naming the mode when an operation
--- does not belong to it, so callers pick a MODE, not a type.
--- `extract` safely unpacks an archive — an open one, or a path —
--- to a directory (entry names from an archive are
--- attacker-controlled; never write them to disk without extract's
--- zip-slip validation).
local zip = require("cosmo.zip")
local fs = require("cosmic.fs")

--- Options for adding a file to a ZIP archive: method ("store" or
--- "deflate"), mtime, and mode. The generated cosmo.zip.AddOptions record.
local type AddOptions = zip.AddOptions

--- File metadata within a ZIP archive: size, compressed_size, crc32,
--- mtime, method (0=stored, 8=deflated), and mode.
local type EntryStat = zip.Stat

--- Directory entry returned by Archive:list(): name, size, and mode. The
--- generated cosmo.zip.Entry record.
local type Entry = zip.Entry

--- How an archive is opened.
local enum Mode
  "read"
  "write"
  "append"
end

--- Options for open()/open_string().
local record OpenOptions
  --- "read" (default), "write" (truncate or create), or "append"
  --- (add to an existing archive, creating it if absent).
  mode: Mode
  --- Compression level 0-9, for write/append.
  level: integer
  --- Refuse any member whose declared uncompressed size exceeds this
  --- many bytes.
  max_file_size_bytes: integer
end

--- Options for extract().
local record ExtractOptions
  --- Refuse any entry whose declared uncompressed size exceeds this many
  --- bytes (checked before anything is read or written).
  max_file_size_bytes: integer
end

--- An open archive, in one of three modes. Read operations (list,
--- stat, read) answer only in "read" mode; add answers in "write" and
--- "append"; remove in "append" alone. An operation outside the
--- archive's mode fails with an error naming the mode, so the type
--- carries every method and the MODE — not the type — says which
--- apply.
local record Archive
  --- The mode this archive was opened in.
  mode: Mode
  --- List every entry (read mode).
  list: function(self: Archive): {Entry} | nil, string
  --- Metadata for one entry (read mode).
  stat: function(self: Archive, name: string): EntryStat | nil, string
  --- One entry's content (read mode).
  read: function(self: Archive, name: string): string | nil, string
  --- Add a member (write or append mode).
  add: function(self: Archive, name: string, content: string, opts?: AddOptions): boolean, string
  --- Remove a member (append mode).
  remove: function(self: Archive, name: string): boolean, string
  --- Close the archive (any mode; idempotent: a second close is a
  --- no-op that returns true). In write and append mode close is where
  --- the archive lands on disk -- the central directory and any
  --- pending adds flush here -- so `false, error` means the file is
  --- NOT a valid archive.
  close: function(self: Archive): boolean, string
end

-- The raw binding handles behind an Archive; exactly one is set.
local record RawHandles
  reader: zip.Reader
  writer: zip.Writer
  appender: zip.Appender
end

--- Build the one Archive wrapper over whichever raw handle the mode
--- produced. A wrapper table (not the raw userdata) is what lets one
--- type answer every operation with an honest mode error instead of a
--- nil-method crash from the wrong metatable.
local function make_archive(mode: Mode, raw: RawHandles): Archive
  local closed = false
  local a: Archive = {mode = mode}

  -- `wants` carries its article ("a read", "an append"): the message
  -- must read as a sentence for every mode word.
  local function mode_err(op: string, wants: string): string
    return "zip: " .. op .. " requires " .. wants ..
    " archive (opened mode=" .. mode .. ")"
  end

  function a:list(): {Entry} | nil, string
    if closed then return nil, "zip: archive is closed" end
    if not raw.reader then return nil, mode_err("list", "a read") end
    return raw.reader:list()
  end

  function a:stat(name: string): EntryStat | nil, string
    if closed then return nil, "zip: archive is closed" end
    if not raw.reader then return nil, mode_err("stat", "a read") end
    return raw.reader:stat(name)
  end

  function a:read(name: string): string | nil, string
    if closed then return nil, "zip: archive is closed" end
    if not raw.reader then return nil, mode_err("read", "a read") end
    return raw.reader:read(name)
  end

  function a:add(name: string, content: string, opts?: AddOptions): boolean, string
    if closed then return false, "zip: archive is closed" end
    if raw.writer then
      local ok, err = raw.writer:add(name, content, opts)
      if not ok then return false, err or "add failed" end
      return true
    end
    if raw.appender then
      local ok, err = raw.appender:add(name, content, opts)
      if not ok then return false, err or "add failed" end
      return true
    end
    return false, mode_err("add", "a write or append")
  end

  function a:remove(name: string): boolean, string
    if closed then return false, "zip: archive is closed" end
    if not raw.appender then return false, mode_err("remove", "an append") end
    local ok, err = raw.appender:remove(name)
    if not ok then return false, err or "remove failed" end
    return true
  end

  -- The cosmos pin now declares Writer/Appender close returns
  -- (cosmopolitan#254), but this file is in the type GENERATOR's import
  -- closure (gentype reads the cosmos zip through cosmic.zip), so on a
  -- cold start it must also compile under the bin/cosmic.pin release's
  -- EMBEDDED types, which predate the annotation and say void. The cast
  -- reads the returns either way; drop it once the bootstrap pin
  -- advances past this change.
  local type fallible_close = function(any): boolean, string

  function a:close(): boolean, string
    if closed then return true end
    closed = true
    if raw.reader then raw.reader:close() end
    if raw.writer then
      -- cast: bootstrap pin's embedded types under-declare close returns
      local ok, err = (raw.writer.close as fallible_close)(raw.writer)
      if not ok then return false, "zip: close failed: " .. (err or "unknown error") end
    end
    if raw.appender then
      -- cast: bootstrap pin's embedded types under-declare close returns
      local ok, err = (raw.appender.close as fallible_close)(raw.appender)
      if not ok then return false, "zip: close failed: " .. (err or "unknown error") end
    end
    return true
  end

  return setmetatable(a, {
      -- a <close> scope cannot propagate a value, so the error is
      -- necessarily dropped here; callers who care call close() directly
      __close = function(self: Archive) local _ok, _err = self:close() end
    }) as Archive -- cast: table seeded as record
end

--- The binding's options record for a public OpenOptions.
local function to_raw_options(opts?: OpenOptions): zip.OpenOptions
  if not opts then return nil end
  if opts.level == nil and opts.max_file_size_bytes == nil then return nil end
  return {level = opts.level, max_file_size = opts.max_file_size_bytes}
end

--- Open a ZIP archive. Mode "read" (default) reads an existing
--- archive; "write" creates (truncating any existing file); "append"
--- adds to an existing archive, creating it when absent. A file
--- descriptor is accepted for read and write; append requires a path
--- (the binding reopens the file).
--- @param path string|integer File path (or fd, for read/write)
--- @param opts OpenOptions? mode, level, max_file_size_bytes
--- @return Archive | nil The archive, or nil on error
--- @return string? Error message if opening failed
local function open(path: string | integer, opts?: OpenOptions): Archive | nil, string
  local mode: Mode = (opts and opts.mode) or "read"
  local raw_opts = to_raw_options(opts)
  if mode == "read" then
    local handle: any
    local err: string
    if raw_opts then
      handle, err = zip.open(path, "r", raw_opts)
    else
      handle, err = zip.open(path, "r")
    end
    if not handle then
      return nil, err or "failed to open zip archive"
    end
    return make_archive("read", {reader = handle as zip.Reader}) -- cast: from any
  end
  if mode == "write" then
    local handle, err = zip.create(path, raw_opts)
    if not handle then
      return nil, err or "failed to create zip archive"
    end
    return make_archive("write", {writer = handle})
  end
  -- append: the binding takes a path only.
  if not (path is string) then
    return nil, "zip: append requires a path, not a file descriptor"
  end
  local handle, err = zip.append(path, raw_opts)
  if not handle then
    return nil, err or "failed to open zip archive for appending"
  end
  return make_archive("append", {appender = handle})
end

--- Open a ZIP archive from in-memory data, always in read mode
--- (`_string` is the bytes-not-path sibling spelling; `_bytes` is
--- reserved for counts).
--- @param data string The ZIP archive data
--- @param opts OpenOptions? max_file_size_bytes (mode is always read)
--- @return Archive | nil The archive, or nil on error
--- @return string? Error message if opening failed
local function open_string(data: string, opts?: OpenOptions): Archive | nil, string
  if opts and opts.mode and opts.mode ~= "read" then
    return nil, "zip: open_string is read-only (mode=" .. opts.mode .. ")"
  end
  local raw_opts = to_raw_options(opts)
  local handle: zip.Reader
  local err: string
  if raw_opts then
    handle, err = zip.from(data, raw_opts)
  else
    handle, err = zip.from(data)
  end
  if not handle then
    return nil, err or "failed to open zip from data"
  end
  return make_archive("read", {reader = handle})
end

-- THE guard is fs.is_unsafe_entry_name — one definition for zip, tar and
-- embed, which protect the same operation and do not get to disagree.
local unsafe_entry = fs.is_unsafe_entry_name

local function extract_entries(archive: Archive, destdir: string,
    opts?: ExtractOptions): boolean, string
  local entries_maybe, lerr = archive:list()
  if not entries_maybe then
    return false, lerr or "zip: list failed"
  end
  -- A fresh local keeps the narrowed type past the ensure_dir closure
  -- below (narrowing does not survive a nested function definition).
  local entries: {Entry} = entries_maybe

  -- Validate everything up front: a single bad entry rejects the whole
  -- archive before any bytes hit the filesystem. list() entries carry
  -- size and mode, so no per-entry stat is needed.
  for _, entry in ipairs(entries) do
    if unsafe_entry(entry.name) then
      return false, "unsafe path in archive: " .. entry.name
    end
    if opts and opts.max_file_size_bytes and entry.size > opts.max_file_size_bytes then
      return false, "entry exceeds max_file_size_bytes: " .. entry.name
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
      local content, read_err = archive:read(name)
      if not content then
        return false, "cannot read '" .. name .. "' from archive: " .. (read_err or "unknown error")
      end
      local filepath = fs.join(destdir, name)
      ok, err = ensure_dir(fs.dirname(filepath))
      if not ok then return false, err end

      -- Sane-masked mode from the archive: permission bits only.
      local file_mode = tonumber("644", 8)
      local mode = entry.mode & tonumber("777", 8)
      if mode > 0 then
        file_mode = mode
      end

      local write_ok, write_err = fs.write(filepath, content, {mode = file_mode})
      if not write_ok then
        return false, "cannot write '" .. filepath .. "': " .. (write_err or "unknown error")
      end
    end
  end
  return true
end

--- Extract every entry of a read archive into destdir, refusing
--- archives that attempt zip-slip. All entry names (and sizes, when
--- opts.max_file_size_bytes is set) are validated before anything is
--- written, so a malicious archive fails without leaving partial
--- output. File modes are taken from the archive masked to 0777
--- (setuid/setgid/sticky bits are stripped); entries without a mode
--- default to 0644. Existing files are overwritten. An archive passed
--- as a handle is left open; a path is opened read-mode and closed.
--- @param archive Archive|string An open read archive, or a path to one
--- @param destdir string Directory to extract into (created if needed)
--- @param opts ExtractOptions? Per-entry size limit
--- @return boolean true when every entry was written
--- @return string? Error message if validation or writing failed
local function extract(archive: Archive | string, destdir: string,
    opts?: ExtractOptions): boolean, string
  if archive is string then
    local a, oerr = open(archive)
    if not a then
      return false, "zip: cannot open " .. archive .. ": " ..
      (oerr or "unknown error")
    end
    local ok, err = extract_entries(a, destdir, opts)
    -- read-mode close releases resources only; nothing to surface
    local _cok, _cerr = a:close()
    return ok, err
  else
    return extract_entries(archive, destdir, opts)
  end
end

local record ZipModule
  --- Options for open()/open_string(): mode, level, max_file_size_bytes.
  type OpenOptions = OpenOptions
  --- How an archive is opened: "read", "write", or "append".
  type Mode = Mode
  --- Options for adding a file to a ZIP archive.
  type AddOptions = AddOptions
  --- Options for extract().
  type ExtractOptions = ExtractOptions
  --- File metadata within a ZIP archive (was `Stat`, #996).
  type EntryStat = EntryStat
  --- Directory entry returned by Archive:list().
  type Entry = Entry
  --- The one archive handle; its mode says which operations answer.
  type Archive = Archive

  open: function(path: string | integer, opts?: OpenOptions): Archive | nil, string
  open_string: function(data: string, opts?: OpenOptions): Archive | nil, string
  extract: function(archive: Archive | string, destdir: string, opts?: ExtractOptions): boolean, string
end

local M: ZipModule = {
  open = open,
  open_string = open_string,
  extract = extract,
}

return M
