--- `cosmic fix --rename Old=new` in a project ([`build.fix.rename`]): it renames a member or a field where it is
--- declared, at each place `cosmic uses` finds and at each key or write the checker then refuses, and the run builds
--- the tree after. Run in this process ([`build.invoke`]), as build/docs_project_test.tl runs its lookups.
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local invoke = require("build.invoke")

Test.policy{
  grants = { { path = "core", letters = "r" }, { path = "o/cosmic.db", letters = "r" } },
  env = { "COSMIC_TREE" },
}

--- `cosmic <args>` in `dir`, built without the shared cache, which lives outside the test's own directory.
local function cosmic(dir: string, args: {string}): invoke.Result
  return invoke.run(args, { cwd = dir,
    env = { COSMIC_BUILD_CACHE = "0", COSMIC_BUILD_HOME = assert(Env.get("COSMIC_BUILD_HOME")) } })
end

local function read(path: string): string
  return assert(Fs.read(path))
end

--- A project of two modules: money, whose `format` a caller reads through an alias beside `string.format`, and shop,
--- whose record `Line` has a field `name` written in a table literal and by assignment.
local function project_in(tmp: string): string
  local project = tmp .. "/project"
  assert(Fs.mkdirs(project))
  assert(Fs.write(project .. "/money.tl",
    "--- [`Money.format`] writes cents with `string.format`.\nlocal record Money\nend\n\n" ..
      "--- `12.34`.\nfunction Money.format(cents: integer): string\n" ..
      "  return string.format(\"%d.%02d\", cents // 100, cents % 100)\nend\n\nreturn Money\n"))
  assert(Fs.write(project .. "/shop.tl",
    "local Cash = require(\"money\")\n\n--- A shop.\nlocal record Shop\n  --- One line.\n  record Line\n" ..
      "    mut name: string\n    cents: integer\n  end\nend\n\n" ..
      "--- A line of `name`.\nfunction Shop.line(name: string, cents: integer): Shop.Line\n" ..
      "  local l: Shop.Line = { name = name, cents = cents }\n  l.name = name\n  return l\nend\n\n" ..
      "--- `name 12.34`.\nfunction Shop.show(l: Shop.Line): string\n" ..
      "  return string.format(\"%s %s\", l.name, Cash.format(l.cents))\nend\n\nreturn Shop\n"))
  assert(Fs.write(project .. "/shop_test.tl",
    "local Shop = require(\"shop\")\n\nlocal function test_show()\n" ..
      "  assert(Shop.show(Shop.line(\"tea\", 1234)) == \"tea 12.34\")\nend\n"))
  local built = cosmic(project, { "build", "--host" })
  assert(built.code == 0, built.stdout .. built.stderr)
  return project
end

--- A member is renamed at its declaration, its link and its use through an alias; `string.format` on the same line
--- stays.
local function test_a_member_is_renamed_through_an_alias(tmp: string)
  local project = project_in(tmp)
  local result = cosmic(project, { "fix", "--rename", "Money.format=render" })
  assert(result.code == 0, result.stdout .. result.stderr)
  local money = read(project .. "/money.tl")
  assert(money:find("function Money.render(cents: integer)", 1, true), money)
  assert(money:find("[`Money.render`] writes cents with `string.format`.", 1, true), money)
  assert(money:find("return string.format(", 1, true), money)
  local shop = read(project .. "/shop.tl")
  assert(shop:find("string.format(\"%s %s\", l.name, Cash.render(l.cents))", 1, true), shop)
  -- The run after it covers the two files written, not shop_test.tl.
  assert((result.stdout .. result.stderr):find("fix: 2 Teal files", 1, true), result.stdout .. result.stderr)
end

--- The run after a rename builds each file that binds the module by `require` too, where a use `cosmic uses` missed
--- would hide, and not the others.
local function test_the_run_after_a_rename_covers_the_files_that_require_the_module(tmp: string)
  local project = project_in(tmp)
  assert(Fs.write(project .. "/till.tl", "local Money = require(\"money\")\n\nlocal _ = Money\n"))
  local result = cosmic(project, { "fix", "--rename", "Money.format=render" })
  assert(result.code == 0, result.stdout .. result.stderr)
  assert((result.stdout .. result.stderr):find("fix: 3 Teal files", 1, true), result.stdout .. result.stderr)
end

--- A field is renamed where it is declared and read, and at the key of a table literal and the write, which no use
--- lists: the tree builds after.
local function test_a_field_is_renamed_at_its_keys_and_writes(tmp: string)
  local project = project_in(tmp)
  local result = cosmic(project, { "fix", "--rename", "Shop.Line.name=label" })
  assert(result.code == 0, result.stdout .. result.stderr)
  local shop = read(project .. "/shop.tl")
  assert(shop:find("    mut label: string\n", 1, true), shop)
  assert(shop:find("{ label = name, cents = cents }", 1, true), shop)
  assert(shop:find("l.label = name", 1, true), shop)
  assert(shop:find("l.label, Cash.format(l.cents)", 1, true), shop)
  -- The parameter called name is no field.
  assert(shop:find("function Shop.line(name: string", 1, true), shop)
end

--- A rename that names no member, no new name, a keyword or a name its record has already, is refused before anything
--- is written; with --check it writes nothing and fails.
local function test_a_rename_is_refused_where_it_names_nothing(tmp: string)
  local project = project_in(tmp)
  local before = read(project .. "/money.tl")
  local none = cosmic(project, { "fix", "--rename", "Money.nothing=x" })
  assert(none.code ~= 0 and (none.stderr .. none.stdout):find("names no member", 1, true) ~= nil, none.stdout .. none.stderr)
  local bad = cosmic(project, { "fix", "--rename", "Money.format=Money.render" })
  assert(bad.code == 2 and (bad.stderr .. bad.stdout):find("is no name", 1, true) ~= nil, bad.stdout .. bad.stderr)
  local keyword = cosmic(project, { "fix", "--rename", "Money.format=end" })
  assert(keyword.code == 2 and (keyword.stderr .. keyword.stdout):find("keyword", 1, true) ~= nil,
    keyword.stdout .. keyword.stderr)
  local taken = cosmic(project, { "fix", "--rename", "Shop.line=show" })
  assert(taken.code ~= 0 and (taken.stderr .. taken.stdout):find("declared already", 1, true) ~= nil,
    taken.stdout .. taken.stderr)
  local checked = cosmic(project, { "fix", "--check", "--rename", "Money.format=render" })
  assert(checked.code ~= 0 and (checked.stderr .. checked.stdout):find("would change", 1, true) ~= nil,
    checked.stdout .. checked.stderr)
  assert(read(project .. "/money.tl") == before)
end
