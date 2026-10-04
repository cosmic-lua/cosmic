--- `cosmic archive` run as this program: real standard input and the
--- rule that it prints its data and no verdict line, exiting 0, 1 or 2.
--- These start this program, so they need `tool`; the operations are in
--- `archive_test.tl`.

local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start.
Test.needs{ tool = true }

local record Ran
  code: integer
  out: string
  err: string
end

local function cosmic(dir: string, words: {string}, input?: string): Ran
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", input = input,
    timeout_ns = Clock.seconds(30),
  })
  local result = assert(Child.run(started.argv, started.options))
  return { code = result.code, out = result.stdout or "", err = result.stderr or "" }
end

local function test_create_list_and_extract_print_data_and_no_verdict(tmp: string)
  assert(Fs.mkdirs(tmp .. "/tree"))
  assert(Fs.write(tmp .. "/tree/a.txt", "aye"))
  local made = cosmic(tmp, { "archive", "create", "out.tar.gz", "tree" })
  assert(made.code == 0 and made.out == "tree\ntree/a.txt\n" and made.err == "", made.out .. made.err)
  local listed = cosmic(tmp, { "archive", "list", "out.tar.gz" })
  assert(listed.code == 0 and listed.err == "", listed.err)
  assert(listed.out:find("tree/a.txt\t3\t", 1, true), listed.out)
  assert(not listed.out:find("archive: PASS", 1, true), listed.out)
  local out = cosmic(tmp, { "archive", "extract", "out.tar.gz", "-C", "dest" })
  assert(out.code == 0 and out.out == "tree\ntree/a.txt\n", out.out .. out.err)
  assert(Fs.read(tmp .. "/dest/tree/a.txt") == "aye")
  local again = cosmic(tmp, { "archive", "extract", "out.tar.gz", "-C", "dest" })
  assert(again.code == 1 and again.out == "", again.out)
  assert(again.err:find("cosmic: archive: would overwrite", 1, true) == 1, again.err)
end

local function test_standard_input_feeds_list_and_the_json_verb(tmp: string)
  assert(Fs.write(tmp .. "/f.txt", "hello"))
  assert(cosmic(tmp, { "archive", "create", "s.zip", "f.txt" }).code == 0)
  local bytes = assert(Fs.read(tmp .. "/s.zip"))
  local listed = cosmic(tmp, { "archive", "list", "--json", "-" }, bytes)
  assert(listed.code == 0, listed.err)
  local piped = cosmic(tmp, { "json", "-r", "$[0].path", "-" }, listed.out)
  assert(piped.code == 0 and piped.out == "f.txt\n", piped.out .. piped.err)
end

local function test_a_bad_archive_and_a_bad_command_line_exit_2(tmp: string)
  local bad = cosmic(tmp, { "archive", "list", "-" }, "not an archive")
  assert(bad.code == 2 and bad.out == "", bad.out)
  assert(bad.err:find("not a recognized archive format", 1, true), bad.err)
  local usage = cosmic(tmp, { "archive", "unpack", "x" })
  assert(usage.code == 2 and usage.out == "", usage.out)
  assert(not usage.err:find("archive: FAIL", 1, true), usage.err)
end

--- Help reads the store's docs, which a test not declaring `store` is held
--- from, and one that does runs again on every edit to the tree; so it
--- is here, with the tests that start the program, not in-process.
local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "archive", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic archive", 1, true) and ran.out:find("--reproducible", 1, true), ran.out)
end
