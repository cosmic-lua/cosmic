--- Tests of [`build.new_declarations`]: each line it replaces is in the file it is about, once, and the replacement is
--- what the new checker reads the file with.
local Fs = require("cosmic.fs")
local NewDeclarations = require("build.new_declarations")
local Translate = require("lang.translate")
local Pipeline = require("build.pipeline")
local Test = require("cosmic.test")

Test.policy{
  profiles = { "cosmic" },
  grants = {
    { path = "o/bin", letters = "rx" },
    { path = "cosmic/json.tl", letters = "r" },
    { path = "build/tree_checks.tl", letters = "r" },
    { path = "cosmic/web/response.tl", letters = "r" },
    { path = "cosmic/web/init.tl", letters = "r" },
    { path = "cosmic/web/htmx.tl", letters = "r" },
    { path = "cosmic/web/types.tl", letters = "r" },
  },
}

--- The text of `file` as the new checker reads it before the edits: translated.
local function read(file: string): string
  return Translate.translate((assert(Fs.read(file))), file).text
end

local function test_each_line_a_file_is_edited_at_is_in_it_once()
  local files = 0
  for file, edits in pairs(NewDeclarations.files) do
    files = files + 1
    assert(#edits > 0, file)
    local missing = NewDeclarations.missing(file, read(file))
    assert(#missing == 0, file .. " lacks, or repeats: " .. table.concat(missing, " | "))
  end
  assert(files == 5, "files with edits: " .. files)
end

local function test_a_missing_line_is_told_and_leaves_the_text_as_it_was()
  local text = "local x = 1\n  type Value = any -- not the whole line\n"
  assert(#NewDeclarations.missing("cosmic/json.tl", text) == 8)
  assert(NewDeclarations.edited("cosmic/json.tl"))
  assert(NewDeclarations.apply("cosmic/json.tl", text) == text)
  -- Read as the tree reads it, a line that drifted from the table is an error that names it.
  local ok, why = pcall(NewDeclarations.apply, "cosmic/json.tl", text, true)
  assert(not ok and tostring(why):find("new_declarations: cosmic/json.tl lacks, or repeats, the line", 1, true) ~= nil, tostring(why))
  local dropped = read("cosmic/json.tl"):gsub("  type Value = any\n", "")
  local ok2, why2 = pcall(NewDeclarations.apply, "cosmic/json.tl", dropped, true)
  assert(not ok2 and tostring(why2):find("type Value = any", 1, true) ~= nil, tostring(why2))
  assert(pcall(NewDeclarations.apply, "cosmic/json.tl", read("cosmic/json.tl"), true))
  assert(not NewDeclarations.edited("cosmic/fs.tl"))
  assert(NewDeclarations.apply("cosmic/fs.tl", text) == text)
  assert(#NewDeclarations.missing("cosmic/fs.tl", text) == 0)
end

local function test_the_memo_of_each_check_that_reads_a_mended_source_is_salted_with_the_table()
  -- The salts name the files whose text decides what a check answers; the table changes what the sources say.
  local text = (assert(Fs.read("build/tree_checks.tl")))
  local salts, named = 0, 0
  for list in text:gmatch("check_memo%.salt%(root, (%b{})") do
    if list:find("build/tree_program.tl", 1, true) ~= nil then
      salts = salts + 1
      if list:find("build/new_declarations.tl", 1, true) ~= nil then
        named = named + 1
      end
    end
  end
  assert(salts >= 5, "salts that name the tree program: " .. salts)
  assert(named == salts, named .. " of " .. salts .. " salts that name build/tree_program.tl name build/new_declarations.tl")
end

local function test_the_alias_json_value_is_read_as_the_recursive_union_and_the_rest_of_the_text_is_not_touched()
  local text = read("cosmic/json.tl")
  local mended = NewDeclarations.apply("cosmic/json.tl", text)
  assert(mended ~= text)
  assert(mended:find("  type Value = string | number | boolean | Json.Null | {Json.Value} | {string: Json.Value}\n", 1, true) ~= nil)
  assert(mended:find("  null: Json.Null\n", 1, true) ~= nil)
  assert(mended:find("function Json.encode(value: Json.Value, opts?: Json.EncodeOptions)", 1, true) ~= nil)
  -- A line each: the lines of the module stay where they are.
  local _, before = text:gsub("\n", "\n")
  local _, after = mended:gsub("\n", "\n")
  assert(before == after, before .. " lines, then " .. after)
  -- The function that takes any value is not the one that takes a value of the alias.
  assert(mended:find("function Json.encode_any(value: any, opts?: Json.EncodeOptions)", 1, true) ~= nil)
end

local function test_the_web_modules_take_the_alias_where_json_is_written()
  local response = NewDeclarations.apply("cosmic/web/response.tl", read("cosmic/web/response.tl"))
  assert(response:find("function Response.json(value: Json.Value,", 1, true) ~= nil)
  local mended = NewDeclarations.apply("cosmic/web/init.tl", read("cosmic/web/init.tl"))
  assert(mended:find("  json: function(value: Json.Value,", 1, true) ~= nil)
  assert(mended:find("local type Json = require(\"cosmic.json\")", 1, true) ~= nil)
end

local function test_the_real_encode_takes_a_natural_literal_and_refuses_a_function_under_the_new_checker()
  local options = assert(Pipeline.alone())
  local function lines_of(literal: string): {string}
    local source = 'local Json = require("cosmic.json")\nprint(Json.encode(' .. literal .. '))\n'
    return Pipeline.checked_alone("probe.tl", source, options).lines
  end
  -- Names and keys in brackets beside each other, a nested array and map, a boolean and [`Json.null`].
  local natural = lines_of('{ name = "x", ["content-type"] = "y", tags = { "a", 1 }, meta = { ok = true, none = Json.null } }')
  assert(#natural == 0, table.concat(natural, "\n"))
  local keyed = lines_of('{ ["content-type"] = "y", name = "x" }')
  assert(#keyed == 0, table.concat(keyed, "\n"))
  local refused = lines_of('{ name = "x", run = print }')
  assert(#refused > 0 and table.concat(refused, "\n"):find("Json.Value", 1, true) ~= nil, table.concat(refused, "\n"))
end
