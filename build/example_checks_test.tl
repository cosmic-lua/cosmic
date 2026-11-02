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
    for at = 1, size do body[#body + 1] = "  print(" .. tostring(at) .. ")" end
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
  assert(#found == 1 and found[1]:find("uses helper helper, too long to carry: inline it", 1, true) ~= nil,
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
    1, true) ~= nil, table.concat(found, "\n"))
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
  assert(#found > 0 and found[1]:find("`Missing` is not declared (unknown_variable)", 1, true) ~= nil and
      not found[1]:find("helper", 1, true), table.concat(found, "\n"))
  local long: mut {string} = { "local a, b = {" }
  for at = 1, 20 do long[#long + 1] = "  " .. tostring(at) .. "," end
  long[#long + 1] = "}, 2"
  found = found_in(dir, source(
    "local record Example end",
    table.concat(long, "\n"),
    "",
    "function Example.use()",
    "  print(b)",
    "end",
    "return Example"))
  assert(#found == 1 and found[1]:find("uses helper b, too long to carry: inline it", 1, true) ~= nil,
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

--- The example of a view written, with `mark` after the line that writes it.
local function writes(mark: string): string
  return source(
    "local record Example end",
    "--- Collects words.",
    "function Example.collect()",
    "  local words: {string} = {}",
    "  local function add()",
    '    words[#words + 1] = "a"' .. mark,
    "  end",
    "  add()",
    "  print(#words)",
    "end",
    "return Example")
end

--- A finding of the checker in an example is held by the marker on its line, which is part of the text shown.
local function test_a_finding_with_a_marker_on_its_line_is_held(dir: string)
  local found = found_in(dir, writes(" -- checked: view_written"))
  assert(#found == 0, table.concat(found, "\n"))
end

--- Without the marker the same example is told, with the line of the text shown and what the markers hold.
local function test_a_finding_with_no_marker_is_told(dir: string)
  local told = table.concat(found_in(dir, writes("")), "\n")
  assert(told:find("(view_written)", 1, true) ~= nil, told)
  assert(told:find("cosmic/thing_example.tl:3: example collect: 1 error of view_written on line 4 of the text shown, " ..
      "marked 0 rather than add a marker; follow the fix above", 1, true) ~= nil, told)
end

--- A marker holds the findings of its own line: one on another line holds nothing here, and is stale where it is.
local function test_a_marker_on_another_line_holds_nothing_and_is_stale(dir: string)
  local moved = writes(""):gsub('(  local words: {string} = {})', "%1 -- checked: view_written")
  local told = table.concat(found_in(dir, moved), "\n")
  assert(told:find("1 error of view_written on line 4 of the text shown, marked 0", 1, true) ~= nil, told)
  assert(told:find("line 2 of the text shown: its marker holds 1 finding of view_written that the line no longer has; " ..
      "remove the marker", 1, true) ~= nil, told)
end

--- A marker whose finding is gone is told, so a marker is not left behind when the example is made clean.
local function test_a_marker_with_no_finding_is_stale(dir: string)
  local clean = source(
    "local record Example end",
    "--- Prints.",
    "function Example.say()",
    '  print("hi") -- checked: map_field',
    "end",
    "return Example")
  local found = found_in(dir, clean)
  assert(#found == 1 and found[1]:find("line 2 of the text shown: its marker holds 1 finding of map_field that the line " ..
      "no longer has", 1, true) ~= nil, table.concat(found, "\n"))
end

--- A marker holds as many findings as it counts: `view_written*2` over one finding is stale by one.
local function test_a_marker_holds_no_more_than_it_counts(dir: string)
  local found = found_in(dir, writes(" -- checked: view_written*2"))
  assert(#found == 1 and found[1]:find("its marker holds 1 finding of view_written that the line no longer has", 1, true) ~= nil,
    table.concat(found, "\n"))
end

--- A closed code has no exceptions: a marker for it holds nothing, and is refused for it.
local function test_a_marker_for_a_closed_code_holds_nothing(dir: string)
  local found = found_in(dir, source(
    "local record Example end",
    "function Example.use()",
    "  print(Missing) -- scoped: unknown_variable",
    "end",
    "return Example"))
  local told = table.concat(found, "\n")
  assert(told:find("(unknown_variable)", 1, true) ~= nil and
      told:find("unknown_variable is closed: the tree keeps this rule with no exceptions", 1, true) ~= nil, told)
end

--- A guide's block is copied whole, so it holds no marker: its finding is told whatever the block says.
local function test_a_guide_block_holds_no_marker(dir: string)
  local found = found_in_guide(dir, source(
    "# Fixture", "", "```teal", "local words: {string} = {}",
    'local function add() words[#words + 1] = "a" end -- checked: view_written',
    "add()", "print(#words)", "```"))
  local told = table.concat(found, "\n")
  assert(told:find("(view_written)", 1, true) ~= nil and told:find("doc/guides/fixture.md:3: example: 1 error of view_written " ..
      "on line 2 of the text shown; follow the fix above", 1, true) ~= nil, told)
end
