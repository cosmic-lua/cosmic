#!/usr/bin/env cosmic
--- Bulk-content test for fs.copy, split from ops_test.tl (file-length
--- limit). Big enough that the kernel-side copy_file_range path (where
--- the host supports it) moves bytes across several page-cache pages;
--- ops_test.tl's pipe tests cover the buffered fallback pump on the
--- same hosts.
local fs = require("cosmic.fs")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR")

local function test_copy_multi_megabyte_content()
  local test_dir = fs.join(TEST_TMPDIR, "fs_copy_bulk_test")
  assert(fs.make_dirs(test_dir))
  local src = fs.join(test_dir, "big.bin")
  local piece: {string} = {}
  for i = 1, 4096 do
    piece[i] = string.pack("<I4", i) .. string.rep("\0\255ab", 256)
  end
  local content = table.concat(piece)
  assert(fs.write(src, content))
  local dst = fs.join(test_dir, "big.out")

  local ok, err = fs.copy(src, dst)
  assert(ok, "copy should succeed: " .. (err or ""))
  assert(fs.read(dst) == content, "dst should be byte-identical to src")

  assert(fs.remove_all(test_dir))
end
test_copy_multi_megabyte_content()
