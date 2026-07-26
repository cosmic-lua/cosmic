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
    -- The regex this replaced stripped `--` to end of LINE, which
    -- removed the opener's line and left the interior matching: a
    -- require inside a `--[[ ]]` block refused the project.
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
    -- The mirror failure: stripping `--` to end of line inside a STRING
    -- deleted the rest of a real line, losing requires after it.
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
-- same process would see the old tree.
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

print("all imports tests passed")
