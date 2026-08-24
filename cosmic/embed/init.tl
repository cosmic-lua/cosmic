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
--- and installs the cosmic runtime .tl searcher : modules
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
local errstr = require("cosmic.errno").format
local fs_types = require("cosmic.fs.types")
local floor = require("cosmic.embed.floor")
local extract_mod = require("cosmic.embed.extract")

--- Options for write().
local record Options
  --- Output path for the new executable (default "cosmic").
  output: string
  --- Path to the source executable to copy (default arg[-1], the
  --- running binary).
  exe_path: string
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

local type EmbedDirHandle = fs_types.DirHandle

-- One directory entry plus its d_type, sorted together for deterministic
-- embed order without needing two parallel arrays.
local record DirEntry
  name: string
  kind: integer
end

-- Internal record for files staged for embedding. Exactly one of
-- content (bytes already in hand, e.g. the generated wrapper entry) or
-- source (a path the appender streams in C via add_file, so the file
-- never exists as a Lua string) is set.
local record FileToEmbed
  path: string
  content: string
  source: string
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
        local st = fs.stat_link(full_path)
        if st then
          local sst = st
          if sst:is_dir() then
            local walk_err = do_walk(full_path, rel)
            if walk_err then return walk_err end
          elseif unix.S_ISREG(sst:mode()) then
            -- Only embed regular files; skip symlinks (S_ISLNK) entirely.
            -- Contents are NOT read here: the add loop streams them in C
            -- (add_file), so a tree never lives in memory as Lua strings.
            -- Extract permission bits (lower 9 bits)
            local file_mode = sst:mode() & tonumber("777", 8)
            collected[#collected + 1] = {
              path = full_path,
              source = full_path,
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
--- path (embedded mod.lua / mod.tl beside main.lua resolve;), install
--- the /zip and .tl searchers, then run the byte-identical entry.
local WRAP_MAIN < const > = WRAP_SENTINEL .. "\n" .. [[
package.path = "/zip/?.lua;/zip/?/init.lua;" .. package.path
local searcher = require("cosmic.searcher")
-- install() is the whole contract a project providing its own cosmic/**
-- has to meet; the /zip searcher is this base's, when it is there.
if searcher.install_zip then searcher.install_zip() end
searcher.install()
local chunk = assert(loadfile("/zip/main.user.lua"))
return chunk(...)
]]

--- Every entry name the base executable carries.
--- @param exe_path string The base executable
--- @return {string} Entry names, or empty when it carries no zip
local function base_entries(exe_path: string): {string}
  local names: {string} = {}
  local rd = czip.open(exe_path)
  if rd == nil then
    return names
  end
  local reader = rd
  local entries = reader:list()
  if not entries then
    -- A read archive that opened but will not list carries nothing
    -- usable; the contract here is "empty when it carries no zip".
    local _ok, _err = reader:close()
    return names
  end
  for _, e in ipairs(entries) do
    names[#names + 1] = e.name
  end
  local _ok, _err = reader:close()
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
  -- The one entry whose bytes the wrapper decision needs in Lua: staged
  -- entries carry a source path (streamed in C at add time), so read
  -- this single file here rather than materializing the whole tree.
  local main_content = main_entry.content
  if main_content == nil then
    local data, read_err = fs.read(main_entry.source)
    if not data then
      return "error: cannot open file '" .. main_entry.source .. "': " ..
      (read_err or "unknown error")
    end
    main_content = data
  end
  if main_content:sub(1, #WRAP_SENTINEL) == WRAP_SENTINEL then
    return nil -- already wrapped (extract/embed roundtrip)
  end
  local exe_reader = czip.open(exe_path)
  if exe_reader ~= nil then
    local rd = exe_reader
    local exe_main = rd:read("main.lua")
    local _ok, _err = rd:close()
    if exe_main == main_content then
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
--- @param opts Options? output, exe_path, stripping, reproducibility
--- @return integer | nil The embedded file count, or nil on failure
--- @return string? Error message on failure
local function write(paths: {string}, opts?: Options): integer | nil, string
  opts = opts or {}
  local output = opts.output or "cosmic"
  local exe_path = opts.exe_path or arg[-1]

  if not exe_path then
    return nil, "error: could not determine executable path"
  end

  if #paths == 0 then
    return nil, "error: no files specified"
  end

  -- Collect all files to embed, resolving directories recursively
  local files_to_embed: {FileToEmbed} = {}

  for _, p in ipairs(paths) do
    if fs.is_dir(p) then
      local dir_files, err = collect_dir(p)
      if not dir_files then
        return nil, "error: " .. (err or "unknown error")
      end
      for _, f in ipairs(dir_files) do
        files_to_embed[#files_to_embed + 1] = f
      end
    else
      -- Stat up front so a missing or unreadable file fails here, with
      -- the same error surface fs.read would give; the bytes
      -- themselves are streamed in C by the add loop (add_file).
      local st, stat_err = fs.stat(p)
      if not st then
        return nil, "error: cannot open file '" .. p .. "': " .. (stat_err or "unknown error")
      end

      local stored_name = p:gsub("^/+", "")
      local file_mode = st:mode() & tonumber("777", 8)

      files_to_embed[#files_to_embed + 1] = {
        path = p,
        source = p,
        stored_name = stored_name,
        mode = file_mode,
      }
    end
  end

  if #files_to_embed == 0 then
    return nil, "error: no files found to embed"
  end

  local wrap_err = wrap_user_main(files_to_embed, exe_path)
  if wrap_err then
    return nil, wrap_err
  end

  -- Build in a temp file, then atomically rename into place.
  -- Writing directly to the output path would corrupt any running process
  -- that has the file mmapped (the APE loader uses MAP_PRIVATE file-backed
  -- mappings for code pages; overwriting the file invalidates those pages).
  local tmp_fd, tmp_path = unix.mkstemp(output .. ".XXXXXX")
  if not tmp_fd then
    return nil, "error: cannot create temp file near '" .. output .. "'"
  end
  unix.close(tmp_fd)

  local copy_ok, copy_err = fs.copy(exe_path, tmp_path)
  if not copy_ok then
    local _ok, _err = fs.remove(tmp_path)
    return nil, "error: cannot copy '" .. exe_path .. "' to '" .. tmp_path .. "': " .. (copy_err or "unknown error")
  end
  unix.chmod(tmp_path, tonumber("755", 8))

  -- Open the copy in append mode to modify its zip in-place
  -- (cosmic.zip's own Archive)
  local appender_maybe, appender_err = czip.open(tmp_path, {mode = "append"})
  if not appender_maybe then
    local _ok, _err = fs.remove(tmp_path)
    return nil, "error: failed to open zip for appending: " .. tostring(appender_err or "unknown error")
  end
  local appender = appender_maybe

  -- Strip first, so an entry the caller supplies is never removed after
  -- being added. The floor is positive: everything the base carried
  -- that is not on it goes, including entries this build has never
  -- heard of.
  if opts.strip then
    for _, name in ipairs(base_entries(exe_path)) do
      -- A trailing slash makes remove() a PREFIX removal, so removing
      -- a bare directory marker would take everything beneath it —
      -- including the floor, which is `cosmic/**`. Directory
      -- markers are zero bytes and are therefore never removed; the
      -- entries beneath them are removed by name.
      if name:sub(-1) ~= "/" and not floor.in_floor(name, opts.provides) then
        local _ok, _err = appender:remove(name)
      end
    end
  end

  -- Remove existing entries that conflict, then add new ones.
  -- Store .lua uncompressed; deflate everything else. The produced
  -- executable loads its embedded Lua at boot, so a deflated .lua costs an
  -- inflate() on every launch. Bulk assets, which the entry point does not
  -- necessarily read at startup, stay compressed to hold the size down.
  for _, file_info in ipairs(files_to_embed) do
    -- The error is deliberately discarded: "entry not found" is the
    -- NORMAL result for a name not already in the base, and the
    -- binding reports it through the same channel as a real failure.
    -- Propagating it would fail every fresh embed with a misleading
    -- "entry not found" error. Distinguishing the two needs an
    -- exists() on the appender that the binding does not offer; until
    -- it does, a genuinely failed removal would surface as the
    -- duplicate entry it creates.
    local _ok, _err = appender:remove(file_info.stored_name)
    local is_lua = file_info.stored_name:sub(-4) == ".lua"
    local add: czip.AddOptions = {
      mode = file_info.mode,
      method = is_lua and "store" or "deflate",
      -- Default the epoch rather than letting the binding fall back to
      -- `time(NULL)`. Without a fixed default, two runs of the same
      -- inputs seconds apart would produce different binaries --
      -- breaking content-addressed caching and "same inputs, same
      -- artifact" for every caller outside `--make`. A caller wanting
      -- live mtimes now has to ask for them.
      mtime = opts.mtime or floor.epoch(),
    }
    -- Staged sources stream through the appender in C (add_file); only
    -- generated entries (the wrapper main.lua) carry in-memory content.
    -- mode and mtime are always passed, so add_file's source-derived
    -- defaults never apply and rebuilds stay byte-identical.
    local add_ok: boolean
    local add_err: string
    if file_info.source ~= nil then
      add_ok, add_err = appender:add_file(file_info.stored_name, file_info.source, add)
    else
      add_ok, add_err = appender:add(file_info.stored_name, file_info.content, add)
    end
    if not add_ok then
      -- the add error is what the caller needs; a close error here is
      -- secondary and the temp file is removed either way
      local _cok, _cerr = appender:close()
      local _ok, _err = fs.remove(tmp_path)
      return nil, "error: failed to add '" .. file_info.stored_name .. "' to zip: " .. tostring(add_err or "unknown error")
    end
  end

  -- Close is where every staged entry actually flushes to disk: a
  -- failure here (disk full, write error) means tmp_path is NOT a
  -- valid archive, so it must never be renamed over the output.
  local close_ok, close_err = appender:close()
  if not close_ok then
    local _ok, _err = fs.remove(tmp_path)
    return nil, "error: failed to finalize zip: " .. tostring(close_err or "unknown error")
  end

  -- Atomically replace the output file. rename() on the same filesystem is
  -- atomic — any running process with the old inode mmapped keeps its pages.
  local rename_ok, rename_err = fs.move(tmp_path, output)
  if not rename_ok then
    local _ok, _err = fs.remove(tmp_path)
    return nil, "error: cannot rename temp file to '" .. output .. "': " .. tostring(rename_err or "unknown")
  end

  return #files_to_embed
end

local record EmbedModule
  --- Exported so callers can name options and results; type aliases,
  --- not runtime values.
  type Options = Options
  type ExtractOptions = extract_mod.ExtractOptions

  EPOCH_SECONDS: integer
  write: function(paths: {string}, opts?: Options): integer | nil, string
  extract: function(output_dir: string, opts?: extract_mod.ExtractOptions): integer | nil, string
end

local M: EmbedModule = {
  EPOCH_SECONDS = floor.epoch(),
  write = write,
  extract = extract_mod.extract,
}

return M
