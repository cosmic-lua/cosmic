--- [`causes.tl`]: the cause a refusal's code and text give, the findings of a refusal's text, and the names
--- it shows a model guessed.
local Causes = require("causes")
local Test = require("cosmic.test")

Test.policy{}

local function test_a_code_names_its_cause_and_a_text_can_name_another()
  assert(Causes.of("index_may_be_nil", "x (index_may_be_nil): y").tag == "lang")
  local bang = Causes.of("alternatives_as_value", "`Json.get(v)` answers one of 2 lists, and `assert` tells none of them apart (alternatives_as_value): bind")
  assert(bang.tag == "lang" and bang.name == "`!` on a call whose first value may be false")
  local plain = Causes.of("alternatives_as_value", "`Json.get(v)` answers one of 2 lists, which is no value (alternatives_as_value): bind")
  assert(plain.tag == "stdlib" and plain.name == "a call that may fail used as a value")
  assert(Causes.of("unknown_variable", "`Fs` is not declared (unknown_variable): require its module above").tag == "prompt")
  assert(Causes.of("unknown_variable", "`foo` is not declared (unknown_variable): declare it").tag == "stdlib")
  assert(Causes.of("field_unknown", "`Json` has no field `x` (field_unknown): `Json` has: a").tag == "stdlib")
  assert(Causes.of("field_unknown", "`cosmic.fs` has no field `x` (field_unknown): a").tag == "stdlib")
  assert(Causes.of("field_unknown", "`R` has no field `x` (field_unknown): a").tag == "prompt")
  assert(Causes.of("field_unknown", "`data.Page` has no field `x` (field_unknown): a").tag == "prompt")
  assert(Causes.of("unknown_variable", "`x` is used before the local `x` (unknown_variable): move").tag == "prompt")
  assert(Causes.of("literal_needs_type", "this literal has no items (literal_needs_type): declare").tag == "lang")
  assert(Causes.of("return_unexpected", "this function returns nothing (return_unexpected): declare").tag == "prompt")
  assert(Causes.of("array_hole", "x (array_hole): y").tag == "prompt")
  assert(Causes.of("local_untyped", "x (local_untyped): y").tag == "prompt")
  assert(Causes.of("unclosed", "expected `end` (unclosed): write").tag == "prompt")
  local other = Causes.of("no_such_code", "x")
  assert(other.tag == "untagged" and other.name == "other: no_such_code")
end

local function test_a_refusals_text_is_read_by_its_lines()
  local found = Causes.findings("The checker refused the snippet, so it did not run:\n" ..
      "run.tl:10:30: `ls[i-1]` is `string?` (an index read may be nil), where `string` is wanted (index_may_be_nil): iterate (`cosmic.array`: raises)\n" ..
      "-e:3: q (semicolon): r\n" ..
      "run.tl: 1 error of index_may_be_nil in its bodies on line 10; follow the fix above\n")
  assert(#found == 2)
  assert(assert(found[1]).code == "index_may_be_nil" and assert(found[1]).cause.tag == "lang")
  assert(assert(found[2]).code == "semicolon" and assert(found[2]).cause.tag == "prompt")
  assert(#Causes.findings("ok\n") == 0)
end

local function test_a_name_that_does_not_exist_is_a_guess()
  local function guess(line: string): string?
    local found = Causes.findings(line)
    local first = found[1]
    if first == nil then return nil end
    return Causes.guess(first)
  end
  assert(guess("run.tl:2:11: `Json` has no field `string_of` (field_unknown): `Json` has: array") ==
      "Json.string_of (field_unknown)")
  assert(guess("run.tl:3:11: cosmic has no module `cosmic.nothere` (require_unknown): `cosmic docs` lists") ==
      "cosmic.nothere (require_unknown)")
  assert(guess("run.tl:4:7: `foo` is not declared (unknown_variable): declare it") == "foo (unknown_variable)")
  assert(guess("run.tl:5:1: x (index_may_be_nil): y") == nil)
  assert(guess("run.tl:6:1: `x` is used before the local `x` (unknown_variable): move it") == nil)
end
