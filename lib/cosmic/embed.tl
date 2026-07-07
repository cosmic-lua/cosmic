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

local cio = require("cosmic.io")
local czip = require("cosmic.zip")
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str
local Stat = require("cosmic.fs_types").Stat

--- Result returned from embed and extract operations.
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end

--- Options for adding files to a ZIP archive.
local record AddOptions
  mode: number
  method: string
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
  method: number
end

--- Reader interface for reading files from a ZIP archive.
local record ZipReader
  list: function(self: ZipReader): {string}
  read: function(self: ZipReader, name: string): string | nil, string | nil
  stat: function(self: ZipReader, name: string): ZipStat | nil
  close: function(self: ZipReader)
end

--- Directory handle whose `read` exposes the dirent d_type (unix.DT_DIR /
--- DT_REG / DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it,
--- letting collect_dir skip a stat(2) call for entries d_type already
--- identifies as neither a directory nor a regular file.
local record EmbedDirHandle
  read: function(self): string, number
  close: function(self)
end

-- One directory entry plus its d_type, sorted together for deterministic
-- embed order without needing two parallel arrays.
local record DirEntry
  name: string
  kind: number
end

-- Internal record for files staged for embedding.
local record FileToEmbed
  path: string
  content: string
  stored_name: string
  mode: number
end

--- Recursively collect all files from a directory.
--- Files are stored with paths relative to the directory root.
--- @param dir string The directory to collect from
--- @return {FileToEmbed} Collected files, or nil on error
--- @return string Error message, or nil on success
local function collect_dir(dir: string): {FileToEmbed} | nil, string
  local collected: {FileToEmbed} = {}

  local function do_walk(base_dir: string, rel_prefix: string): string
    local raw, dir_err = unix.opendir(base_dir)
    local handle = raw as EmbedDirHandle
    if not handle then
      return "cannot open directory '" .. base_dir .. "': " .. errstr(dir_err, "opendir")
    end

    local entries: {DirEntry} = {}
    while true do
      local entry, kind = handle:read()
      if not entry then break end
      if entry ~= "." and entry ~= ".." then
        entries[#entries + 1] = {name = entry, kind = kind}
      end
    end
    handle:close()
    table.sort(entries, function(a: DirEntry, b: DirEntry): boolean
        return a.name < b.name
      end)

    for _, de in ipairs(entries) do
      local entry = de.name
      local kind = de.kind
      local full_path = fs.join(base_dir, entry)
      local rel = rel_prefix == "" and entry or (rel_prefix .. "/" .. entry)

      if kind == unix.DT_DIR then
        -- d_type never follows symlinks, so this is a real directory (a
        -- symlinked dir reports DT_LNK), skipping a stat(2) call. This is
        -- also what prevents infinite recursion through symlink cycles.
        local walk_err = do_walk(full_path, rel)
        if walk_err then return walk_err end
      elseif kind ~= unix.DT_REG and kind ~= unix.DT_UNKNOWN then
        -- Definitely neither a directory nor a regular file (symlink,
        -- fifo, socket, ...): skip without paying for a stat(2) call.
      else
        -- kind is DT_REG (need the mode bits) or DT_UNKNOWN (filesystem
        -- doesn't expose d_type; fall back to a real lstat so a symlinked
        -- dir reports S_ISLNK, not S_ISDIR, preserving the same cycle
        -- prevention as the d_type == DT_DIR branch above).
        local st = fs.lstat(full_path)
        if st then
          local sst = st as Stat
          if fs.is_dir(sst:mode()) then
            local walk_err = do_walk(full_path, rel)
            if walk_err then return walk_err end
          elseif unix.S_ISREG(sst:mode()) then
            -- Only embed regular files; skip symlinks (S_ISLNK) entirely.
            local content, read_err = cio.slurp(full_path)
            if not content then
              return "cannot open file '" .. full_path .. "': " .. (read_err or "unknown error")
            end
            -- Extract permission bits (lower 9 bits)
            local file_mode = sst:mode() & tonumber("777", 8)
            collected[#collected + 1] = {
              path = full_path,
              content = content,
              stored_name = rel,
              mode = file_mode,
            }
          end
          -- S_ISLNK entries are silently skipped (no recurse, no embed)
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
    if fs.isdir(p) then
      local dir_files, err = collect_dir(p)
      if not dir_files then
        return {ok = false, message = "error: " .. (err or "unknown error"), file_count = 0}
      end
      for _, f in ipairs(dir_files as {FileToEmbed}) do
        files_to_embed[#files_to_embed + 1] = f
      end
    else
      local content, open_err = cio.slurp(p)
      if not content then
        return {ok = false, message = "error: cannot open file '" .. p .. "': " .. (open_err or "unknown error"), file_count = 0}
      end

      local stored_name = p:gsub("^/+", "")

      -- Get file mode
      local st = fs.stat(p)
      local file_mode = tonumber("644", 8) -- default
      if st then
        file_mode = (st as Stat):mode() & tonumber("777", 8)
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

  -- Build in a temp file, then atomically rename into place.
  -- Writing directly to the output path would corrupt any running process
  -- that has the file mmapped (the APE loader uses MAP_PRIVATE file-backed
  -- mappings for code pages; overwriting the file invalidates those pages).
  local tmp_fd, tmp_path = unix.mkstemp(output .. ".XXXXXX")
  if not tmp_fd then
    return {ok = false, message = "error: cannot create temp file near '" .. output .. "'", file_count = 0}
  end
  unix.close(tmp_fd)

  local exe_data = cio.slurp(exe_path)
  if not exe_data then
    fs.unlink(tmp_path)
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  local barf_ok = cio.barf(tmp_path, exe_data)
  if not barf_ok then
    fs.unlink(tmp_path)
    return {ok = false, message = "error: cannot write to '" .. tmp_path .. "'", file_count = 0}
  end
  unix.chmod(tmp_path, tonumber("755", 8))

  -- Open the copy as an appender to modify its zip in-place
  local appender_result: any
  local appender_err: any
  appender_result, appender_err = czip.appender(tmp_path)
  if not appender_result then
    fs.unlink(tmp_path)
    return {ok = false, message = "error: failed to open zip for appending: " .. tostring(appender_err or "unknown error"), file_count = 0}
  end
  local appender = appender_result as ZipAppender

  -- Remove existing entries that conflict, then add new ones.
  -- Store .lua uncompressed; deflate everything else. The produced
  -- executable loads its embedded Lua at boot, so a deflated .lua costs an
  -- inflate() on every launch (the per-boot cost backlog 024 removed from
  -- cosmic's own payload). Bulk assets, which the entry point does not
  -- necessarily read at startup, stay compressed to hold the size down.
  for _, file_info in ipairs(files_to_embed) do
    appender:remove(file_info.stored_name)
    local is_lua = file_info.stored_name:sub(-4) == ".lua"
    local opts: AddOptions = {mode = file_info.mode, method = is_lua and "store" or "deflate"}
    local add_ok, add_err = appender:add(file_info.stored_name, file_info.content, opts)
    if not add_ok then
      appender:close()
      fs.unlink(tmp_path)
      return {ok = false, message = "error: failed to add '" .. file_info.stored_name .. "' to zip: " .. tostring(add_err or "unknown error"), file_count = 0}
    end
  end

  appender:close()

  -- Atomically replace the output file. rename() on the same filesystem is
  -- atomic — any running process with the old inode mmapped keeps its pages.
  local rename_ok, rename_err = fs.rename(tmp_path, output)
  if not rename_ok then
    fs.unlink(tmp_path)
    return {ok = false, message = "error: cannot rename temp file to '" .. output .. "': " .. tostring(rename_err or "unknown"), file_count = 0}
  end

  return {
    ok = true,
    message = "embedded " .. #files_to_embed .. " file(s) into " .. output,
    file_count = #files_to_embed,
  }
end

--- Report whether a zip entry name would escape the extraction root
--- (zip-slip). Rejects absolute paths — POSIX (`/x`), Windows/UNC
--- (`\x`, `\\server\share`), and drive-letter (`C:\x`, `C:/x`, `C:x`) —
--- and any `..` traversal component. Both `/` and `\` are treated as
--- separators, since cosmic executables also extract on Windows where a
--- `..\evil` entry would otherwise slip past a POSIX-only guard.
--- @param name string Archive entry name
--- @return boolean true if the entry is unsafe to extract
local function unsafe_entry(name: string): boolean
  -- Absolute roots escape output_dir.
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

  local exe_data = cio.slurp(exe_path)
  if not exe_data then
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  local reader_maybe = czip.from(exe_data)
  if not reader_maybe then
    return {ok = false, message = "error: no zip archive found in '" .. exe_path .. "'", file_count = 0}
  end
  local reader = reader_maybe as ZipReader

  local entries = reader:list()
  local count = 0
  -- Archive entries are frequently many files under the same directory
  -- (e.g. a whole embedded tree); memoize which output directories have
  -- already been created so each one gets exactly one makedirs(2) walk
  -- instead of one per file.
  local made_dirs: {string: boolean} = {}

  for _, name in ipairs(entries) do
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
        fs.makedirs(dir_path)
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
        fs.makedirs(dir)
        made_dirs[dir] = true
      end

      -- Get file mode from zip, default to 644
      local file_mode = tonumber("644", 8)
      local zst = reader:stat(name)
      if zst then
        local mode = (zst as ZipStat).mode & tonumber("777", 8)
        if mode > 0 then
          file_mode = mode
        end
      end

      local write_ok = cio.barf(filepath, content, file_mode)
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

local record EmbedModule
  run: function(paths: {string}, output?: string, exe_path?: string): EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
  unsafe_entry: function(name: string): boolean
end

local M: EmbedModule = {
  run = run,
  extract = extract,
  unsafe_entry = unsafe_entry,
}

return M
