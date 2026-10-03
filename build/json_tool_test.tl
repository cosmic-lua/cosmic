--- `cosmic json` run as this program: real standard input, and the
--- rule that it prints its value and no verdict line, exiting 0, 1 or 2.
--- These start this program, so they need `tool`; the lookups themselves
--- are in `json_test.tl`.

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

local function test_it_reads_standard_input_and_prints_no_verdict(tmp: string)
  local ran = cosmic(tmp, { "json", "$.a[1]" }, '{"a": [1, {"b": "c"}]}')
  assert(ran.code == 0, ran.err)
  assert(ran.out == '{\n  "b": "c"\n}\n', ran.out)
  assert(ran.err == "", ran.err)
  local dash = cosmic(tmp, { "json", "-r", "$.a", "-" }, '{"a": "text"}')
  assert(dash.code == 0 and dash.out == "text\n", dash.out)
end

local function test_a_file_and_the_exit_status_are_the_verdict(tmp: string)
  local path = tmp .. "/doc.json"
  assert(Fs.write(path, '{"a": 1}'))
  local found = cosmic(tmp, { "json", "--compact", "$.a", path })
  assert(found.code == 0 and found.out == "1\n" and found.err == "", found.out .. found.err)
  local missing = cosmic(tmp, { "json", "$.b", path })
  assert(missing.code == 1 and missing.out == "", missing.out)
  assert(missing.err == 'cosmic: json: no value at pointer "/b"\n', missing.err)
  local exists = cosmic(tmp, { "json", "--exists", "$.b", path })
  assert(exists.code == 1 and exists.out == "" and exists.err == "")
  local invalid = cosmic(tmp, { "json", "$.a" }, "{")
  assert(invalid.code == 2 and invalid.out == "", invalid.out)
  local usage = cosmic(tmp, { "json", "--bogus", path })
  assert(usage.code == 2 and usage.out == "", usage.out)
  assert(usage.err:find("no such option: --bogus", 1, true), usage.err)
  assert(not usage.err:find("json: FAIL", 1, true), usage.err)
end

--- Help reads the store's docs, which a test not declaring `store` is held
--- from, and one that does runs again on every edit to the tree; so it
--- is here, with the tests that start the program, not in-process.
local function test_help_names_the_verb_and_its_options(tmp: string)
  local ran = cosmic(tmp, { "json", "--help" })
  assert(ran.code == 0, ran.err)
  assert(ran.out:find("cosmic json", 1, true) and ran.out:find("--exists", 1, true), ran.out)
end
