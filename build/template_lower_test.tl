--- A [`Template.text`] of a literal is lowered before the checker reads the module ([`build.template_lower`]): checked as
--- a lone file is, against the declarations the tool carries, a template's field is checked against the value it is
--- given, a template the compiler refuses is a syntax error at its literal, and every place keeps the line and column
--- it has in the text written.
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Pipeline = require("build.pipeline")
local TemplateLower = require("build.template_lower")
local standalone = require("build.standalone")
-- The modules the snippets below require: the store carries their stubs for a test that names them.
local type _ = require("cosmic.html")
local type _ = require("cosmic.template")

--- What `text` checked alone as `t.tl` makes.
local function checked(text: string): Pipeline.Alone
  local options, why = Pipeline.alone()
  return Pipeline.checked_alone("t.tl", text, (assert(options, why)))
end

--- What the Lua of `code` returns when it runs, in an environment of the standard library.
local function loaded(code: string): any...
  local none: {string: string} = {}
  local chunk, why = standalone.loaded_with("t.tl", code, none)
  return assert(chunk, why)()
end

--- What the Lua of `made` returns when it runs.
local function run(made: Pipeline.Alone): any...
  return loaded((assert(made.code, table.concat(made.lines, "\n"))))
end

local HEAD <const> = 'local Template = require("cosmic.template")\n'

local function test_a_template_literal_reads_the_fields_of_the_value_it_is_given()
  local made = checked(HEAD .. 'local items = { { name = "a", size = 3 }, { name = "b", size = 5 } }\n' ..
      'return Template.text("{{.n}} kinds:{{range .items}} {{.name}}={{.size}}{{end}}{{if .big}} (big){{end}}", ' ..
      '{ n = #items, items = items, big = true })\n')
  local got = run(made)
  assert(got == "2 kinds: a=3 b=5 (big)", tostring(got))
end

local function test_a_field_the_value_has_not_got_is_a_type_error_at_the_literal()
  local made = checked(HEAD .. 'local items = { { name = "a" } }\n' ..
      'return Template.text("{{range .items}}{{.nme}}{{end}}", { items = items }) .. tostring(1)\n')
  assert(made.code == nil)
  local told = table.concat(made.lines, "\n")
  -- Line 3, at the literal's first byte: the column of the text written, not of what the lowering wrote.
  assert(told:find("t.tl:3:22: ", 1, true) ~= nil and told:find("nearest `name`", 1, true) ~= nil, told)
end

local function test_a_place_after_a_template_on_its_line_keeps_its_column()
  local made = checked(HEAD .. 'local s = Template.text("{{.a}}", { a = "x" }) local n: integer = "no"\nreturn s .. n\n')
  local told = table.concat(made.lines, "\n")
  assert(told:find("t.tl:2:67: ", 1, true) ~= nil, told)
end

local function test_a_literal_alone_is_its_text_and_a_slot_in_it_is_refused()
  local plain = checked(HEAD .. 'return Template.text("3 files")\n')
  local got = run(plain)
  assert(got == "3 files", tostring(got))
  local slot = checked(HEAD .. 'return Template.text("{{.n}} files")\n')
  local told = table.concat(slot.lines, "\n")
  assert(slot.code == nil and told:find("t.tl:2:22: ", 1, true) ~= nil and told:find("slots and no data", 1, true) ~= nil,
    told)
end

local function test_a_template_the_compiler_refuses_is_a_syntax_error_at_its_literal()
  local made = checked(HEAD .. 'return Template.text("{{if .x}}", { x = 1 })\n')
  local told = table.concat(made.lines, "\n")
  assert(made.code == nil and told:find("t.tl:2:23: ", 1, true) ~= nil and told:find("template_refused", 1, true) ~= nil,
    told)
  local header = checked(HEAD .. 'return Template.text("{{type P from m}}", {})\n')
  assert(table.concat(header.lines, "\n"):find("has no {{type}}", 1, true) ~= nil, table.concat(header.lines, "\n"))
end

local function test_a_template_that_is_no_literal_is_left_and_raises_when_it_runs()
  local made = checked(HEAD .. 'local src = "{{.a}}"\nreturn pcall(Template.text, src, { a = 1 })\n')
  local ok, why = run(made)
  assert(ok == false and tostring(why):find("as a string literal", 1, true) ~= nil, tostring(why))
end

local function test_a_long_literal_keeps_each_line_of_the_template_on_its_own()
  local made = checked(HEAD .. 'return Template.text([[\n{{.a}}\n{{range .xs}}{{.}}{{end}}\n{{.b}}]], ' ..
      '{ a = 1, xs = { "p", "q" }, b = "z" })\n')
  local text = run(made)
  assert(text == "1\npq\nz", tostring(text))
  -- The lines after the literal are where they were.
  local after = checked(HEAD .. 'local s = Template.text([[\n{{.a}}\n{{.a}}]], { a = 1 })\nlocal n: integer = "no"\n' ..
      'return s .. n\n')
  assert(table.concat(after.lines, "\n"):find("t.tl:5:20: ", 1, true) ~= nil, table.concat(after.lines, "\n"))
end

local function test_a_quoted_literal_whose_lines_are_not_the_templates_keeps_the_lines_after_it()
  local made = checked(HEAD .. 'local s = Template.text("{{.a}}\\n{{.a}}\\\n{{.a}}", { a = 1 })\nlocal n: integer = "no"\n' ..
      'return s .. n\n')
  local told = table.concat(made.lines, "\n")
  assert(told:find("t.tl:4:20: ", 1, true) ~= nil, told)
end

local function test_a_function_takes_a_template_where_its_first_parameter_is_declared_a_source()
  local text = 'local T = require("cosmic.template")\nlocal M = {}\n' ..
    'function M.say(text: T.Source, data?: any) end\n' ..
    'function M.plain(text: string, data?: any) end\n' ..
    'function M.more(text: T.Source, data?: any, n?: integer) end\nreturn M\n'
  local chunk = Parser.parse(Lexer.lex(text, "m.tl"), "m.tl", "tl").chunk
  local takers = TemplateLower.takers("m", chunk)
  assert(takers["say"] == true and takers["plain"] == nil and takers["more"] == nil)
  -- The module of templates names its own record.
  local own = 'local record Template type Source = string end\n' ..
    'function Template.text(src: Template.Source, data?: any): string return "" end\nreturn Template\n'
  local of_own = TemplateLower.takers("cosmic.template", Parser.parse(Lexer.lex(own, "t.tl"), "t.tl", "tl").chunk)
  assert(of_own["text"] == true)
end
