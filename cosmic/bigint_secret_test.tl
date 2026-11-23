--- A [`Bigint.Secret`] reaches only the functions for secrets: the
--- checker refuses one to a function whose time shows its value.
local Fs = require("cosmic.fs")
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
  { path = "cosmic/bigint.tl", letters = "r" }, { path = "cosmic/string.tl", letters = "r" },
  { path = "cosmic/internal/bigint.d.tl", letters = "r" } } }

--- The codes of the errors `source` has, checked against the tree's own cosmic.bigint.
local function codes_of(source: string): string
  local run = Programs.standard(assert(Fs.read("lang/prelude.d.tl")), assert(Fs.read("lang/stdlib.d.tl")),
    'local Bigint = require("cosmic.bigint")\nlocal secret = Bigint.hide("\\7")\nlocal m = "\\13"\n' .. source, {
      ["cosmic.bigint"] = assert(Fs.read("cosmic/bigint.tl")),
      ["cosmic.string"] = assert(Fs.read("cosmic/string.tl")),
      ["cosmic.internal.bigint"] = assert(Fs.read("cosmic/internal/bigint.d.tl")),
    })
  assert(#run.before == 0, table.concat(run.before, " "))
  return Programs.codes(run)
end

local function test_a_secret_goes_to_the_functions_for_secrets()
  assert(codes_of("local _: Bigint.Secret = Bigint.secret_mulmod(secret, secret, m)\n" ..
      "local _: string = Bigint.powmod(\"\\2\", secret, m)\n" ..
      "local _: string = Bigint.reveal(Bigint.secret_add(secret, \"\\1\"))\n") == "")
end

local function test_a_secret_is_refused_where_time_shows_its_value()
  for _, call in ipairs{ "Bigint.mul(secret, m)", "Bigint.mul(m, secret)", "Bigint.add(secret, m)",
      "Bigint.add(m, secret)", "Bigint.sub(secret, m)", "Bigint.sub(m, secret)", "Bigint.mod(secret, m)",
      "Bigint.mod(m, secret)", "Bigint.compare(secret, m)", "Bigint.compare(m, secret)",
      "Bigint.powmod(secret, m, m)", "Bigint.powmod(m, m, secret)", "Bigint.pad(secret, 4)",
      "Bigint.secret_mod(m, secret)", "Bigint.secret_powmod(m, m, secret)" } do
    local codes = codes_of("local _ = " .. call .. "\n")
    assert(codes == "not_assignable", call .. ": " .. codes)
  end
end

--- A secret's bytes are an operand as a string's are: arithmetic on
--- secrets answers what it answers on their bytes.
local function test_a_secret_is_an_operand_of_its_bytes()
  local Bigint = require("cosmic.bigint")
  local m = "\0\101"
  local a, b = Bigint.hide("\7"), Bigint.hide("\0\200")
  assert(Bigint.reveal(Bigint.secret_mulmod(a, b, m)) == Bigint.reveal(Bigint.secret_mulmod("\7", "\0\200", m)))
  assert(Bigint.reveal(Bigint.secret_add(a, Bigint.secret_mul(a, b))) == Bigint.reveal(Bigint.secret_add("\7", "\0\5\120")))
  assert(Bigint.powmod("\2", a, m) == Bigint.powmod("\2", "\7", m))
end

local function test_a_secret_prints_its_length_alone()
  local Bigint = require("cosmic.bigint")
  assert(tostring(Bigint.hide("\0\1\2")) == "Bigint.Secret (3 bytes)")
  assert(Bigint.reveal(Bigint.hide("\0\1")) == "\0\1")
end
