--- Embed/extract scenarios: exercises cosmic.embed's directory walk
--- (collect_dir) and zip-to-disk unpack (extract) against a real tree of
--- directories and files, using the cosmic binary under test as the
--- source executable.

local embed = require("cosmic.embed")
local fs = require("cosmic.fs")
local czip = require("cosmic.zip")
local pt = require("_perf.perf_types")

-- Deliberately dir-heavy: embed.embed()'s dominant, roughly-fixed cost is
-- copying the whole source executable (megabytes) into the output file,
-- which would swamp small per-entry syscall differences measured over
-- just a handful of directories. A large DIRS count makes collect_dir's
-- d_type-vs-stat(2) savings big enough to show over that fixed floor;
-- FILES_PER_DIR > 1 gives extract() multiple files per directory, so a
-- memoized makedirs(2) has something to dedupe against.
local DIRS = 120
local FILES_PER_DIR = 5

-- Mirrors cosmic.embed's EmbedResult shape (not exported by that module).
local record EmbedResult
  ok: boolean
  message: string
  file_count: integer
end

local tmpdir: string
local srcdir: string
local packed_exe: string
local extract_dir: string

--- Base directory for scratch files.
--- @return string An existing writable directory
local function tmp_base(): string
  return os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
end

--- Locate the cosmic binary to benchmark.
--- PERF_BIN wins; then TEST_BIN/cosmic (set by the test harness); then
--- the interpreter running this script (arg[-1], per cosmic.child docs).
--- @return string Path to the binary, or nil if none was found
local function find_bin(): string
  local envbin = os.getenv("PERF_BIN")
  if envbin and #envbin > 0 then
    return envbin
  end
  local test_bin = os.getenv("TEST_BIN")
  if test_bin and #test_bin > 0 then
    local p = fs.join(test_bin, "cosmic")
    if fs.is_file(p) then
      return p
    end
  end
  return rawget(arg, -1) as string -- cast: from any
end

--- Create DIRS directories of FILES_PER_DIR small files under srcdir.
--- @return string Error message, or nil on success
local function init_tree(): string
  for d = 1, DIRS do
    local sub = fs.join(srcdir, "dir-" .. d)
    local ok, merr = fs.make_dirs(sub)
    if not ok then
      return "makedirs: " .. tostring(merr)
    end
    for f = 1, FILES_PER_DIR do
      local wok, werr = fs.write(
        fs.join(sub, "file-" .. f .. ".txt"), "data-" .. d .. "-" .. f .. "\n")
      if not wok then
        return "barf: " .. tostring(werr)
      end
    end
  end
  return nil
end

--- Count non-directory entries in a packed executable's zip archive.
--- extract()'s file_count covers the whole archive (the base binary's own
--- embedded stdlib plus whatever was just embedded), not just the tree
--- this bench module added, so the check needs the real total.
--- @param exe_path string Path to the packed executable
--- @return integer Number of non-directory zip entries, or nil on error
--- @return string Error message, or nil on success
local function count_zip_files(exe_path: string): integer, string
  local data, rerr = fs.read(exe_path)
  if not data then
    return nil, "slurp: " .. tostring(rerr)
  end
  local reader, zerr = czip.open_bytes(data)
  if not reader then
    return nil, "zip.open_bytes: " .. tostring(zerr)
  end
  local rr = reader
  local count = 0
  for _, entry in ipairs(rr:list()) do
    if entry.name:sub(-1) ~= "/" then
      count = count + 1
    end
  end
  rr:close()
  return count
end

local function scenarios(): {pt.Scenario}, string
  local bin = find_bin()
  if bin == nil or #bin == 0 then
    return nil, "cannot locate cosmic binary (set PERF_BIN)"
  end

  local dir, derr = fs.temp_dir(fs.join(tmp_base(), "perf-embed-XXXXXX"))
  if dir == nil then
    return nil, "mkdtemp: " .. tostring(derr)
  end
  tmpdir = dir
  srcdir = fs.join(tmpdir, "src")
  local mok, merr = fs.make_dirs(srcdir)
  if not mok then
    return nil, "makedirs: " .. tostring(merr)
  end
  local ierr = init_tree()
  if ierr then
    return nil, ierr
  end

  packed_exe = fs.join(tmpdir, "packed")
  extract_dir = fs.join(tmpdir, "extracted")
  local total_files = DIRS * FILES_PER_DIR

  return {
    {
      -- Many directories, few files each: isolates collect_dir's d_type
      -- fast path (skip stat(2) on entries the dirent already identifies
      -- as a directory or as neither dir nor regular file) from the
      -- per-file slurp/embed cost.
      name = "embed_run_tree",
      fn = function(_: any): any
        return embed.embed({srcdir}, {output = packed_exe, exe_path = bin})
      end,
      check = function(_: any, res: any): boolean, string
        local r = res as EmbedResult -- cast: from any
        if not r.ok then
          return false, "embed.embed failed"
        end
        if r.file_count ~= total_files then
          return false, string.format("embedded %d files, want %d",
            r.file_count, total_files)
        end
        return true
      end,
    },
    {
      -- Extracting this archive writes FILES_PER_DIR files per directory,
      -- isolating extract()'s per-file makedirs(dir) call — repeated
      -- FILES_PER_DIR times for the same already-created directory —
      -- from the archive read/write cost.
      name = "embed_extract_tree",
      setup = function(): any, string
        local result = embed.embed({srcdir}, {output = packed_exe, exe_path = bin})
        if not result.ok then
          return nil, "embed.embed: " .. tostring(result.message)
        end
        local expected, cerr = count_zip_files(packed_exe)
        if not expected then
          return nil, cerr
        end
        return expected
      end,
      fn = function(_: any): any
        return embed.extract(extract_dir, packed_exe)
      end,
      check = function(ctx: any, res: any): boolean, string
        local r = res as EmbedResult -- cast: from any
        local expected = ctx as integer -- cast: from any
        if not r.ok then
          return false, "embed.extract failed"
        end
        if r.file_count ~= expected then
          return false, string.format("extracted %d files, want %d",
            r.file_count, expected)
        end
        return true
      end,
    },
  }
end

local function cleanup()
  if tmpdir then
    local _ok, _err = fs.remove_all(tmpdir)
    tmpdir = nil
  end
end

local M: pt.BenchModule = {
  scenarios = scenarios,
  cleanup = cleanup,
}

return M
