--- The pinned release runs the bootstrap scripts with COSMIC_GRAMMAR=new ([`bin/cosmic-bootstrap`] sets it for them), and
--- [`ci/islands.txt`] lists none, since it would read a file it lists as Teal. Which scripts those are, the CI driver's
--- `check-islands` finds from the wrappers (ci/cosmic_ci/islands.tl, tested in ci/cosmic_ci/islands_test.tl).

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "bin/", letters = "r" }, { path = "ci/", letters = "r" } } }

--- The scripts the pinned release runs set COSMIC_GRAMMAR=new, through the one line of bin/cosmic-bootstrap that runs it.
local function test_the_bootstrap_script_runs_what_it_runs_in_the_new_grammar()
  local text = (assert(Fs.read("bin/cosmic-bootstrap")))
  assert(text:find('exec env COSMIC_GRAMMAR=new "$cached" "$@"', 1, true) ~= nil, "the pinned release is not run with COSMIC_GRAMMAR=new")
  assert(text:find('exec env COSMIC_GRAMMAR=new "$COSMIC_BOOTSTRAP" "$@"', 1, true) ~= nil, "a stand-in is not run with COSMIC_GRAMMAR=new")
end

local function test_no_file_is_listed_as_an_island()
  for line in (assert(Fs.read("ci/islands.txt"))):gmatch("[^\n]+") do
    assert(String.trim((line:gsub("#.*$", ""))) == "", "ci/islands.txt lists " .. line .. ", which the pinned release reads as Teal")
  end
end
