--- Embed files and directories into a cosmic executable.
---
--- cosmic is an executable zip — a native binary with a zip archive appended.
--- Files in the archive are accessible at /zip/ paths from Lua code. The
--- entry point is /zip/main.lua, configured by /zip/.args.
---
--- Any file can be embedded (Lua source, data files, binaries, etc.), but
--- the entry point must be a plain Lua file named main.lua. Teal files are
--- not compiled at runtime, so compile them first:
---
---   cosmic --compile myapp.tl > myapp/main.lua
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

--- Options for adding files to a ZIP archive.
local record AddOptions
  mode: number
end

--- Appender interface for modifying a ZIP archive in-place.
local record ZipAppender
  add: function(self: ZipAppender, name: string, content: string, options?: AddOptions): boolean, string
  remove: function(self: ZipAppender, name: string): boolean, string
  close: function(self: ZipAppender)
end

--- Stat record for zip file metadata.
local record ZipStat
  mode: number
end

--- Reader interface for reading files from a ZIP archive.
local record ZipReader
  list: function(self: ZipReader): {string}
  read: function(self: ZipReader, name: string): string | nil, string | nil
  stat: function(self: ZipReader, name: string): ZipStat | nil
  close: function(self: ZipReader)
end

-- Internal record for files staged for embedding.
local record FileToEmbed
  path: string
  content: string
  stored_name: string
  mode: number
end

-- Unix interfaces used for directory walking.
local record WalkStat
  mode: function(self: WalkStat): integer
end
local record WalkDirHandle
  read: function(self: WalkDirHandle): string
  close: function(self: WalkDirHandle)
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
          -- Extract permission bits (lower 9 bits)
          local file_mode = st:mode() & tonumber("777", 8)
          collected[#collected + 1] = {
            path = full_path,
            content = content,
            stored_name = stored_name,
            mode = file_mode,
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

      -- Get file mode
      local st = unix.stat(p)
      local file_mode = tonumber("644", 8) -- default
      if st then
        file_mode = st:mode() & tonumber("777", 8)
      end

      files_to_embed[#files_to_embed + 1] = {
        path = p,
        content = content,
        stored_name = stored_name,
        mode = file_mode,
      }
    end
  end

  if #files_to_embed == 0 then
    return {ok = false, message = "error: no files found to embed", file_count = 0}
  end

  -- Copy source executable to output path
  local exe_data = cosmo.Slurp(exe_path)
  if not exe_data then
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  if not cosmo.Barf(output, exe_data, tonumber("755", 8)) then
    return {ok = false, message = "error: cannot write to '" .. output .. "'", file_count = 0}
  end

  -- Open the copy as an appender to modify its zip in-place
  local appender_result: any
  local appender_err: any
  appender_result, appender_err = zip.open(output, "a")
  if not appender_result then
    os.remove(output)
    return {ok = false, message = "error: failed to open zip for appending: " .. tostring(appender_err or "unknown error"), file_count = 0}
  end
  local appender = appender_result as ZipAppender

  -- Remove existing entries that conflict, then add new ones
  for _, file_info in ipairs(files_to_embed) do
    appender:remove(file_info.stored_name)
    local add_ok, add_err = appender:add(file_info.stored_name, file_info.content, {mode = file_info.mode})
    if not add_ok then
      appender:close()
      os.remove(output)
      return {ok = false, message = "error: failed to add '" .. file_info.stored_name .. "' to zip: " .. tostring(add_err or "unknown error"), file_count = 0}
    end
  end

  appender:close()

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

      -- Get file mode from zip, default to 644
      local file_mode = tonumber("644", 8)
      local st = reader:stat(name)
      if st then
        local mode = (st as ZipStat).mode & tonumber("777", 8)
        if mode > 0 then
          file_mode = mode
        end
      end

      if not cosmo.Barf(filepath, content, file_mode) then
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
