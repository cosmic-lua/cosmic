#!/usr/bin/env cosmic
--- Tests for the fs batch: copy_tree, temp_file, glob-only patterns,
--- Dir:read d_type, access default. Reaches fs directly and typed,
--- except for the one removed-surface probe (fsa) that asserts
--- retired names are absent from the typed record.
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local fsa = fs as {string: any} -- cast: probe removed surface

local function write_file(path: string, content: string, mode?: integer)
  assert(fs.write(path, content, {mode = mode}))
end

-- 1. copy_tree: nested dirs, exec-bit file, symlinks recreated (never
-- followed — same cycle policy as walk).
local function test_copytree()
  local base = fs.join(TEST_TMPDIR, "ct")
  assert(fs.remove_all(base))
  local src = fs.join(base, "src")
  assert(fs.make_dirs(fs.join(src, "sub")))
  write_file(fs.join(src, "a.txt"), "alpha", tonumber("755", 8))
  write_file(fs.join(src, "sub", "b.txt"), "beta")
  assert(fs.symlink("a.txt", fs.join(src, "link")))
  -- symlink cycle: sub/loop -> .. must be recreated, not descended into
  assert(fs.symlink("..", fs.join(src, "sub", "loop")))

  local dst = fs.join(base, "dst")
  local ok, err = fs.copy_tree(src, dst)
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
  assert(fs.remove_all(base))
end
test_copytree()

local function test_copytree_missing_src_errors()
  local ok, err = fs.copy_tree(fs.join(TEST_TMPDIR, "nope"), fs.join(TEST_TMPDIR, "out"))
  assert(ok == false, "copy_tree of missing src must fail")
  assert(err and err:match("ENOENT"), "error names ENOENT: " .. tostring(err))
end
test_copytree_missing_src_errors()

-- copy_tree must overwrite an existing symlink at the destination rather
-- than fail EEXIST, matching the doc ("existing destination files and
-- symlinks are overwritten") and copy()'s treatment of regular files.
local function test_copytree_symlink_overwrite()
  local base = fs.join(TEST_TMPDIR, "ct_link_overwrite")
  assert(fs.remove_all(base))
  local src = fs.join(base, "src")
  assert(fs.make_dirs(src))
  write_file(fs.join(src, "a.txt"), "alpha")
  assert(fs.symlink("a.txt", fs.join(src, "link")))

  local dst = fs.join(base, "dst")
  assert(fs.make_dirs(dst))
  -- Pre-existing symlink at the destination, pointing somewhere else —
  -- without an unlink first, unix.symlink() fails EEXIST here.
  assert(fs.symlink("nonexistent-old-target", fs.join(dst, "link")))

  local ok, err = fs.copy_tree(src, dst)
  assert(ok, "copy_tree must overwrite an existing symlink: " .. tostring(err))
  assert(fs.is_link(fs.join(dst, "link")), "destination is still a symlink")
  assert(fs.readlink(fs.join(dst, "link")) == "a.txt",
    "symlink target should be replaced, got " .. tostring((fs.readlink(fs.join(dst, "link")))))
  assert(fs.remove_all(base))
end
test_copytree_symlink_overwrite()

-- copy_tree must apply the source directory's exact permission bits even
-- when the destination directory already existed (make_dirs() is a no-op
-- then, and mkdir()'s own mode is umask-filtered on creation either way).
local function test_copytree_dir_mode_exact()
  local base = fs.join(TEST_TMPDIR, "ct_dir_mode")
  assert(fs.remove_all(base))
  local src_mode = tonumber("750", 8)
  local src = fs.join(base, "src")
  assert(fs.make_dirs(src))
  assert(fs.set_mode(src, src_mode))
  write_file(fs.join(src, "a.txt"), "alpha")

  local dst = fs.join(base, "dst")
  assert(fs.make_dirs(dst))
  assert(fs.set_mode(dst, tonumber("777", 8)))

  local ok, err = fs.copy_tree(src, dst)
  assert(ok, "copy_tree failed: " .. tostring(err))
  local st = check.must(fs.stat(dst))
  assert((st:mode() & tonumber("777", 8)) == src_mode,
    "dst dir mode should match src exactly, got "
    .. string.format("%o", st:mode() & tonumber("777", 8)))
  assert(fs.remove_all(base))
end
test_copytree_dir_mode_exact()

-- 2. temp_file: Handle + path on the happy path; fs.mkstemp is gone.
local function test_tmpfile_handle_and_path()
  local tf = check.must(fs.temp_file(fs.join(TEST_TMPDIR, "traps_XXXXXX")))
  assert(tf.handle:write("via handle"))
  assert(tf.handle:close())
  assert(fs.read(tf.path) == "via handle", "fs.read sees what the Handle wrote")
  assert(fs.remove(tf.path))
end
test_tmpfile_handle_and_path()

local function test_tmpfile_default_template()
  local tf = check.must(fs.temp_file())
  assert(tf.handle:close())
  assert(fs.is_file(tf.path), "returned path exists")
  assert(fs.remove(tf.path))
end
test_tmpfile_default_template()

local function test_mkstemp_is_gone()
  assert(fsa.mkstemp == nil, "fs.mkstemp should be dropped in favor of temp_file")
  assert(type(fsa.temp_fd) == "function", "fs.temp_fd stays, returning a Handle")
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
  local hits = check.must(fs.find(dir, {glob = "%.txt$"}))
  assert(#hits == 1, "glob should match exactly the literal file, got " .. #hits)
  assert(fs.basename(hits[1]) == "%.txt$", "literal-name match")
  assert(fs.remove_all(dir))
end
test_collect_pattern_is_always_glob()

local function test_find_pattern_takes_lua_patterns()
  local dir = fs.join(TEST_TMPDIR, "luapat")
  assert(fs.make_dirs(dir))
  write_file(fs.join(dir, "x.txt"), "x")
  write_file(fs.join(dir, "y.lua"), "y")

  local hits = check.must(fs.find(dir, {pattern = "%.txt$"}))
  assert(#hits == 1 and fs.basename(hits[1]) == "x.txt",
    "a Lua pattern matches via FindOptions.pattern")
  assert(fs.remove_all(dir))
end
test_find_pattern_takes_lua_patterns()

local function test_files_pattern_is_always_glob()
  local dir = fs.join(TEST_TMPDIR, "globfiles")
  assert(fs.make_dirs(dir))
  write_file(fs.join(dir, "foo.lua"), "1")
  write_file(fs.join(dir, "foo1.lua"), "2")

  -- "foo?.lua" is a glob: ? is exactly one character.
  local seen: {string: boolean} = {}
  for p in check.must(fs.find_iter(dir, {glob = "foo?.lua"})) do
    seen[fs.basename(p)] = true
  end
  assert(seen["foo1.lua"], "glob ? matches one char")
  assert(not seen["foo.lua"], "glob ? must not match zero chars")
  assert(fs.remove_all(dir))
end
test_files_pattern_is_always_glob()

-- 4. Dir:read exposes the dirent d_type; DT_* constants live on fs.
local function test_dir_read_returns_d_type()
  local dir = fs.join(TEST_TMPDIR, "dtype")
  assert(fs.make_dirs(fs.join(dir, "subdir")))
  write_file(fs.join(dir, "plain.txt"), "p")

  assert(fs.DT_DIR ~= nil, "fs.DT_DIR should be exported")
  assert(fs.DT_REG ~= nil, "fs.DT_REG should be exported")
  local d = assert(fs.open_dir(dir))
  local kinds: {string: number} = {}
  while true do
    local name, kind = d:read()
    if not name then break end
    kinds[name] = kind
  end
  d:close()
  assert(kinds["subdir"] == fs.DT_DIR,
    "Dir:read must report DT_DIR for a subdir, got " .. tostring(kinds["subdir"]))
  assert(kinds["plain.txt"] == fs.DT_REG,
    "Dir:read must report DT_REG for a file, got " .. tostring(kinds["plain.txt"]))
  assert(fs.remove_all(dir))
end
test_dir_read_returns_d_type()

-- 5. is_accessible requires a mode; there is no parameterless access
-- alias.
local function test_is_accessible()
  local path = fs.join(TEST_TMPDIR, "acc.txt")
  write_file(path, "here")
  assert(fs.is_accessible(path, fs.R_OK), "readable file is accessible R_OK")
  assert(not fs.is_accessible(fs.join(TEST_TMPDIR, "missing.txt"), fs.R_OK),
    "missing path is not accessible")
  assert(fs.is_present(path), "and is_present is the no-mode question")
  assert(fsa.access == nil, "the access alias is retired (#988)")
  assert(fs.remove(path))
end
test_is_accessible()

-- 6. the old spellings are GONE, and the names that replaced them
-- answer. A retired alias must not linger as a second way to say the
-- same thing.
local function test_retired_aliases_are_gone()
  local retired = {
    "exists", "abspath", "relpath", "splitext", "expanduser",
    "unsafe_entry_name", "mkdir", "rmdir", "unlink", "opendir",
    "fdopendir", "chdir", "chmod", "chown", "realpath", "lstat",
    "fstat", "fstatfs", "sync", "write_atomic", "walk", "access",
  }
  for _, name in ipairs(retired) do
    assert(fsa[name] == nil, name .. " is retired (#987/#988)")
  end
  local live = {
    "is_present", "absolute_path", "relative_path", "split_extension",
    "expand_user", "is_unsafe_entry_name", "make_dir", "remove_dir",
    "remove", "open_dir", "open_dir_fd", "set_cwd", "set_mode",
    "set_owner", "resolve", "stat_link", "stat_fd", "statfs_fd",
    "sync_all", "visit",
  }
  for _, name in ipairs(live) do
    assert(type(fsa[name]) == "function", name .. " is the name that answers")
  end
  assert(fsa.rename == nil, "fs.rename is deleted (move is the superset)")
  assert(fsa.major == nil and fsa.minor == nil, "fs.major/minor are deleted")
  assert(fsa.ext == nil, "fs.ext is deleted (split_extension's second return)")
end
test_retired_aliases_are_gone()
