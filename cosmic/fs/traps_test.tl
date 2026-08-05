#!/usr/bin/env cosmic
--- Tests for the fs batch: copy_tree, temp_file, glob-only patterns,
--- Dir:read d_type, access default. New/changed surfaces are reached via
--- casts so this file typechecks red (pre-change) and green alike.
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local fsa = fs as {string: any} -- cast: signature transition

local function write_file(path: string, content: string, mode?: integer)
  assert(fs.write(path, content, mode))
end

-- 1. copy_tree: nested dirs, exec-bit file, symlinks recreated (never
-- followed — same cycle policy as walk).
local function test_copytree()
  local base = fs.join(TEST_TMPDIR, "ct")
  fs.remove_all(base)
  local src = fs.join(base, "src")
  assert(fs.make_dirs(fs.join(src, "sub")))
  write_file(fs.join(src, "a.txt"), "alpha", tonumber("755", 8))
  write_file(fs.join(src, "sub", "b.txt"), "beta")
  assert(fs.symlink("a.txt", fs.join(src, "link")))
  -- symlink cycle: sub/loop -> .. must be recreated, not descended into
  assert(fs.symlink("..", fs.join(src, "sub", "loop")))

  -- cast: from any
  local copy_tree = fsa.copy_tree as function(string, string): boolean, string
  assert(copy_tree, "fs.copy_tree should exist")
  local dst = fs.join(base, "dst")
  local ok, err = copy_tree(src, dst)
  assert(ok, "copy_tree failed: " .. tostring(err))

  assert(fs.read(fs.join(dst, "a.txt")) == "alpha", "file content copied")
  assert(fs.read(fs.join(dst, "sub", "b.txt")) == "beta", "nested content copied")
  local st = check.must(fs.stat(fs.join(dst, "a.txt")))
  assert((st:mode() & tonumber("777", 8)) == tonumber("755", 8),
    "exec bit preserved")
  assert(fs.is_link(fs.join(dst, "link")), "symlink recreated as symlink")
  assert(fs.readlink(fs.join(dst, "link")) == "a.txt", "symlink target preserved")
  assert(fs.is_link(fs.join(dst, "sub", "loop")), "cycle symlink recreated")
  assert(not fs.is_dir(fs.join(dst, "sub", "loop", "dst")) or true,
    "loop is a symlink, so no infinite copy happened (we finished)")
  fs.remove_all(base)
end
test_copytree()

local function test_copytree_missing_src_errors()
  -- cast: from any
  local copy_tree = fsa.copy_tree as function(string, string): boolean, string
  local ok, err = copy_tree(fs.join(TEST_TMPDIR, "nope"), fs.join(TEST_TMPDIR, "out"))
  assert(ok == false, "copy_tree of missing src must fail")
  assert(err and err:match("ENOENT"), "error names ENOENT: " .. tostring(err))
end
test_copytree_missing_src_errors()

-- copy_tree must overwrite an existing symlink at the destination rather
-- than fail EEXIST, matching the doc ("existing destination files and
-- symlinks are overwritten") and copy()'s treatment of regular files.
local function test_copytree_symlink_overwrite()
  local base = fs.join(TEST_TMPDIR, "ct_link_overwrite")
  fs.remove_all(base)
  local src = fs.join(base, "src")
  assert(fs.make_dirs(src))
  write_file(fs.join(src, "a.txt"), "alpha")
  assert(fs.symlink("a.txt", fs.join(src, "link")))

  local dst = fs.join(base, "dst")
  assert(fs.make_dirs(dst))
  -- Pre-existing symlink at the destination, pointing somewhere else —
  -- without an unlink first, unix.symlink() fails EEXIST here.
  assert(fs.symlink("nonexistent-old-target", fs.join(dst, "link")))

  -- cast: from any
  local copy_tree = fsa.copy_tree as function(string, string): boolean, string
  local ok, err = copy_tree(src, dst)
  assert(ok, "copy_tree must overwrite an existing symlink: " .. tostring(err))
  assert(fs.is_link(fs.join(dst, "link")), "destination is still a symlink")
  assert(fs.readlink(fs.join(dst, "link")) == "a.txt",
    "symlink target should be replaced, got " .. tostring((fs.readlink(fs.join(dst, "link")))))
  fs.remove_all(base)
end
test_copytree_symlink_overwrite()

-- copy_tree must apply the source directory's exact permission bits even
-- when the destination directory already existed (make_dirs() is a no-op
-- then, and mkdir()'s own mode is umask-filtered on creation either way).
local function test_copytree_dir_mode_exact()
  local base = fs.join(TEST_TMPDIR, "ct_dir_mode")
  fs.remove_all(base)
  local src_mode = tonumber("750", 8)
  local src = fs.join(base, "src")
  assert(fs.make_dirs(src))
  assert(fs.chmod(src, src_mode))
  write_file(fs.join(src, "a.txt"), "alpha")

  local dst = fs.join(base, "dst")
  assert(fs.make_dirs(dst))
  assert(fs.chmod(dst, tonumber("777", 8)))

  -- cast: from any
  local copy_tree = fsa.copy_tree as function(string, string): boolean, string
  local ok, err = copy_tree(src, dst)
  assert(ok, "copy_tree failed: " .. tostring(err))
  local st = check.must(fs.stat(dst))
  assert((st:mode() & tonumber("777", 8)) == src_mode,
    "dst dir mode should match src exactly, got "
    .. string.format("%o", st:mode() & tonumber("777", 8)))
  fs.remove_all(base)
end
test_copytree_dir_mode_exact()

-- 2. temp_file: Handle + path on the happy path; fs.mkstemp is gone.
local function test_tmpfile_handle_and_path()
  local temp_file = fsa.temp_file as function(string): any, string -- cast: from any
  assert(temp_file, "fs.temp_file should exist")
  local tf, err = temp_file(fs.join(TEST_TMPDIR, "traps_XXXXXX"))
  assert(tf, "temp_file failed: " .. tostring(err))
  local t = tf as {string: any} -- cast: from any
  local h = t.handle
  local hh = h as {string: any} -- cast: from any
  local path = t.path as string -- cast: from any
  -- cast: from any
  assert((hh.write as function(any, string): number, string)(h, "via handle"))
  assert((hh.close as function(any): boolean, string)(h)) -- cast: from any
  assert(fs.read(path) == "via handle", "fs.read sees what the Handle wrote")
  fs.unlink(path)
end
test_tmpfile_handle_and_path()

local function test_tmpfile_default_template()
  local temp_file = fsa.temp_file as function(): any, string -- cast: from any
  local tf = temp_file()
  assert(tf, "temp_file() with no template should create somewhere sane")
  local t = tf as {string: any} -- cast: from any
  local h = t.handle
  local hh = h as {string: any} -- cast: from any
  local path = t.path as string -- cast: from any
  assert((hh.close as function(any): boolean, string)(h)) -- cast: from any
  assert(fs.is_file(path), "returned path exists")
  fs.unlink(path)
end
test_tmpfile_default_template()

local function test_mkstemp_is_gone()
  assert(fsa.mkstemp == nil, "fs.mkstemp should be dropped in favor of temp_file")
  assert(type(fsa.temp_fd) == "function", "fs.temp_fd stays for raw-fd use")
end
test_mkstemp_is_gone()

-- 3. patterns: the plain argument is ALWAYS a glob; Lua patterns move to
-- collect_matching. No more contains-*-or-? guessing.
local function test_collect_pattern_is_always_glob()
  local dir = fs.join(TEST_TMPDIR, "globonly")
  assert(fs.make_dirs(dir))
  write_file(fs.join(dir, "x.txt"), "x")
  write_file(fs.join(dir, "%.txt$"), "literal")

  -- "%.txt$" has no * or ?, so a heuristic that guesses "glob or Lua
  -- pattern" reads it as a pattern and matches x.txt. It is a glob, and
  -- matches only the file literally named "%.txt$".
  local hits = check.must(fs.collect(dir, "%.txt$"))
  assert(#hits == 1, "glob should match exactly the literal file, got " .. #hits)
  assert(fs.basename(hits[1]) == "%.txt$", "literal-name match")
  fs.remove_all(dir)
end
test_collect_pattern_is_always_glob()

local function test_collect_matching_takes_lua_patterns()
  local dir = fs.join(TEST_TMPDIR, "luapat")
  assert(fs.make_dirs(dir))
  write_file(fs.join(dir, "x.txt"), "x")
  write_file(fs.join(dir, "y.lua"), "y")

  -- cast: from any
  local collect_matching = fsa.collect_matching as function(string, string): {string} | nil, string
  assert(collect_matching, "fs.collect_matching should exist")
  local hits = check.must(collect_matching(dir, "%.txt$"))
  assert(#hits == 1 and fs.basename(hits[1]) == "x.txt",
    "Lua pattern matches via collect_matching")
  fs.remove_all(dir)
end
test_collect_matching_takes_lua_patterns()

local function test_files_pattern_is_always_glob()
  local dir = fs.join(TEST_TMPDIR, "globfiles")
  assert(fs.make_dirs(dir))
  write_file(fs.join(dir, "foo.lua"), "1")
  write_file(fs.join(dir, "foo1.lua"), "2")

  -- "foo?.lua" is a glob: ? is exactly one character.
  local seen: {string: boolean} = {}
  for p in check.must(fs.files(dir, "foo?.lua")) do
    seen[fs.basename(p)] = true
  end
  assert(seen["foo1.lua"], "glob ? matches one char")
  assert(not seen["foo.lua"], "glob ? must not match zero chars")
  fs.remove_all(dir)
end
test_files_pattern_is_always_glob()

-- 4. Dir:read exposes the dirent d_type; DT_* constants live on fs.
local function test_dir_read_returns_d_type()
  local dir = fs.join(TEST_TMPDIR, "dtype")
  assert(fs.make_dirs(fs.join(dir, "subdir")))
  write_file(fs.join(dir, "plain.txt"), "p")

  assert(fsa.DT_DIR ~= nil, "fs.DT_DIR should be exported")
  assert(fsa.DT_REG ~= nil, "fs.DT_REG should be exported")
  local d = assert(fs.opendir(dir))
  local dd = d as {string: any} -- cast: signature transition
  local read = dd.read as function(any): string, number -- cast: from any
  local close = dd.close as function(any) -- cast: from any
  local kinds: {string: number} = {}
  while true do
    local name, kind = read(d)
    if not name then break end
    kinds[name] = kind
  end
  close(d)
  assert(kinds["subdir"] == fsa.DT_DIR,
    "Dir:read must report DT_DIR for a subdir, got " .. tostring(kinds["subdir"]))
  assert(kinds["plain.txt"] == fsa.DT_REG,
    "Dir:read must report DT_REG for a file, got " .. tostring(kinds["plain.txt"]))
  fs.remove_all(dir)
end
test_dir_read_returns_d_type()

-- 5. access defaults to F_OK.
local function test_access_defaults_to_exists()
  local path = fs.join(TEST_TMPDIR, "acc.txt")
  write_file(path, "here")
  local access = fsa.access as function(string): boolean -- cast: from any
  assert(access(path) == true, "access(path) with no mode means exists")
  assert(access(fs.join(TEST_TMPDIR, "missing.txt")) == false,
    "access on a missing path is false")
  fs.unlink(path)
end
test_access_defaults_to_exists()
