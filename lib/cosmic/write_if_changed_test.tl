#!/usr/bin/env cosmic
-- test cosmic --write-if-changed flag

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local cosmo = require("cosmo")
local unix = require("cosmo.unix")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function write_temp(name: string, content: string): string
  local filepath = path.join(tmpdir, name)
  cosmo.Barf(filepath, content)
  return filepath
end

local function mtime(filepath: string): number, number
  local st = unix.stat(filepath)
  if not st then
    return -1, 0
  end
  return st:mtim()
end

-- Test: --write-if-changed creates file when missing
local function test_write_if_changed_creates_file()
  local input = write_temp("wic_create.tl", [[
local x: number = 42
print(x)
]])
  local output = path.join(tmpdir, "wic_create.lua")

  local ok, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input}):read()
  assert(ok, "--compile --write-if-changed should succeed")

  local content = cosmo.Slurp(output)
  assert(content, "output file should exist after --write-if-changed")
  assert(content:find("local x = 42"), "output should contain compiled Lua")
end
test_write_if_changed_creates_file()

-- Test: --write-if-changed preserves mtime when content unchanged
local function test_write_if_changed_preserves_mtime()
  local input = write_temp("wic_mtime.tl", [[
local x: number = 99
print(x)
]])
  local output = path.join(tmpdir, "wic_mtime.lua")

  -- First invocation creates file
  local ok1, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input}):read()
  assert(ok1, "first compilation should succeed")

  local mt1s, mt1n = mtime(output)
  assert(mt1s > 0, "output file should exist after first compile")

  -- Sleep briefly to ensure clock tick
  unix.nanosleep(0, 100000000)

  -- Second invocation with same input: should not update mtime
  local ok2, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input}):read()
  assert(ok2, "second compilation should succeed")

  local mt2s, mt2n = mtime(output)
  assert(mt1s == mt2s and mt1n == mt2n, "mtime should be unchanged when content is identical (got " .. tostring(mt1s) .. "." .. tostring(mt1n) .. " vs " .. tostring(mt2s) .. "." .. tostring(mt2n) .. ")")
end
test_write_if_changed_preserves_mtime()

-- Test: --write-if-changed updates file when content changes
local function test_write_if_changed_updates_on_change()
  local input = write_temp("wic_change.tl", [[
local x: number = 1
print(x)
]])
  local output = path.join(tmpdir, "wic_change.lua")

  local ok1, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input}):read()
  assert(ok1, "first compilation should succeed")

  local mt1s, mt1n = mtime(output)

  -- Sleep briefly to ensure clock tick
  unix.nanosleep(0, 100000000)

  -- Overwrite input with different content
  cosmo.Barf(input, [[
local x: number = 2
print(x)
]])

  local ok2, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--compile", input}):read()
  assert(ok2, "second compilation should succeed")

  local mt2s, mt2n = mtime(output)
  assert(mt2s > mt1s or (mt2s == mt1s and mt2n > mt1n), "mtime should update when content changes (got " .. tostring(mt1s) .. "." .. tostring(mt1n) .. " vs " .. tostring(mt2s) .. "." .. tostring(mt2n) .. ")")
end
test_write_if_changed_updates_on_change()

-- Test: without --write-if-changed, -o still writes unconditionally
local function test_output_without_write_if_changed()
  local input = write_temp("wic_plain.tl", [[
local x: number = 7
print(x)
]])
  local output = path.join(tmpdir, "wic_plain.lua")

  local ok, _ = spawn.spawn({cosmic, "--output", output, "--compile", input}):read()
  assert(ok, "--compile --output should succeed without --write-if-changed")

  local content = cosmo.Slurp(output)
  assert(content, "output file should exist")
  assert(content:find("local x = 7"), "output should contain compiled Lua")
end
test_output_without_write_if_changed()

-- Test: --write-if-changed with --check-types creates output file
local function test_write_if_changed_check_types()
  local input = write_temp("wic_check.tl", [[
local x: number = 42
print(x)
]])
  local output = path.join(tmpdir, "wic_check.got")

  local ok, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--check-types", input}):read()
  assert(ok, "--check-types --write-if-changed should succeed")

  local content = cosmo.Slurp(output)
  assert(content, "output file should exist")
  assert(content:find("Type check passed"), "output should contain check result")
end
test_write_if_changed_check_types()

-- Test: --write-if-changed with --check-format creates output file
local function test_write_if_changed_check_format()
  local input = write_temp("wic_fmt.tl", "local x: number = 42\nprint(x)\n")
  local output = path.join(tmpdir, "wic_fmt.got")

  local ok, _ = spawn.spawn({cosmic, "--write-if-changed", "--output", output, "--check-format", input}):read()
  assert(ok, "--check-format --write-if-changed should succeed on formatted file")

  local content = cosmo.Slurp(output)
  assert(content, "output file should exist")
  assert(content:find("Format check passed"), "output should contain format check result")
end
test_write_if_changed_check_format()

print("All write-if-changed tests passed!")
