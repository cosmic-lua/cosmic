--- `cosmic fetch` run as this program: no verdict line, exit 2 for a
--- refused command line and 1 for a fetch that fails, all offline (a
--- closed local port). The fetches themselves are in `fetch_test.tl`.

local Child = require("cosmic.child")
local Test = require("cosmic.test")
local this_program = require("build.this_program")

--- The program itself, which its tests start, and a closed local port.
Test.needs{ tool = true, network = { "127.0.0.1" } }

local function cosmic(dir: string, words: {string}): integer, string, string
  local started = this_program.program(words, {
    cwd = dir, stdout = "capture", stderr = "capture", timeout_ms = 30000,
  })
  local result = assert(Child.run(started.argv, started.options))
  return result.code, result.stdout or "", result.stderr or ""
end

local function test_a_refusal_is_two_and_prints_no_verdict(tmp: string)
  local code, out, err = cosmic(tmp, { "fetch", "notaurl" })
  assert(code == 2 and out == "", out)
  assert(err:find("cosmic: fetch: ", 1, true) == 1, err)
  assert(not err:find("fetch: FAIL", 1, true), err)
end

local function test_a_failed_fetch_is_one_and_prints_no_verdict(tmp: string)
  local code, out, err = cosmic(tmp, { "fetch", "http://127.0.0.1:1/" })
  assert(code == 1 and out == "", out)
  assert(not err:find("fetch: FAIL", 1, true), err)
end

local function test_help_names_the_verb_and_its_options(tmp: string)
  local code, out, err = cosmic(tmp, { "fetch", "--help" })
  assert(code == 0, err)
  assert(out:find("cosmic fetch", 1, true) and out:find("--sha256", 1, true), out)
end
