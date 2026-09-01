#!/usr/bin/env cosmic
local codegen = require("cosmic.template.codegen")
local parse = require("cosmic.template.parse")

--- Parse then generate in one call, for tests that only care about the
--- Teal text codegen produces.
local function gen(src: string, name: string): string
  local t, err = parse.parse(src, name)
  assert(t, "expected a template, got error: " .. tostring(err))
  return codegen.generate(t, name)
end

local function test_text_mode_returns_string()
  local out = gen("{{type Page from myapp.page}}hi", "t")
  assert(out:match("render%(d: page%.Page%): string"), out)
  assert(out:match('return table%.concat%(parts%)'), out)
  assert(not out:match("cosmic%.html"), "text mode must not require cosmic.html")
end

local function test_html_mode_returns_safe_html_and_wraps_trusted()
  local out = gen("{{type Page from myapp.page}}\n{{mode html}}hi", "t")
  assert(out:match("local html = require%(\"cosmic%.html\"%)"), out)
  assert(out:match("render%(d: page%.Page%): html%.SafeHtml"), out)
  assert(out:match("return html%.trusted%(table%.concat%(parts%)%)"), out)
end

local function test_interpolation_carries_a_source_comment()
  local out = gen("{{type Page from myapp.page}}\nhi {{.title}}", "t")
  assert(out:match("%-%- t:2\n"), "expected a '-- t:2' source comment:\n" .. out)
end

local function test_html_interpolation_types_through_safe_html()
  local out = gen(
    "{{type Page from myapp.page}}\n{{mode html}}{{.body | cosmic.html.safe}}",
    "t")
  assert(out:match("local v1: html%.SafeHtml = html%.safe%(d%.body%)"), out)
  assert(out:match("parts%[#parts %+ 1%] = v1%.raw"), out)
end

local function test_html_interpolation_with_no_stage_stays_untyped_as_string()
  -- The generator does not know html.safe from any other function — it
  -- only ever wraps an interpolation's expression in a `SafeHtml`
  -- annotation. Given no pipeline stage, the expression is the raw
  -- field access, so the checker (not this module) is what turns a
  -- missing escaper into an error; see init_test.tl.
  local out = gen(
    "{{type Page from myapp.page}}\n{{mode html}}{{.body}}", "t")
  assert(out:match("local v1: html%.SafeHtml = d%.body"), out)
end

local function test_pipeline_stage_calls_are_ordinary_function_calls()
  local out = gen(
    "{{type Page from myapp.page}}{{.body | myapp.filters.upper}}", "t")
  assert(out:match('local filters = require%("myapp%.filters"%)'), out)
  assert(out:match("filters%.upper%(d%.body%)"), out)
end

local function test_range_opens_a_fresh_dot_variable_never_shadowed()
  local out = gen(
    "{{type Page from myapp.page}}{{range .items}}{{.}}{{end}}", "t")
  assert(out:match('for _, d1 in ipairs%(d%.items%) do'), out)
  assert(not out:match("for _, d in ipairs"),
    "range must not reuse the outer dot variable's name")
end

local function test_with_rescopes_dot_to_a_fresh_variable()
  local out = gen(
    "{{type Page from myapp.page}}{{with .user}}{{.name}}{{end}}", "t")
  assert(out:match("local d1 = d%.user"), out)
  assert(out:match("d1%.name"), out)
end

local function test_nested_range_allocates_distinct_dot_variables()
  local out = gen(
    "{{type Page from myapp.page}}" ..
    "{{range .items}}{{range .items}}{{.}}{{end}}{{end}}", "t")
  assert(out:match("for _, d1 in ipairs%(d%.items%) do"), out)
  assert(out:match("for _, d2 in ipairs%(d1%.items%) do"), out)
end

local function test_if_else_both_branches_generate()
  local out = gen(
    "{{type Page from myapp.page}}{{if .ok}}yes{{else}}no{{end}}", "t")
  assert(out:match("if d%.ok then"), out)
  assert(out:match('"yes"'), out)
  assert(out:match("else"), out)
  assert(out:match('"no"'), out)
end

local function test_two_stages_from_the_same_module_share_one_import()
  local out = gen(
    "{{type Page from myapp.page}}{{.a | cosmic.html.safe}}" ..
    "{{.b | cosmic.html.trusted}}", "t")
  local _, count = out:gsub('require%("cosmic%.html"%)', "")
  assert(count == 1, "expected one require for cosmic.html, got " .. count)
end
