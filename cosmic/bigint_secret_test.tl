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
  for _, call in ipairs{ "Bigint.mul(secret, m)", "Bigint.add(secret, m)", "Bigint.mod(secret, m)",
      "Bigint.compare(secret, m)", "Bigint.powmod(secret, m, m)", "Bigint.pad(secret, 4)",
      "Bigint.secret_mod(m, secret)" } do
    local codes = codes_of("local _ = " .. call .. "\n")
    assert(codes == "not_assignable", call .. ": " .. codes)
  end
end

local function test_a_secret_prints_its_length_alone()
  local Bigint = require("cosmic.bigint")
  assert(tostring(Bigint.hide("\0\1\2")) == "Bigint.Secret (3 bytes)")
  assert(Bigint.reveal(Bigint.hide("\0\1")) == "\0\1")
end
