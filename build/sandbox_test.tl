--- `cosmic sandbox` (build/sandbox.tl), run in this process with the start
--- stood in for: what its command line asks of [`Child.run`], what it
--- refuses before starting anything, how it reports the program's end,
--- and that every field of a policy has a flag.
--- build/sandbox_tool_test.tl starts programs in a sandbox.

local Child = require("cosmic.child")
local Cli = require("cosmic.cli")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Sandbox = require("cosmic.sandbox")
local Shape = require("cosmic.shape")
local sys = require("cosmic.sys")
local sandbox = require("build.sandbox")

local record Ran
  code: integer
  err: string
  --- What it asked to start: nil when it started nothing.
  argv: {string}
  opts: Child.Options
end

--- What a stood-in start answers: a result, or nil and why.
local record Answer
  result: Child.Result
  why: string
end

local function finished(code: integer | nil, signal?: integer, timed_out?: boolean): Child.Result
  return { code = code, signal = signal, ok = code == 0, timed_out = timed_out or false,
    captured = {}, truncated = false }
end

--- Runs the verb on `words`, its start answering `answer` (the program
--- exits 0 when none is given), and says what it asked to start.
local function run(words: {string}, answer?: Answer): Ran
  local argv: {integer:string} = { [0] = "cosmic", [1] = "sandbox" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local ran: Ran = { code = -1, err = "" }
  local given = answer or { result = finished(0) }
  ran.code = sandbox.run(argv, {
    err = function(line: string) ran.err = ran.err .. line .. "\n" end,
    run = function(command: {string}, opts: Child.Options): Child.Result | nil, string
      ran.argv, ran.opts = command, opts
      if given.result == nil then return nil, given.why end
      return given.result, ""
    end,
  })
  return ran
end

local function refused(words: {string}): Ran
  local ran = run(words)
  assert(ran.code == 2, table.concat(words, " ") .. ": " .. ran.code .. " " .. ran.err)
  assert(ran.argv == nil, "nothing starts")
  assert(ran.err:find("^cosmic: sandbox: "), ran.err)
  return ran
end

--- The letters `policy` grants `path`, or "".
local function letters(policy: Sandbox.Policy, path: string): string
  for _, grant in ipairs(policy.grants or {}) do
    if grant.path == path then return grant.letters end
  end
  return ""
end

local function same(got: {string}, want: {string})
  assert(table.concat(got or {}, "|") == table.concat(want, "|"),
    table.concat(got or {}, "|") .. " is not " .. table.concat(want, "|"))
end

local function test_each_option_sets_its_field()
  local ran = run({ "--read", "a", "--run", "b", "--write", "c", "--path", "rwxc:d", "--", "prog" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  local policy = ran.opts.policy
  assert(letters(policy, "a") == "r" and letters(policy, "b") == "rx", letters(policy, "b"))
  assert(letters(policy, "c") == "rwc" and letters(policy, "d") == "rwxc")
  same(ran.argv, { "prog" })

  ran = run({ "--system", "--cosmic", "--isolate", "file", "--isolate", "proc", "--promise", "fork",
    "--promise", "nest", "--connect", "github.com:443", "--loopback", "127.0.0.2", "--env", "HOME",
    "--env", "TERM", "--set-env", "LANG=C", "--set-env", "EMPTY=", "--tmp", "prog" })
  policy = ran.opts.policy
  same(policy.profiles, { "system", "cosmic" })
  same(policy.isolate, { "file", "proc" })
  same(policy.promises, { "fork", "nest" })
  same(policy.connect, { "github.com:443" })
  same(policy.loopback, { "127.0.0.2" })
  same(policy.env, { "HOME", "TERM" })
  assert(policy.set_env.LANG == "C" and policy.set_env.EMPTY == "" and policy.tmp == true)

  ran = run({ "--open-files", "64", "--file-bytes", "0", "--cpu-seconds", "9", "--processes", "5",
    "--fd", "3", "--fd", "7", "--timeout", "30", "prog" })
  local limits = ran.opts.policy.limits
  assert(limits.open_files == 64 and limits.file_bytes == 0 and limits.cpu_seconds == 9 and
      limits.processes == 5)
  assert(ran.opts.fds[3] == 3 and ran.opts.fds[7] == 7 and ran.opts.fds[4] == nil)
  assert(ran.opts.timeout_ns == 30000000000, tostring(ran.opts.timeout_ns))
  assert(ran.opts.env == nil, "the policy's environment alone")
  assert(ran.opts.cwd == nil, "this process's own directory")

  ran = run({ "--cwd", "work", "--read", ".", "prog" })
  assert(ran.code == 0 and ran.opts.cwd == "work" and letters(ran.opts.policy, ".") == "r", ran.err)
end

local function test_cwd_is_given_once()
  local ran = refused({ "--cwd", "a", "--cwd", "b", "prog" })
  assert(ran.err:find("--cwd is given more than once", 1, true), ran.err)
end

local function test_a_policy_with_no_option_is_the_empty_one()
  local ran = run({ "prog" })
  assert(ran.code == 0)
  local policy = ran.opts.policy
  assert(#(policy.grants or {}) == 0 and #(policy.profiles or {}) == 0 and not policy.tmp)
  assert(ran.opts.timeout_ns == nil and next(ran.opts.fds) == nil)
end

local function test_a_value_is_the_next_word_or_follows_an_equals_sign()
  local ran = run({ "--read=a b", "--set-env=PATH=/x=y", "--timeout=5", "--path=r:c:d", "prog" })
  local policy = ran.opts.policy
  assert(letters(policy, "a b") == "r" and letters(policy, "c:d") == "r", "a path may hold a colon")
  assert(policy.set_env.PATH == "/x=y" and ran.opts.timeout_ns == 5000000000)
end

local function test_the_program_is_the_first_word_no_option_claims()
  local function slot(words: {string}): integer | nil
    local argv: {integer:string} = { [0] = "cosmic", [1] = "sandbox" }
    for index, word in ipairs(words) do argv[index + 1] = word end
    return sandbox.program_slot(argv)
  end
  assert(slot({ "ls", "-l" }) == 2)
  assert(slot({ "--read", "/a", "--tmp", "ls", "--help" }) == 5)
  assert(slot({ "--read=/a", "ls" }) == 3)
  assert(slot({ "--", "--odd-name" }) == 3)
  assert(slot({ "--read", "--", "ls" }) == 4, "an option's value is the next word")
  assert(slot({ "--tmp" }) == nil)
  assert(slot({ "--read", "/a", "--" }) == nil)
  assert(slot({}) == nil)
end

local function test_words_after_the_program_are_the_programs()
  local ran = run({ "--system", "ls", "--read", "x", "-l", "--", "--tmp" })
  same(ran.argv, { "ls", "--read", "x", "-l", "--", "--tmp" })
  assert(#(ran.opts.policy.grants or {}) == 0 and not ran.opts.policy.tmp)
  ran = run({ "--", "--read", "x" })
  same(ran.argv, { "--read", "x" })
  ran = run({ "--read", "a", "--", "prog", "--", "b" })
  same(ran.argv, { "prog", "--", "b" })
  assert(letters(ran.opts.policy, "a") == "r")
  ran = run({ "prog", "" })
  same(ran.argv, { "prog", "" })
end

local function test_a_line_without_a_program_or_with_an_unknown_option_is_refused()
  for _, words in ipairs({ {}, { "--tmp" }, { "--read", "a" }, { "--read", "a", "--" }, { "--" } }) do
    assert(refused(words).err:find("give a program", 1, true))
  end
  assert(refused({ "--no-such", "ls" }).err:find("--no-such", 1, true))
  assert(refused({ "-x", "ls" }).err:find("-x", 1, true))
  assert(refused({ "--read" }).err:find("--read needs a value", 1, true))
  assert(refused({ "--tmp=1", "ls" }).err:find("--tmp takes no value", 1, true))
  assert(refused({ "--read", "--tmp", "ls" }).err:find("--read needs a value", 1, true))
end

local function test_user_names_the_user_and_group_by_number()
  local ran = run({ "--user", "1000", "prog" })
  assert(ran.code == 0 and ran.opts.policy.user == 1000 and ran.opts.policy.group == nil, ran.err)
  ran = run({ "--user=1000:100", "prog" })
  assert(ran.opts.policy.user == 1000 and ran.opts.policy.group == 100, ran.err)
  for _, given in ipairs({ "0", "me", "1000:", ":100", "1000:0", "4294967295", "1:2:3" }) do
    local why = refused({ "--user", given, "prog" }).err
    assert(why:find("--user takes UID or UID:GID", 1, true), given .. ": " .. why)
  end
  assert(refused({ "--user", "1", "--user", "2", "prog" }).err:find("more than once", 1, true))
end

local function test_a_number_is_a_whole_one_in_range()
  for _, case in ipairs({
      { "--open-files", "0" }, { "--open-files", "ten" }, { "--open-files", "1.5" },
      { "--open-files", "-1" }, { "--file-bytes", "-1" }, { "--cpu-seconds", "0" },
      { "--processes", "0" }, { "--processes", "99999999999999999999" },
      { "--open-files", "1", "--open-files", "2" },
      { "--fd", "2" }, { "--fd", "256" }, { "--fd", "x" },
      { "--timeout", "0" }, { "--timeout", "1.5" }, { "--timeout", "99999999999" },
      { "--timeout", "1", "--timeout", "2" },
  }) do
    local words: {string} = {}
    for _, word in ipairs(case) do words[#words + 1] = word end
    words[#words + 1] = "prog"
    local ran = refused(words)
    assert(ran.err:find(case[1], 1, true), ran.err)
  end
end

local function test_a_path_names_its_letters_and_the_decoder_judges_them()
  local ran = refused({ "--path", "xr:.", "prog" })
  assert(ran.err:find("rwxcu", 1, true) and ran.err:find("/grants/0/letters", 1, true), ran.err)
  assert(not ran.err:find("sandbox: sandbox:", 1, true), ran.err)
  assert(refused({ "--path", "z:.", "prog" }).err:find("letters", 1, true))
  assert(refused({ "--path", ":.", "prog" }).err:find("letters", 1, true))
  assert(refused({ "--path", "rw", "prog" }).err:find("LETTERS:PATH", 1, true))
  assert(refused({ "--path", "r:", "prog" }).err:find("LETTERS:PATH", 1, true))
  assert(refused({ "--read", "", "prog" }).err:find("/grants/0/path", 1, true))
  assert(refused({ "--read", "../x", "prog" }).err:find("..", 1, true))
end

local function test_the_other_values_are_the_decoders_too()
  assert(refused({ "--isolate", "net", "prog" }).err:find("/isolate/0", 1, true))
  assert(refused({ "--promise", "all", "prog" }).err:find("/promises/0", 1, true))
  assert(refused({ "--connect", "nohost", "prog" }).err:find("/connect/0", 1, true))
  assert(refused({ "--loopback", "10.0.0.1", "prog" }).err:find("/loopback/0", 1, true))
  assert(refused({ "--set-env", "NOVALUE", "prog" }).err:find("NAME=VALUE", 1, true))
  assert(refused({ "--set-env", "A=1", "--set-env", "A=2", "prog" }).err:find("two values", 1, true))
  assert(refused({ "--env", "A=B", "prog" }).err:find("/env/0", 1, true))
end

local function test_a_connect_is_the_starts_to_serve_and_its_failure_is_the_starts(tmp: string)
  assert(Fs.write(tmp .. "/there", "x") and sys.chmod(tmp .. "/there", 493))
  local ran = run({ "--connect", "github.com:443", tmp .. "/there" },
    { why = "child: start: sandbox: relay: the relay ended (status 1) before it served" })
  assert(ran.code == 125, ran.code .. ran.err)
  assert(ran.err:find("relay: the relay ended", 1, true), ran.err)
  same(ran.opts.policy.connect, { "github.com:443" })
end

--- Runs the verb on `words` with the relay's client stood in for: the words
--- it was given, or nil when it was not run, and the verb's status.
local function client_of(words: {string}): {string} | nil, integer
  local argv: {integer:string} = { [0] = "cosmic", [1] = "sandbox" }
  for index, word in ipairs(words) do argv[index + 1] = word end
  local given: {string} | nil
  local started = false
  local code = sandbox.run(argv, {
    err = function(_: string) end,
    run = function(_: {string}, _: Child.Options): Child.Result | nil, string
      started = true
      return finished(0), ""
    end,
    connect = function(args: {string}): integer
      given = args
      return 42
    end,
  })
  assert(not started or given == nil, "the client and a program are not both run")
  return given, code
end

local function test_a_connect_right_after_the_verb_is_the_relays_client()
  local given, code = client_of({ "connect", "github.com", "22" })
  same(given, { "github.com", "22" })
  assert(code == 42, "its status is the verb's: " .. code)
  same(client_of({ "connect" }), {})
  -- Only the bare word after the verb: every other place is a program's.
  assert(client_of({ "--system", "connect", "github.com", "22" }) == nil, "after an option it is a program")
  assert(client_of({ "--", "connect", "github.com", "22" }) == nil, "after -- it is a program")
  assert(client_of({ "prog", "connect", "github.com", "22" }) == nil, "after a program it is an argument")
  assert(run({ "--", "connect" }).argv[1] == "connect", "a program of that name is still run")
  same(run({ "--", "connect", "a", "b" }).argv, { "connect", "a", "b" })
  same(run({ "--cosmic", "connect" }).argv, { "connect" })
end

local function test_the_relays_decision_lines_go_to_the_verbs_standard_error()
  assert(run({ "--connect", "github.com:443", "prog" }).opts.relay_log == "inherit")
end

local function test_the_programs_end_is_the_exit_status()
  assert(run({ "p" }, { result = finished(0) }).code == 0)
  assert(run({ "p" }, { result = finished(3) }).code == 3)
  assert(run({ "p" }, { result = finished(255) }).code == 255)
  local killed = run({ "p" }, { result = finished(nil, 9) })
  assert(killed.code == 137 and killed.err == "", killed.err)
  assert(run({ "p" }, { result = finished(nil, 15) }).code == 143)
  local late = run({ "--timeout", "2", "p" }, { result = finished(nil, 15, true) })
  assert(late.code == 124 and late.err:find("timed out after 2 seconds", 1, true), late.err)
  local quiet = run({ "p" }, { result = finished(0) })
  assert(quiet.err == "", "nothing is said when the program starts")
end

local function test_a_start_that_fails_exits_125_with_the_reason(tmp: string)
  assert(Fs.write(tmp .. "/there", "x") and sys.chmod(tmp .. "/there", 493))
  local ran = run({ tmp .. "/there" }, { why = "child: start: Landlock is not available" })
  assert(ran.code == 125 and ran.err == "cosmic: sandbox: child: start: Landlock is not available\n",
    ran.code .. ran.err)
  same(ran.argv, { tmp .. "/there" })
end

local function test_a_program_that_is_not_there_exits_127(tmp: string)
  local ran = run({ tmp .. "/absent" },
    { why = "child: start: sandbox: " .. tmp .. "/absent: No such file or directory" })
  assert(ran.code == 127, ran.code .. ran.err)
  assert(ran.err:find("No such file", 1, true))
  ran = run({ "zzqqx-no-such-program" }, { why = "child: start: zzqqx-no-such-program: not found" })
  assert(ran.code == 127, ran.code .. ran.err)
end

local function test_127_is_only_for_a_failure_that_is_the_program_not_found(tmp: string)
  local ran = run({ "zzqqx-no-such-program" }, { why = "child: start: cwd \"/x\" does not exist" })
  assert(ran.code == 125 and ran.err:find("cwd", 1, true), ran.code .. ran.err)
  ran = run({ tmp .. "/absent" }, { why = "child: start: grant /y: No such file or directory" })
  assert(ran.code == 125, ran.code .. ran.err)
end

local function test_a_program_that_cannot_be_run_exits_126(tmp: string)
  assert(Fs.write(tmp .. "/plain", "x"))
  assert(sys.chmod(tmp .. "/plain", 420))
  local ran = run({ tmp .. "/plain" }, { why = "child: start: Permission denied" })
  assert(ran.code == 126 and ran.err:find("Permission denied", 1, true), ran.code .. ran.err)
  -- Where it can run, a failure is the start's.
  assert(Fs.write(tmp .. "/runs", "x"))
  assert(sys.chmod(tmp .. "/runs", 493))
  assert(run({ tmp .. "/runs" }, { why = "child: start: sandbox: not granted" }).code == 125)
end

local function test_a_relative_program_is_judged_from_cwd(tmp: string)
  assert(Fs.mkdirs(tmp .. "/work"))
  assert(Fs.write(tmp .. "/work/plain", "x") and sys.chmod(tmp .. "/work/plain", 420))
  local ran = run({ "--cwd", tmp .. "/work", "./plain" }, { why = "child: start: Permission denied" })
  assert(ran.code == 126, ran.code .. ran.err)
end

local function test_childs_hint_about_a_path_search_is_left_out()
  local ran = run({ "zzqqx-no-such-program" }, { why = "child: start: grant /nope: No such file or " ..
      "directory: \"zzqqx-no-such-program\" is run as a path, with no PATH search; " ..
      "Proc.find(\"zzqqx-no-such-program\") answers where a shell would find it" })
  assert(ran.code == 125, ran.code .. ran.err)
  assert(ran.err == "cosmic: sandbox: child: start: grant /nope: No such file or directory\n", ran.err)
end

--- `--database` names the file the policy runs the program on, resolved
--- against `--cwd`; with no command it is this program that runs.
local function test_database_sets_the_policys_database(tmp: string)
  assert(Fs.mkdirs(tmp .. "/work") and Fs.write(tmp .. "/work/p.db", "not a database\n"))
  -- The policy holds the real path.
  local real = assert(sys.realpath(tmp .. "/work/p.db"))
  local ran = run({ "--database", tmp .. "/work/p.db", "--", "prog", "a" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.opts.policy.database.path == real, tostring(ran.opts.policy.database.path))
  same(ran.argv, { "prog", "a" })
  ran = run({ "--cwd", tmp .. "/work", "--database=p.db" })
  assert(ran.code == 0 and ran.err == "", ran.err)
  assert(ran.opts.policy.database.path == real, tostring(ran.opts.policy.database.path))
  same(ran.argv, { (assert(Proc.executable())) })
  local missing = refused({ "--database", tmp .. "/absent.db", "prog" })
  assert(missing.err:find("absent.db", 1, true), missing.err)
end

--- Each of the three options names the database the program runs on, so
--- no two go together, and `--closure` takes this program and a script.
local function test_the_database_options_are_refused_where_they_conflict()
  local function refusing(words: {string}, needle: string)
    local ran = refused(words)
    assert(ran.err:find(needle, 1, true), table.concat(words, " ") .. ": " .. ran.err)
  end
  refusing({ "--closure", "--modules", "a", "--", "prog", "x.tl" }, "--closure and --modules are exclusive")
  refusing({ "--closure", "--database", "d", "--", "prog", "x.tl" }, "--closure and --database are exclusive")
  refusing({ "--modules", "a", "--database", "d", "prog" }, "--modules and --database are exclusive")
  refusing({ "--closure", "--modules", "a", "--database", "d", "prog", "x.tl" },
    "--closure and --modules and --database are exclusive")
  refusing({ "--closure", "--cosmic", "--", "prog", "x.tl" }, "--closure and --cosmic are exclusive")
  refusing({ "--closure" }, "--closure runs a script")
  refusing({ "--closure", "--", "prog" }, "--closure runs a script")
  refusing({ "--database", "a", "--database", "b", "prog" }, "--database is given more than once")
  refusing({ "--modules", "a", "--modules", "b", "prog" }, "--modules is given more than once")
  refusing({ "--modules", "a,,b", "prog" }, "--modules takes module names")
  refusing({ "--modules", "", "prog" }, "--modules takes module names")
  -- After the program it is the program's own.
  same(run({ "prog", "--closure" }).argv, { "prog", "--closure" })
end

--- The fields of [`Sandbox.Policy`], from its declaration.
local POLICY <const> = Shape.record_of("cosmic.sandbox.Policy")

--- Words that set each field of the policy and of its limits, to a value
--- the test reads back. A field added to the record fails the test below
--- until it has a flag and a line here.
local samples <const>: {string:{string}} = {
  profiles = { "--system" }, grants = { "--read", "x" }, isolate = { "--isolate", "proc" },
  promises = { "--promise", "fork" }, connect = { "--connect", "h:1" },
  loopback = { "--loopback", "127.0.0.2" }, env = { "--env", "X" },
  set_env = { "--set-env", "X=1" }, tmp = { "--tmp" },
  open_files = { "--open-files", "5" }, file_bytes = { "--file-bytes", "5" },
  cpu_seconds = { "--cpu-seconds", "5" }, processes = { "--processes", "5" },
  user = { "--user", "5" }, group = { "--user", "5:6" },
}

--- The fields no flag sets, each with why.
local exempt <const>: {string:string} = {
  set_env_digests = "what encode writes in place of set_env's values; a policy that holds one " ..
    "and no value cannot start a program, so a command line has no use for it",
  database = "--database, --modules and --closure each name the database, and set it only once " ..
    "it is sealed or resolved (test_database_sets_the_policys_database)",
}

--- The options that set no field of the policy by themselves: the descriptors handed over and the
--- wall-clock limit, and the ones that give a field another option gives (checked in
--- test_each_option_sets_its_field).
local others <const>: {string:boolean} = {
  ["--fd"] = true, ["--timeout"] = true, ["--cwd"] = true,
  ["--run"] = true, ["--write"] = true, ["--path"] = true, ["--cosmic"] = true,
  ["--database"] = true, ["--modules"] = true, ["--closure"] = true,
}

--- The policy the verb builds from `words` and a program.
local function policy_after(words: {string}): {string:any}
  local line: {string} = {}
  for _, word in ipairs(words) do line[#line + 1] = word end
  line[#line + 1] = "prog"
  local ran = run(line)
  assert(ran.code == 0, words[1] .. ": " .. ran.err)
  return ran.opts.policy as {string:any}
end

--- Whether a field holds something: a non-empty list or map, or a value.
local function holds(value: any): boolean
  if type(value) == "table" then return next(value as {any:any}) ~= nil end
  return value ~= nil and value ~= false
end

local function test_every_policy_field_has_a_flag()
  assert(POLICY.spec.kind == "record" and #POLICY.spec.names > 0)
  local seen: {string:boolean} = {}
  for _, name in ipairs(POLICY.spec.names) do
    if exempt[name] == nil and name ~= "limits" then
      local words = samples[name]
      assert(words ~= nil, "Policy." .. name .. " has no flag: add one to cosmic sandbox and to " ..
          "Cli.verbs.sandbox.spec, and a sample here")
      assert(Cli.verbs.sandbox.spec[words[1]] ~= nil, words[1] .. " is not in the spec")
      seen[words[1]] = true
      assert(holds(policy_after(words)[name]), words[1] .. " does not set Policy." .. name)
    end
  end
  local limits = POLICY.spec.fields.limits
  assert(limits ~= nil and limits.kind == "record" and #limits.names > 0)
  for _, name in ipairs(limits.names) do
    local words = samples[name]
    assert(words ~= nil, "Policy.limits." .. name .. " has no flag: add one to cosmic sandbox " ..
        "and to Cli.verbs.sandbox.spec, and a sample here")
    seen[words[1]] = true
    local set = (policy_after(words).limits as {string:any})
    assert(set ~= nil and set[name] == 5, words[1] .. " does not set Policy.limits." .. name)
  end
  -- A grant's path and letters are one option's. `from` has none: it needs
  -- isolate file and names a host path; it waits on policy files (the
  -- design's Roadmap).
  for _, name in ipairs(POLICY.spec.fields.grants.of.names) do
    assert(name == "path" or name == "letters" or name == "from", "Policy.grants[]." .. name ..
        " has no flag: add one, and say so here")
  end
  for flag in pairs(Cli.verbs.sandbox.spec) do
    assert(seen[flag] or others[flag], flag .. " sets no field of the policy")
  end
  for name in pairs(samples) do
    assert(Cli.verbs.sandbox.spec[samples[name][1]] ~= nil, name .. ": no such flag")
  end
end
