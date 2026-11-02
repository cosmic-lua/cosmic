--- Small helpers the tests of the tree each need: an element they know is
--- there, a list that holds a string, and a fresh build directory. Test
--- support.

local Fs = require("cosmic.fs")
local build_paths = require("build.paths")

local record test_support_fixture
end

--- The element of `list` at `index`, which the case knows is there.
--- @param list the list
--- @param index where the element is
--- @return the element
function test_support_fixture.nth<T>(list: {T}, index: integer): T
  local found = list[index]
  assert(found ~= nil, "the list has an element at " .. tostring(index))
  return found
end

--- Whether `list` holds `value`.
--- @param list the strings to look through
--- @param value the string to look for
function test_support_fixture.holds(list: {string}, value: string): boolean
  for _, each in ipairs(list) do
    if each == value then return true end
  end
  return false
end

--- The build directory for a project rooted at `root`, made if it is not
--- there ([`build.paths.prepare`]).
--- @param root the project's root
--- @return the build directory
function test_support_fixture.build_dir(root: string): string
  assert(Fs.mkdirs(root))
  return (assert(build_paths.prepare(root)))
end

return test_support_fixture
