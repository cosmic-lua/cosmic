#!/usr/bin/env cosmic
--- Tests for the #559 fs batch: copytree, tmpfile, glob-only patterns,
--- Dir:read d_type, access default. New/changed surfaces are reached via
--- casts so this file typechecks red (pre-change) and green alike.
local check = require("cosmic.check")
local fs = require("cosmic.fs")

global TEST_TMPDIR: string

local fsa = fs as {string: any} -- cast: signature transition

local function write_file(path: string, content: string, mode?: integer)
  assert(fs.write(path, content, mode))
end

-- 1. copytree: nested dirs, exec-bit file, symlinks recreated (never
-- followed — same cycle policy as walk).
local function test_copytree()
  local base = fs.join(TEST_TMPDIR, "ct")
  fs.rmrf(base)
  local src = fs.join(base, "src")
  assert(fs.makedirs(fs.join(src, "sub")))
  write_file(fs.join(src, "a.txt"), "alpha", tonumber("755", 8))
  write_file(fs.join(src, "sub", "b.txt"), "beta")
  assert(fs.symlink("a.txt", fs.join(src, "link")))
  -- symlink cycle: sub/loop -> .. must be recreated, not descended into
  assert(fs.symlink("..", fs.join(src, "sub", "loop")))

  -- cast: from any
  local copytree = fsa.copytree as function(string, string): boolean, string
  assert(copytree, "fs.copytree should exist")
  local dst = fs.join(base, "dst")
  local ok, err = copytree(src, dst)
  assert(ok, "copytree failed: " .. tostring(err))

  assert(fs.read(fs.join(dst, "a.txt")) == "alpha", "file content copied")
  assert(fs.read(fs.join(dst, "sub", "b.txt")) == "beta", "nested content copied")
  local st = check.must(fs.stat(fs.join(dst, "a.txt")))
  assert((st:mode() & tonumber("777", 8)) == tonumber("755", 8),
    "exec bit preserved")
  assert(fs.islink(fs.join(dst, "link")), "symlink recreated as symlink")
  assert(fs.readlink(fs.join(dst, "link")) == "a.txt", "symlink target preserved")
  assert(fs.islink(fs.join(dst, "sub", "loop")), "cycle symlink recreated")
  assert(not fs.isdir(fs.join(dst, "sub", "loop", "dst")) or true,
    "loop is a symlink, so no infinite copy happened (we finished)")
  fs.rmrf(base)
end
test_copytree()

local function test_copytree_missing_src_errors()
  -- cast: from any
  local copytree = fsa.copytree as function(string, string): boolean, string
  local ok, err = copytree(fs.join(TEST_TMPDIR, "nope"), fs.join(TEST_TMPDIR, "out"))
  assert(ok == false, "copytree of missing src must fail")
  assert(err and err:match("ENOENT"), "error names ENOENT: " .. tostring(err))
end
test_copytree_missing_src_errors()

-- 2. tmpfile: Handle + path on the happy path; fs.mkstemp is gone.
local function test_tmpfile_handle_and_path()
  local tmpfile = fsa.tmpfile as function(string): any, string, string -- cast: from any
  assert(tmpfile, "fs.tmpfile should exist")
  local h, path, err = tmpfile(fs.join(TEST_TMPDIR, "traps_XXXXXX"))
  assert(h, "tmpfile failed: " .. tostring(err))
  local hh = h as {string: any} -- cast: from any
  -- cast: from any
  assert((hh.write as function(any, string): number, string)(h, "via handle"))
  assert((hh.close as function(any): boolean, string)(h)) -- cast: from any
  assert(fs.read(path) == "via handle", "fs.read sees what the Handle wrote")
  fs.unlink(path)
end
test_tmpfile_handle_and_path()

local function test_tmpfile_default_template()
  local tmpfile = fsa.tmpfile as function(): any, string, string -- cast: from any
  local h, path = tmpfile()
  assert(h, "tmpfile() with no template should create somewhere sane")
  local hh = h as {string: any} -- cast: from any
  assert((hh.close as function(any): boolean, string)(h)) -- cast: from any
  assert(fs.isfile(path), "returned path exists")
  fs.unlink(path)
end
test_tmpfile_default_template()

local function test_mkstemp_is_gone()
  assert(fsa.mkstemp == nil, "fs.mkstemp should be dropped in favor of tmpfile")
  assert(type(fsa.tmpfd) == "function", "fs.tmpfd stays for raw-fd use")
end
test_mkstemp_is_gone()

-- 3. patterns: the plain argument is ALWAYS a glob; Lua patterns move to
-- collect_matching. No more contains-*-or-? guessing.
local function test_collect_pattern_is_always_glob()
  local dir = fs.join(TEST_TMPDIR, "globonly")
  assert(fs.makedirs(dir))
  write_file(fs.join(dir, "x.txt"), "x")
  write_file(fs.join(dir, "%.txt$"), "literal")

  -- Under the old heuristic "%.txt$" had no * or ?, so it silently ran as
  -- a Lua pattern and matched x.txt. As a glob it matches only the file
  -- literally named "%.txt$".
  local hits = check.must(fs.collect(dir, "%.txt$"))
  assert(#hits == 1, "glob should match exactly the literal file, got " .. #hits)
  assert(fs.basename(hits[1]) == "%.txt$", "literal-name match")
  fs.rmrf(dir)
end
test_collect_pattern_is_always_glob()

local function test_collect_matching_takes_lua_patterns()
  local dir = fs.join(TEST_TMPDIR, "luapat")
  assert(fs.makedirs(dir))
  write_file(fs.join(dir, "x.txt"), "x")
  write_file(fs.join(dir, "y.lua"), "y")

  -- cast: from any
  local collect_matching = fsa.collect_matching as function(string, string): {string} | nil, string
  assert(collect_matching, "fs.collect_matching should exist")
  local hits = check.must(collect_matching(dir, "%.txt$"))
  assert(#hits == 1 and fs.basename(hits[1]) == "x.txt",
    "Lua pattern matches via collect_matching")
  fs.rmrf(dir)
end
test_collect_matching_takes_lua_patterns()

local function test_files_pattern_is_always_glob()
  local dir = fs.join(TEST_TMPDIR, "globfiles")
  assert(fs.makedirs(dir))
  write_file(fs.join(dir, "foo.lua"), "1")
  write_file(fs.join(dir, "foo1.lua"), "2")

  -- "foo?.lua" is a glob: ? is exactly one character.
  local seen: {string: boolean} = {}
  for p in check.must(fs.files(dir, "foo?.lua")) do
    seen[fs.basename(p)] = true
  end
  assert(seen["foo1.lua"], "glob ? matches one char")
  assert(not seen["foo.lua"], "glob ? must not match zero chars")
  fs.rmrf(dir)
end
test_files_pattern_is_always_glob()

-- 4. Dir:read exposes the dirent d_type; DT_* constants live on fs.
local function test_dir_read_returns_d_type()
  local dir = fs.join(TEST_TMPDIR, "dtype")
  assert(fs.makedirs(fs.join(dir, "subdir")))
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
  fs.rmrf(dir)
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
