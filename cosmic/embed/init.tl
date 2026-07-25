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
--- Embedding a main.lua overrides the default entry point. A custom
--- entry is stored byte-identical at /zip/main.user.lua behind a
--- generated /zip/main.lua that puts the zip root on the module path
--- and installs the cosmic runtime .tl searcher (#687/#690): modules
--- embedded beside main.lua resolve with the same guarantees as
--- `cosmic script.tl`, no loader boilerplate. An unmodified
--- dispatcher main.lua (extract/re-embed roundtrip) and an
--- already-wrapped entry pass through unchanged.
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

local czip = require("cosmic.zip")
local fs = require("cosmic.fs")
local unix = require("cosmo.unix")
local errstr = require("cosmic.errno").str
local Stat = require("cosmic.fs.types").Stat
local floor = require("cosmic.embed.floor")
local extract_mod = require("cosmic.embed.extract")

--- Options for run().
local record Options
  --- Strip the base executable down to the floor (cosmic.embed.floor)
  --- before adding the caller's files. Everything the base carried
  --- that is not on the floor is a tool for BUILDING programs, not a
  --- runtime an artifact needs.
  strip: boolean
  --- Module namespaces these files supply themselves (`cosmic`, ...).
  --- A supplied namespace leaves the strip floor, so the artifact ships
  --- one definition of it instead of the project's winning on
  --- `package.path` while the base's rides along underneath.
  provides: {string: boolean}
  --- Fixed modification time for every added entry, so two builds of
  --- one tree agree byte-for-byte.
  mtime: integer
end

--- Result returned from embed and extract operations. The extraction
--- half declares the same shape; this is the one the module surface
--- publishes.
local type EmbedResult = extract_mod.EmbedResult

--- Options for adding files to a ZIP archive.
local record AddOptions
  mode: integer
  method: string
  mtime: integer
end

--- Appender interface for modifying a ZIP archive in-place.
local record ZipAppender
  add: function(self: ZipAppender, name: string, content: string, options?: AddOptions): boolean, string
  remove: function(self: ZipAppender, name: string): boolean, string
  close: function(self: ZipAppender)
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

--- Directory handle whose `read` exposes the dirent d_type (unix.DT_DIR /
--- DT_REG / DT_LNK / ... / DT_UNKNOWN) where the filesystem supports it,
--- letting collect_dir skip a stat(2) call for entries d_type already
--- identifies as neither a directory nor a regular file.
local record EmbedDirHandle
  read: function(self): string, integer
  close: function(self)
end

-- One directory entry plus its d_type, sorted together for deterministic
-- embed order without needing two parallel arrays.
local record DirEntry
  name: string
  kind: integer
end

-- Internal record for files staged for embedding.
local record FileToEmbed
  path: string
  content: string
  stored_name: string
  mode: integer
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
    local handle = raw as EmbedDirHandle -- cast: userdata boundary
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
          local sst = st as Stat -- cast: mixed-representation Stat
          if sst:is_dir() then
            local walk_err = do_walk(full_path, rel)
            if walk_err then return walk_err end
          elseif unix.S_ISREG(sst:mode()) then
            -- Only embed regular files; skip symlinks (S_ISLNK) entirely.
            local content, read_err = fs.read(full_path)
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

--- Sentinel first line of the generated entry wrapper; recognizing it
--- keeps wrapping idempotent across extract/embed roundtrips.
local WRAP_SENTINEL < const > = "-- cosmic-embed searcher wrapper (#687); app entry: /zip/main.user.lua"

--- The generated /zip/main.lua: put the app's zip root on the module
--- path (embedded mod.lua / mod.tl beside main.lua resolve; #690),
--- install the cosmic searcher, then run the byte-identical entry.
local WRAP_MAIN < const > = WRAP_SENTINEL .. "\n" .. [[
package.path = "/zip/?.lua;/zip/?/init.lua;" .. package.path
require("cosmic._cli.searcher").install()
local chunk = assert(loadfile("/zip/main.user.lua"))
return chunk(...)
]]

--- Every entry name the base executable carries.
--- @param exe_path string The base executable
--- @return {string} Entry names, or empty when it carries no zip
local function base_entries(exe_path: string): {string}
  local names: {string} = {}
  local rd = czip.reader(exe_path)
  if rd == nil then
    return names
  end
  local reader = rd as czip.Reader -- cast: record union after guard
  for _, e in ipairs(reader:list()) do
    names[#names + 1] = e.name
  end
  reader:close()
  return names
end

--- Wrap a user-supplied main.lua behind the searcher-installing entry.
--- Mutates files_to_embed in place: the user entry moves to
--- main.user.lua and the generated wrapper becomes main.lua. Skipped
--- when the embedded main.lua is the source executable's own (an
--- unmodified dispatcher roundtrip) or already the wrapper.
--- @param files_to_embed {FileToEmbed} Collected entries (mutated)
--- @param exe_path string Source executable (for the roundtrip check)
--- @return string|nil Error message, or nil
local function wrap_user_main(files_to_embed: {FileToEmbed}, exe_path: string): string | nil
  local main_entry: FileToEmbed = nil
  local has_user_slot = false
  for _, f in ipairs(files_to_embed) do
    if f.stored_name == "main.lua" then
      main_entry = f
    elseif f.stored_name == "main.user.lua" then
      has_user_slot = true
    end
  end
  if not main_entry then
    return nil
  end
  if main_entry.content:sub(1, #WRAP_SENTINEL) == WRAP_SENTINEL then
    return nil -- already wrapped (extract/embed roundtrip)
  end
  local exe_reader = czip.reader(exe_path)
  if exe_reader ~= nil then
    local rd = exe_reader as czip.Reader -- cast: record union after guard
    local exe_main = rd:read("main.lua")
    rd:close()
    if exe_main == main_entry.content then
      return nil -- unmodified dispatcher entry: keep the roundtrip exact
    end
  end
  if has_user_slot then
    return "error: main.user.lua is reserved by the embed entry wrapper (#687); rename that file"
  end
  main_entry.stored_name = "main.user.lua"
  files_to_embed[#files_to_embed + 1] = {
    path = "main.lua",
    content = WRAP_MAIN,
    stored_name = "main.lua",
    mode = tonumber("644", 8),
  }
  return nil
end

--- Embed files and directories into a copy of the cosmic executable.
--- Creates a new executable with the given paths appended to the zip archive.
--- Paths can be files or directories. Directories are walked recursively and
--- their contents are stored relative to the directory root. Files are stored
--- with their given path (leading / stripped).
--- @param paths {string} List of file or directory paths to embed
--- @param output string Output path for the new executable (defaults to "cosmic")
--- @param exe_path string Path to the source executable (defaults to arg[-1])
--- @param opts Options Stripping and reproducibility (both off by default)
--- @return EmbedResult Result with ok status, message, and file count
local function run(paths: {string}, output?: string, exe_path?: string,
    opts?: Options): EmbedResult
  output = output or "cosmic"
  exe_path = exe_path or arg[-1]
  opts = opts or {}

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
      for _, f in ipairs(dir_files as {FileToEmbed}) do -- cast: record union after guard
        files_to_embed[#files_to_embed + 1] = f
      end
    else
      local content, open_err = fs.read(p)
      if not content then
        return {ok = false, message = "error: cannot open file '" .. p .. "': " .. (open_err or "unknown error"), file_count = 0}
      end

      local stored_name = p:gsub("^/+", "")

      -- Get file mode
      local st = fs.stat(p)
      local file_mode = tonumber("644", 8) -- default
      if st then
        file_mode = (st as Stat):mode() & tonumber("777", 8) -- cast: mixed-rep Stat
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

  local wrap_err = wrap_user_main(files_to_embed, exe_path)
  if wrap_err then
    return {ok = false, message = wrap_err, file_count = 0}
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

  local exe_data = fs.read(exe_path)
  if not exe_data then
    fs.unlink(tmp_path)
    return {ok = false, message = "error: cannot read executable '" .. exe_path .. "'", file_count = 0}
  end

  local barf_ok = fs.write(tmp_path, exe_data)
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
  local appender = appender_result as ZipAppender -- cast: from any

  -- Strip first, so an entry the caller supplies is never removed after
  -- being added. The floor is positive: everything the base carried
  -- that is not on it goes, including entries this build has never
  -- heard of.
  if opts.strip then
    for _, name in ipairs(base_entries(exe_path)) do
      -- A trailing slash makes remove() a PREFIX removal, so removing
      -- the bare `.lua/` marker takes `.lua/cosmic/**` — the floor —
      -- with it. Directory markers are zero bytes and are therefore
      -- never removed; the entries beneath them are removed by name.
      if name:sub(-1) ~= "/" and not floor.in_floor(name, opts.provides) then
        appender:remove(name)
      end
    end
  end

  -- Remove existing entries that conflict, then add new ones.
  -- Store .lua uncompressed; deflate everything else. The produced
  -- executable loads its embedded Lua at boot, so a deflated .lua costs an
  -- inflate() on every launch (the per-boot cost backlog 024 removed from
  -- cosmic's own payload). Bulk assets, which the entry point does not
  -- necessarily read at startup, stay compressed to hold the size down.
  for _, file_info in ipairs(files_to_embed) do
    appender:remove(file_info.stored_name)
    local is_lua = file_info.stored_name:sub(-4) == ".lua"
    local add: AddOptions = {
      mode = file_info.mode,
      method = is_lua and "store" or "deflate",
      mtime = opts.mtime,
    }
    local add_ok, add_err = appender:add(file_info.stored_name, file_info.content, add)
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

local record EmbedModule
  EPOCH: integer
  FLOOR: {string}
  run: function(paths: {string}, output?: string, exe_path?: string, opts?: Options): EmbedResult
  extract: function(output_dir: string, exe_path?: string): EmbedResult
  unsafe_entry: function(name: string): boolean
end

local M: EmbedModule = {
  EPOCH = floor.epoch(),
  FLOOR = floor.FLOOR,
  run = run,
  extract = extract_mod.extract,
  unsafe_entry = extract_mod.unsafe_entry,
}

return M
