--- `cosmic sandbox` (build/sandbox.tl), run in this process with its
--- start stood in for: what its command line asks of [`Child.start`],
--- and what it refuses before starting anything.
--- build/sandbox_tool_test.tl starts a program in a sandbox.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local sandbox = require("build.sandbox")
local sys = require("cosmic.sys")

local record Ran
  code: integer
  err: string
  argv: {string}
  opts: Child.Options
end

--- Runs the verb on `words`, its start answering nil and `refusal`,
--- and says what it asked to start.
local function run(words: {string}, refusal?: string): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "sandbox" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, err = "" }
  ran.code = sandbox.run(argv, {
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    start = function(command: {string}, opts: Child.Options): Child.Handle | nil, string
      ran.argv, ran.opts = command, opts
      return nil, refusal or "child: start: stood in"
    end,
  })
  return ran
end

local function has(list: {string}, wanted: string): boolean
  for _, item in ipairs(list or {}) do
    if item == wanted then return true end
  end
  return false
end

local function test_the_program_is_the_first_word_no_option_claims()
  local function slot(words: {string}): integer | nil
    local argv: {integer:string} = { [0] = "cosmic", [1] = "sandbox" }
    for index, word in ipairs(words) do argv[index + 1] = word end
    return sandbox.program_slot(argv)
  end
  assert(slot({ "ls", "-l" }) == 2)
  assert(slot({ "--read", "/a", "--offline", "ls", "--help" }) == 5)
  assert(slot({ "--read=/a", "ls" }) == 3)
  assert(slot({ "--", "--odd-name" }) == 3)
  assert(slot({ "--offline" }) == nil)
  assert(slot({ "--read", "/a", "--" }) == nil)
end

local function test_a_line_without_a_program_or_with_an_unknown_option_is_refused()
  for _, words in ipairs({ {}, { "--offline" }, { "--no-such", "ls" }, { "--read" },
    { "--read", "", "/bin/true" }, { "--", "" } }) do
    local ran = run(words)
    assert(ran.code == 2, table.concat(words, " ") .. ": " .. ran.err)
    assert(ran.argv == nil, "nothing starts")
    assert(ran.err:find("^cosmic: sandbox: "), ran.err)
  end
  assert(run({ "--no-such", "ls" }).err:find("--no-such", 1, true))
end

--- With no PATH, a bare name is looked for in /bin and /usr/bin, which
--- this test's sandbox has none of.
local function test_a_program_not_found_exits_127()
  local ran = run({ "zzqqx-no-such-program" })
  assert(ran.code == 127, ran.err)
  assert(ran.err:find("zzqqx-no-such-program: not found", 1, true), ran.err)
  assert(ran.argv == nil)
end

local function test_unveiled_the_program_and_the_paths_named_are_given(tmp: string)
  assert(Fs.write(tmp .. "/f", "x"))
  local ran = run({ "--read", tmp .. "/f", "--write", tmp, "--read", ".", "--offline", "/bin/true",
    "--help" })
  assert(ran.code == 125, ran.err)
  assert(ran.err:find("^cosmic: sandbox: child: start: stood in\n"), ran.err)
  assert(ran.argv[1] == "/bin/true" and ran.argv[2] == "--help" and #ran.argv == 2)
  local given = ran.opts.sandbox
  assert(given.offline == true and given.landlock == nil)
  assert(has(given.unveil.reads, "/bin/true") and has(given.unveil.reads, tmp .. "/f"))
  assert(has(given.unveil.writes, tmp) and #given.unveil.writes == 1)
  -- The working directory is among the paths given, as ".".
  assert(ran.opts.cwd == assert(sys.getcwd()), tostring(ran.opts.cwd))
end

local function test_unveiled_a_working_directory_not_given_is_left_for_the_root(tmp: string)
  assert(Fs.mkdirs(tmp .. "/elsewhere"))
  local ran = run({ "--read", tmp .. "/elsewhere", "/bin/true" })
  local here = assert(sys.getcwd())
  if here:sub(1, #tmp + 11) ~= tmp .. "/elsewhere" then
    assert(ran.opts.cwd == "/", tostring(ran.opts.cwd))
  end
end

local function test_a_relative_path_is_read_from_the_working_directory()
  local ran = run({ "--read", ".", "/bin/true" })
  assert(has(ran.opts.sandbox.unveil.reads, (assert(sys.getcwd()))))
end

local function test_landlocked_the_paths_are_a_ruleset_and_no_root_is_made(tmp: string)
  local ran = run({ "--landlock", "--read", tmp, "--write", tmp .. "/out", "--", "/bin/true", "-x" })
  local given = ran.opts.sandbox
  assert(given.unveil == nil and given.offline == false)
  assert(has(given.landlock.reads, "/bin/true") and has(given.landlock.reads, tmp))
  assert(has(given.landlock.writes, tmp .. "/out"))
  assert(ran.opts.process_group == false and ran.opts.cwd == nil)
  assert(ran.argv[2] == "-x")
end

--- A start that fails without `--system` names what it may lack.
local function test_a_start_that_fails_without_the_system_says_what_it_gives()
  local ran = run({ "/bin/true" })
  assert(ran.code == 125, ran.err)
  assert(ran.err:find("--system gives", 1, true), ran.err)
  assert(not run({ "--system", "/bin/true" }).err:find("--system gives", 1, true))
end

--- A path is given as named, its links unresolved, so the program finds
--- it by the name it was told.
local function test_a_path_through_a_link_is_given_by_its_own_name(tmp: string)
  assert(Fs.mkdirs(tmp .. "/real"))
  assert(sys.symlink("real", tmp .. "/link"))
  local ran = run({ "--read", tmp .. "/link/./", "--read", "rel//dir", "/bin/true" })
  assert(has(ran.opts.sandbox.unveil.reads, tmp .. "/link"))
  assert(has(ran.opts.sandbox.unveil.reads, assert(sys.getcwd()) .. "/rel/dir"))
end
