--- Every verb `cosmic.cli` names, held to the same command-line contract:
--- an option it does not know and an argument it does not take are
--- refused with exit 2, and every exit -- a pass, a failure, a refused
--- command line -- ends in the verb's verdict line. The verbs come from
--- `Cli.order`, so a new verb is held to this the moment it is listed.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Env = require("cosmic.env")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local invoke = require("build.invoke")
local observations = require("build.filesystem_observations")

-- What these tests start is this very program.
observations.confine({ reads = observations.itself() })

--- The verbs that end in no verdict line: those whose words after the
--- file are the program's own, so no option or argument is theirs to
--- refuse, and whose output is the program's; and `--version`, whose
--- one line is all it prints (build/version_test.tl holds it).
local passthrough: {string:string} = {
  run = "the words after the file are its program's argv",
  standalone = "the words after the file are its program's argv",
  eval = "the words after the chunk are its `...`",
  version = "it prints one line and no verdict",
}

--- A command line with one argument more than each verb takes, or why
--- the verb has none: it takes any number of words.
local surplus: {string:{string} | string} = {
  test = "takes any number of selectors",
  fix = "takes any number of paths",
  build = "takes any number of paths",
  db = "takes any number of paths",
  docs = "takes any number of words to search for",
  uses = "takes a symbol and any number of paths",
  todos = "takes any number of paths and words",
  sql = { "sql", "SELECT 1", "extra" },
  help = { "help", "test", "fix" },
  bom = { "bom", "extra" },
  refresh = { "refresh", "-o", "out", "nosuch" },
}

--- The vendored bundle, which `refresh` reads with no network; the
--- tree's root is where a test module loads.
local bundle = assert(Fs.absolute("vendor/cacert/cacert.pem"))

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
  sql = { pass = { "sql", "SELECT 1" }, fail = { "sql", "SELECT * FROM zzqqx_no_table" } },
  help = { pass = { "help" }, fail = "help has nothing to fail on but its command line" },
  bom = { pass = { "bom" }, fail = { "bom", "--json", "no/such/directory/bom.json" } },
  refresh = { pass = { "refresh", "-o", "out", "--cacert", bundle },
    fail = { "refresh", "-o", "out", "--cacert", "no/such/cacert.pem" } },
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
  elseif args[1] == "todos" and not asks_help then
    return "it starts git to ask who wrote each line"
  elseif args[1] == "--standalone" or (args[1] ~= nil and args[1]:match("%.tl$")) then
    return "a file run loads its tree's modules into the process"
  end
  return nil
end

local function cosmic(dir: string, args: {string}): invoke.Result
  if needs_a_process(args) == nil then
    return invoke.run(args, { cwd = dir })
  end
  local argv: {string} = { (assert(Proc.executable())) }
  for _, word in ipairs(args) do argv[#argv + 1] = word end
  local result, trouble = Child.run(argv, {
    cwd = dir, env = Env.all(), stdout = "capture", stderr = "capture",
    timeout_ms = 60000,
  })
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
local function expect(dir: string, verb: string, args: {string}, code: integer): invoke.Result
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

--- Whether `verb`'s cases run in this process: a test that starts one
--- never stands, so those that must are tests of their own.
local function in_process(verb: string): boolean
  return needs_a_process({ verb }) == nil
end

local function started(verb: string): boolean
  return not in_process(verb)
end

local function refuses_what_it_does_not_take(tmp: string, which: function(string): boolean)
  local tree = write_tree(tmp)
  for _, verb in ipairs(Cli.order) do
    if passthrough[verb] == nil and which(verb) then
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

local function test_every_verb_refuses_what_it_does_not_take(tmp: string)
  refuses_what_it_does_not_take(tmp, in_process)
end

local function test_every_started_verb_refuses_what_it_does_not_take(tmp: string)
  refuses_what_it_does_not_take(tmp, started)
end

local function ends_in_a_verdict(tmp: string, which: function(string): boolean)
  local tree = write_tree(tmp)
  -- `db` passes once the tree has a database.
  local _ = expect(tree, "build", { "build" }, 0)
  for _, verb in ipairs(Cli.order) do
    local case = cases[verb]
    if case ~= nil and which(verb) then
      local _ = expect(tree, verb, case.pass, 0)
      local fail = case.fail
      if fail is {string} then
        local dir = case.fail_in ~= nil and tmp .. "/" .. case.fail_in or tree
        local _ = expect(dir, verb, fail, 1)
      end
    end
  end
end

local function test_every_verb_ends_in_a_verdict(tmp: string)
  ends_in_a_verdict(tmp, in_process)
end

local function test_every_started_verb_ends_in_a_verdict(tmp: string)
  ends_in_a_verdict(tmp, started)
end

local function test_a_mistyped_verb_is_named(tmp: string)
  local result = cosmic(tmp, { "tset" })
  local err = result.stderr or ""
  assert(result.code == 2, err)
  -- The whole of stderr: one line, prefixed once.
  assert(err == "cosmic: no such verb or file: tset; see `cosmic help`\n", err)
end

local function test_each_selector_must_match(tmp: string)
  local tree = write_tree(tmp)
  local result = cosmic(tree, { "test", "good", "nothing_here" })
  local err = result.stderr or ""
  assert(result.code == 1, err)
  assert(err:find("no test module matches: nothing_here", 1, true), err)
  assert(not err:find("good", 1, true), err)
end

local function test_help_takes_a_verb(tmp: string)
  local _ = expect(tmp, "help", { "help", "test" }, 0)
  local _ = expect(tmp, "help", { "test", "--help" }, 0)
  local _ = expect(tmp, "help", { "db", "-h" }, 0)
  local _ = expect(tmp, "help", { "help", "--standalone" }, 0)
  -- Anywhere on the verb's line, before a "--".
  local late = expect(tmp, "help", { "test", "good", "--jobs", "2", "--help" }, 0).stdout or ""
  assert(late:find("`cosmic test", 1, true), late)
  local _ = expect(tmp, "help", { "sql", "SELECT 1", "-h" }, 0)
  -- Not after a "--": there "-h" is the statement, which fails as SQL.
  local _ = expect(tmp, "sql", { "sql", "--", "-h" }, 1)
  local refused = expect(tmp, "help", { "help", "tset" }, 2)
  local out = refused.stdout or ""
  assert(out:find("help: FAIL (no such verb: tset)", 1, true), out)
end

local function test_help_lists_each_option_a_verb_parses(tmp: string)
  for verb, options in pairs(Cli.options) do
    local out = expect(tmp, "help", { "help", verb }, 0).stdout or ""
    for name, entry in pairs(options) do
      assert(entry is Flags.Option and entry.about ~= nil and entry.about ~= "",
        verb .. " " .. name .. " says nothing of what it does")
      local shown = entry.value ~= nil and name .. " <" .. entry.value .. ">" or name
      assert(out:find("\n  " .. shown .. " ", 1, true), verb .. ": " .. out)
    end
  end
  local all = expect(tmp, "help", { "help" }, 0).stdout or ""
  assert(all:find("\n  --jobs <n> ", 1, true), all)
  -- `cosmic docs` shows them under the verb's field too.
  -- Asked nothing, it lists the modules there are.
  local index = expect(tmp, "docs", { "docs" }, 0).stdout or ""
  assert(index:find("\ncosmic.fs  ", 1, true), index)
  local docs = expect(tmp, "docs", { "docs", "Cli.test" }, 0).stdout or ""
  assert(docs:find("\n  options:\n", 1, true) and docs:find("\n    --jobs <n> ", 1, true) and
    docs:find("\n    --all ", 1, true), docs)
  -- And a search finds a verb by what one of its options does, though
  -- no doc comment says it: "launcher" is only in `build --host`'s.
  local found = expect(tmp, "docs", { "docs", "native", "launcher" }, 0).stdout or ""
  assert(found:find("Cli.build", 1, true), found)
  -- Its words may be split between the prose and the options.
  local split = expect(tmp, "docs", { "docs", "timeout", "processor" }, 0).stdout or ""
  assert(split:find("Cli.test", 1, true), split)
  -- A word joined by "_" is those words in a row, as FTS5 reads it, and
  -- the verb's own name counts, as it does in the index.
  local joined = expect(tmp, "docs", { "docs", "COSMIC_TEST_TIMEOUT" }, 0).stdout or ""
  assert(joined:find("Cli.test", 1, true), joined)
  local named = expect(tmp, "docs", { "docs", "cli", "launcher" }, 0).stdout or ""
  assert(named:find("Cli.build", 1, true), named)
  -- A word neither holds finds no verb.
  local none = expect(tmp, "docs", { "docs", "launcher", "zzzqqq" }, 1).stdout or ""
  assert(not none:find("Cli.build", 1, true), none)
end

local function test_a_timeout_that_would_wrap_is_refused(tmp: string)
  local tree = write_tree(tmp)
  local result = expect(tree, "test", { "test", "--timeout", "99999999999999999", "good" }, 2)
  local err = result.stderr or ""
  assert(err:find("--timeout must be at most", 1, true), err)
end

local function test_help_of_a_verb_is_that_verb_alone(tmp: string)
  local one = expect(tmp, "help", { "help", "test" }, 0).stdout or ""
  assert(one:find("`cosmic test ", 1, true), one)
  assert(not one:find("`cosmic fix ", 1, true), one)
  assert(not one:find("cosmic -- a runtime", 1, true), one)
  local all = expect(tmp, "help", { "help" }, 0).stdout or ""
  assert(all:find("`cosmic test ", 1, true), all)
  assert(all:find("`cosmic fix ", 1, true), all)
  local e = expect(tmp, "help", { "help", "-e" }, 0).stdout or ""
  assert(e:find("`cosmic -e", 1, true), e)
  assert(not e:find("`cosmic test ", 1, true), e)
  -- Every verb's help is one entry, its synopsis first: one paragraph
  -- before the verdict, where the whole surface is a blank line apart.
  for _, verb in ipairs(Cli.order) do
    local out = expect(tmp, "help", { "help", verb }, 0).stdout or ""
    local body = out:match("^(.-)\n+help: ") or ""
    assert(body:sub(1, 8) == "`cosmic " and not body:find("\n\n", 1, true), verb .. ": " .. out)
  end
end

local function test_e_runs_a_lua_chunk(tmp: string)
  local said = cosmic(tmp, { "-e", "print(...)", "a", "b c" })
  assert(said.code == 0, said.stderr)
  assert(said.stdout == "a\tb c\n", said.stdout)
  assert(cosmic(tmp, { "-e", "return 3" }).code == 3)
  local raised = cosmic(tmp, { "-e", "error('boom')" })
  assert(raised.code == 1 and raised.stdout == "", raised.stdout)
  assert((raised.stderr or ""):find("-e:1: boom", 1, true), raised.stderr)
  local broken = cosmic(tmp, { "-e", "x =" })
  assert(broken.code == 1, broken.stderr)
  local bare = cosmic(tmp, { "-e" })
  assert(bare.code == 2, bare.stderr)
  assert((bare.stderr or ""):find("usage: cosmic -e", 1, true), bare.stderr)
  assert(cosmic(tmp, { "-e", "return nil" }).code == 0)
  assert(cosmic(tmp, { "-e", "return 3.0" }).code == 3)
  assert(cosmic(tmp, { "-e", "return 255" }).code == 255)
  for chunk, shown in pairs({ ["256"] = "256", ["-1"] = "-1", ["1.5"] = "1.5", ["true"] = "true",
    ["'text'"] = '"text"', ["{}"] = "table: " } as {string:string}) do
    local refused = cosmic(tmp, { "-e", "return " .. chunk })
    assert(refused.code == 2, chunk .. ": " .. tostring(refused.code))
    assert((refused.stderr or ""):find("-e returned " .. shown, 1, true), refused.stderr)
    assert((refused.stderr or ""):find("not an exit status 0-255", 1, true), refused.stderr)
  end
  local nothing, _ = Fs.exists(tmp .. "/o")
  assert(nothing == false, "-e wrote under o/")
end

local function test_a_file_run_refuses_an_exit_status_out_of_range(tmp: string)
  assert(Fs.write(tmp .. "/far.tl", "return function(): integer\n  return 300\nend\n"))
  local result = cosmic(tmp, { "far.tl" })
  assert(result.code == 2, result.stderr)
  assert(result.stderr == "cosmic: far.tl returned 300, not an exit status 0-255\n",
    result.stderr)
end

--- Text naming a whole number is that number, as `cosmic_tostatus`
--- reads a built program's answer (build/exit_status_test.tl).
local function test_a_file_run_that_returns_numeric_text_exits_with_it(tmp: string)
  assert(Fs.write(tmp .. "/text.tl", "return function(): string\n  return \"3\"\nend\n"))
  local result = cosmic(tmp, { "text.tl" })
  assert(result.code == 3, tostring(result.code) .. ": " .. tostring(result.stderr))
  assert(result.stderr == "", result.stderr)
  assert(cosmic(tmp, { "-e", "return ' 0x4 '" }).code == 4)
end

--- A directory's own `init.tl` is the module named for the directory,
--- as the build names it, not `<dir>.init`.
local function test_a_file_run_of_an_init_is_its_directory(tmp: string)
  assert(Fs.mkdirs(tmp .. "/lib"))
  assert(Fs.write(tmp .. "/lib/init.tl", "return function(): integer\n  return 3\nend\n"))
  local result = cosmic(tmp, { "lib/init.tl" })
  assert(result.code == 3, result.stderr)
end

--- A tree with two programs and a module that reads a file.
local function write_programs(tmp: string): string
  local tree = tmp .. "/programs"
  local main = "return function(): integer\n  return 0\nend\n"
  for _, name in ipairs({ "hi", "bye" }) do
    assert(Fs.mkdirs(tree .. "/cmd/" .. name))
    assert(Fs.write(tree .. "/cmd/" .. name .. "/main.tl", main))
  end
  assert(Fs.mkdirs(tree .. "/lib"))
  assert(Fs.write(tree .. "/lib/reader.tl", "local Fs = require(\"cosmic.fs\")\nreturn Fs.read\n"))
  return tree
end

local function test_build_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local one = expect(tree, "build", { "build", "./cmd/hi/" }, 0).stdout or ""
  assert(one:find("o/bin/hi,", 1, true) and not one:find("bye", 1, true), one)
  assert(Fs.exists(tree .. "/o/bin/hi"))
  assert(not Fs.exists(tree .. "/o/bin/bye"))
  local refused = expect(tree, "build", { "build", "cmd/hi", "lib" }, 1)
  assert((refused.stderr or ""):find("no cmd/<name>/main.tl under lib", 1, true), refused.stderr)
  local _ = expect(tree, "build", { "build", "cmd" }, 0)
  assert(Fs.exists(tree .. "/o/bin/bye"))
end

local function test_uses_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local _ = expect(tree, "build", { "build" }, 0)
  local narrowed = expect(tree, "uses", { "uses", "Fs.read", "lib" }, 0).stdout or ""
  assert(narrowed:find("lib/reader.tl:2:", 1, true), narrowed)
  assert(not narrowed:find("cosmic/", 1, true), narrowed)
  local all = expect(tree, "uses", { "uses", "Fs.read" }, 0).stdout or ""
  assert(all:find("lib/reader.tl:2:", 1, true), all)
  local none = expect(tree, "uses", { "uses", "Fs.read", "cmd" }, 1).stdout or ""
  assert(none:find("nothing under cmd refers to 'Fs.read'", 1, true), none)
end

local function test_db_takes_paths_to_narrow_it(tmp: string)
  local tree = write_programs(tmp)
  local _ = expect(tree, "build", { "build" }, 0)
  local narrowed = expect(tree, "db", { "db", "./lib/" }, 0).stdout or ""
  assert(narrowed:find("rows about lib in 2 databases", 1, true), narrowed)
  -- lib/reader.tl is one module and one staged file.
  assert(narrowed:find("\n +1  modules\n"), narrowed)
  assert(narrowed:find("\n +1  files\n"), narrowed)
  -- and one row of `parsed`, a table keyed only by its source's hash.
  assert(narrowed:find("\n +1  parsed\n"), narrowed)
  assert(not narrowed:find("builds, latest first", 1, true), narrowed)
  assert(not narrowed:find("pages", 1, true), narrowed)
  local whole = expect(tree, "db", { "db" }, 0).stdout or ""
  assert(whole:find("in 2 databases", 1, true) and whole:find("builds, latest first", 1, true),
    whole)
  local none = expect(tree, "db", { "db", "nowhere" }, 1).stdout or ""
  assert(none:find("no row is about nowhere", 1, true), none)
end
