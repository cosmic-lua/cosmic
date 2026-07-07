--- Examples for the cosmic.fs_walk module.
--- Demonstrates walk(), collect(), and files() for directory traversal.

-- Example_walk demonstrates walking a directory tree.
-- The visitor receives the FULL path as the first argument and the basename
-- as the second. Do not join them — path is already complete.
local function Example_walk()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")
  local types = require("cosmic.fs_types")

  -- Build a small tree under a temp directory.
  local tmpdir = fs.mkdtemp("/tmp/walk_ex_XXXXXX")
  assert(tmpdir, "mkdtemp failed")

  local subdir = fs.join(tmpdir, "conf")
  assert(fs.makedirs(subdir))
  assert(cio.barf(fs.join(subdir, "app.ini"), "[app]\nname=test\n"))
  assert(cio.barf(fs.join(tmpdir, "README"), "readme\n"))

  -- Collect entries and sort for deterministic output.
  local entries: {string} = {}
  fs.walk(tmpdir, function(_path: string, name: string, st: types.WalkStat, ctx: {string})
      -- path is the full path; name is just the basename.
      -- Never do fs.join(path, name) — that would double the path.
      local kind = st:is_dir() and "dir" or "file"
      table.insert(ctx, kind .. " " .. name)
    end, entries)

  table.sort(entries)
  for _, line in ipairs(entries) do
    print(line)
  end

  fs.rmrf(tmpdir)
  -- Output:
  -- dir conf
  -- file README
  -- file app.ini
end

-- Example_collect demonstrates collecting files matching a glob pattern.
local function Example_collect()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")

  local tmpdir = fs.mkdtemp("/tmp/collect_ex_XXXXXX")
  assert(tmpdir, "mkdtemp failed")

  local subdir = fs.join(tmpdir, "src")
  assert(fs.makedirs(subdir))
  assert(cio.barf(fs.join(subdir, "main.lua"), "-- main\n"))
  assert(cio.barf(fs.join(subdir, "util.lua"), "-- util\n"))
  assert(cio.barf(fs.join(tmpdir, "README.txt"), "readme\n"))

  -- collect returns full paths (or nil if the root could not be opened);
  -- sort for deterministic output.
  local luafiles = (fs.collect(tmpdir, "*.lua") or {}) as {string}
  table.sort(luafiles)
  for _, p in ipairs(luafiles) do
    -- print only the basename so output is not path-dependent.
    print(fs.basename(p))
  end

  fs.rmrf(tmpdir)
  -- Output:
  -- main.lua
  -- util.lua
end

-- Example_files demonstrates the files() iterator for streaming traversal.
local function Example_files()
  local fs = require("cosmic.fs")
  local cio = require("cosmic.io")

  local tmpdir = fs.mkdtemp("/tmp/files_ex_XXXXXX")
  assert(tmpdir, "mkdtemp failed")

  assert(cio.barf(fs.join(tmpdir, "a.txt"), "a\n"))
  assert(cio.barf(fs.join(tmpdir, "b.txt"), "b\n"))

  local names: {string} = {}
  for p in fs.files(tmpdir, "*.txt") do
    table.insert(names, fs.basename(p))
  end
  table.sort(names)
  for _, n in ipairs(names) do
    print(n)
  end

  fs.rmrf(tmpdir)
  -- Output:
  -- a.txt
  -- b.txt
end

local _ = {Example_walk, Example_collect, Example_files}
