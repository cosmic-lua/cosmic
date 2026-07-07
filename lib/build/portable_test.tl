local portable = require("build.portable")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_write_file_roundtrip()
  local path = fs.join(tmpdir, "portable-roundtrip.txt")
  local data = "hello\0binary\nworld"
  local ok, err = portable.write_file(path, data)
  assert(ok, "write failed: " .. tostring(err))
  local got = fs.read(path)
  assert(got == data, "content mismatch: " .. tostring(got))
end
test_write_file_roundtrip()

local function test_write_file_truncates()
  local path = fs.join(tmpdir, "portable-trunc.txt")
  assert(portable.write_file(path, "a longer first write"))
  assert(portable.write_file(path, "short"))
  local got = fs.read(path)
  assert(got == "short", "expected truncation, got: " .. tostring(got))
end
test_write_file_truncates()

local function test_write_file_mode()
  local path = fs.join(tmpdir, "portable-mode.bin")
  assert(portable.write_file(path, "#!x", tonumber("755", 8)))
  local st = fs.stat(path)
  assert(st, "stat failed")
  local perms = (st as fs_types.Stat):mode() & 511
  assert(perms == tonumber("755", 8), "expected 0755, got " .. tostring(perms))
end
test_write_file_mode()

local function test_write_file_empty()
  local path = fs.join(tmpdir, "portable-empty.txt")
  assert(portable.write_file(path, ""))
  local got = fs.read(path)
  assert(got == "", "expected empty file, got: " .. tostring(got))
end
test_write_file_empty()

local function test_write_file_bad_path()
  local ok, err = portable.write_file(fs.join(tmpdir, "no/such/dir/f"), "x")
  assert(not ok, "expected failure for missing directory")
  assert(err and err:find("open ", 1, true), "expected open error, got: " .. tostring(err))
end
test_write_file_bad_path()
