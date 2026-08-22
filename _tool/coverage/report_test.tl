#!/usr/bin/env cosmic
--- Tests for coverage report merging and rendering helpers.
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local report = require("_tool.coverage.report")

local tmpdir = check.must(os.getenv("TEST_TMPDIR"))

--- A .cov body in the shape the collector writes: Lua the reader loads,
--- with the `return` prefix and integer line keys. Written out here
--- rather than encoded, so the fixture states the on-disk format the
--- reader is being tested against.
--- @param inner string The table body, without the `return`
--- @return string The file's bytes
local function cov_body(inner: string): string
  return "return " .. inner .. "\n"
end

-- format_ranges

local function test_format_ranges_empty()
  assert(report.format_ranges({}, 8) == "", "empty input must render empty")
end
test_format_ranges_empty()

local function test_format_ranges_compacts_runs()
  local got = report.format_ranges({1, 2, 3, 5, 9, 10}, 8)
  assert(got == "1-3,5,9-10", "got: " .. got)
end
test_format_ranges_compacts_runs()

local function test_format_ranges_truncates()
  local got = report.format_ranges({1, 3, 5, 7, 9}, 2)
  assert(got == "1,3 +3 more", "got: " .. got)
end
test_format_ranges_truncates()

-- normalize

local function test_normalize_maps_compiled_artifact_to_source()
  -- cosmic/codec.tl exists in the repo, so its compiled artifact maps
  local display = report.normalize("@o/cosmic/codec.lua", "")
  assert(display == "cosmic/codec.tl", "got: " .. tostring(display))
end
test_normalize_maps_compiled_artifact_to_source()

local function test_normalize_strips_cwd_prefix()
  local cwd = check.must(fs.cwd(), "cwd failed")
  local display = report.normalize("@" .. cwd .. "/o/cosmic/codec.lua", cwd)
  assert(display == "cosmic/codec.tl", "got: " .. tostring(display))
  -- a ./-prefixed spelling of the same chunk must merge into the same row
  local dotted = report.normalize("@./o/cosmic/codec.lua", cwd)
  assert(dotted == "cosmic/codec.tl", "got: " .. tostring(dotted))
end
test_normalize_strips_cwd_prefix()

local function test_normalize_skips_non_files_and_foreign_paths()
  assert(report.normalize("=stdin", "") == nil, "non-file chunk must skip")
  assert(report.normalize("@/zip/cosmic/no_such_module.lua", "") == nil,
    "an embedded module with no source in this tree must skip")
  assert(report.normalize("@o/cosmic/codec_test.lua", "") == nil,
    "test files must skip")
  assert(report.normalize("@o/cosmic/no_such_module.lua", "") == nil,
    "artifact without a .tl source must skip")
end
test_normalize_skips_non_files_and_foreign_paths()

-- The artifact flattens a directory module: `require("cosmic.fs")`
-- executes `/zip/cosmic/fs.lua`, whose source is `cosmic/fs/init.tl`.
-- Mapping only the leaf spelling attributed nothing to any of them.
local function test_normalize_maps_embedded_directory_modules()
  assert(report.normalize("@/zip/cosmic/url.lua", "") == "cosmic/url.tl",
    "a leaf module maps to its own source")
  assert(report.normalize("@/zip/cosmic/fs.lua", "") == "cosmic/fs/init.tl",
    "a directory module maps to its init.tl")
end
test_normalize_maps_embedded_directory_modules()

-- `.lua` sources are first-class in this project (see the `luaonly`
-- fixture and `_make/testdata/luaonly/`): when a staged `o/x.lua` has
-- no matching `x.tl`, the source IS `x.lua` and must not be dropped.
local function test_normalize_maps_lua_only_source_with_no_tl()
  local saved = check.must(fs.cwd(), "cwd failed")
  assert(fs.write(fs.join(tmpdir, "greet.lua"), "print('hi')\n"))
  assert(fs.set_cwd(tmpdir))
  local display = report.normalize("@o/greet.lua", "")
  assert(fs.set_cwd(saved))
  assert(display == "greet.lua", "got: " .. tostring(display))
end
test_normalize_maps_lua_only_source_with_no_tl()

local function test_normalize_accepts_existing_tl_script()
  -- a directly-run script records a cwd-relative source; absolute
  -- sources normalize only when they sit under the given cwd
  local saved = check.must(fs.cwd(), "cwd failed")
  assert(fs.write(fs.join(tmpdir, "direct.tl"), "local x = 1\nreturn x\n"))
  assert(fs.set_cwd(tmpdir))
  local display = report.normalize("@direct.tl", "")
  local abs_display = report.normalize("@" .. fs.join(tmpdir, "direct.tl"), tmpdir)
  assert(fs.set_cwd(saved))
  assert(display == "direct.tl", "got: " .. tostring(display))
  assert(abs_display == "direct.tl", "got: " .. tostring(abs_display))
end
test_normalize_accepts_existing_tl_script()

-- read_cov

local function test_read_cov_roundtrip()
  local path = fs.join(tmpdir, "rt.cov")
  local body = cov_body('{version = 1, hits = {["@x.lua"] = {[3] = 7}}}')
  assert(fs.write(path, body))
  local h = check.must(report.read_cov(path))
  assert(h["@x.lua"][3] == 7, "hit count lost in roundtrip")
end
test_read_cov_roundtrip()

local function test_read_cov_accepts_prefixless_bodies()
  -- A .cov file may carry no `return` prefix, e.g. one left over from
  -- a stale build; the reader supplies it.
  local path = fs.join(tmpdir, "old.cov")
  assert(fs.write(path, '{version = 1, hits = {["@y.lua"] = {[2] = 1}}}'))
  local h = check.must(report.read_cov(path))
  assert(h["@y.lua"][2] == 1, "an old-generation .cov still reads")
end
test_read_cov_accepts_prefixless_bodies()

local function test_read_cov_rejects_garbage_and_bad_version()
  local garbage = fs.join(tmpdir, "garbage.cov")
  assert(fs.write(garbage, "not lua at all ("))
  local hits, err = report.read_cov(garbage)
  assert(hits == nil, "garbage must not decode")
  assert(err and #err > 0, "garbage must carry an error")

  local badver = fs.join(tmpdir, "badver.cov")
  assert(fs.write(badver, cov_body("{version = 99, hits = {}}")))
  hits, err = report.read_cov(badver)
  assert(hits == nil, "unsupported version must not decode")
  assert(err and #err > 0, "unsupported version must carry an error")
end
test_read_cov_rejects_garbage_and_bad_version()

-- report

local function test_report_returns_error_without_data()
  local empty = fs.join(tmpdir, "empty_covroot")
  assert(fs.make_dirs(empty))
  local code = report.report({empty})
  assert(code == 1, "no .cov files must exit 1, got " .. code)
end
test_report_returns_error_without_data()

local function test_report_renders_merged_data()
  local covroot = fs.join(tmpdir, "covroot")
  assert(fs.make_dirs(covroot))
  -- two processes hitting the same repo file merge into one row
  for i, hits in ipairs({"{[9] = 1}", "{[9] = 2, [10] = 1}"}) do
    local body = cov_body(
      '{version = 1, hits = {["@o/cosmic/codec.lua"] = ' .. hits .. "}}")
    assert(fs.write(fs.join(covroot, i .. ".cov"), body))
  end
  local code = report.report({covroot})
  assert(code == 0, "report failed with " .. code)
end
test_report_renders_merged_data()

--- One display path's `total` from a covroot holding a single chunk
--- spelling of it.
--- @param root string The tree to run in, holding the source and covroots
--- @param covroot string The directory of .cov files to report on
--- @param display string The row to read
--- @return integer The row's total
local function total_from(root: string, covroot: string, display: string): integer
  local saved = check.must(fs.cwd(), "cwd failed")
  assert(fs.set_cwd(root))
  local reports, err = report.compute({covroot})
  assert(fs.set_cwd(saved))
  assert(reports, tostring(err))
  local found: integer = nil
  for _, r in ipairs(reports) do
    if r.display == display then
      found = r.total
    end
  end
  return check.must(found, display .. " missing from " .. covroot)
end

-- One module arrives under several chunk spellings in a single run --
-- `/zip/mod.lua` from the artifact under test and `o/mod.lua` in
-- process -- and both merge into one row. The denominator is a property
-- of the file, so it must not depend on which spelling reached it: the
-- two spellings would analyze different files (a `local record` is a
-- type declaration in the .tl and an assignment in the compiled .lua),
-- so picking per chunk would let `pairs` order over the .cov files
-- decide the reported total.
local function test_denominator_is_independent_of_chunk_spelling()
  local root = fs.join(tmpdir, "spelling")
  assert(fs.make_dirs(fs.join(root, "o")))
  assert(fs.write(fs.join(root, "mod.tl"),
      "local record R\n  x: integer\nend\nlocal t: R = {x = 1}\nreturn t\n"))
  assert(fs.write(fs.join(root, "o", "mod.lua"),
      "local R = {}\n\n\nlocal t = {x = 1}\nreturn t\n"))
  local totals: {integer} = {}
  for i, chunk in ipairs({"@/zip/mod.lua", "@o/mod.lua"}) do
    local covroot = fs.join(root, "cov" .. i)
    assert(fs.make_dirs(covroot))
    assert(fs.write(fs.join(covroot, "1.cov"), cov_body(
          '{version = 1, hits = {["' .. chunk .. '"] = {[4] = 1, [5] = 1}}}')))
    totals[i] = total_from(root, covroot, "mod.tl")
  end
  assert(totals[1] == totals[2],
    "spelling changed the denominator: " .. totals[1] .. " vs " .. totals[2])
  -- Both analyze the compiled artifact, whose `local R = {}` is a third
  -- executable line the .tl does not have.
  assert(totals[1] == 3, "got: " .. totals[1])
end
test_denominator_is_independent_of_chunk_spelling()
