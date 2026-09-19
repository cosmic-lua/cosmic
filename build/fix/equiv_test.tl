--- That `build.fix.equiv` actually reports a difference, which is the
--- half of it nothing else would notice going wrong.
---
--- `cosmic fix` refuses to write a file whose rendered text does not
--- parse back to the tree it came from, so a comparison that quietly
--- answered "same" to everything would turn that guard off and leave no
--- trace. Each case here is a change a broken renderer could plausibly
--- make -- an attribute dropped, one attribute swapped for the other, a
--- comment lost, two operands transposed -- and each has to be caught.
--- The last case is the other direction: spacing alone is not a
--- difference, or the guard would refuse every file it ever fixed.

local ast = require("build.ast")
local equiv = require("build.fix.equiv")
local teal = require("build.teal")

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Compare two sources as trees and as comment streams.
--- @return boolean Whether the trees match
--- @return boolean Whether the comments match
--- @return string What differed, when something did
local function compare(before_src: string,
                       after_src: string): boolean, boolean, string
  local before, before_trouble = ast.parse(built, before_src, "before.tl")
  assert(before ~= nil, "before did not parse: " .. tostring(before_trouble))
  local after, after_trouble = ast.parse(built, after_src, "after.tl")
  assert(after ~= nil, "after did not parse: " .. tostring(after_trouble))
  local same, difference = equiv.same_tree(before.node, after.node)
  local kept, lost = equiv.same_comments(before.tokens, after.tokens)
  return same, kept, same and lost or difference
end

local function test_a_dropped_variable_attribute_is_a_difference()
  local same, _, difference = compare("local x <const> = 5\n", "local x = 5\n")
  assert(not same, "dropping <const> was not noticed")
  assert(difference:find("const", 1, true) ~= nil, "got: " .. difference)
end

local function test_one_attribute_swapped_for_the_other_is_a_difference()
  local same = compare("local x <const> = 5\n", "local x <close> = 5\n")
  assert(not same, "const becoming close was not noticed")
end

local function test_a_lost_comment_is_a_difference()
  local _, kept, lost = compare("-- why\nlocal x = 5\n", "local x = 5\n")
  assert(not kept, "a lost comment was not noticed")
  assert(lost:find("2 comments", 1, true) == nil, "got: " .. lost)
end

local function test_a_reordered_expression_is_a_difference()
  local same = compare("local a = x - y\n", "local a = y - x\n")
  assert(not same, "transposed operands were not noticed")
end

local function test_a_changed_string_literal_is_a_difference()
  local same = compare('local a = "one"\n', 'local a = "two"\n')
  assert(not same, "a changed literal was not noticed")
end

local function test_spacing_alone_is_not_a_difference()
  local same, kept, difference = compare("local  a =  x -  y -- why\n",
                                         "local a = x - y -- why\n")
  assert(same, "spacing counted as a difference: " .. difference)
  assert(kept, "spacing counted as a comment change: " .. difference)
end
