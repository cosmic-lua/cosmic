--- The pinned release reads the bootstrap scripts in the new grammar, its default, and
--- [`ci/islands.txt`] lists none, since it would read a file it lists as Teal. Which scripts those are, the CI driver's
--- `check-islands` finds from the wrappers (ci/cosmic_ci/islands.tl, tested in ci/cosmic_ci/islands_test.tl).

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "bin/", letters = "r" }, { path = "ci/", letters = "r" } } }

local function test_no_file_is_listed_as_an_island()
  for line in (assert(Fs.read("ci/islands.txt"))):gmatch("[^\n]+") do
    assert(String.trim((line:gsub("#.*$", ""))) == "", "ci/islands.txt lists " .. line .. ", which the pinned release reads as Teal")
  end
end
