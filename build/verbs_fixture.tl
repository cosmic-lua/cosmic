--- What build/verbs_tool_test.tl and build/verbs_store_test.tl share:
--- a tree to run verbs in, a verb's run -- in this process where it
--- can be, else started from this program -- and the assertion that it
--- exits as asked and says how it went. Test support; the
--- tables of each verb's cases are [`build.verb_cases`]', which the
--- tests read themselves.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local invoke = require("build.invoke")
local this_program = require("build.this_program")
local verb_list = require("build.verb_list")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")

local record verbs_fixture
end

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
  assert(Fs.write(tree .. "/messy.tl", "local  x: integer = 1\nreturn x\n"))
  assert(Fs.mkdirs(tmp .. "/broken"))
  assert(Fs.write(tmp .. "/broken/wrong.tl", "local x: integer = \"text\"\nreturn x\n"))
  assert(Fs.mkdirs(tmp .. "/empty"))
  return tree
end

--- The command lines only a process of their own can run, and why:
--- every other runs here ([`build.invoke`]) without starting a process.
local function needs_a_process(args: {string}): string?
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

--- `cosmic <args>` in `dir`: run in this process ([`build.invoke`])
--- where it can be, else started from this program.
function verbs_fixture.run(dir: string, args: {string}): invoke.Result
  if needs_a_process(args) == nil then
    return invoke.run(args, { cwd = dir })
  end
  -- The environment the program needs, with its temporary files (the
  -- directory of a test `cosmic test bad` fails, which it keeps) in this
  -- test's own directory. A `cosmic test`'s workers run unsandboxed: its
  -- command line is what is held here, and a sandbox nested in this
  -- test's own is one a host may refuse.
  local env = this_program.environment()
  env.COSMIC_TEST_SANDBOX = "0"
  local started = this_program.program(args, {
    cwd = dir, env = env, stdout = "capture", stderr = "capture",
    timeout_ns = Clock.seconds(60),
  })
  local result, trouble = Child.run(started.argv, started.options)
  local ran = assert(result, trouble)
  return { code = ran.code, stdout = ran.stdout or "", stderr = ran.stderr or "" }
end

--- The last line of `text`, or "" when it has none.
local function last_line(text: string): string
  local last = ""
  for line in text:gmatch("[^\n]+") do
    last = line
  end
  return last
end

--- Asserts `cosmic <args>` in `dir` exits `code` and says how it went:
--- a refused command line (2) is complained about on stderr, with nothing
--- on stdout and no summary; a run that passed ends in its summary, last
--- on stderr (`verb: ...`) or, for `test`, last on stdout; one that failed
--- says why on stderr, with a summary only where its spec's
--- `summarizes_failure` says, or, for `test`, in its summary. No line is
--- a verdict line, `verb: PASS` or `verb: FAIL`.
function verbs_fixture.expect(dir: string, verb: string, args: {string}, code: integer): invoke.Result
  local result = verbs_fixture.run(dir, args)
  local out, err = result.stdout or "", result.stderr or ""
  local shown = table.concat(args, " ") .. " exited " .. tostring(result.code) ..
    "\nstdout:\n" .. out .. "\nstderr:\n" .. err
  assert(result.code == code, shown)
  for line in (out .. "\n" .. err):gmatch("[^\n]+") do
    assert(line ~= verb .. ": PASS" and line ~= verb .. ": FAIL" and
        not String.starts_with(line, verb .. ": PASS (") and
        not String.starts_with(line, verb .. ": FAIL ("), "a verdict line in " .. shown)
  end
  if code == 2 then
    assert(out == "" and err ~= "", "expected a complaint and no output from " .. shown)
    for line in err:gmatch("[^\n]+") do
      assert(not String.starts_with(line, verb .. ": "), "a summary of a refusal in " .. shown)
    end
  elseif verb == "test" then
    local summary = last_line(out)
    local pattern = if code == 0 then "^test: %d+ tests? passed in " else "^test: %d+ of %d+ tests? failed, " end
    assert(summary:find(pattern) ~= nil, "expected the summary last on stdout: " .. shown)
  elseif code == 0 then
    assert(String.starts_with(last_line(err), verb .. ": "),
      "expected the summary last on stderr: " .. shown)
  else
    assert(err ~= "", "expected stderr to say why from " .. shown)
    local spec = verb_list.find(verb)
    if spec == nil or not spec.summarizes_failure then
      for line in err:gmatch("[^\n]+") do
        assert(not String.starts_with(line, verb .. ": "), "a summary of a failure in " .. shown)
      end
    end
  end
  return result
end

--- Whether `verb`'s cases can share this process's loaded modules and
--- coverage. Cases that need isolation start this program instead.
function verbs_fixture.in_process(verb: string): boolean
  return needs_a_process({ verb }) == nil
end

--- Whether `verb`'s cases start this program.
function verbs_fixture.started(verb: string): boolean
  return not verbs_fixture.in_process(verb)
end

return verbs_fixture
