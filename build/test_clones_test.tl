--- Tests of [`build.test_clones`]: a top-level helper is read off the tree whole, whatever strings and one-liners
--- stand in it, tests are left out, and two helpers that differ in comments and layout alone give the same tokens.
local Test = require("cosmic.test")
local TestClones = require("build.test_clones")

Test.policy{}

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The helpers of `text` that [`TestClones.read`] answers, all heads read.
local function read(text: string): {{string}}
  local scan = TestClones.scan(text)
  local out: mut {{string}} = {}
  for _, head in ipairs(scan.heads) do
    local helper, trouble = TestClones.read(scan, head, "t_test.tl")
    if helper == nil then
      out[#out + 1] = { head.name, tostring(head.line), "refused", trouble }
    else
      out[#out + 1] = { helper.name, tostring(helper.line), tostring(helper.size), helper.body }
    end
  end
  return out
end

local function test_helpers_are_read_with_their_lines_and_tests_are_left_out()
  local found = read(source(
    "local x = 1",
    "",
    "local function first(a: string): string",
    "  return a",
    "end",
    "local function test_one()",
    "  assert(true)",
    "end",
    "local function second(a: string): string",
    "  return a .. a",
    "end"))
  assert(#found == 2, #found)
  local first, second = assert(found[1]), assert(found[2])
  assert(first[1] == "first" and first[2] == "3" and first[3] == "10", table.concat(first, ","))
  assert(second[1] == "second" and second[2] == "9", table.concat(second, ","))
end

local function test_a_helper_holding_a_string_of_source_or_written_on_one_line_is_read_whole()
  local text = source(
    "local function writes(root: string)",
    "  assert(Fs.write(root .. \"/a.tl\", [[",
    "  local function inner()",
    "    return 1",
    "end",
    "]]))",
    "end",
    "local function one() return 1 end",
    "local function after(a: string): string",
    "  return a",
    "end")
  local found = read(text)
  assert(#found == 3, #found)
  assert(assert(found[1])[1] == "writes" and assert(found[1])[2] == "1", table.concat(assert(found[1]), ","))
  assert(assert(found[2])[1] == "one" and assert(found[2])[3] == "5", table.concat(assert(found[2]), ","))
  assert(assert(found[3])[1] == "after" and assert(found[3])[2] == "9", table.concat(assert(found[3]), ","))
  -- Its string is a token of it, so a copy that writes another source is another helper.
  local other = read(source(
    "local function writes(root: string)",
    "  assert(Fs.write(root .. \"/a.tl\", [[",
    "  local function inner()",
    "    return 2",
    "end",
    "]]))",
    "end"))
  assert(assert(other[1])[4] ~= assert(found[1])[4])
end

local function test_a_helper_no_run_of_lines_makes_whole_is_refused_with_a_reason()
  local found = read("local function broken(a: string): string\n  return a +\nend\n")
  assert(#found == 1 and assert(found[1])[3] == "refused", table.concat(assert(found[1]), ","))
end

local function test_a_comment_and_the_layout_are_no_part_of_a_helper()
  local plain = assert(read(source("local function f(a: string): string", "  return a", "end"))[1])
  local noted = assert(read(source("local function f(a: string): string  -- the name",
    "  -- returns it", "  return   a", "end"))[1])
  assert(plain[4] == noted[4], tostring(plain[4]) .. " / " .. tostring(noted[4]))
  local changed = assert(read(source("local function f(a: string): string", "  return b", "end"))[1])
  assert(plain[4] ~= changed[4])
end

local function test_heads_are_the_first_line_without_the_name_or_a_comment_and_three_lines_of_code()
  local scan = TestClones.scan(source(
    "local function first(a: string): string -- note",
    "  -- a comment line",
    "",
    "  return a",
    "end",
    "local function test_one() end",
    "  local function nested() end",
    "local function second<T>(a: T): T return a end"))
  assert(#scan.heads == 2, #scan.heads)
  assert(assert(scan.heads[1]).key == "(a: string): string\nreturn a\nend\nlocal function test_one() end", assert(scan.heads[1]).key)
  assert(assert(scan.heads[2]).key == "<T>(a: T): T return a end", assert(scan.heads[2]).key)
end
