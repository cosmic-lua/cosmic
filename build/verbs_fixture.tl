--- What build/verbs_tool_test.tl and build/verbs_store_test.tl share:
--- a tree to run verbs in, a verb's run -- in this process where it
--- can be, else started from this program -- and the assertion that it
--- exits as asked and ends in its verdict line.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Fs = require("cosmic.fs")
local invoke = require("build.invoke")
local this_program = require("build.this_program")
local verb_cases = require("build.verb_cases")

local record verbs_fixture
end

--- The vendored bundle, which `refresh` reads with no network; the
--- tree's root is where a test module loads.
local bundle = assert(Fs.absolute("vendor/cacert/cacert.pem"))

local cases = verb_cases.cases(bundle)

--- A tree under `tmp` with a passing test, a failing one and a file
--- `fix` would change; beside it a module that does not type-check, and
--- an empty directory. Answers the tree.
function verbs_fixture.write_tree(tmp: string): string
  local tree = tmp .. "/tree"
  assert(Fs.mkdirs(tree .. "/good"))
  assert(Fs.mkdirs(tree .. "/bad"))
  assert(Fs.write(tree .. "/good/ok_test.tl", "local function test_ok()\n  assert(true)\nend\n"))
  assert(Fs.write(tree .. "/bad/no_test.tl",
    "local function test_no()\n  error(\"meant to fail\")\nend\n"))
  assert(Fs.write(tree .. "/messy.tl", "local  x = 1\nreturn x\n"))
  assert(Fs.mkdirs(tmp .. "/broken"))
  assert(Fs.write(tmp .. "/broken/wrong.tl", "local x: integer = \"text\"\nreturn x\n"))
  assert(Fs.mkdirs(tmp .. "/empty"))
  return tree
end

--- The command lines only a process of their own can run, and why:
--- every other runs here (`build.invoke`), so a test of it can stand.
local function needs_a_process(args: {string}): string | nil
  local asks_help = false
  for _, word in ipairs(args) do
    if word == "--" then break end
    if word == "--help" or word == "-h" then asks_help = true end
  end
  if args[1] == "test" and not asks_help then
    return "it starts a process for each test, and coverage this one is keeping"
  elseif args[1] == "--standalone" or (args[1] ~= nil and args[1]:match("%.tl$")) then
    return "a file run loads its tree's modules into the process"
  end
  return nil
end

--- `cosmic <args>` in `dir`: run in this process (`build.invoke`)
--- where it can be, else started from this program.
function verbs_fixture.run(dir: string, args: {string}): invoke.Result
  if needs_a_process(args) == nil then
    return invoke.run(args, { cwd = dir })
  end
  -- What of the environment the program needs, its temporary files --
  -- the directory of a test `cosmic test bad` fails, which it keeps --
  -- in this test's own directory; and a `cosmic test`'s workers
  -- unsandboxed, since its command line is what is held here and a
  -- sandbox nested in this test's own is one a host may refuse.
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  local started = this_program.program(args, {
    cwd = dir, env = env, stdout = "capture", stderr = "capture",
    timeout_ms = 60000,
  })
  local result, trouble = Child.run(started.argv, started.options)
  local ran = assert(result, trouble)
  return { code = ran.code, stdout = ran.stdout or "", stderr = ran.stderr or "" }
end

--- "PASS" or "FAIL" when `line` is a verdict line of `verb`'s -- `verb:
--- PASS` or `verb: FAIL`, alone or before a detail in parentheses.
local function verdict_of(line: string, verb: string): string | nil
  local head = verb .. ": "
  if line:sub(1, #head) ~= head then
    return nil
  end
  local rest = line:sub(#head + 1)
  for _, word in ipairs({ "PASS", "FAIL" }) do
    if rest == word or rest:sub(1, 6) == word .. " (" then
      return word
    end
  end
  return nil
end

--- Asserts `cosmic <args>` in `dir` exits `code` and that its output ends
--- in its only verdict line for `verb`, a pass when the code is 0.
function verbs_fixture.expect(dir: string, verb: string, args: {string}, code: integer): invoke.Result
  local result = verbs_fixture.run(dir, args)
  local out = result.stdout or ""
  local shown = table.concat(args, " ") .. " exited " .. tostring(result.code) ..
    "\nstdout:\n" .. out .. "\nstderr:\n" .. (result.stderr or "")
  assert(result.code == code, shown)
  local count = 0
  local last = ""
  for line in out:gmatch("[^\n]+") do
    if verdict_of(line, verb) ~= nil then count = count + 1 end
    last = line
  end
  assert(count == 1, "expected one verdict line from " .. shown)
  assert(verdict_of(last, verb) == (code == 0 and "PASS" or "FAIL"),
    "expected the output to end in the verdict: " .. shown)
  return result
end

--- Whether `verb`'s cases run in this process: a test that starts one
--- never stands, so those that must are tests of their own.
function verbs_fixture.in_process(verb: string): boolean
  return needs_a_process({ verb }) == nil
end

--- Whether `verb`'s cases start this program.
function verbs_fixture.started(verb: string): boolean
  return not verbs_fixture.in_process(verb)
end

--- Asserts each verb `which` answers for passes and fails its case
--- (`build.verb_cases`), each run ending in its verdict line.
function verbs_fixture.ends_in_a_verdict(tmp: string, which: function(string): boolean)
  local tree = verbs_fixture.write_tree(tmp)
  -- `db` passes once the tree has a database.
  local _ = verbs_fixture.expect(tree, "build", { "build" }, 0)
  for _, verb in ipairs(Cli.order) do
    local case = cases[verb]
    if case ~= nil and which(verb) then
      local _ = verbs_fixture.expect(tree, verb, case.pass, 0)
      local fail = case.fail
      if fail is {string} then
        local dir = case.fail_in ~= nil and tmp .. "/" .. case.fail_in or tree
        local _ = verbs_fixture.expect(dir, verb, fail, 1)
      end
    end
  end
end

return verbs_fixture
