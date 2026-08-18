local fs = require("cosmic.fs")
local check = require("cosmic.check")
local zip = require("cosmic.zip")
local stage = require("_eval.stage")
local bundle = require("_eval.bundle")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- A fixture run directory with three task subdirectories: the first
--- two real task ids (from the live suite manifest, so bundle.tl's own
--- id source is exercised) get NOTES.md+final.txt and NOTES.md-only
--- respectively; the third gets no directory at all, to prove a
--- wholly-missing task is not an error.
--- @return string The run directory
--- @return string The first task id (both files)
--- @return string The second task id (NOTES.md only)
local function fixture_run_dir(): string, string, string
  local manifest = check.must(stage.load_manifest(stage.MANIFEST_PATH))
  assert(#manifest.tasks >= 2, "suite must have at least two tasks")
  local id1 = manifest.tasks[1].id
  local id2 = manifest.tasks[2].id
  local out = fs.join(tmpdir,
    "bundle-run-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.make_dirs(fs.join(out, id1)))
  check.must(fs.write(fs.join(out, id1, "NOTES.md"), "notes for " .. id1 .. "\n"))
  check.must(fs.write(fs.join(out, id1, "final.txt"), "final for " .. id1 .. "\n"))
  check.must(fs.make_dirs(fs.join(out, id2)))
  check.must(fs.write(fs.join(out, id2, "NOTES.md"), "notes for " .. id2 .. "\n"))
  -- The third task (whichever id follows) gets no directory at all.
  return out, id1, id2
end

local function test_bundle_journals_counts_and_skips_missing()
  local out, id1, id2 = fixture_run_dir()
  local zip_path = fs.join(tmpdir,
    "bundle-out-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)) .. ".zip")
  local count = check.must(bundle.bundle_journals(out, zip_path))
  assert(count == 3, "expected 3 files written, got " .. tostring(count))

  local archive = check.must(zip.open(zip_path))
  local entries = check.must(archive:list())
  local names: {string} = {}
  for _, e in ipairs(entries) do
    names[#names + 1] = e.name
  end
  table.sort(names)
  local want < const >: {string} = {
    id1 .. "/NOTES.md",
    id1 .. "/final.txt",
    id2 .. "/NOTES.md",
  }
  table.sort(want)
  assert(#names == #want, "expected " .. #want .. " entries, got " ..
    table.concat(names, ", "))
  for i, n in ipairs(want) do
    assert(names[i] == n, "entry " .. i .. ": expected " .. n .. ", got " .. names[i])
  end
  assert(archive:close())
end
test_bundle_journals_counts_and_skips_missing()

local function test_parse_args_requires_run_dir_and_out()
  assert(bundle.parse_args({"--out", "x"}).err ~= nil, "--run-dir should be required")
  assert(bundle.parse_args({"--run-dir", "x"}).err ~= nil, "--out should be required")
  assert(bundle.parse_args({"--run-dir", "x", "--out", "y"}).err == nil,
    "both flags present should parse cleanly")
end
test_parse_args_requires_run_dir_and_out()

local function test_bundle_journals_on_empty_run_dir_writes_nothing()
  local out = fs.join(tmpdir,
    "bundle-empty-run-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)))
  check.must(fs.make_dirs(out))
  local zip_path = fs.join(tmpdir,
    "bundle-empty-out-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000000)) ..
    ".zip")
  local count = check.must(bundle.bundle_journals(out, zip_path))
  assert(count == 0, "expected 0 files written, got " .. tostring(count))
  assert(not fs.is_file(zip_path), "no archive should be created when nothing is bundled")
end
test_bundle_journals_on_empty_run_dir_writes_nothing()
