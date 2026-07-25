#!/usr/bin/env cosmic
--- Tests for coverage report merging and rendering helpers.
local check = require("cosmic.check")
local codec = require("cosmic.codec")
local fs = require("cosmic.fs")
local report = require("cosmic.coverage.report")

local tmpdir = check.must(os.getenv("TEST_TMPDIR"))

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
  local display, parse = report.normalize("@o/cosmic/codec.lua", "")
  assert(display == "cosmic/codec.tl", "got: " .. tostring(display))
  assert(parse == "o/cosmic/codec.lua", "got: " .. tostring(parse))
end
test_normalize_maps_compiled_artifact_to_source()

local function test_normalize_strips_cwd_prefix()
  local cwd = check.must(fs.getcwd(), "getcwd failed")
  local display = report.normalize("@" .. cwd .. "/o/cosmic/codec.lua", cwd)
  assert(display == "cosmic/codec.tl", "got: " .. tostring(display))
  -- a ./-prefixed spelling of the same chunk must merge into the same row
  local dotted = report.normalize("@./o/cosmic/codec.lua", cwd)
  assert(dotted == "cosmic/codec.tl", "got: " .. tostring(dotted))
end
test_normalize_strips_cwd_prefix()

local function test_normalize_skips_non_files_and_foreign_paths()
  assert(report.normalize("=stdin", "") == nil, "non-file chunk must skip")
  assert(report.normalize("@/zip/cosmic/fs.lua", "") == nil,
    "embedded binary module must skip")
  assert(report.normalize("@o/cosmic/codec_test.lua", "") == nil,
    "test files must skip")
  assert(report.normalize("@o/cosmic/no_such_module.lua", "") == nil,
    "artifact without a .tl source must skip")
end
test_normalize_skips_non_files_and_foreign_paths()

local function test_normalize_accepts_existing_tl_script()
  -- a directly-run script records a cwd-relative source; absolute
  -- sources normalize only when they sit under the given cwd
  local saved = check.must(fs.getcwd(), "getcwd failed")
  assert(fs.write(fs.join(tmpdir, "direct.tl"), "local x = 1\nreturn x\n"))
  assert(fs.chdir(tmpdir))
  local display, parse = report.normalize("@direct.tl", "")
  local abs_display = report.normalize("@" .. fs.join(tmpdir, "direct.tl"), tmpdir)
  fs.chdir(saved)
  assert(display == "direct.tl", "got: " .. tostring(display))
  assert(parse == "direct.tl", "got: " .. tostring(parse))
  assert(abs_display == "direct.tl", "got: " .. tostring(abs_display))
end
test_normalize_accepts_existing_tl_script()

-- read_cov

local function test_read_cov_roundtrip()
  local path = fs.join(tmpdir, "rt.cov")
  local body = check.must(codec.encode_lua({
        version = 1,
        hits = {["@x.lua"] = {[3] = 7}},
      }), "encode failed")
  assert(fs.write(path, body))
  local h = check.must(report.read_cov(path))
  assert(h["@x.lua"][3] == 7, "hit count lost in roundtrip")
end
test_read_cov_roundtrip()

local function test_read_cov_rejects_garbage_and_bad_version()
  local garbage = fs.join(tmpdir, "garbage.cov")
  assert(fs.write(garbage, "not lua at all ("))
  local hits, err = report.read_cov(garbage)
  assert(hits == nil, "garbage must not decode")
  assert(err and #err > 0, "garbage must carry an error")

  local badver = fs.join(tmpdir, "badver.cov")
  local body = check.must(codec.encode_lua({version = 99, hits = {}}))
  assert(fs.write(badver, body))
  hits, err = report.read_cov(badver)
  assert(hits == nil, "unsupported version must not decode")
  assert(err and #err > 0, "unsupported version must carry an error")
end
test_read_cov_rejects_garbage_and_bad_version()

-- report

local function test_report_returns_error_without_data()
  local empty = fs.join(tmpdir, "empty_covroot")
  assert(fs.makedirs(empty))
  local code = report.report({empty})
  assert(code == 1, "no .cov files must exit 1, got " .. code)
end
test_report_returns_error_without_data()

local function test_report_renders_merged_data()
  local covroot = fs.join(tmpdir, "covroot")
  assert(fs.makedirs(covroot))
  -- two processes hitting the same repo file merge into one row
  for i, hits in ipairs({{[9] = 1}, {[9] = 2, [10] = 1}}) do
    local body = check.must(codec.encode_lua({
          version = 1,
          hits = {["@o/cosmic/codec.lua"] = hits},
        }))
    assert(fs.write(fs.join(covroot, i .. ".cov"), body))
  end
  local code = report.report({covroot})
  assert(code == 0, "report failed with " .. code)
end
test_report_renders_merged_data()
