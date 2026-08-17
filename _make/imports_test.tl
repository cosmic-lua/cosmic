#!/usr/bin/env cosmic
-- Tests for _make.imports: the one require-edge scanner.
--
-- It is one scanner because it has four consumers that must agree, and
-- the interesting cases are the ones where a regex and a lexer differ.
-- Each case below is stated as source in, module names out, so the
-- table IS the contract.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local imports = require("_make.imports")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local record Case
  name: string
  src: string
  want: string
end

-- The scan ERRORS on what it finds (`check_imports` refuses a project
-- over a cross-`cmd` import), so a false POSITIVE is the expensive
-- direction: it refuses a project for code that never runs. A false
-- negative only costs a missing edge.
local cases: {Case} = {
  {
    name = "the three call spellings, in file order",
    src = "local a = require('pkg.a')\n" ..
    'local b = require("pkg.b")\nlocal c = require "pkg.c"\n',
    want = "pkg.a,pkg.b,pkg.c",
  },
  {
    name = "a line-commented require is not an edge",
    src = "-- local x = require('cmd.other.main')\nlocal a = require('pkg.a')\n",
    want = "pkg.a",
  },
  {
    -- A regex that strips `--` to end of LINE would remove only the
    -- opener's line and leave the interior matching: a require inside
    -- a `--[[ ]]` block would refuse the project.
    name = "a require inside a long comment is not an edge",
    src = "--[[ this is prose\nlocal x = require('cmd.other.main')\n]]\n" ..
    "local a = require('pkg.a')\n",
    want = "pkg.a",
  },
  {
    name = "…at any long-bracket level",
    src = "--[==[ local x = require('cmd.other.main') ]==]\n" ..
    "local a = require('pkg.a')\n",
    want = "pkg.a",
  },
  {
    name = "an identifier ending in the word is not a require",
    src = "local ok = myrequire('cmd.other.main')\nlocal a = require('pkg.a')\n",
    want = "pkg.a",
  },
  {
    -- The mirror failure: stripping `--` to end of line inside a
    -- STRING would delete the rest of a real line, losing requires
    -- after it.
    name = "a `--` inside a string does not start a comment",
    src = "local s = \"a -- b\"\nlocal a = require('pkg.a')\n",
    want = "pkg.a",
  },
  {
    name = "a require inside a long string is not an edge",
    src = "local s = [[ require('cmd.other.main') ]]\nlocal a = require('pkg.a')\n",
    want = "pkg.a",
  },
  {
    -- Documented, deliberate: a project that computes its module names
    -- has left the shape the model describes.
    name = "a computed require is invisible",
    src = "local n = 'pkg.a'\nlocal a = require(n)\n",
    want = "",
  },
  {
    name = "an unterminated string does not swallow the file",
    src = "local s = \"oops\nlocal a = require('pkg.a')\n",
    want = "pkg.a",
  },
}

local function test_scan()
  for _, c in ipairs(cases) do
    local got = table.concat(imports.scan(c.src), ",")
    assert(got == c.want, c.name .. ": got '" .. got .. "', want '" .. c.want .. "'")
  end
end
test_scan()

-- of_file is the memoized front door, and the memo's lifetime is one
-- model build: a re-read within a build can only cost time. `forget`
-- is what a new build calls, and without it a rebuilt project in the
-- same process sees the tree as it was at first read.
local function test_of_file_memoizes_until_forgotten()
  local path = fs.join(tmpdir, "imports-memo.tl")
  check.must(fs.write(path, "local a = require('pkg.a')\n"))
  assert(table.concat(imports.of_file(path), ",") == "pkg.a", "first read")

  check.must(fs.write(path, "local b = require('pkg.b')\n"))
  assert(table.concat(imports.of_file(path), ",") == "pkg.a",
    "within one model build the tree is a snapshot")

  imports.forget()
  assert(table.concat(imports.of_file(path), ",") == "pkg.b",
    "and a new build sees the new tree")
end
test_of_file_memoizes_until_forgotten()

-- An unreadable file has no edges. Missing files are the validator's
-- own complaint to make, by its own rule, with its own message.
local function test_an_unreadable_file_has_no_edges()
  local got = imports.of_file(fs.join(tmpdir, "no-such-source.tl"))
  assert(#got == 0, "expected no edges, got " .. tostring(#got))
end
test_an_unreadable_file_has_no_edges()

-- `env_scan` is multi-token by design: a test commonly reads more than
-- one variable at once (FUZZ_SEED and FUZZ_ITERS together), the same
-- grammar `reads_scan` uses below.
local function test_env_scan_splits_on_whitespace()
  local got = table.concat(
    imports.env_scan("--- env: A B C\nprint('x')\n"), ",")
  assert(got == "A,B,C", "got: " .. got)
end
test_env_scan_splits_on_whitespace()

--- A fresh fixture directory holding one file, for env_of_file cases.
local function env_fixture(name: string, src: string): string
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "env-" .. name .. "-XXXXXX")))
  check.must(fs.write(fs.join(dir, "x_test.tl"), src))
  return dir
end

local function test_env_of_file_sorts_and_dedupes()
  local dir = env_fixture("dedupe", "--- env: B A A\nprint('x')\n")
  local got = check.must(imports.env_of_file(dir, "x_test.tl"))
  assert(table.concat(got, ",") == "A,B", "got: " .. table.concat(got, ","))
end
test_env_of_file_sorts_and_dedupes()

local function test_env_of_file_refuses_a_bad_name()
  local dir = env_fixture("badname", "--- env: 9BAD\nprint('x')\n")
  local got, err = imports.env_of_file(dir, "x_test.tl")
  assert(got == nil, "a bad name must refuse")
  assert(err and err:find("9BAD", 1, true),
    "the message must name it, got: " .. tostring(err))
end
test_env_of_file_refuses_a_bad_name()

local function test_env_of_file_refuses_an_env_switch()
  local dir = env_fixture("switch", "--- env: COSMIC_COVERAGE\nprint('x')\n")
  local got, err = imports.env_of_file(dir, "x_test.tl")
  assert(got == nil, "an ENV_SWITCHES name must refuse")
  assert(err and err:find("COSMIC_COVERAGE", 1, true),
    "the message must name it, got: " .. tostring(err))
end
test_env_of_file_refuses_an_env_switch()

local function test_env_of_file_with_no_declaration_is_empty()
  local dir = env_fixture("none", "print('x')\n")
  local got = check.must(imports.env_of_file(dir, "x_test.tl"))
  assert(#got == 0, "expected no declarations, got " .. #got)
end
test_env_of_file_with_no_declaration_is_empty()

-- `reads_scan` is multi-token, mirroring `env_scan`: a `--- reads:` line
-- names every declared path, not just the first.
local function test_reads_scan_splits_on_whitespace()
  local got = table.concat(
    imports.reads_scan("--- reads: a.tl b.tl c.tl\nprint('x')\n"), ",")
  assert(got == "a.tl,b.tl,c.tl", "got: " .. got)
end
test_reads_scan_splits_on_whitespace()

-- A single-path declaration is the one-token case of the same grammar
-- and must keep working unchanged.
local function test_reads_scan_single_path_unchanged()
  local got = table.concat(imports.reads_scan("--- reads: a.tl\nprint('x')\n"), ",")
  assert(got == "a.tl", "got: " .. got)
end
test_reads_scan_single_path_unchanged()

--- A fresh fixture directory holding one file, for reads_of_file cases.
local function reads_fixture(name: string, src: string): string
  local dir = check.must(fs.temp_dir(fs.join(tmpdir, "reads-" .. name .. "-XXXXXX")))
  check.must(fs.write(fs.join(dir, "x_test.tl"), src))
  return dir
end

-- A multi-path declaration must land every declared path, not just the
-- first, once the paths themselves exist.
local function test_reads_of_file_multi_path()
  local dir = reads_fixture("multi", "--- reads: a.tl b.tl\nprint('x')\n")
  check.must(fs.write(fs.join(dir, "a.tl"), "a\n"))
  check.must(fs.write(fs.join(dir, "b.tl"), "b\n"))
  local got = check.must(imports.reads_of_file(dir, "x_test.tl"))
  assert(table.concat(got, ",") == "a.tl,b.tl", "got: " .. table.concat(got, ","))
end
test_reads_of_file_multi_path()

-- A single-path declaration is unchanged by the multi-token grammar.
local function test_reads_of_file_single_path_unchanged()
  local dir = reads_fixture("single", "--- reads: a.tl\nprint('x')\n")
  check.must(fs.write(fs.join(dir, "a.tl"), "a\n"))
  local got = check.must(imports.reads_of_file(dir, "x_test.tl"))
  assert(table.concat(got, ",") == "a.tl", "got: " .. table.concat(got, ","))
end
test_reads_of_file_single_path_unchanged()

-- One missing path among several must still refuse loudly, naming the
-- missing one -- a multi-path declaration either parses fully or
-- refuses; it never silently drops the bad token.
local function test_reads_of_file_refuses_one_missing_among_several()
  local dir = reads_fixture("missing", "--- reads: a.tl no-such.tl\nprint('x')\n")
  check.must(fs.write(fs.join(dir, "a.tl"), "a\n"))
  local got, err = imports.reads_of_file(dir, "x_test.tl")
  assert(got == nil, "a missing declared path must refuse")
  assert(err and err:find("no-such.tl", 1, true),
    "the message must name it, got: " .. tostring(err))
end
test_reads_of_file_refuses_one_missing_among_several()

print("all imports tests passed")
