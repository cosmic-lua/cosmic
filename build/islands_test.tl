--- The bootstrap scripts of `build/` that the pinned release runs ([`bin/cosmic-bootstrap`] sets COSMIC_GRAMMAR=new for
--- them) are what the CI driver's `check-islands` checks (ci/cosmic_ci/islands.tl), each is in the tree, and
--- [`ci/islands.txt`] lists none, since the pinned release reads a file it lists as Teal.

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local Test = require("cosmic.test")

Test.policy{ grants = {
  { path = "bin/", letters = "r" }, { path = "build/", letters = "r" }, { path = "ci/", letters = "r" },
} }

--- The scripts `check-islands` checks: the strings of the list `Islands.scripts` in ci/cosmic_ci/islands.tl.
local function checked_scripts(): {string}
  local text = (assert(Fs.read("ci/cosmic_ci/islands.tl")))
  local from = assert(text:find("Islands.scripts = {", 1, true))
  local to = assert(text:find("\n}", from, true))
  local out: mut {string} = {}
  for path in text:sub(from, to):gmatch('"(build/[%w_]+%.tl)"') do out[#out + 1] = path end
  return out
end

local function test_the_list_is_in_order_and_each_script_is_in_the_tree()
  local last = ""
  local paths = checked_scripts()
  assert(#paths > 0, "check-islands names no script")
  for _, path in ipairs(paths) do
    assert(path > last, path .. " is out of order or repeated")
    last = path
    assert(Fs.exists(path) == true, path .. " does not exist")
  end
end

--- A script of `bin/` that runs a file of `build/` standalone on the bootstrap release is one whose file is checked, and
--- so is a file that build/zig.tl runs standalone (`standalone(root, "build/patch.tl", ...)`) on that release's own
--- binary; each script `check-islands` lists is run so.
local function test_the_scripts_run_on_the_pinned_release_are_the_ones_check_islands_lists()
  local run: mut {string: boolean} = {}
  local text = (assert(Fs.read("build/zig.tl")))
  for _, name in ipairs((assert(Fs.list("bin")))) do
    text = text .. "\n" .. (Fs.read("bin/" .. name) or "")
  end
  for _, pattern in ipairs({ "cosmic%-bootstrap\" %-%-standalone \"%$root/(build/[%w_]+%.tl)\"",
      "standalone%(root, \"(build/[%w_]+%.tl)\"" }) do
    for path in text:gmatch(pattern) do
      run[path] = true
    end
  end
  for _, path in ipairs({ "build/patch.tl", "build/paths.tl", "build/zig_fetch.tl" }) do
    assert(run[path] == true, "build/zig.tl no longer runs " .. path .. ", which this test looks for")
  end
  local listed: mut {string: boolean} = {}
  for _, path in ipairs(checked_scripts()) do
    listed[path] = true
  end
  for path in pairs(run) do
    assert(listed[path], path .. " runs on the pinned release and check-islands does not check it")
  end
  for path in pairs(listed) do
    assert(run[path], path .. " is checked by check-islands but no script of bin/ runs it")
  end
end

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
