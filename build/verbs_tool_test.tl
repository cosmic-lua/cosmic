--- Every verb [`cosmic.cli`] names, held to the same command-line contract:
--- an option it does not know and an argument it does not take are
--- refused with exit 2, and every exit -- a pass, a failure, a refused
--- command line -- ends in the verb's verdict line. The verbs come from
--- [`Cli.order`], so a new verb is held to this the moment it is listed.
---
--- Its cases start this program, so it declares `tool`; those that read
--- its store beyond their module's closure (help, docs, and the verbs'
--- verdicts run in this process) are in build/verbs_store_test.tl, and
--- build/verbs_test.tl holds what needs neither, every verb classified
--- among it, over the tables all read ([`build.verb_cases`]). One case
--- here starts nothing -- each verb refusing in this process what it
--- does not take -- but shares its helpers with the started verbs'
--- case, so it stays with it.

local Cli = require("cosmic.cli")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local verb_cases = require("build.verb_cases")
local verbs_fixture = require("build.verbs_fixture")

--- The tool itself, the CA bundle a file run reads, and what bin/zig reads
--- to find or fetch zig.
Test.needs{
  reads = { "vendor/cacert/cacert.pem" },
  env = { "ALL_PROXY", "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
    "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE", "CURL_CA_BUNDLE", "HTTPS_PROXY",
    "HTTP_PROXY", "NO_PROXY", "SSL_CERT_DIR", "SSL_CERT_FILE", "all_proxy", "http_proxy",
    "https_proxy", "no_proxy" },
  tool = true,
}

local passthrough = verb_cases.passthrough
local surplus = verb_cases.surplus

--- The vendored bundle, which `refresh` reads with no network; the
--- tree's root is where a test module loads.
local bundle = assert(Fs.absolute("vendor/cacert/cacert.pem"))

local cases = verb_cases.cases(bundle)

--- Asserts each verb whose cases start this program passes and fails its case,
--- each run ending in its verdict line.
local function ends_in_a_verdict(tmp: string)
  local tree = verbs_fixture.write_tree(tmp)
  -- `db` passes once the tree has a database.
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  for _, verb in ipairs(Cli.order) do
    local case = cases[verb]
    if case ~= nil and verbs_fixture.started(verb) then
      local _ = verbs_fixture.expect(tree, verb, case.pass, 0)
      local fail = case.fail
      if fail is {string} then
        local dir = case.fail_in ~= nil and tmp .. "/" .. case.fail_in or tree
        local _ = verbs_fixture.expect(dir, verb, fail, 1)
      end
    end
  end
end

local function refuses_what_it_does_not_take(tmp: string, which: function(string): boolean)
  local tree = verbs_fixture.write_tree(tmp)
  for _, verb in ipairs(Cli.order) do
    if passthrough[verb] == nil and which(verb) then
      local result = verbs_fixture.expect(tree, verb, { verb, "--no-such-flag" }, 2)
      local err = result.stderr or ""
      assert(err:find("--no-such-flag", 1, true), err)
      local extra = surplus[verb]
      if extra is {string} then
        local _ = verbs_fixture.expect(tree, verb, extra, 2)
      end
    end
  end
end

local function test_every_verb_refuses_what_it_does_not_take(tmp: string)
  refuses_what_it_does_not_take(tmp, verbs_fixture.in_process)
end

local function test_every_started_verb_refuses_what_it_does_not_take(tmp: string)
  refuses_what_it_does_not_take(tmp, verbs_fixture.started)
end

local function test_every_started_verb_ends_in_a_verdict(tmp: string)
  ends_in_a_verdict(tmp)
end

local function test_each_selector_must_match(tmp: string)
  local tree = verbs_fixture.write_tree(tmp)
  local result = verbs_fixture.run(tree, { "test", "good", "nothing_here" })
  local err = result.stderr or ""
  assert(result.code == 1, err)
  assert(err:find("no test module matches: nothing_here", 1, true), err)
  assert(not err:find("good", 1, true), err)
end

local function test_a_timeout_that_would_wrap_is_refused(tmp: string)
  local tree = verbs_fixture.write_tree(tmp)
  local result = verbs_fixture.expect(tree, "test", { "test", "--timeout", "99999999999999999", "good" }, 2)
  local err = result.stderr or ""
  assert(err:find("--timeout must be at most", 1, true), err)
end

local function test_a_file_run_refuses_an_exit_status_out_of_range(tmp: string)
  assert(Fs.write(tmp .. "/far.tl", "return function(): integer\n  return 300\nend\n"))
  local result = verbs_fixture.run(tmp, { "far.tl" })
  assert(result.code == 2, result.stderr)
  assert(result.stderr == "cosmic: far.tl returned 300, not an exit status 0-255\n",
    result.stderr)
end

--- Text naming a whole number is that number, as `cosmic_tostatus`
--- reads a built program's answer (build/exit_status_test.tl).
local function test_a_file_run_that_returns_numeric_text_exits_with_it(tmp: string)
  assert(Fs.write(tmp .. "/text.tl", "return function(): string\n  return \"3\"\nend\n"))
  local result = verbs_fixture.run(tmp, { "text.tl" })
  assert(result.code == 3, tostring(result.code) .. ": " .. tostring(result.stderr))
  assert(result.stderr == "", result.stderr)
  assert(verbs_fixture.run(tmp, { "-e", "return ' 0x4 '" }).code == 4)
end

--- A directory's own `init.tl` is the module named for the directory,
--- as the build names it, not `<dir>.init`.
local function test_a_file_run_of_an_init_is_its_directory(tmp: string)
  assert(Fs.mkdirs(tmp .. "/lib"))
  assert(Fs.write(tmp .. "/lib/init.tl", "return function(): integer\n  return 3\nend\n"))
  local result = verbs_fixture.run(tmp, { "lib/init.tl" })
  assert(result.code == 3, result.stderr)
end
