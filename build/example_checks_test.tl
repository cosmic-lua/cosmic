--- `build.example_checks` on fixture trees: an example whose shown text
--- lacks a `require`, or reads a name only the harness defines, is
--- refused, and a good one passes; a guide's example likewise.
local Fs = require("cosmic.fs")
local example_checks = require("build.example_checks")
local fixture = require("build.docs_fixture")
local teal = require("build.teal")
-- In the closure, so the checker's `Store.source` of what the fixtures
-- require (`teal.serve_standard`) is read past the worker's hold.
local type _ = require("cosmic.fs")

local built = teal.lazy()

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- What the check says of one example file paired with `cosmic.thing`.
local function found_in(dir: string, example: string): {string}
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source("local record thing", "end", "return thing"),
    ["cosmic/thing_example.tl"] = example,
  })
  return example_checks.run(db, dir, built, {})
end

local good = source(
  'local Fs = require("cosmic.fs")',
  "local Example = {}",
  "",
  "--- Reads a file.",
  "function Example.read()",
  '  local data = Fs.read("/nonexistent")',
  "  print(data)",
  "end",
  "return Example")

local function test_an_example_that_runs_as_shown_passes(dir: string)
  local found = found_in(dir, good)
  assert(#found == 0, table.concat(found, "\n"))
end

local function test_an_example_missing_a_require_is_refused(dir: string)
  local found = found_in(dir, (good:gsub('local Fs = require%("cosmic.fs"%)\n', "")))
  assert(#found > 0 and found[1]:find("cosmic/thing_example.tl:", 1, true) ~= nil
    and found[1]:find("Fs", 1, true) ~= nil, table.concat(found, "\n"))
end

local function test_an_example_reading_a_harness_variable_is_refused(dir: string)
  local found = found_in(dir, source(
    "local Example = {}",
    "--- Uses the test's directory.",
    "function Example.where()",
    "  print(tmp)",
    "end",
    "return Example"))
  assert(#found > 0 and found[1]:find("tmp", 1, true) ~= nil, table.concat(found, "\n"))
end

--- Runs the check over one guide, written under `dir`.
local function found_in_guide(dir: string, text: string): {string}
  assert(Fs.mkdirs(dir .. "/doc/guides"))
  assert(Fs.write(dir .. "/doc/guides/fixture.md", text))
  local db = fixture.database(dir, {})
  return example_checks.run(db, dir, built, { "fixture" })
end

local function test_a_guide_example_must_compile_alone(dir: string)
  local found = found_in_guide(dir, source(
    "# Fixture", "", "```teal", 'local Fs = require("cosmic.fs")', "print(Fs.is_dir(\".\"))", "```"))
  assert(#found == 0, table.concat(found, "\n"))
  found = found_in_guide(dir, source(
    "# Fixture", "", "```teal", "print(Fs.is_dir(\".\"))", "```"))
  assert(#found > 0 and found[1]:find("doc/guides/fixture.md:3:", 1, true) ~= nil,
    table.concat(found, "\n"))
  found = found_in_guide(dir, source(
    "# Fixture", "", "```teal", "print(tmp)", "```"))
  assert(#found > 0 and found[1]:find("tmp", 1, true) ~= nil, table.concat(found, "\n"))
end

--- An entry with `file=` companions reads them through `tmp`, which is
--- the harness's; it is not refused for that, and is for any other name.
local function test_a_guide_entry_with_companions_may_read_tmp(dir: string)
  local found = found_in_guide(dir, source(
    "# Fixture", "", "```teal file=a.txt", "hi", "```", "",
    "```teal", "print(tmp .. \"/a.txt\")", "```"))
  assert(#found == 0, table.concat(found, "\n"))
  found = found_in_guide(dir, source(
    "# Fixture", "", "```teal file=a.txt", "hi", "```", "",
    "```teal", "print(Fs.read(tmp .. \"/a.txt\"))", "```"))
  assert(#found > 0 and found[1]:find("Fs", 1, true) ~= nil, table.concat(found, "\n"))
end
