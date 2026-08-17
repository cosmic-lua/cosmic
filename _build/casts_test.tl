#!/usr/bin/env cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
--- reads: cmd
--- reads: cosmic
-- Ratchet over the tree's `as`-cast count.
--
-- Every cast is an unchecked hole in the type system, and a hole
-- nothing counts is a hole that multiplies. This gate holds the count
-- per file against a committed floor, in both directions: a file may
-- not grow casts, and a file that sheds them banks the improvement by
-- failing until the floor is rewritten. The floor therefore always
-- says what the tree actually carries, which is what makes it a
-- measurement and not a memory.

local casts = require("_build.casts")
local check = require("cosmic.check")
local fs = require("cosmic.fs")

local REBASELINE < const > =
"stale baseline — run: bin/cosmic --make run _build/casts.tl" ..
" --baseline and commit the result"

local function test_the_cast_counts_match_the_committed_baseline()
  local fresh = casts.count(".")
  local base = check.must(casts.baseline())
  local over: {string} = {}
  local under: {string} = {}
  for path, n in pairs(fresh) do
    local was = base[path] or 0
    if n > was then
      over[#over + 1] = string.format(
        "%s: %d casts (baseline %d) — remove them, or justify the" ..
        " increase in the PR", path, n, was)
    elseif n < was then
      under[#under + 1] = string.format(
        "%s: %d casts (baseline %d)", path, n, was)
    end
  end
  for path, was in pairs(base) do
    if not fresh[path] then
      under[#under + 1] = string.format(
        "%s: no casts left (baseline %d)", path, was)
    end
  end
  table.sort(over)
  table.sort(under)
  assert(#over == 0,
    "file(s) over their cast baseline:\n  " .. table.concat(over, "\n  "))
  assert(#under == 0,
    "file(s) under their cast baseline — " .. REBASELINE .. ":\n  " ..
    table.concat(under, "\n  "))
end
test_the_cast_counts_match_the_committed_baseline()

-- What the count actually reads. The fixture holds both justification
-- positions, a file with none, and one under `testdata/` — the tree the
-- count skips, because a fixture's casts are not the tree's.
local function test_count_reads_justification_comments()
  local root = fs.join(check.must(os.getenv("TEST_TMPDIR")), "casts")
  local both = table.concat({
      "local a = x as {string} -- cast: from any",
      "-- cast: userdata boundary",
      "local b = y as Handle",
      "local c = z",
    }, "\n") .. "\n"
  for _, dir in ipairs({"cosmic/testdata", "untracked"}) do
    assert(fs.make_dirs(fs.join(root, dir)))
  end
  assert(fs.write(fs.join(root, "cosmic", "both.tl"), both))
  assert(fs.write(fs.join(root, "cosmic", "none.tl"), "local a = 1\n"))
  assert(fs.write(fs.join(root, "cosmic", "testdata", "fixture.tl"),
      both))
  assert(fs.write(fs.join(root, "untracked", "loose.tl"), both))

  local got = casts.count(root)
  assert(got["cosmic/both.tl"] == 2,
    "both positions count: " .. tostring(got["cosmic/both.tl"]))
  assert(got["cosmic/none.tl"] == nil,
    "a file with no casts stays out of the count")
  assert(got["cosmic/testdata/fixture.tl"] == nil,
    "testdata is skipped")
  assert(got["untracked/loose.tl"] == nil,
    "only the counted trees are walked")
end
test_count_reads_justification_comments()

print("all cast ratchet tests passed")
