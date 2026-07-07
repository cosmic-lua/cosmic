#!/usr/bin/env cosmic
-- Edge cases for normalize()'s already-normal fast path. The predicate
-- that returns the input unchanged must be exactly "output == input":
-- it must accept genuinely-normal paths and dot-adjacent-but-legal
-- component names, and it must reject any input that the split/collapse
-- loop would rewrite. These live in their own file so fs_path_test.tl
-- stays under the 500-line cap.
local fs = require("cosmic.fs")

-- Already-normal inputs are returned unchanged (they take the fast path).
local function test_fast_path_already_normal()
  assert(fs.normalize("/usr/lib") == "/usr/lib", "normal absolute")
  assert(fs.normalize("a/b/c") == "a/b/c", "normal relative")
  assert(fs.normalize("/a") == "/a", "single absolute component")
  assert(fs.normalize("a") == "a", "single relative component")
end
test_fast_path_already_normal()

-- Components that merely contain dots are legal filenames, not "." / ".."
-- segments, so the fast path must pass them through untouched.
local function test_fast_path_dotty_components()
  assert(fs.normalize("...") == "...", "triple-dot filename")
  assert(fs.normalize("a/.../b") == "a/.../b", "triple-dot middle")
  assert(fs.normalize("..a/b..") == "..a/b..", "leading/trailing dot names")
  assert(fs.normalize("a.b/c.d") == "a.b/c.d", "dotted names")
end
test_fast_path_dotty_components()

-- Near-miss non-normal paths must be REJECTED by the fast path and
-- collapsed by the loop — the dangerous failure mode is over-acceptance.
local function test_fast_path_rejects_nonnormal()
  assert(fs.normalize("a/b/..") == "a", "trailing ..")
  assert(fs.normalize("foo/.") == "foo", "trailing .")
  assert(fs.normalize("./foo") == "foo", "leading .")
  assert(fs.normalize("../foo") == "../foo", "leading .. (preserved)")
  assert(fs.normalize("a//b") == "a/b", "double slash")
  assert(fs.normalize("a/b/") == "a/b", "trailing slash")
  assert(fs.normalize("a/./b") == "a/b", "interior .")
  assert(fs.normalize("a/../b") == "b", "interior ..")
end
test_fast_path_rejects_nonnormal()
