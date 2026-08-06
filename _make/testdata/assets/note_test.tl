#!/usr/bin/env cosmic
-- A test sees the root payload at its artifact path: `--make test` runs
-- tests under a cosmic carrying `embed/**`, so `/zip/data/note.txt`
-- resolves here exactly as it does inside `o/bin/assets`.
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local function test_payload_visible_at_zip()
  local note = check.must(fs.read("/zip/data/note.txt"))
  check.eq(note, "shipped\n", "payload bytes at their artifact path")
end
test_payload_visible_at_zip()
