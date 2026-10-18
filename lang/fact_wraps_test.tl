--- Tests of [`lang.fact_wraps`]: the arguments of the call of `__fact` that wraps each narrowed read, and the place
--- (`file:line:column`) each is given.
local Check = require("lang.check")
local FactWraps = require("lang.fact_wraps")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

local SOURCE <const> = table.concat({
  "local enum Color",
  "  \"red\"",
  "end",
  "local function f(x: string?, c: Color | integer): string",
  "  if x == nil then return \"-\" end",
  "  if c is Color then",
  "    return x .. c",
  "  end",
  "  return x",
  "end",
  "",
}, "\n")

local function test_each_narrowed_read_is_wrapped_with_its_place()
  local run = Programs.run(SOURCE)
  assert(Programs.codes(run) == "", Programs.codes(run))
  local wraps = FactWraps.of(run.result.narrowed, SOURCE, "m.tl")
  local seen = ""
  for _, n in ipairs(run.result.narrowed) do
    seen = seen .. n.text .. "=" .. (wraps[n.id] or "?") .. "\n"
  end
  local want = table.concat({
    "x=\"nil\", \"x\", nil, nil, nil, nil, \"m.tl:7:12\"",
    "c=\"number\", \"c\", nil, nil, nil, nil, \"m.tl:7:17\"",
    "x=\"nil\", \"x\", nil, nil, nil, nil, \"m.tl:9:10\"",
    "",
  }, "\n")
  assert(seen == want, seen)
end

local function test_a_place_is_one_based_at_the_first_byte_of_the_read()
  local run = Programs.run(SOURCE)
  local first = assert(run.result.narrowed[1])
  local wraps = FactWraps.of({ first }, SOURCE, "a/b.tl")
  local wrapped = assert(wraps[first.id])
  assert(wrapped:find("\"a/b.tl:7:12\"$") ~= nil, wrapped)
  -- The same offset at the start of the text is line 1, column 1.
  local lone: Check.Narrowed = {
    id = 1, offset = 1, length = 1, text = "x", taken = { "nil", "boolean" }, strings = nil, classes = nil, tag = nil,
    tags = nil,
  }
  assert(FactWraps.of({ lone }, "x", "z.tl")[1] == "\"nil,boolean\", \"x\", nil, nil, nil, nil, \"z.tl:1:1\"")
end

local function test_a_string_with_a_newline_or_a_quote_is_one_line_of_lua()
  local odd: Check.Narrowed = {
    id = 2, offset = 1, length = 1, text = "a\"b\nc", taken = { "nil" }, strings = { "q\"", "n\n" }, classes = nil,
    tag = nil, tags = nil,
  }
  local text = FactWraps.arguments(odd, "f.tl:1:1")
  assert(not text:find("\n", 1, true), text)
  local chunk = assert(load("local t = {" .. text .. "}\nreturn t[2] == \"a\\\"b\\nc\" and t[3][2] == \"n\\n\" and t[4] == nil"))
  assert(chunk() == true, text)
end
