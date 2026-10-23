--- `cosmic migrate` run as this program: which files it reads, that `--check` writes nothing, the files it writes and the
--- mode they keep, what it leaves and how it exits, and its help. What the rewrites make of a program is in
--- `migrate_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

--- A program the migration finishes: an array that is written, and nothing else to do.
local WRITTEN <const> = table.concat({
  "return function(): string",
  "  local names: {string} = {}",
  "  names[#names + 1] = \"a\"",
  "  return table.concat(names, \",\")",
  "end",
  "",
}, "\n")

local MIGRATED <const> = (WRITTEN:gsub("local names: {string}", "local names: mut {string}"))

local function test_check_writes_nothing_and_exits_1_where_a_file_would_change(tmp: string)
  assert(Fs.write(tmp .. "/m.tl", WRITTEN))
  local ran = cosmic(tmp, { "migrate", "--check", "m.tl" })
  assert(ran.code == 1 and ran.out:find("would migrate m.tl\n", 1, true) == 1, ran.out .. ran.err)
  assert(ran.out:find("would change 1; findings 1 after the translation (view_written 1), 0 after 1 rewrite in 1 round", 1, true),
    ran.out)
  assert(Fs.read(tmp .. "/m.tl") == WRITTEN)
end

local function test_a_run_writes_the_files_and_a_second_run_has_nothing_to_change(tmp: string)
  assert(Fs.write(tmp .. "/m.tl", WRITTEN))
  local ran = cosmic(tmp, { "migrate", "m.tl" })
  assert(ran.code == 0 and ran.out:find("migrated m.tl\n", 1, true) == 1 and ran.err == "", ran.out .. ran.err)
  assert(Fs.read(tmp .. "/m.tl") == MIGRATED)
  local again = cosmic(tmp, { "migrate", "--check", "m.tl" })
  assert(again.code == 0 and again.out:find("would change 0; findings 0 after the translation", 1, true) ~= nil, again.out)
  assert(again.out:find("would migrate", 1, true) == nil)
  assert(Fs.read(tmp .. "/m.tl") == MIGRATED)
end

local function test_a_directory_is_read_for_its_tl_files_but_not_hidden_directories_or_vendor(tmp: string)
  assert(Fs.mkdirs(tmp .. "/p/lib") and Fs.mkdirs(tmp .. "/p/.hidden") and Fs.mkdirs(tmp .. "/p/vendor"))
  assert(Fs.write(tmp .. "/p/lib/a.tl", WRITTEN) and Fs.write(tmp .. "/p/b.tl", WRITTEN))
  assert(Fs.write(tmp .. "/p/.hidden/c.tl", WRITTEN) and Fs.write(tmp .. "/p/vendor/d.tl", WRITTEN))
  assert(Fs.write(tmp .. "/p/notes.md", WRITTEN))
  local ran = cosmic(tmp .. "/p", { "migrate", "." })
  assert(ran.code == 0 and ran.out:find("read 2 files, changed 2;", 1, true) ~= nil, ran.out .. ran.err)
  assert(Fs.read(tmp .. "/p/lib/a.tl") == MIGRATED and Fs.read(tmp .. "/p/b.tl") == MIGRATED)
  assert(Fs.read(tmp .. "/p/.hidden/c.tl") == WRITTEN and Fs.read(tmp .. "/p/vendor/d.tl") == WRITTEN)
  assert(Fs.read(tmp .. "/p/notes.md") == WRITTEN)
end

local function test_a_file_keeps_its_mode(tmp: string)
  assert(Fs.write(tmp .. "/m.tl", WRITTEN, 0x1ed))
  local ran = cosmic(tmp, { "migrate", "m.tl" })
  assert(ran.code == 0, ran.out .. ran.err)
  local st = assert(Fs.stat(tmp .. "/m.tl"))
  assert(st.mode & 0x1ff == 0x1ed, tostring(st.mode))
end

local function test_a_file_that_needs_nothing_is_not_written(tmp: string)
  local clean = "--- A function.\nreturn function(): integer -- seven\n  return 7\nend\n"
  assert(Fs.write(tmp .. "/m.tl", clean))
  local ran = cosmic(tmp, { "migrate", "m.tl" })
  assert(ran.code == 0 and ran.out:find("migrated", 1, true) == nil and ran.out:find("changed 0;", 1, true) ~= nil, ran.out)
  assert(Fs.read(tmp .. "/m.tl") == clean)
end

local function test_what_is_left_is_listed_with_its_place_and_the_run_exits_1(tmp: string)
  local source = table.concat({
    "local function first(s: string | nil): string",
    "  return s",
    "end",
    "return first",
    "",
  }, "\n")
  assert(Fs.write(tmp .. "/m.tl", source))
  local ran = cosmic(tmp, { "migrate", "m.tl" })
  assert(ran.code == 1 and ran.out:find("migrated m.tl\n", 1, true) == 1, ran.out .. ran.err)
  assert(ran.out:find("m.tl:2:10: `s` is `string?`", 1, true) ~= nil and ran.out:find("(nil_not_allowed)", 1, true) ~= nil, ran.out)
  assert(Fs.read(tmp .. "/m.tl") == (source:gsub("string | nil", "string?")))
end

local function test_a_long_list_of_findings_is_cut_and_its_rest_counted(tmp: string)
  local lines: {string} = {}
  for i = 1, 205 do
    lines[#lines + 1] = "local n" .. i .. ": string = " .. i
  end
  lines[#lines + 1] = ""
  assert(Fs.write(tmp .. "/m.tl", table.concat(lines, "\n")))
  local ran = cosmic(tmp, { "migrate", "--check", "m.tl" })
  assert(ran.code == 0, ran.out .. ran.err)
  local listed = 0
  for _ in ran.out:gmatch("%(not_assignable%)\n") do
    listed = listed + 1
  end
  assert(listed == 200 and ran.out:find("... and 5 more\n", 1, true) ~= nil, tostring(listed))
end

local function test_a_command_line_it_cannot_read_is_refused_with_exit_2(tmp: string)
  assert(Fs.write(tmp .. "/m.tl", WRITTEN) and Fs.write(tmp .. "/notes.md", "# notes\n") and Fs.mkdirs(tmp .. "/sub"))
  local none = cosmic(tmp, { "migrate" })
  assert(none.code == 2 and none.err:find("name a directory or a .tl file", 1, true), none.err)
  local missing = cosmic(tmp, { "migrate", "gone.tl" })
  assert(missing.code == 2 and missing.err:find("gone.tl", 1, true), missing.err)
  local markdown = cosmic(tmp, { "migrate", "notes.md" })
  assert(markdown.code == 2 and markdown.err:find("notes.md: not a .tl source", 1, true), markdown.err)
  local above = cosmic(tmp .. "/sub", { "migrate", "../m.tl" })
  assert(above.code == 2 and above.err:find("below the working directory", 1, true), above.err)
  local absolute = cosmic(tmp .. "/sub", { "migrate", tmp .. "/m.tl" })
  assert(absolute.code == 2 and absolute.err:find("below the working directory", 1, true), absolute.err)
  local option = cosmic(tmp, { "migrate", "--write", "m.tl" })
  assert(option.code == 2 and option.err:find("--write", 1, true), option.err)
  assert(Fs.read(tmp .. "/m.tl") == WRITTEN)
end

local function test_help_names_the_verb_and_its_option(tmp: string)
  local ran = cosmic(tmp, { "migrate", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic migrate", 1, true) and ran.out:find("--check", 1, true), ran.out)
  local index = cosmic(tmp, { "help" })
  assert(index.out:find("migrate", 1, true) ~= nil, index.out)
end
