--- Filesystem scenarios: directory walking, whole-file I/O, tree churn.
--- Exercises cosmic.fs and cosmic.fd wrappers over the cosmo unix/path
--- C bindings, against a real temp directory tree.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local pt = require("_perf.perf_types")

local DIRS = 10
local FILES_PER_DIR = 20
local BLOB = string.rep("cosmic performance harness line\n", 2048)

local tmpdir: string

--- Base directory for scratch files.
--- @return string An existing writable directory
local function tmp_base(): string
  return os.getenv("TEST_TMPDIR") or os.getenv("TMPDIR") or "/tmp"
end

--- Create the scratch tree: DIRS directories of FILES_PER_DIR small files.
--- @return string Error message, or nil on success
local function init_tree(): string
  local dir, derr = fs.temp_dir(fs.join(tmp_base(), "perf-fs-XXXXXX"))
  if dir == nil then
    return "mkdtemp: " .. tostring(derr)
  end
  tmpdir = dir
  for d = 1, DIRS do
    local sub = fs.join(dir, "dir-" .. d)
    local ok, merr = fs.make_dirs(sub)
    if not ok then
      return "makedirs: " .. tostring(merr)
    end
    for f = 1, FILES_PER_DIR do
      local wok, werr = fs.write(fs.join(sub, "file-" .. f .. ".txt"),
        "data-" .. d .. "-" .. f .. "\n")
      if not wok then
        return "barf: " .. tostring(werr)
      end
    end
  end
  return nil
end

local function scenarios(): {pt.Scenario}, string
  local ierr = init_tree()
  if ierr then
    return nil, ierr
  end
  local blob_path = fs.join(tmpdir, "blob.bin")
  -- Entries visited under tmpdir: each subdirectory plus its files. The
  -- blob and churn paths live at the top level and are counted separately.
  local tree_entries = DIRS + DIRS * FILES_PER_DIR

  return {
    {
      name = "fs_walk_tree",
      fn = function(_: any): any
        local count = 0
        local _ok, _err = fs.visit(tmpdir, function(e: fs.Entry, _ctx: any)
            -- Only count the seeded tree so fs_barf_slurp's blob (created
            -- by a sibling scenario) does not change the expected total.
            if e.path:find("dir-", 1, true) then
              count = count + 1
            end
          end)
        return count
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is integer) then
          return false, "fs_walk_tree: result is not an integer"
        end
        local count = res
        if count ~= tree_entries then
          return false, string.format("walked %s entries, want %d",
            tostring(count), tree_entries)
        end
        return true
      end,
    },
    {
      -- Iterate matching files without ever needing stat data (fs.find_iter()
      -- only returns paths), so this is the scenario a d_type fast path
      -- (skip stat(2) when the dirent already says "not a directory")
      -- should show up in most clearly.
      name = "fs_files_tree",
      fn = function(_: any): any
        local count = 0
        for _ in check.must(fs.find_iter(tmpdir, {glob = "*.txt"})) do
          count = count + 1
        end
        return count
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is integer) then
          return false, "fs_files_tree: result is not an integer"
        end
        local count = res
        if count ~= DIRS * FILES_PER_DIR then
          return false, string.format("found %s *.txt files, want %d",
            tostring(count), DIRS * FILES_PER_DIR)
        end
        return true
      end,
    },
    {
      name = "fs_barf_slurp_64k",
      fn = function(_: any): any
        local wok, werr = fs.write(blob_path, BLOB)
        assert(wok, werr)
        local data, rerr = fs.read(blob_path)
        assert(data, rerr)
        return data
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is string) then
          return false, "fs_barf_slurp_64k: result is not a string"
        end
        if res ~= BLOB then
          return false, "read back different content"
        end
        return true
      end,
    },
    {
      -- Relative path, no explicit base: the case where relpath() needs
      -- cwd for both the target and the implicit base, isolating any
      -- redundant getcwd(2) call from the pure-string path math.
      name = "fs_relpath_relative",
      fn = function(_: any): any
        return fs.relative_path("dir-1/file-1.txt")
      end,
      check = function(_: any, res: any): boolean, string
        if not (res is string) then
          return false, "fs_relpath_relative: result is not a string"
        end
        if res ~= "dir-1/file-1.txt" then
          return false, "wrong relpath: " .. tostring(res)
        end
        return true
      end,
    },
    {
      -- Read-only metadata pass over the seeded tree. Write-churn
      -- scenarios (mkdir+rmrf) drift monotonically on overlay
      -- filesystems, which breaks baseline comparisons, so this
      -- deliberately sticks to stat.
      name = "fs_stat_tree",
      fn = function(_: any): any
        local size_total: number = 0
        for d = 1, DIRS do
          for f = 1, FILES_PER_DIR do
            local st, serr = fs.stat(fs.join(tmpdir, "dir-" .. d, "file-" .. f .. ".txt"))
            assert(st, serr)
            local stt = st
            size_total = size_total + stt:size()
          end
        end
        return size_total
      end,
      check = function(_: any, res: any): boolean, string
        -- Each file holds "data-<d>-<f>\n"; sizes are deterministic.
        local expected = 0
        for d = 1, DIRS do
          for f = 1, FILES_PER_DIR do
            expected = expected + #("data-" .. d .. "-" .. f .. "\n")
          end
        end
        if not (res is number) then
          return false, "fs_stat_tree: result is not a number"
        end
        if res ~= expected then
          return false, string.format("stat size total %s, want %d",
            tostring(res), expected)
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
