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
