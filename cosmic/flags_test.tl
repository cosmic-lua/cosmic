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
    assert(got == nil and why == "--jobs needs a value, not " .. next_word ..
      "; give one that begins with \"-\" as --jobs=" .. next_word, why)
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
  for _, key in ipairs({ "x", "-", "--", "--a=b", "-=" }) do
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
  whole["-e"] = false
  got = assert(Flags.parse({ "-ve" }, 1, whole))
  assert(got.set["-v"] and got.set["-e"] and not got.set["-verbose"])
  whole["-é"] = false
  assert(assert(Flags.parse({ "-é" }, 1, whole)).set["-é"])
  local _, why = Flags.parse({ "-vé" }, 1, whole)
  assert(why == "no such option: -vé", why)
end

local function test_a_cluster_is_refused_with_the_letter_at_fault()
  local cases: {{string}} = {
    { "-vx", "no such option: -x in -vx" },
    { "-xv", "no such option: -xv" },
    { "-v=1", "-v takes no value" },
    { "-v-q", "no such option: -v-q" },
    { "-vn", "-n needs a value" },
  }
  for _, case in ipairs(cases) do
    local got, why = Flags.parse({ case[1] }, 1, short)
    assert(got == nil and why == case[2], why)
  end
end

local function test_a_value_is_never_a_word_that_looks_like_an_option()
  -- Whether or not the spec names it: a mistyped option is not a value.
  for _, next_word in ipairs({ "-v", "-vq", "--", "-n4", "-x", "--chek", "--check=1" }) do
    local got, why = Flags.parse({ "-n", next_word }, 1, short)
    assert(got == nil and why == "-n needs a value, not " .. next_word ..
      "; give one that begins with \"-\" as -n" .. next_word, why)
  end
  local got, why = Flags.parse({ "x", "--jobs", "--chek" }, 2, spec)
  assert(got == nil and why == "--jobs needs a value, not --chek; " ..
    "give one that begins with \"-\" as --jobs=--chek", why)
  for _, number in ipairs({ "-1", "-0.5", "-1e3", "-0x10" }) do
    assert(assert(Flags.parse({ "-n", number }, 1, short)).values["-n"] == number)
  end
  assert(assert(Flags.parse({ "-n", "-" }, 1, short)).values["-n"] == "-")
  assert(assert(Flags.parse({ "-n--chek" }, 1, short)).values["-n"] == "--chek")
  assert(assert(Flags.parse({ "x", "--jobs=--chek" }, 2, spec)).values["--jobs"] == "--chek")
  local _, missing = Flags.parse({ "-n" }, 1, short)
  assert(missing == "-n needs a value", missing)
end

local function test_a_spec_may_describe_its_options()
  local described: {string:boolean | Flags.Option} = {
    ["--out"] = { value = "path", about = "where to write" },
    ["-q"] = { about = "say less" },
    ["--plain"] = true,
  }
  local got = assert(Flags.parse({ "-q", "--out", "o.txt", "--plain", "p" }, 1, described))
  assert(got.set["-q"] and got.values["--out"] == "o.txt" and got.values["--plain"] == "p")
  local _, why = Flags.parse({ "-q=1" }, 1, described)
  assert(why == "-q takes no value", why)
end

local function test_help_lists_each_option_sorted_beside_what_it_does()
  local described: {string:boolean | Flags.Option} = {
    ["--verbose"] = { about = "say more" },
    ["-o"] = { value = "path", about = "where to write" },
    ["--jobs"] = { value = "n" },
    ["--color"] = false,
    ["-n"] = true,
  }
  local help = Flags.help("tool [options] <file>", described)
  assert(help == table.concat({
    "usage: tool [options] <file>",
    "",
    "options:",
    "  --color",
    "  --jobs <n>",
    "  -n <value>",
    "  -o <path>   where to write",
    "  --verbose   say more",
  }, "\n"), help)
  assert(Flags.help("tool", {}) == "usage: tool")
  assert(Flags.help("tool", {}, "Does one thing.") == "usage: tool\n\nDoes one thing.")
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
  local done, why = Flags.dispatch({ [0] = "prog", "build", "--jobs=2", "a" }, 1, commands)
  assert(done ~= nil and done.code == 3 and done.help == "" and why == "", why)
  local cleaned = assert(Flags.dispatch({ "prog", "clean" }, 2, commands))
  assert(cleaned.code == 0 and cleaned.help == "")
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
  assert(not pcall(Flags.dispatch, { "x" }, 1, {}))
end

local help_commands: {string:Flags.Command} = {
  build = {
    about = "Builds the target.",
    usage = "[options] <target>",
    spec = { ["-j"] = { value = "n", about = "run n at once" } },
    run = function(_: Flags.Parsed): integer error("help runs nothing") end,
  },
  clean = {
    run = function(_: Flags.Parsed): integer error("help runs nothing") end,
  },
}

local build_help = table.concat({
  "usage: prog build [options] <target>",
  "",
  "Builds the target.",
  "",
  "options:",
  "  -j <n>  run n at once",
}, "\n")

local function test_dispatch_answers_help_rather_than_running()
  local program_help = table.concat({
    "usage: prog <command> [options]",
    "",
    "commands:",
    "  build  Builds the target.",
    "  clean",
    "",
    "Run `prog <command> --help` for a command's options.",
  }, "\n")
  local asks: {{integer:string}} = {
    { [0] = "/usr/bin/prog", "--help" },
    { [0] = "prog", "-h", "build" },
    { [0] = "prog", "help" },
  }
  for _, argv in ipairs(asks) do
    local done, why = Flags.dispatch(argv, 1, help_commands)
    assert(done ~= nil and done.code == 0 and done.help == program_help, why)
  end
  for _, argv in ipairs({
    { "help", "build" }, { "build", "--help" }, { "build", "-j", "2", "-h" },
    { "build", "--nope", "--help" },
  }) do
    local done = assert(Flags.dispatch(argv, 1, help_commands, "prog"))
    assert(done.code == 0 and done.help == build_help, done.help)
  end
  local clean = assert(Flags.dispatch({ "clean", "-h" }, 1, help_commands, "prog"))
  assert(clean.help == "usage: prog clean", clean.help)
  local unknown, why = Flags.dispatch({ "help", "bulid" }, 1, help_commands, "prog")
  assert(unknown == nil and why == "no such command: bulid", why)
  local missing, why_missing = Flags.dispatch({}, 1, help_commands)
  assert(missing == nil and why_missing == "needs a command: build, clean", why_missing)
end

local function test_help_after_a_double_dash_or_named_by_the_spec_is_not_help()
  local seen: {string} = {}
  local commands: {string:Flags.Command} = {
    grep = {
      spec = { ["-h"] = false },
      run = function(got: Flags.Parsed): integer
        seen[#seen + 1] = tostring(got.set["-h"]) .. " " .. table.concat(got.words, " ")
        return 0
      end,
    },
    help = {
      run = function(got: Flags.Parsed): integer
        seen[#seen + 1] = "own help " .. #got.words
        return 0
      end,
    },
  }
  assert(assert(Flags.dispatch({ "grep", "-h", "x" }, 1, commands)).help == "")
  assert(assert(Flags.dispatch({ "grep", "--", "--help" }, 1, commands)).help == "")
  assert(assert(Flags.dispatch({ "help" }, 1, commands)).help == "")
  assert(seen[1] == "true x" and seen[2] == "nil --help" and seen[3] == "own help 0",
    table.concat(seen, "|"))
end
