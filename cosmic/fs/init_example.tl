--- Examples for the cosmic.fs module.

-- Example demonstrating basic fs operations
local function Example_basic()
  local check = require("cosmic.check")
  local fs = require("cosmic.fs")

  -- Create a temp directory
  local base = os.getenv("TEST_TMPDIR") or "/tmp"
  local tmpdir = fs.temp_dir(fs.join(base, "fs_example_XXXXXX"))
  if not tmpdir then
    print("failed to create temp dir")
    return
  end
  print("created temp dir")

  -- Create a subdirectory
  local subdir = fs.join(tmpdir, "subdir")
  local ok, err = fs.mkdir(subdir)
  if not ok then
    print("mkdir failed:", err)
    assert(fs.remove_all(tmpdir))
    return
  end

  -- Check if it exists
  local st = check.must(fs.stat(subdir))
  if st:is_dir() then
    print("subdir is a directory")
  end

  -- Create a symlink
  local linkpath = fs.join(tmpdir, "link")
  ok, err = fs.symlink(subdir, linkpath)
  if ok then
    local target = fs.readlink(linkpath)
    if target == subdir then
      print("symlink points to subdir")
    end
  end

  -- Clean up
  assert(fs.remove_all(tmpdir))
  print("cleaned up")

  -- Output:
  -- created temp dir
  -- subdir is a directory
  -- symlink points to subdir
  -- cleaned up
end

--- Example_normalize demonstrates path normalization
local function Example_normalize()
  local fs = require("cosmic.fs")
  print(fs.normalize("/usr/./lib"))
  print(fs.normalize("/usr/lib/../bin"))
  print(fs.normalize("a/b/../c"))
  print(fs.normalize("//usr///lib//"))
  -- Output:
  -- /usr/lib
  -- /usr/bin
  -- a/c
  -- /usr/lib
end

--- Example_splitext demonstrates extension splitting
local function Example_splitext()
  local fs = require("cosmic.fs")
  local root: string
  local extension: string
  root, extension = fs.splitext("archive.tar.gz")
  print(root, extension)
  root, extension = fs.splitext(".bashrc")
  if extension == "" then
    print(root)
  else
    print(root, extension)
  end
  root, extension = fs.splitext("/path/to/file.txt")
  print(root, extension)
  -- Output:
  -- archive.tar	.gz
  -- .bashrc
  -- /path/to/file	.txt
end

--- Example_relpath demonstrates computing relative paths
local function Example_relpath()
  local fs = require("cosmic.fs")
  print(fs.relpath("/usr/lib", "/usr"))
  print(fs.relpath("/usr/lib", "/usr/bin"))
  print(fs.relpath("/foo", "/bar"))
  -- Output:
  -- lib
  -- ../lib
  -- ../foo
end

-- Suppress unused warnings for examples
local _ = {Example_basic, Example_normalize, Example_splitext, Example_relpath}
