--- A fake's main for the test of `Fake.build(dir, main)`
--- (build/fake_main_test.tl): it prints what [`Fake.given`] reads, or
--- "none", then its arguments joined by spaces, and ends with status 3.

local Fake = require("cosmic.fake")

local function main(argv: {string}): integer
  print(Fake.given() or "none")
  print(table.concat(argv, " "))
  return 3
end

return main
