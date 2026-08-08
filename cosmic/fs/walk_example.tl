--- Examples for directory traversal: visit() with its Entry record,
--- find() for collection, find_iter() for streaming.

-- Example_visit demonstrates walking a directory tree. The visitor
-- receives an fs.Entry: e.path is the FULL path (already complete),
-- e.name the basename, e.stat the entry's Stat, e.depth the depth.
local function Example_visit()
  local fs = require("cosmic.fs")

  -- Build a small tree under a temp directory.
  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = fs.temp_dir(fs.join(base, "walk_ex_XXXXXX"))
  assert(tmpdir, "temp_dir failed")

  local subdir = fs.join(tmpdir, "conf")
  assert(fs.make_dirs(subdir))
  assert(fs.write(fs.join(subdir, "app.ini"), "[app]\nname=test\n"))
  assert(fs.write(fs.join(tmpdir, "README"), "readme\n"))

  -- Collect entries and sort for deterministic output.
  local entries: {string} = {}
  assert(fs.visit(tmpdir, function(e: fs.Entry, ctx: {string})
        local kind = e.stat:is_dir() and "dir" or "file"
        table.insert(ctx, kind .. " " .. e.name .. " depth=" .. e.depth)
      end, entries))

  table.sort(entries)
  for _, line in ipairs(entries) do
    print(line)
  end

  assert(fs.remove_all(tmpdir))
  -- Output:
  -- dir conf depth=1
  -- file README depth=1
  -- file app.ini depth=2
end

-- Example_find demonstrates collecting files matching a glob pattern.
local function Example_find()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = fs.temp_dir(fs.join(base, "collect_ex_XXXXXX"))
  assert(tmpdir, "temp_dir failed")

  local subdir = fs.join(tmpdir, "src")
  assert(fs.make_dirs(subdir))
  assert(fs.write(fs.join(subdir, "main.lua"), "-- main\n"))
  assert(fs.write(fs.join(subdir, "util.lua"), "-- util\n"))
  assert(fs.write(fs.join(tmpdir, "README.txt"), "readme\n"))

  -- find returns full paths, or nil plus the error if the root could
  -- not be opened; sorted = true makes the output deterministic.
  local luafiles = check.must(fs.find(tmpdir, {glob = "*.lua", sorted = true}))
  for _, p in ipairs(luafiles) do
    -- print only the basename so output is not path-dependent.
    print(fs.basename(p))
  end

  assert(fs.remove_all(tmpdir))
  -- Output:
  -- main.lua
  -- util.lua
end

-- Example_find_iter demonstrates the streaming iterator.
local function Example_find_iter()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")

  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = fs.temp_dir(fs.join(base, "files_ex_XXXXXX"))
  assert(tmpdir, "temp_dir failed")

  assert(fs.write(fs.join(tmpdir, "a.txt"), "a\n"))
  assert(fs.write(fs.join(tmpdir, "b.txt"), "b\n"))

  local names: {string} = {}
  -- find_iter returns nil, err if the root cannot be opened; must
  -- passes the iterator and its closing guard through on success.
  for p in check.must(fs.find_iter(tmpdir, {glob = "*.txt"})) do
    table.insert(names, fs.basename(p))
  end
  table.sort(names)
  for _, n in ipairs(names) do
    print(n)
  end

  assert(fs.remove_all(tmpdir))
  -- Output:
  -- a.txt
  -- b.txt
end

local _ = {Example_visit, Example_find, Example_find_iter}
