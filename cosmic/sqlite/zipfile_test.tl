#!/usr/bin/env cosmic
--- Tests for the `zipfile` virtual table over a cosmic artifact: that
--- sqlite still registers the module, that an artifact's members and
--- their columns read back, that an inserted member survives into a
--- runnable binary, and what each failure path reports.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local sqlite = require("cosmic.sqlite")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

-- The member every cosmic artifact carries. Tests name it instead of
-- counting members: how many members a build has is a property of that
-- build, not of the contract.
local KNOWN_MEMBER < const > = "cosmic/fs.lua"

-- Registration

-- The virtual table is not sqlite's by default: one call in the fork
-- registers it on every database that opens. Losing that call turns
-- every other test in this file into a confusing "no such table"
-- error, so ask the question directly first.
local function test_zipfile_module_is_registered()
  local db = check.must(sqlite.open(":memory:"))
  local row = db:query_one(
    "SELECT name FROM pragma_module_list WHERE name = 'zipfile'")
  assert(row ~= nil,
    "sqlite did not register the zipfile module — look at " ..
    "sqlite3_zipfile_init in whilp/cosmopolitan tool/net/lsqlite3.c")
  check.equal(tostring(row.name), "zipfile")
  assert(db:close())
end
test_zipfile_module_is_registered()

-- Reading an artifact

-- proc.interpreter() is the running artifact's own path; arg[0] inside
-- one is /zip/main.lua, a member rather than the file.
local function test_artifact_members_are_readable()
  local exe = check.must(proc.interpreter())
  local db = check.must(sqlite.open(":memory:"))

  local counted = check.must(
    db:query_one("SELECT count(*) AS n FROM zipfile(?)", {exe}))
  assert(tonumber(counted.n) > 0, "an artifact carries members")

  local named = check.must(db:query_one(
      "SELECT name FROM zipfile(?) WHERE name = ?", {exe, KNOWN_MEMBER}))
  check.equal(tostring(named.name), KNOWN_MEMBER)
  assert(db:close())
end
test_artifact_members_are_readable()

-- The seven columns the artifacts guide documents. A member selected by
-- name has a value in every one of them.
local function test_every_documented_column_is_selectable()
  local exe = check.must(proc.interpreter())
  local db = check.must(sqlite.open(":memory:"))
  local row = check.must(db:query_one(
      "SELECT name, mode, mtime, sz, rawdata, data, method" ..
      " FROM zipfile(?) WHERE name = ?", {exe, KNOWN_MEMBER}))

  check.equal(tostring(row.name), KNOWN_MEMBER)
  assert(row.mode ~= nil, "mode")
  assert(row.mtime ~= nil, "mtime")
  assert(row.sz ~= nil, "sz")
  assert(row.rawdata ~= nil, "rawdata")
  assert(row.data ~= nil, "data")
  assert(row.method ~= nil, "method")
  assert(db:close())
end
test_every_documented_column_is_selectable()

-- Writing an artifact

-- Copy the artifact before editing it: a program that rewrites the zip
-- it is executing from is asking for the failure it will get. fs.copy
-- carries the mode across, so the copy stays executable.
local function artifact_copy(): string
  local exe = check.must(proc.interpreter())
  local copy = fs.join(TEST_TMPDIR, "artifact")
  check.must(fs.copy(exe, copy))
  return copy
end

local function test_insert_and_delete_round_trip()
  local copy = artifact_copy()
  local body < const > = "written by zipfile_test"

  local db = check.must(sqlite.open(":memory:"))
  check.must(db:exec("CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
  check.must(db:exec(
      "INSERT INTO z(name, data) VALUES ('zipfile_test.txt', '" .. body .. "')"))
  assert(db:close())

  -- The edited binary still runs, and serves the member through /zip.
  local ran = check.must(child.run({copy, "-e",
        "local f = assert(io.open('/zip/zipfile_test.txt'))" ..
        " io.write(f:read('a')) f:close()"}))
  check.equal(ran.stdout, body)

  local reopened = check.must(sqlite.open(":memory:"))
  check.must(reopened:exec(
      "CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
  check.must(reopened:exec("DELETE FROM z WHERE name = 'zipfile_test.txt'"))
  local left = check.must(reopened:query_one(
      "SELECT count(*) AS n FROM zipfile(?) WHERE name = 'zipfile_test.txt'",
      {copy}))
  check.equal(tonumber(left.n), 0)
  assert(reopened:close())
end
test_insert_and_delete_round_trip()

-- Failure paths

local function reports(err: string, needle: string)
  assert(err:find(needle, 1, true),
    "expected an error naming '" .. needle .. "', got: " .. err)
end

-- Each of the three ways a caller gets this wrong reports its own
-- cause, so a caller can tell them apart without guessing.
local function test_failure_modes_report_their_cause()
  local copy = artifact_copy()
  local db = check.must(sqlite.open(":memory:"))
  check.must(db:exec("CREATE VIRTUAL TABLE z USING zipfile('" .. copy .. "')"))
  check.must(db:exec("INSERT INTO z(name, data) VALUES ('dup.txt', 'first')"))

  local again, dup_err = db:exec(
    "INSERT INTO z(name, data) VALUES ('dup.txt', 'second')")
  check.equal(again, false, "a member name is claimed once")
  reports(tostring(dup_err), "duplicate name")

  local not_a_zip = fs.join(TEST_TMPDIR, "not_a_zip")
  check.must(fs.write(not_a_zip, "plain text, not a zip"))
  local read_plain, plain_err = db:query_one(
    "SELECT count(*) AS n FROM zipfile(?)", {not_a_zip})
  check.equal(read_plain, nil)
  reports(tostring(plain_err), "end of central directory")

  local absent = fs.join(TEST_TMPDIR, "no_such_artifact")
  local read_absent, absent_err = db:query_one(
    "SELECT count(*) AS n FROM zipfile(?)", {absent})
  check.equal(read_absent, nil)
  reports(tostring(absent_err), "cannot open file")
  assert(db:close())
end
test_failure_modes_report_their_cause()
