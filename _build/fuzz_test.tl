#!/usr/bin/env cosmic
--- reads: _fuzz
--- reads: .github/workflows/fuzz.yml
-- Ratchet over the deep-fuzz lane: `.github/workflows/fuzz.yml` runs
-- every module under `_fuzz` at FUZZ_ITERS=50000 on a daily cron. Two
-- silent failure modes would make that cadence a lie without a test
-- failing: a module that never declares `--- env: FUZZ_SEED
-- FUZZ_ITERS` replays a cached shallow verdict whenever only the
-- environment moved (D18's stamp does not see an undeclared var), and
-- the workflow itself could be narrowed or deleted without anything
-- else noticing, since nothing else in the tree reads it.

local check = require("cosmic.check")
local fs = require("cosmic.fs")

local FUZZ_DIR < const > = "_fuzz"
local FUZZ_WORKFLOW < const > = ".github/workflows/fuzz.yml"
local ENV_LINE < const > = "--- env: FUZZ_SEED FUZZ_ITERS"

--- Every `*_fuzz_test.tl` file under `_fuzz`, in path order.
--- @return {string} Paths relative to the repo root
local function fuzz_modules(): {string}
  local found = check.must(fs.find(FUZZ_DIR, {glob = "*_fuzz_test.tl"}))
  table.sort(found)
  return found
end

-- Every fuzz module must declare the two vars the deep lane sets, so
-- the deps stamp changes when they do and the test actually re-runs at
-- depth instead of replaying a cached shallow PASS.
local function test_every_fuzz_module_declares_its_env()
  local modules = fuzz_modules()
  assert(#modules > 0,
    "no *_fuzz_test.tl files found under " .. FUZZ_DIR ..
    " -- this loop must not pass vacuously")
  local missing: {string} = {}
  for _, path in ipairs(modules) do
    local contents = check.must(fs.read(path))
    if not contents:find(ENV_LINE, 1, true) then
      missing[#missing + 1] = path
    end
  end
  table.sort(missing)
  assert(#missing == 0,
    "missing `" .. ENV_LINE .. "` in: " .. table.concat(missing, ", ") ..
    " -- without it, the deep-fuzz lane's FUZZ_ITERS/FUZZ_SEED bump " ..
    "is invisible to the build graph, so these modules replay a " ..
    "cached shallow verdict instead of actually running at depth, and " ..
    "their deep PASS is a lie")
end
test_every_fuzz_module_declares_its_env()

-- The lane must run the whole directory, not an enumerated list of
-- module paths -- `_fuzz` as a selection covers every file under it,
-- current and future, so a narrowed or deleted selection is the one
-- way the cadence could silently end.
local function test_the_deep_lane_runs_the_whole_directory()
  assert(fs.is_file(FUZZ_WORKFLOW),
    FUZZ_WORKFLOW .. " is missing -- the deep-fuzz lane does not exist")
  local contents = check.must(fs.read(FUZZ_WORKFLOW))
  assert(contents:find("--make test _fuzz", 1, true),
    FUZZ_WORKFLOW .. " no longer runs `--make test _fuzz` -- the deep " ..
    "lane must run the whole directory, not an enumerated subset, so a " ..
    "narrowed selection fails here instead of silently ending the cadence")
end
test_the_deep_lane_runs_the_whole_directory()

print("all fuzz ratchet tests passed")
