--- Extracting an executable's zip contents, and the zip-slip guard
--- that makes it safe.
---
--- Split out of cosmic.embed for the 500-line cap: extraction is the
--- inverse of embedding and shares only the result record with it.

local czip = require("cosmic.zip")
local fs = require("cosmic.fs")

--- Result returned from embed and extract operations.
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end

--- Directory entry returned by ZipReader:list().
local record ZipEntry
  name: string
  size: integer
  mode: integer
end

--- Reader interface for reading files from a ZIP archive.
local record ZipReader
  list: function(self: ZipReader): {ZipEntry}
  read: function(self: ZipReader, name: string): string | nil, string | nil
  close: function(self: ZipReader)
end

--- Whether an archive entry name is unsafe to extract; the predicate
--- is fs.unsafe_entry_name, one guard for zip, tar and embed.
--- @param name string Archive entry name
--- @return boolean true if the entry is unsafe to extract
local unsafe_entry = fs.unsafe_entry_name

--- Extract the zip contents of a cosmic executable to a directory.
--- Creates the output directory if needed. Existing files are overwritten.
--- @param output_dir string Directory to extract into
--- @param exe_path string Path to the executable to extract (defaults to arg[-1])
--- @return EmbedResult Result with ok status, message, and file count
local function extract(output_dir: string, exe_path?: string): EmbedResult
  exe_path = exe_path or arg[-1]

  if not exe_path then
    return {ok = false, message = "error: could not determine executable path", file_count = 0}
  end

  local exe_data = fs.read(exe_path)
  if not exe_data then
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  local reader_maybe = czip.open_bytes(exe_data)
  if not reader_maybe then
    return {ok = false, message = "error: no zip archive found in '" .. exe_path .. "'", file_count = 0}
  end
  local reader = reader_maybe as ZipReader -- cast: record union after guard

  local entries = reader:list()
  local count = 0
  -- Archive entries are frequently many files under the same directory
  -- (e.g. a whole embedded tree); memoize which output directories have
  -- already been created so each one gets exactly one make_dirs(2) walk
  -- instead of one per file.
  local made_dirs: {string: boolean} = {}

  for _, entry in ipairs(entries) do
    local name = entry.name
    -- Guard against zip-slip: an entry with an absolute path or a ".."
    -- component could otherwise be written outside output_dir.
    if unsafe_entry(name) then
      reader:close()
      return {ok = false, message = "error: unsafe path in archive: " .. name, file_count = count}
    end
    -- Skip directory entries (trailing /)
    if name:sub(-1) == "/" then
      local dir_path = fs.join(output_dir, name)
      if not made_dirs[dir_path] then
        fs.make_dirs(dir_path)
        made_dirs[dir_path] = true
      end
    else
      local content, read_err = reader:read(name)
      if not content then
        reader:close()
        return {ok = false, message = "error: cannot read '" .. name .. "' from archive: " .. (read_err or "unknown error"), file_count = count}
      end

      local filepath = fs.join(output_dir, name)
      local dir = fs.dirname(filepath)
      if not made_dirs[dir] then
        fs.make_dirs(dir)
        made_dirs[dir] = true
      end

      -- Sane-masked mode from the archive entry: permission bits only.
      local file_mode = tonumber("644", 8)
      local mode = entry.mode & tonumber("777", 8)
      if mode > 0 then
        file_mode = mode
      end

      local write_ok = fs.write(filepath, content, file_mode)
      if not write_ok then
        reader:close()
        return {ok = false, message = "error: cannot write '" .. filepath .. "'", file_count = count}
      end
      count = count + 1
    end
  end

  reader:close()

  return {
    ok = true,
    message = "extracted " .. count .. " file(s) to " .. output_dir,
    file_count = count,
  }
end

local record ExtractModule
  type EmbedResult = EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
  unsafe_entry: function(name: string): boolean
end

local M: ExtractModule = {
  extract = extract,
  unsafe_entry = unsafe_entry,
}

return M
