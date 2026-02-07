--- Embed files and directories into a cosmic executable.
---
--- cosmic is an executable zip — a native binary with a zip archive appended.
--- Files in the archive are accessible at /zip/ paths from Lua code. The
--- entry point is /zip/main.lua, configured by /zip/.args.
---
--- Create a custom executable:
---
---   mkdir myapp
---   echo 'print("hello world")' > myapp/main.lua
---   cosmic --embed myapp/ --output hello
---   ./hello
---
--- Directory contents are stored relative to the directory root, so
--- myapp/main.lua becomes /zip/main.lua in the resulting executable.
--- Embedding a main.lua overrides the default entry point.
---
--- The resulting executable keeps cosmic's bundled libraries, so embedded
--- code can require("cosmic.fetch"), require("lsqlite3"), etc.
---
--- Extract an executable's zip contents for inspection or modification:
---
---   cosmic --extract myapp/
---   # edit myapp/main.lua
---   cosmic --embed myapp/ --output myapp
---
--- This roundtrips: extract produces exactly the files that embed consumes.

local cosmo = require("cosmo")
local zip = require("cosmo.zip")
local pathlib = require("cosmo.path")
local unix = require("cosmo.unix")

--- Result returned from embed and extract operations.
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end

--- Writer interface for creating a ZIP archive.
local record ZipWriter
  add: function(self: ZipWriter, name: string, content: string): boolean, string
  close: function(self: ZipWriter)
end

--- Reader interface for reading files from a ZIP archive.
local record ZipReader
  list: function(self: ZipReader): {string}
  read: function(self: ZipReader, name: string): string | nil, string | nil
  close: function(self: ZipReader)
end

-- Internal record for files staged for embedding.
local record FileToEmbed
  path: string
  content: string
  stored_name: string
end

-- Unix interfaces used for directory walking.
local record WalkStat
  mode: function(self: WalkStat): integer
end
local record WalkDirHandle
  read: function(self: WalkDirHandle): string
  close: function(self: WalkDirHandle)
end

-- Read a 32-bit little-endian integer from data at 1-indexed position.
local function read_le32(data: string, pos: integer): integer
  return data:byte(pos)
       + data:byte(pos + 1) * 256
       + data:byte(pos + 2) * 65536
       + data:byte(pos + 3) * 16777216
end

-- Encode a 32-bit little-endian integer as a 4-byte string.
local function write_le32(n: integer): string
  return string.char(n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff)
end

-- Find the byte offset where the ZIP archive starts within a binary.
-- Returns the 1-indexed position, or nil if no ZIP is found.
local function find_zip_offset(data: string): integer
  local eocd_sig = "PK\x05\x06"
  local search_start = math.max(1, #data - 65557)
  local eocd_pos: integer = nil

  for i = #data - 3, search_start, -1 do
    if data:sub(i, i + 3) == eocd_sig then
      eocd_pos = i
      break
    end
  end

  if not eocd_pos then return nil end

  local num_entries = data:byte(eocd_pos + 10) + data:byte(eocd_pos + 11) * 256
  if num_entries == 0 then return eocd_pos end

  local cd_offset = read_le32(data, eocd_pos + 16)

  local cd_pos = cd_offset + 1
  local cd_sig = "PK\x01\x02"
  local min_local_offset = cd_offset

  while cd_pos <= #data - 45 and data:sub(cd_pos, cd_pos + 3) == cd_sig do
    local local_off = read_le32(data, cd_pos + 42)
    if local_off < min_local_offset then
      min_local_offset = local_off
    end
    local fn_len = data:byte(cd_pos + 28) + data:byte(cd_pos + 29) * 256
    local extra_len = data:byte(cd_pos + 30) + data:byte(cd_pos + 31) * 256
    local comment_len = data:byte(cd_pos + 32) + data:byte(cd_pos + 33) * 256
    cd_pos = cd_pos + 46 + fn_len + extra_len + comment_len
  end

  return min_local_offset + 1
end

-- Adjust all offsets in ZIP archive data by a fixed amount.
-- Used when prepending a binary prefix to a zip file.
local function adjust_zip_offsets(zip_data: string, adj: integer): string
  local eocd_sig = "PK\x05\x06"
  local search_start = math.max(1, #zip_data - 65557)
  local eocd_pos: integer = nil
  for i = #zip_data - 3, search_start, -1 do
    if zip_data:sub(i, i + 3) == eocd_sig then
      eocd_pos = i
      break
    end
  end
  if not eocd_pos then return zip_data end

  -- Collect patches: {1-indexed position, new 4-byte value}
  local patches: {{integer, string}} = {}

  -- Patch EOCD's CD offset (bytes 16-19 from EOCD start)
  local cd_offset = read_le32(zip_data, eocd_pos + 16)
  patches[#patches + 1] = {eocd_pos + 16, write_le32(cd_offset + adj)}

  -- Patch each CD entry's local header offset (bytes 42-45 from entry start)
  local cd_pos = cd_offset + 1
  local cd_sig = "PK\x01\x02"
  while cd_pos <= #zip_data - 45 and zip_data:sub(cd_pos, cd_pos + 3) == cd_sig do
    local local_off = read_le32(zip_data, cd_pos + 42)
    patches[#patches + 1] = {cd_pos + 42, write_le32(local_off + adj)}

    local fn_len = zip_data:byte(cd_pos + 28) + zip_data:byte(cd_pos + 29) * 256
    local extra_len = zip_data:byte(cd_pos + 30) + zip_data:byte(cd_pos + 31) * 256
    local comment_len = zip_data:byte(cd_pos + 32) + zip_data:byte(cd_pos + 33) * 256
    cd_pos = cd_pos + 46 + fn_len + extra_len + comment_len
  end

  -- Apply patches sorted by position, rebuilding the string
  table.sort(patches, function(a: {integer, string}, b: {integer, string}): boolean
    return a[1] < b[1]
  end)

  local parts: {string} = {}
  local last_end = 1
  for _, patch in ipairs(patches) do
    local pos = patch[1]
    local new_bytes = patch[2]
    parts[#parts + 1] = zip_data:sub(last_end, pos - 1)
    parts[#parts + 1] = new_bytes
    last_end = pos + #new_bytes
  end
  parts[#parts + 1] = zip_data:sub(last_end)

  return table.concat(parts)
end

--- Recursively collect all files from a directory.
--- Files are stored with paths relative to the directory root.
--- @param dir string The directory to collect from
--- @return {FileToEmbed} Collected files, or nil on error
--- @return string Error message, or nil on success
local function collect_dir(dir: string): {FileToEmbed}, string
  local collected: {FileToEmbed} = {}

  local function do_walk(base_dir: string, rel_prefix: string): string
    local handle = unix.opendir(base_dir) as WalkDirHandle
    if not handle then
      return "cannot open directory '" .. base_dir .. "'"
    end

    local entries: {string} = {}
    while true do
      local entry = handle:read()
      if not entry then break end
      if entry ~= "." and entry ~= ".." then
        entries[#entries + 1] = entry
      end
    end
    handle:close()
    table.sort(entries)

    for _, entry in ipairs(entries) do
      local full_path = pathlib.join(base_dir, entry)
      local st = unix.stat(full_path) as WalkStat
      if st then
        if unix.S_ISDIR(st:mode()) then
          local rel = rel_prefix == "" and entry or (rel_prefix .. "/" .. entry)
          local walk_err = do_walk(full_path, rel)
          if walk_err then return walk_err end
        else
          local stored_name = rel_prefix == "" and entry or (rel_prefix .. "/" .. entry)
          local f, open_err = io.open(full_path, "rb")
          if not f then
            return "cannot open file '" .. full_path .. "': " .. (open_err or "unknown error")
          end
          local content = f:read("*a")
          f:close()
          collected[#collected + 1] = {
            path = full_path,
            content = content,
            stored_name = stored_name,
          }
        end
      end
    end
    return nil
  end

  local err = do_walk(dir, "")
  if err then return nil, err end
  return collected, nil
end

--- Embed files and directories into a copy of the cosmic executable.
--- Creates a new executable with the given paths appended to the zip archive.
--- Paths can be files or directories. Directories are walked recursively and
--- their contents are stored relative to the directory root. Files are stored
--- with their given path (leading / stripped).
--- @param paths {string} List of file or directory paths to embed
--- @param output string Output path for the new executable (defaults to "cosmic")
--- @param exe_path string Path to the source executable (defaults to arg[-1])
--- @return EmbedResult Result with ok status, message, and file count
local function run(paths: {string}, output?: string, exe_path?: string): EmbedResult
  output = output or "cosmic"
  exe_path = exe_path or arg[-1]

  if not exe_path then
    return {ok = false, message = "error: could not determine executable path", file_count = 0}
  end

  if #paths == 0 then
    return {ok = false, message = "error: no files specified", file_count = 0}
  end

  -- Collect all files to embed, resolving directories recursively
  local files_to_embed: {FileToEmbed} = {}

  for _, p in ipairs(paths) do
    if pathlib.isdir(p) then
      local dir_files, err = collect_dir(p)
      if not dir_files then
        return {ok = false, message = "error: " .. (err or "unknown error"), file_count = 0}
      end
      for _, f in ipairs(dir_files) do
        files_to_embed[#files_to_embed + 1] = f
      end
    else
      local f, open_err = io.open(p, "rb")
      if not f then
        return {ok = false, message = "error: cannot open file '" .. p .. "': " .. (open_err or "unknown error"), file_count = 0}
      end
      local content = f:read("*a")
      f:close()

      local stored_name = p:gsub("^/+", "")

      files_to_embed[#files_to_embed + 1] = {
        path = p,
        content = content,
        stored_name = stored_name,
      }
    end
  end

  if #files_to_embed == 0 then
    return {ok = false, message = "error: no files found to embed", file_count = 0}
  end

  -- Read source executable
  local exe_data = cosmo.Slurp(exe_path)
  if not exe_data then
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  -- Read existing zip contents
  local existing: {string:string} = {}
  local reader_maybe = zip.from(exe_data)
  if reader_maybe then
    local reader = reader_maybe as ZipReader
    for _, name in ipairs(reader:list()) do
      -- Skip directory entries (trailing /)
      if name:sub(-1) ~= "/" then
        local content = reader:read(name)
        if content then
          existing[name] = content
        end
      end
    end
    reader:close()
  end

  -- Merge: new files override existing entries
  for _, file_info in ipairs(files_to_embed) do
    existing[file_info.stored_name] = file_info.content
  end

  -- Find binary/zip boundary
  local zip_offset = find_zip_offset(exe_data)
  local prefix: string
  if zip_offset then
    prefix = exe_data:sub(1, zip_offset - 1)
  else
    prefix = exe_data
  end

  -- Create a fresh zip in a temp file with all merged entries
  local tmpfile = os.tmpname()
  local zip_result: any
  local zip_err: any
  zip_result, zip_err = zip.open(tmpfile, "w")
  if not zip_result then
    os.remove(tmpfile)
    return {ok = false, message = "error: failed to create zip: " .. tostring(zip_err or "unknown error"), file_count = 0}
  end
  local writer = zip_result as ZipWriter

  local names: {string} = {}
  for name in pairs(existing) do
    names[#names + 1] = name
  end
  table.sort(names)

  for _, name in ipairs(names) do
    local add_ok, add_err = writer:add(name, existing[name])
    if not add_ok then
      writer:close()
      os.remove(tmpfile)
      return {ok = false, message = "error: failed to add '" .. name .. "' to zip: " .. tostring(add_err or "unknown error"), file_count = 0}
    end
  end

  writer:close()

  -- Read the temp zip data and adjust offsets for the binary prefix
  local zip_data = cosmo.Slurp(tmpfile)
  os.remove(tmpfile)

  if not zip_data then
    return {ok = false, message = "error: failed to read temp zip", file_count = 0}
  end

  local adjusted = adjust_zip_offsets(zip_data, #prefix)

  -- Write binary prefix + adjusted zip as the final executable
  if not cosmo.Barf(output, prefix .. adjusted, tonumber("755", 8)) then
    return {ok = false, message = "error: cannot write to '" .. output .. "'", file_count = 0}
  end

  return {
    ok = true,
    message = "embedded " .. #files_to_embed .. " file(s) into " .. output,
    file_count = #files_to_embed,
  }
end

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

  local exe_data = cosmo.Slurp(exe_path)
  if not exe_data then
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  local reader_maybe = zip.from(exe_data)
  if not reader_maybe then
    return {ok = false, message = "error: no zip archive found in '" .. exe_path .. "'", file_count = 0}
  end
  local reader = reader_maybe as ZipReader

  local entries = reader:list()
  local count = 0

  for _, name in ipairs(entries) do
    -- Skip directory entries (trailing /)
    if name:sub(-1) == "/" then
      unix.makedirs(pathlib.join(output_dir, name))
    else
      local content, read_err = reader:read(name)
      if not content then
        reader:close()
        return {ok = false, message = "error: cannot read '" .. name .. "' from archive: " .. (read_err or "unknown error"), file_count = count}
      end

      local filepath = pathlib.join(output_dir, name)
      local dir = pathlib.dirname(filepath)
      unix.makedirs(dir)

      if not cosmo.Barf(filepath, content) then
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

local record EmbedModule
  run: function(paths: {string}, output?: string, exe_path?: string): EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
end

local M: EmbedModule = {
  run = run,
  extract = extract,
}

return M
