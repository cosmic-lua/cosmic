--- Tests of [`build.plural_sites`]: the new checker's reading of a source finds the literal plurals after numbers that
--- the fork's reading finds, with the same lines, snippets and fixes, in programs the check refuses and programs it
--- passes over.
local PluralSites = require("build.plural_sites")
local SyntaxNode = require("build.syntax_node")
local Test = require("cosmic.test")
local ast = require("build.ast")
local teal = require("build.teal")

Test.policy{}

local built = assert(teal.load(true))

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- A site as one line: its line, noun, snippet and fix.
local function told(site: {string}): string
  return table.concat(site, "|")
end

local function told_all(sites: {{string}}): {string}
  local out: mut {string} = {}
  for _, site in ipairs(sites) do out[#out + 1] = told(site) end
  return out
end

--- What the fork's reader finds in `text`, in order.
local function forked(text: string): {string}
  return told_all(PluralSites.of_fork((assert(ast.parse(built, text, "p.tl")))))
end

--- What the new checker's reader finds in `text`, in order.
local function read(text: string): {string}
  return told_all(PluralSites.of_chunk((assert(SyntaxNode.parse(text, "p.tl")))))
end

--- A program and the `line noun` of each site it holds, in order.
local record Case
  name: string
  text: string
  found: {string}
end

local CASES: {Case} = {
  { name = "a length joined to a plural", text = source("return #rows .. \" tests\""), found = { "1 tests" } },
  { name = "tostring of a count", text = source("return tostring(n) .. \" files\""), found = { "1 files" } },
  { name = "a count by its shape in front of a plural that is no unit", text = source(
    "local a1 = #rows .. \" widgets\"",
    "local a2 = (#rows) .. \" widgets\"",
    "local a3 = tostring(n) .. \" widgets\"",
    "local a4 = -n .. \" widgets\"",
    "local a5 = x + 1 .. \" widgets\"",
    "local a6 = x - 1 .. \" widgets\"",
    "local a7 = x * 2 .. \" widgets\"",
    "local a8 = x // 2 .. \" widgets\"",
    "local a9 = x % 2 .. \" widgets\"",
    "local b1 = x / 2 .. \" widgets\"",
    "local b2 = 2 .. \" widgets\"",
    "local b3 = 2.5 .. \" widgets\""),
    found = { "1 widgets", "2 widgets", "3 widgets", "4 widgets", "5 widgets", "6 widgets", "7 widgets", "8 widgets",
      "9 widgets", "10 widgets", "11 widgets", "12 widgets" } },
  { name = "a value that may not be a count, in front of a plural that is no unit", text = source(
    "local a1 = n .. \" widgets\"",
    "local a2 = x.n .. \" widgets\"",
    "local a3 = f(x) .. \" widgets\"",
    "local a4 = x.tostring(n) .. \" widgets\"",
    "local a5 = not x .. \" widgets\"",
    "local a6 = (a and b) .. \" widgets\"",
    "local a7 = t[1] .. \" widgets\"",
    "local a8 = ~n .. \" widgets\"",
    "local a9 = a ^ 2 .. \" widgets\"",
    "local b1 = ((#rows)) .. \" widgets\"",
    "local b2 = x:count() .. \" widgets\""), found = {} },
  { name = "a count in front of a unit, however it is spelled", text = source(
    "local a = count .. \" closure stores\"",
    "local b = counts.n .. \" files\"",
    "local c = f(x) .. \" tests\"",
    "local d = x.tostring(n) .. \" files\""), found = { "1 stores", "2 files", "3 tests", "4 files" } },
  { name = "a name in front of a plural that is no unit, or a verb", text = source(
    "local a = name .. \" lists\"",
    "local b = name .. \" needs\"",
    "local c = name .. \" is here\"",
    "local d = #rows .. \" is the count\""), found = {} },
  { name = "a string in front is no site, and a negation or a parenthesis is one before a unit", text = source(
    "local a = \"x\" .. \" tests\"",
    "local b = not x .. \" tests\"",
    "local c = (\"x\") .. \" tests\""), found = { "2 tests", "3 tests" } },
  { name = "the right of a chain of concatenations", text = source(
    "local a = x .. y .. \" tests\"",
    "local b = x .. \"-\" .. y .. \" tests\"",
    "local c = x .. \" tests\" .. y"), found = { "1 tests", "2 tests", "3 tests" } },
  { name = "a chain broken over lines is at the line of its operator", text = source(
    "local text = prefix ..",
    "  rows ..",
    "  \" tests\"",
    "local more = #rows ..",
    "  \" files\" ..",
    "  \"and the rest\"",
    "local last = #rows",
    "  .. \" bytes\"",
    "local after = #rows .. \" modules\"",
    "  .. more"), found = { "3 tests", "5 files", "8 bytes", "10 modules" } },
  { name = "a long string and an escape", text = source(
    "local a = n .. [[ rows]]",
    "local b = n .. \" rows\\n\"",
    "local c = n .. \" modules that are written out in full\""), found = { "1 rows", "2 rows", "3 modules" } },
  { name = "a format string with a number in it", text = source(
    "local a = (\"%d files\"):format(n)",
    "local b = (\"%d tests, %d files\"):format(n, m)",
    "local c = (\"at byte %d needs\"):format(n)",
    "local d = (\"iters=%d\"):format(n)",
    "local e = (\"%d of %s\"):format(n, s)",
    "local f = (\"line %d rows\"):format(n)",
    "local g = (\"%d rows=\"):format(n)"), found = { "1 files", "2 tests", "2 files" } },
  { name = "a format string joined to a value", text = source(
    "local a = \"%d files\" .. x",
    "local b = x .. \"%d files\""), found = { "1 files", "2 files" } },
  { name = "inside a function, a table and a call", text = source(
    "local function f(rows: {string}): {string}",
    "  local t = { #rows .. \" tests\", name = #rows .. \" files\" }",
    "  say(#rows .. \" rows\")",
    "  return t",
    "end"), found = { "2 tests", "2 files", "3 rows" } },
  { name = "a comment and a string with the words are no site", text = source(
    "-- #rows .. \" tests\" in a comment",
    "local a = plural.count(#rows, \"test\") .. name .. \" is here\"",
    "local b = \"tests\" .. #rows"), found = {} },
}

local function test_the_readers_find_the_same_sites_in_every_case()
  local total = 0
  for _, case in ipairs(CASES) do
    local old, new = forked(case.text), read(case.text)
    assert(#old == #new, case.name .. ": the fork finds " .. tostring(#old) .. ", the new reader " .. tostring(#new) .. "\n" ..
        table.concat(old, "\n") .. "\n--\n" .. table.concat(new, "\n"))
    for i, site in ipairs(old) do
      local other = assert(new[i])
      assert(site == other, case.name .. ": site " .. tostring(i) .. " is `" .. site .. "` and `" .. other .. "`")
    end
    total = total + #old
  end
  assert(total >= 25, "the cases compare " .. tostring(total) .. " sites")
end

local function test_the_sites_are_the_ones_each_case_says()
  for _, case in ipairs(CASES) do
    local expected: mut {string} = {}
    for _, each in ipairs(case.found) do expected[#expected + 1] = each end
    local seen: mut {string} = {}
    for _, site in ipairs(read(case.text)) do
      local line, noun = site:match("^(%d+)|([^|]*)|")
      seen[#seen + 1] = assert(line) .. " " .. assert(noun)
    end
    assert(table.concat(seen, ",") == table.concat(expected, ","),
      case.name .. ": found `" .. table.concat(seen, ",") .. "`, expected `" .. table.concat(expected, ",") .. "`")
  end
end

local function test_a_site_carries_its_snippet_and_the_fix_to_make()
  local concat = read(source("return #rows .. \" modules that are written out in full\""))
  assert(#concat == 1)
  assert(concat[1] == "1|modules|... .. \" modules that are writte|write `plural.count(n, singular)` (with the plural " ..
      "as a third argument when it is not the singular and an `s`)", concat[1])
  local format = read(source("return (\"%d files\"):format(n)"))
  assert(format[1] == "1|files|%d files|print `plural.noun(n, singular)` beside the number", tostring(format[1]))
end
