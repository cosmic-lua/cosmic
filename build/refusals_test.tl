--- Tests of [`build.refusals`]: the refusals of a compile, as a run that fails for them shows them.

local refusals = require("build.refusals")

--- The refusals of a tree where `build/one.tl` and `build/two.tl` are refused for what they hold, and three files require
--- one or both, in the order they compiled; and the positions holding each file out.
local function tree(): {string}, {string:{integer}}
  local lines = {
    "build/one.tl: the compiler refused it\nbuild/one.tl:1:1: wrong (code): fix",
    "build/one_test.tl: not compiled: it requires build.one, which did not build",
    "build/two.tl: the compiler refused it\nbuild/two.tl:1:1: also wrong (code): fix",
    "build/mid.tl: not compiled: it requires build.one, which did not build",
    "build/mid_test.tl: not compiled: it requires build.mid, which did not build",
  }
  local roots = { ["build/one.tl"] = { 1 }, ["build/one_test.tl"] = { 1 }, ["build/two.tl"] = { 3 },
    ["build/mid.tl"] = { 1, 3 }, ["build/mid_test.tl"] = { 1, 3 } }
  return lines, roots
end

--- A whole run shows each refusal of a file refused for what it holds, whole and ahead of the rest, and the files that
--- only require one in a line of their own with a count, so the diagnostic is never buried under its dependents.
local function test_the_refusals_a_run_shows_are_the_roots_first_and_the_dependents_in_one_line()
  local lines, roots = tree()
  local cascade = refusals.cascade(lines, roots)
  assert(#cascade.roots == 2 and cascade.roots[1] == lines[1] and cascade.roots[2] == lines[3],
    table.concat(cascade.roots, "|"))
  assert(table.concat(cascade.dependents, " ") == "build/one_test.tl build/mid.tl build/mid_test.tl")
  assert(refusals.collapsed(cascade) ==
      "not compiled, since each requires a refused module, directly or through another: build/one_test.tl, build/mid.tl, " ..
      "build/mid_test.tl; their own findings show once the files above build")
  assert(refusals.counted(cascade) == "2 files refused on their own, 3 not compiled because they require one")
  assert(refusals.text(lines, roots) == assert(lines[1]) .. "\n" .. assert(lines[3]) .. "\n" ..
      assert(refusals.collapsed(cascade)) .. "\n" .. assert(refusals.counted(cascade)))
end

--- Chosen lines show the roots they rest on and no other; a tree with no dependents shows its refusals alone; and a
--- result that gives no positions shows every line as it is.
local function test_chosen_lines_show_the_roots_they_rest_on_and_a_lone_root_is_counted_by_nothing()
  local lines, roots = tree()
  local one = refusals.cascade(lines, roots, { [2] = true })
  assert(#one.roots == 1 and one.roots[1] == lines[1] and table.concat(one.dependents) == "build/one_test.tl")
  assert(refusals.counted(one) == "1 file refused on its own, 1 not compiled because it requires one")
  local alone = refusals.cascade({ assert(lines[3]) }, { ["build/two.tl"] = { 1 } })
  assert(#alone.roots == 1 and #alone.dependents == 0)
  assert(refusals.collapsed(alone) == nil and refusals.counted(alone) == nil)
  -- One refusal of a source that two files hold (sources alike are one) refuses each on its own.
  local alike = refusals.cascade({ "x.tl: does not parse", "z.tl: not compiled: it requires y, which did not build" },
    { ["x.tl"] = { 1 }, ["y.tl"] = { 1 }, ["z.tl"] = { 1 } })
  assert(refusals.counted(alike) == "2 files refused on their own, 1 not compiled because it requires one")
  local unplaced = refusals.cascade(lines, {})
  assert(#unplaced.roots == #lines and #unplaced.dependents == 0)
end

--- A cascade of many files names the first ten and counts the rest.
local function test_the_line_of_many_dependents_names_ten_and_counts_the_rest()
  local lines: mut {string} = { "a.tl: the compiler refused it" }
  local roots: mut {string:{integer}} = { ["a.tl"] = { 1 } }
  for i = 1, 13 do
    local file = "d" .. tostring(i) .. ".tl"
    lines[#lines + 1] = file .. ": not compiled: it requires a, which did not build"
    roots[file] = { 1 }
  end
  local collapsed = assert(refusals.collapsed(refusals.cascade(lines, roots)))
  assert(collapsed:find(": d1.tl, d2.tl, ", 1, true) and collapsed:find("d10.tl, and 3 more; their own", 1, true), collapsed)
  assert(not collapsed:find("d11.tl", 1, true), collapsed)
end
