#!/usr/bin/env cosmic

local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local lint = require("lint")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_count_lines()
  local path = fs.join(tmpdir, "count_lines.txt")
  cio.barf(path, "one\ntwo\nthree\n")
  local n, err = lint.count_lines(path)
  assert(n == 3, "expected 3 lines, got: " .. tostring(n))
  assert(not err, "unexpected error: " .. tostring(err))
end
test_count_lines()

local function test_count_lines_empty()
  local path = fs.join(tmpdir, "empty.txt")
  cio.barf(path, "")
  local n = lint.count_lines(path)
  assert(n == 0, "expected 0 lines, got: " .. tostring(n))
end
test_count_lines_empty()

local function test_count_lines_missing()
  local n, err = lint.count_lines(fs.join(tmpdir, "nonexistent.txt"))
  assert(n == nil, "expected nil for missing file")
  assert(err, "expected error message")
end
test_count_lines_missing()

local function test_check_file_length_under()
  local diag = lint.check_file_length("test.tl", 100, 500)
  assert(diag == nil, "expected no diagnostic for file under limit")
end
test_check_file_length_under()

local function test_check_file_length_at_limit()
  local diag = lint.check_file_length("test.tl", 500, 500)
  assert(diag == nil, "expected no diagnostic for file at limit")
end
test_check_file_length_at_limit()

local function test_check_file_length_over()
  local diag = lint.check_file_length("test.tl", 501, 500)
  assert(diag ~= nil, "expected diagnostic for file over limit")
  assert(diag.rule == "file-length", "expected file-length rule")
  assert(diag.file == "test.tl", "expected file name")
  assert(diag.message:match("501"), "expected line count in message")
  assert(diag.message:match("500"), "expected limit in message")
end
test_check_file_length_over()

local function test_normalize_path()
  assert(lint.normalize_path("o/lib/cosmic/fs.tl") == "lib/cosmic/fs.tl")
  assert(lint.normalize_path("lib/cosmic/fs.tl") == "lib/cosmic/fs.tl")
end
test_normalize_path()

local function test_lint_file_under_default()
  local path = fs.join(tmpdir, "short.tl")
  local lines: {string} = {}
  for i = 1, 100 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  local diagnostics = lint.lint_file(path)
  assert(#diagnostics == 0, "expected no diagnostics for short file, got: " .. tostring(#diagnostics))
end
test_lint_file_under_default()

local function test_lint_file_over_default()
  local path = fs.join(tmpdir, "long.tl")
  local lines: {string} = {}
  for i = 1, 501 do
    table.insert(lines, "-- line " .. tostring(i))
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  local diagnostics = lint.lint_file(path)
  assert(#diagnostics == 1, "expected 1 diagnostic for long file, got: " .. tostring(#diagnostics))
  assert(diagnostics[1].rule == "file-length", "expected file-length rule")
end
test_lint_file_over_default()

local function test_lint_file_with_ratchet()
  -- simulate a file that's in the ratchet table by creating it at the expected path
  -- the ratchet uses normalized paths, so we test normalize_path + lookup
  local key = "lib/cosmic/fs.tl"
  local limit = lint.FILE_LINES[key]
  assert(limit, "expected ratchet entry for " .. key)

  -- create a file with exactly the ratchet limit lines
  local path = fs.join(tmpdir, "ratchet_at.tl")
  local lines: {string} = {}
  for i = 1, limit do
    table.insert(lines, "-- line " .. tostring(i))
  end
  cio.barf(path, table.concat(lines, "\n") .. "\n")

  -- lint_file won't find this in FILE_LINES since path doesn't normalize to
  -- the key — that's fine, we test check_file_length directly for ratchet
  local diag = lint.check_file_length(key, limit, limit)
  assert(diag == nil, "expected no diagnostic at ratchet limit")

  local diag_over = lint.check_file_length(key, limit + 1, limit)
  assert(diag_over ~= nil, "expected diagnostic over ratchet limit")
end
test_lint_file_with_ratchet()

local function test_default_file_lines()
  assert(lint.DEFAULT_FILE_LINES == 500, "expected default to be 500")
end
test_default_file_lines()

local function test_file_lines_table()
  -- verify all ratchet entries exist and are above the default
  for path, limit in pairs(lint.FILE_LINES) do
    assert(type(path) == "string", "expected string key")
    assert(type(limit) == "number", "expected number value")
    assert(limit > lint.DEFAULT_FILE_LINES,
      path .. " ratchet limit " .. tostring(limit) .. " should be above default " .. tostring(lint.DEFAULT_FILE_LINES))
  end
end
test_file_lines_table()
