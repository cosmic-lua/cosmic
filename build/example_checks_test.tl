--- [`build.example_checks`] on fixture trees: an example whose shown text
--- lacks a `require`, or reads a name only the harness defines, is
--- refused, and a good one passes; a guide's example likewise.

-- The fixtures require cosmic.fs too. In the closure, it is read past the
-- worker's hold by the checker's [`Store.source`].
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local example_checks = require("build.example_checks")
local fixture = require("build.docs_fixture")

-- The new checker types an example against the declarations the tool carries, which only a worker that holds the tool's
-- database ("cosmic") has.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- What the check says of one example file paired with `cosmic.thing`.
local function found_in(dir: string, example: string): {string}
  -- The check reads the example file from the tree, as `fix --check` does.
  assert(Fs.mkdirs(dir .. "/cosmic"))
  assert(Fs.write(dir .. "/cosmic/thing_example.tl", example))
  local db = fixture.database(dir, {
    ["cosmic/thing.tl"] = source("local record thing", "end", "return thing"),
    ["cosmic/thing_example.tl"] = example,
  })
  return example_checks.run(db, dir, {})
end

local good = source(
  'local Fs = require("cosmic.fs")',
  "local record Example end",
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
  -- The finding names the line the function sits at in the example file.
  assert(#found > 0 and found[1]:find("^cosmic/thing_example%.tl:4: example read:%d+:%d+: `Fs` is not declared " ..
      "%(unknown_variable%)") ~= nil, table.concat(found, "\n"))
end

local function test_an_example_reading_a_harness_variable_is_refused(dir: string)
  local found = found_in(dir, source(
    "local record Example end",
    "--- Uses the test's directory.",
    "function Example.where()",
    "  print(tmp)",
    "end",
    "return Example"))
  assert(#found > 0 and found[1]:find("`tmp` is not declared (unknown_variable)", 1, true) ~= nil, table.concat(found, "\n"))
end

--- Runs the check over one guide, written under `dir`.
local function found_in_guide(dir: string, text: string): {string}
  assert(Fs.mkdirs(dir .. "/doc/guides"))
  assert(Fs.write(dir .. "/doc/guides/fixture.md", text))
  local db = fixture.database(dir, {})
  return example_checks.run(db, dir, { "fixture" })
end

local function test_a_guide_example_must_compile_alone(dir: string)
  local found = found_in_guide(dir, source(
    "# Fixture", "", "```teal", 'local Fs = require("cosmic.fs")', "print(Fs.is_dir(\".\"))", "```"))
  assert(#found == 0, table.concat(found, "\n"))
  found = found_in_guide(dir, source(
    "# Fixture", "", "```teal", "print(Fs.is_dir(\".\"))", "```"))
  assert(#found >= 1 and assert(found[1]):find("^doc/guides/fixture%.md:3: example:%d+:%d+: `Fs` is not declared") ~= nil,
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

--- The text shown is the one function, so a call of a sibling example
--- (`Example.other`), which the reader has not copied, is refused.
local function test_an_example_calling_a_sibling_is_refused(dir: string)
  local found = found_in(dir, source(
    "local record Example end",
    "function Example.other() end",
    "function Example.first()",
    "  Example.other()",
    "end",
    "return Example"))
  assert(#found > 0 and found[1]:find("other", 1, true) ~= nil, table.concat(found, "\n"))
end

--- A helper the example file declares is carried, so an example that
--- uses it passes as shown; one too long to carry is refused, naming it.
local function test_a_short_helper_is_carried_and_a_long_one_is_refused(dir: string)
  local function with_helper(size: integer): string
    local body: mut {string} = { "local function helper(): string" }
    for at = 1, size do body[#body + 1] = "  print(" .. at .. ")" end
    body[#body + 1] = '  return "x"'
    body[#body + 1] = "end"
    return source(
      "local record Example end",
      table.concat(body, "\n"),
      "",
      "--- Uses the helper.",
      "function Example.use()",
      "  print(helper())",
      "end",
      "return Example")
  end
  local found = found_in(dir, with_helper(3))
  assert(#found == 0, table.concat(found, "\n"))
  found = found_in(dir, with_helper(20))
  assert(#found == 1 and found[1]:find("uses helper helper, too long to carry: inline it", 1, true),
    table.concat(found, "\n"))
end

--- A helper that calls `Example.x` is refused with what a copy lacks,
--- not with a bare unknown name.
local function test_a_helper_calling_an_example_is_refused(dir: string)
  local found = found_in(dir, source(
    "local record Example end",
    "",
    "local function shared()",
    "  Example.other()",
    "end",
    "",
    "function Example.other() end",
    "",
    "function Example.use()",
    "  shared()",
    "end",
    "return Example"))
  assert(#found > 0 and found[1]:find("helper shared calls Example.other, which a copy does not carry",
    1, true), table.concat(found, "\n"))
end

--- An unknown name no top-level declaration makes is the checker's own
--- finding. Every name of `local a, b = ...` is a helper's.
local function test_only_declarations_count_as_helpers(dir: string)
  local found = found_in(dir, source(
    "local record Example end",
    "",
    "function Example.use()",
    "  print(Missing)",
    "end",
    "return Example"))
  assert(#found > 0 and found[1]:find("`Missing` is not declared (unknown_variable)", 1, true) and
      not found[1]:find("helper", 1, true), table.concat(found, "\n"))
  local long: mut {string} = { "local a, b = {" }
  for at = 1, 20 do long[#long + 1] = "  " .. at .. "," end
  long[#long + 1] = "}, 2"
  found = found_in(dir, source(
    "local record Example end",
    table.concat(long, "\n"),
    "",
    "function Example.use()",
    "  print(b)",
    "end",
    "return Example"))
  assert(#found == 1 and found[1]:find("uses helper b, too long to carry: inline it", 1, true),
    table.concat(found, "\n"))
end

--- An example is compiled as a file alone, with the table of the examples a record of that name (the checker refuses a
--- literal with no type to make it from), and what it finds is said in the checker's words and fixes.
local function test_an_example_whose_file_declares_its_table_either_way_passes_as_shown(dir: string)
  -- the text shown holds the function and the requires it needs, not the file's table: the file may declare it either way
  local found = found_in(dir, source(
    'local Fs = require("cosmic.fs")',
    "local Example = {}",
    "",
    "--- Reads a file.",
    "function Example.read()",
    '  local data = Fs.read("/nonexistent")',
    "  print(data)",
    "end",
    "return Example"))
  assert(#found == 0, table.concat(found, "\n"))
end

--- An array an example writes is a view until it is declared `mut`: the example is refused with the fix.
local function test_an_example_writing_a_view_is_refused(dir: string)
  local writes = source(
    "local record Example end",
    "--- Collects words.",
    "function Example.collect()",
    "  local words: {string} = {}",
    "  local function add()",
    '    words[#words + 1] = "a"',
    "  end",
    "  add()",
    "  print(#words)",
    "end",
    "return Example")
  local found = found_in(dir, writes)
  assert(#found >= 1 and assert(found[1]):find("(view_written): declare `words` `mut {string}` where it is made or received", 1, true) ~= nil,
    table.concat(found, "\n"))
end

--- The checker's findings in the examples are held to the `[examples]` ceilings of the tree: all of a code's findings in a
--- file, or none.
local function test_a_finding_within_its_pin_is_not_told_and_one_over_it_or_a_pin_above_it_is(dir: string)
  local writes = source(
    "local record Example end",
    "--- Collects words.",
    "function Example.collect()",
    "  local words: {string} = {}",
    "  local function add()",
    '    words[#words + 1] = "a"',
    "  end",
    "  add()",
    "  print(#words)",
    "end",
    "return Example")
  assert(Fs.mkdirs(dir .. "/build"))
  local function pinned(count: integer): {string}
    assert(Fs.write(dir .. "/build/ceilings.txt",
      "[examples]\ncosmic/thing_example.tl view_written " .. tostring(count) .. "\n"))
    return found_in(dir, writes)
  end
  local within = pinned(1)
  assert(#within == 0, table.concat(within, "\n"))
  -- a pin of another file leaves this one's finding over its pin of 0, and is itself above what it finds
  assert(Fs.write(dir .. "/build/ceilings.txt", "[examples]\ncosmic/other_example.tl view_written 1\n"))
  local told = table.concat(found_in(dir, writes), "\n")
  assert(told:find("(view_written)", 1, true) ~= nil and
      told:find("cosmic/thing_example.tl view_written: 1 found, pinned 0;", 1, true) ~= nil, told)
  assert(told:find("cosmic/other_example.tl view_written: pinned 1 but 0 found; lower the pin", 1, true) ~= nil, told)
  local above = pinned(2)
  assert(#above == 1 and assert(above[1]) == "cosmic/thing_example.tl view_written: pinned 2 but 1 found; lower the pin in " ..
      "build/ceilings.txt's [examples]", table.concat(above, "\n"))
end
