local Flags = require("cosmic.flags")

local spec: {string:boolean} = { ["--check"] = false, ["--jobs"] = true }

local function parsed(argv: {integer:string}): Flags.Parsed
  local got, why = Flags.parse(argv, 2, spec)
  assert(got ~= nil, why)
  return got
end

local function test_options_and_words_are_told_apart()
  local got = parsed({ "fix", "a.tl", "--check", "b.tl" })
  assert(got.set["--check"] and #got.words == 2)
  assert(got.words[1] == "a.tl" and got.words[2] == "b.tl")
  assert(next(got.values) == nil)
end

local function test_a_value_is_the_next_word_or_after_equals()
  assert(parsed({ "x", "--jobs", "4" }).values["--jobs"] == "4")
  assert(parsed({ "x", "--jobs=4" }).values["--jobs"] == "4")
  assert(parsed({ "x", "--jobs=" }).values["--jobs"] == "")
  assert(parsed({ "x", "--jobs", "-1" }).values["--jobs"] == "-1")
  assert(parsed({ "x", "--jobs=1", "--jobs=2" }).values["--jobs"] == "2")
end

local function test_a_double_dash_ends_the_options()
  local got = parsed({ "x", "--", "--check", "-" })
  assert(not got.set["--check"] and #got.words == 2 and got.words[1] == "--check")
  assert(parsed({ "x", "-" }).words[1] == "-")
end

local function test_mistakes_are_refused_with_why()
  local cases: {{string}} = {
    { "--chek", "no such option: --chek" },
    { "-c", "no such option: -c" },
    { "--check=yes", "--check takes no value" },
    { "--jobs", "--jobs needs a value" },
    { "--nope=1", "no such option: --nope" },
  }
  for _, next_word in ipairs({ "--check", "--" }) do
    local got, why = Flags.parse({ "x", "--jobs", next_word }, 2, spec)
    assert(got == nil and why == "--jobs needs a value", why)
  end
  for _, case in ipairs(cases) do
    local got, why = Flags.parse({ "x", case[1] }, 2, spec)
    assert(got == nil and why == case[2], why)
  end
end

local function test_reading_starts_at_the_slot_given()
  local got = parsed({ "x", "--check" })
  assert(got.set["--check"])
  local all = assert(Flags.parse({ "--check", "w" }, 1, spec))
  assert(all.set["--check"] and all.words[1] == "w")
end

local function test_a_spec_names_only_options()
  for _, key in ipairs({ "x", "-", "--" }) do
    assert(not pcall(Flags.parse, { "x" }, 1, { [key] = false }), key)
  end
  local short = assert(Flags.parse({ "x", "-v", "-n", "3" }, 2, { ["-v"] = false, ["-n"] = true }))
  assert(short.set["-v"] and short.values["-n"] == "3")
end

local function test_a_repeated_option_keeps_every_value_and_its_order()
  local got = parsed({ "x", "--jobs=1", "--check", "--jobs", "2", "--check" })
  assert(got.values["--jobs"] == "2")
  local jobs = got.all["--jobs"]
  assert(#jobs == 2 and jobs[1] == "1" and jobs[2] == "2")
  assert(table.concat(got.given, " ") == "--jobs --check --jobs --check")
  assert(got.all["--check"] == nil)
end

local short: {string:boolean} = { ["-v"] = false, ["-q"] = false, ["-n"] = true }

local function test_one_letter_options_cluster_and_take_the_rest_as_a_value()
  local got = assert(Flags.parse({ "-vq", "a" }, 1, short))
  assert(got.set["-v"] and got.set["-q"] and got.words[1] == "a")
  assert(assert(Flags.parse({ "-n3" }, 1, short)).values["-n"] == "3")
  got = assert(Flags.parse({ "-vn3", "a" }, 1, short))
  assert(got.set["-v"] and got.values["-n"] == "3" and got.words[1] == "a")
  got = assert(Flags.parse({ "-vn", "3", "a" }, 1, short))
  assert(got.values["-n"] == "3" and got.words[1] == "a")
  assert(assert(Flags.parse({ "-nvq" }, 1, short)).values["-n"] == "vq")
  assert(assert(Flags.parse({ "-n=3" }, 1, short)).values["-n"] == "=3")
  assert(table.concat(assert(Flags.parse({ "-vqv" }, 1, short)).given, " ") == "-v -q -v")
end

local function test_a_spec_may_name_a_one_dash_option_whole()
  local whole: {string:boolean} = { ["-v"] = false, ["-verbose"] = false }
  local got = assert(Flags.parse({ "-verbose" }, 1, whole))
  assert(got.set["-verbose"] and not got.set["-v"])
end

local function test_a_cluster_is_refused_with_the_letter_at_fault()
  local cases: {{string}} = {
    { "-vx", "no such option: -x in -vx" },
    { "-xv", "no such option: -xv" },
    { "-v=1", "-v takes no value" },
    { "-vn", "-n needs a value" },
  }
  for _, case in ipairs(cases) do
    local got, why = Flags.parse({ case[1] }, 1, short)
    assert(got == nil and why == case[2], why)
  end
end

local function test_a_value_is_never_an_option_the_spec_names()
  for _, next_word in ipairs({ "-v", "-vq", "--", "-n4" }) do
    local got, why = Flags.parse({ "-n", next_word }, 1, short)
    assert(got == nil and why == "-n needs a value", next_word)
  end
  local got, why = Flags.parse({ "x", "--jobs", "--check=1" }, 2, spec)
  assert(got == nil and why == "--jobs needs a value", why)
  assert(assert(Flags.parse({ "-n", "-1" }, 1, short)).values["-n"] == "-1")
  assert(assert(Flags.parse({ "-n", "-" }, 1, short)).values["-n"] == "-")
end

local function test_dispatch_runs_the_command_with_its_own_options()
  local ran: {string} = {}
  local commands: {string:Flags.Command} = {
    build = {
      spec = { ["--jobs"] = true },
      run = function(got: Flags.Parsed): integer
        ran[#ran + 1] = "build " .. got.values["--jobs"] .. " " .. got.words[1]
        return 3
      end,
    },
    clean = {
      run = function(got: Flags.Parsed): integer
        ran[#ran + 1] = "clean " .. #got.words
        return 0
      end,
    },
  }
  local code, why = Flags.dispatch({ [0] = "prog", "build", "--jobs=2", "a" }, 1, commands)
  assert(code == 3 and why == "", why)
  assert(Flags.dispatch({ "prog", "clean" }, 2, commands) == 0)
  assert(ran[1] == "build 2 a" and ran[2] == "clean 0", table.concat(ran, "|"))
  local refusals: {{string}} = {
    { nil, "needs a command: build, clean" },
    { "bulid", "no such command: bulid" },
    { "--jobs", "no such command: --jobs" },
  }
  for _, case in ipairs(refusals) do
    local refused, trouble = Flags.dispatch({ case[1] }, 1, commands)
    assert(refused == nil and trouble == case[2], trouble)
  end
  local refused, trouble = Flags.dispatch({ "clean", "--jobs=2" }, 1, commands)
  assert(refused == nil and trouble == "clean: no such option: --jobs", trouble)
  assert(#ran == 2)
end
