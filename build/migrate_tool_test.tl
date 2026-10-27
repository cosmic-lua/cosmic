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
    timeout_ns = Clock.seconds(20),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

--- A program the migration finishes: an array that is written, and nothing else to do.
local WRITTEN <const> = table.concat({
  "return function(): string",
  "  local names: {string} = {}",
  "  local function add()",
  "    names[#names + 1] = \"a\"",
  "  end",
  "  add()",
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
  assert(ran.out:find("migrate: exit 1: 1 file would change\n", 1, true) ~= nil, ran.out)
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
  assert(again.out:find("migrate: nothing would change and nothing is left\n", 1, true) ~= nil, again.out)
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
  local lines: mut {string} = {}
  for i = 1, 205 do
    lines[#lines + 1] = "local n" .. i .. ": string = " .. i
  end
  lines[#lines + 1] = ""
  assert(Fs.write(tmp .. "/m.tl", table.concat(lines, "\n")))
  local ran = cosmic(tmp, { "migrate", "--check", "m.tl" })
  assert(ran.code == 1, ran.out .. ran.err)
  assert(ran.out:find("migrate: exit 1: 205 findings left\n", 1, true) ~= nil, ran.out:sub(-300))
  local listed = 0
  for _ in ran.out:gmatch("%(not_assignable%)\n") do
    listed = listed + 1
  end
  assert(listed == 200 and ran.out:find("... and 5 more findings, counted by code in the summary\n", 1, true) ~= nil, tostring(listed))
end

local function test_check_exits_1_while_a_finding_is_left_even_when_no_file_would_change(tmp: string)
  local source = table.concat({
    "local function first(s: string?): string",
    "  return s",
    "end",
    "return first",
    "",
  }, "\n")
  assert(Fs.write(tmp .. "/m.tl", source))
  local ran = cosmic(tmp, { "migrate", "--check", "m.tl" })
  assert(ran.code == 1 and ran.out:find("would change 0;", 1, true) ~= nil, ran.out .. ran.err)
  assert(ran.out:find("migrate: exit 1: 1 finding left\n", 1, true) ~= nil, ran.out)
  local written = cosmic(tmp, { "migrate", "m.tl" })
  assert(written.code == 1 and written.out:find("migrate: exit 1: 1 finding left\n", 1, true) ~= nil, written.out)
end

local function test_a_named_link_stays_a_link_and_its_target_is_written_with_its_mode(tmp: string)
  assert(Fs.write(tmp .. "/real.tl", WRITTEN))
  assert(Fs.chmod(tmp .. "/real.tl", 0x1b4))
  assert(Fs.symlink("real.tl", tmp .. "/link.tl"))
  local ran = cosmic(tmp, { "migrate", "link.tl" })
  assert(ran.code == 0 and ran.out:find("migrated link.tl\n", 1, true) == 1, ran.out .. ran.err)
  assert(Fs.readlink(tmp .. "/link.tl") == "real.tl")
  assert(Fs.read(tmp .. "/real.tl") == MIGRATED)
  local st = assert(Fs.stat(tmp .. "/real.tl"))
  assert(st.mode & 0x1ff == 0x1b4)
end

local function test_a_run_that_is_not_given_every_file_of_a_family_names_the_files_that_mention_it(tmp: string)
  local iface = table.concat({
    "local record Iface",
    "  interface Counter",
    "    n: integer",
    "  end",
    "end",
    "return Iface",
    "",
  }, "\n")
  local impl = table.concat({
    "local Iface = require(\"iface\")",
    "local record Impl is Iface.Counter",
    "  n: integer",
    "end",
    "local record Holder",
    "  impl: Impl",
    "end",
    "return function(h: Holder)",
    "  h.impl.n = 1",
    "end",
    "",
  }, "\n")
  local other = table.concat({
    "local Iface = require(\"iface\")",
    "local record Other is Iface.Counter",
    "  n: integer",
    "end",
    "return function(o: Other): integer",
    "  return o.n",
    "end",
    "",
  }, "\n")
  assert(Fs.write(tmp .. "/iface.tl", iface) and Fs.write(tmp .. "/impl.tl", impl) and Fs.write(tmp .. "/other.tl", other))
  local partial = cosmic(tmp, { "migrate", "--check", "iface.tl", "impl.tl" })
  assert(partial.code == 1 and partial.out:find("other.tl: mentions `Iface.Counter`, whose field `n` was made `mut` with the types that list it", 1, true) ~= nil,
    partial.out .. partial.err)
  assert(partial.out:find("migrate: exit 1: 2 files would change; 1 file outside this run to change with it\n", 1, true) ~= nil,
    partial.out)
  local whole = cosmic(tmp, { "migrate", "." })
  assert(whole.code == 0 and whole.out:find("outside this run", 1, true) == nil, whole.out .. whole.err)
  assert(Fs.read(tmp .. "/other.tl") ~= other)
end

local function test_a_directory_with_no_tl_file_is_refused(tmp: string)
  assert(Fs.mkdirs(tmp .. "/empty"))
  local ran = cosmic(tmp, { "migrate", "empty" })
  assert(ran.code == 2 and ran.err:find("empty: no .tl files below it", 1, true) ~= nil, ran.err)
end

local function test_a_command_line_it_cannot_read_is_refused_with_exit_2(tmp: string)
  assert(Fs.write(tmp .. "/m.tl", WRITTEN) and Fs.write(tmp .. "/notes.md", "# notes\n") and Fs.mkdirs(tmp .. "/sub"))
  local none = cosmic(tmp, { "migrate" })
  assert(none.code == 2 and none.err:find("name a directory or a .tl file", 1, true) ~= nil, none.err)
  local missing = cosmic(tmp, { "migrate", "gone.tl" })
  assert(missing.code == 2 and missing.err:find("gone.tl", 1, true) ~= nil, missing.err)
  local markdown = cosmic(tmp, { "migrate", "notes.md" })
  assert(markdown.code == 2 and markdown.err:find("notes.md: not a .tl source", 1, true) ~= nil, markdown.err)
  local above = cosmic(tmp .. "/sub", { "migrate", "../m.tl" })
  assert(above.code == 2 and above.err:find("below the working directory", 1, true) ~= nil, above.err)
  local absolute = cosmic(tmp .. "/sub", { "migrate", tmp .. "/m.tl" })
  assert(absolute.code == 2 and absolute.err:find("below the working directory", 1, true) ~= nil, absolute.err)
  local option = cosmic(tmp, { "migrate", "--write", "m.tl" })
  assert(option.code == 2 and option.err:find("--write", 1, true) ~= nil, option.err)
  assert(Fs.read(tmp .. "/m.tl") == WRITTEN)
end

local function test_help_names_the_verb_and_its_option(tmp: string)
  local ran = cosmic(tmp, { "migrate", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic migrate", 1, true) and ran.out:find("--check", 1, true), ran.out)
  local index = cosmic(tmp, { "help" })
  assert(index.out:find("migrate", 1, true) ~= nil, index.out)
end
