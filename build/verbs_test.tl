--- Every verb `cosmic.cli` names, held to the same command-line contract:
--- an option it does not know and an argument it does not take are
--- refused with exit 2, and every exit -- a pass, a failure, a refused
--- command line -- ends in the verb's verdict line. The verbs come from
--- `Cli.order`, so a new verb is held to this the moment it is listed.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")

--- The verbs whose words after the file are the program's own, so no
--- option or argument is theirs to refuse, and whose output is the
--- program's rather than a verdict.
local passthrough: {string:string} = {
  run = "the words after the file are its program's argv",
  standalone = "the words after the file are its program's argv",
}

--- A command line with one argument more than each verb takes, or why
--- the verb has none: it takes any number of words.
local surplus: {string:{string} | string} = {
  test = "takes any number of selectors",
  fix = "takes any number of paths",
  build = { "build", "extra" },
  db = { "db", "extra" },
  docs = "takes any number of words to search for",
  uses = { "uses", "Fs.read", "Fs.write" },
  todos = "takes any number of paths and words",
  help = { "help", "extra" },
}

--- One command line that passes and one that fails, each run in `tree`
--- unless it names another directory; a string for a failure no command
--- line can bring about.
local record Case
  pass: {string}
  fail: {string} | string
  fail_in: string
end

local cases: {string:Case} = {
  test = { pass = { "test", "good" }, fail = { "test", "bad" } },
  fix = { pass = { "fix", "--check", "good" }, fail = { "fix", "--check", "messy.tl" } },
  build = { pass = { "build" }, fail = { "build" }, fail_in = "broken" },
  db = { pass = { "db" }, fail = { "db" }, fail_in = "empty" },
  docs = { pass = { "docs", "Fs.read" }, fail = { "docs", "zzqqx_nothing_named" } },
  uses = { pass = { "uses", "Fs.read" }, fail = { "uses", "zzqqx_nothing_named" } },
  todos = { pass = { "todos" }, fail = { "todos", "zzqqx_nothing_named" } },
  help = { pass = { "help" }, fail = "help has nothing to fail on but its command line" },
}

local function write_tree(tmp: string): string
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

local function cosmic(dir: string, args: {string}): Child.Result
  local argv: {string} = { (assert(Proc.executable())) }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = dir, env = Env.all(), stdout = "capture", stderr = "capture",
    timeout_ms = 60000,
  })
  return (assert(result, trouble))
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
local function expect(dir: string, verb: string, args: {string}, code: integer): Child.Result
  local result = cosmic(dir, args)
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

local function test_every_verb_is_classified()
  local listed: {string:boolean} = {}
  for _, verb in ipairs(Cli.order) do
    listed[verb] = true
    if passthrough[verb] == nil then
      assert(surplus[verb] ~= nil, verb .. ": say what one argument too many is")
      assert(cases[verb] ~= nil, verb .. ": give a passing and a failing command line")
    end
  end
  for verb in pairs(passthrough) do assert(listed[verb], verb .. " is not a verb") end
  for verb in pairs(surplus) do assert(listed[verb], verb .. " is not a verb") end
  for verb in pairs(cases) do assert(listed[verb], verb .. " is not a verb") end
end

local function test_every_verb_refuses_what_it_does_not_take(tmp: string)
  local tree = write_tree(tmp)
  for _, verb in ipairs(Cli.order) do
    if passthrough[verb] == nil then
      local result = expect(tree, verb, { verb, "--no-such-flag" }, 2)
      local err = result.stderr or ""
      assert(err:find("--no-such-flag", 1, true), err)
      local extra = surplus[verb]
      if extra is {string} then
        local _ = expect(tree, verb, extra, 2)
      end
    end
  end
end

local function test_every_verb_ends_in_a_verdict(tmp: string)
  local tree = write_tree(tmp)
  -- `db` passes once the tree has a database.
  local _ = expect(tree, "build", { "build" }, 0)
  for _, verb in ipairs(Cli.order) do
    local case = cases[verb]
    if case ~= nil then
      local _ = expect(tree, verb, case.pass, 0)
      local fail = case.fail
      if fail is {string} then
        local dir = case.fail_in ~= nil and tmp .. "/" .. case.fail_in or tree
        local _ = expect(dir, verb, fail, 1)
      end
    end
  end
end

local function test_a_mistyped_verb_is_named(tmp: string)
  local result = cosmic(tmp, { "tset" })
  local err = result.stderr or ""
  assert(result.code == 2, err)
  assert(err:find("no such verb: tset", 1, true), err)
end

local function test_each_selector_must_match(tmp: string)
  local tree = write_tree(tmp)
  local result = cosmic(tree, { "test", "good", "nothing_here" })
  local err = result.stderr or ""
  assert(result.code == 1, err)
  assert(err:find("no test module matches: nothing_here", 1, true), err)
  assert(not err:find("good", 1, true), err)
end

local function test_standalone_needs_a_file(tmp: string)
  local result = cosmic(tmp, { "--standalone" })
  assert(result.code == 2, result.stderr)
end
