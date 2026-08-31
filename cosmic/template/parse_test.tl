#!/usr/bin/env cosmic
local parse = require("cosmic.template.parse")

local function test_type_decl_is_required_first()
  local t, err = parse.parse("hello", "t")
  assert(not t, "expected an error with no {{type}} declaration")
  assert(err:match("^t:1:1: "), "got: " .. err)
end

local function test_type_decl_sets_name_and_import_path()
  local t, err = parse.parse("{{type Page from myapp.page}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  assert(t.type_name == "Page", t.type_name)
  assert(t.import_path == "myapp.page", t.import_path)
  assert(t.mode == "text", "default mode should be text, got " .. t.mode)
end

local function test_mode_decl_sets_mode()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}\n{{mode html}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  assert(t.mode == "html", t.mode)
end

local function test_bad_mode_value_is_an_error()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{mode xml}}", "t")
  assert(not t, "expected an error for an unknown mode")
  assert(err:match("'html' or 'text'"), "got: " .. err)
end

local function test_body_holds_text_and_interp_nodes()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}<h1>{{.title}}</h1>", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  assert(#t.body == 3, "expected 3 nodes, got " .. #t.body)
  assert(t.body[1].kind == "text" and t.body[1].text == "<h1>")
  assert(t.body[2].kind == "interp")
  assert(#t.body[2].pipeline.path == 1 and t.body[2].pipeline.path[1] == "title")
  assert(t.body[3].kind == "text" and t.body[3].text == "</h1>")
end

local function test_bare_dot_is_an_empty_path()
  local t, err = parse.parse("{{type Page from myapp.page}}{{.}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  assert(#t.body[1].pipeline.path == 0,
    "expected an empty path, got " .. #t.body[1].pipeline.path)
end

local function test_pipeline_stages_split_module_and_func()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{.body | cosmic.html.safe}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  local stage = t.body[1].pipeline.stages[1]
  assert(stage.module_path == "cosmic.html", stage.module_path)
  assert(stage.func_name == "safe", stage.func_name)
  assert(stage.import_path == "cosmic.html.safe", stage.import_path)
end

local function test_pipeline_stage_needs_a_module()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{.body | nodot}}", "t")
  assert(not t, "expected an error for a stage with no module")
  assert(err:match("not a function reached by import path"), "got: " .. err)
end

local function test_if_without_else()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{if .ok}}yes{{end}}after", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  local node = t.body[1]
  assert(node.kind == "if")
  assert(#node.body == 1 and node.body[1].text == "yes")
  assert(#node.else_body == 0, "expected no else branch")
  assert(t.body[2].text == "after", t.body[2].text)
end

local function test_if_with_else()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{if .ok}}yes{{else}}no{{end}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  local node = t.body[1]
  assert(#node.body == 1 and node.body[1].text == "yes")
  assert(#node.else_body == 1 and node.else_body[1].text == "no")
end

local function test_range_rebinds_dot()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{range .items}}<li>{{.}}</li>{{end}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  local node = t.body[1]
  assert(node.kind == "range")
  assert(node.pipeline.path[1] == "items")
  assert(#node.body == 3, "expected 3 nodes inside range, got " .. #node.body)
end

local function test_with_rescopes_dot()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{with .user}}{{.name}}{{end}}", "t")
  assert(t, "expected a template, got error: " .. tostring(err))
  assert(t.body[1].kind == "with")
  assert(t.body[1].pipeline.path[1] == "user")
end

local function test_missing_end_is_an_error()
  local t, err = parse.parse(
    "{{type Page from myapp.page}}{{if .ok}}yes", "t")
  assert(not t, "expected an error for a missing {{end}}")
  assert(err:match("missing {{end}}"), "got: " .. err)
end

local function test_else_outside_if_is_an_error()
  local t, _err = parse.parse(
    "{{type Page from myapp.page}}{{range .xs}}{{else}}{{end}}", "t")
  assert(not t, "expected an error: {{else}} only belongs inside {{if}}")
end

local function test_type_name_must_be_a_plain_identifier()
  local t, err = parse.parse("{{type not.valid from myapp.page}}", "t")
  assert(not t, "expected an error for a dotted type name")
  assert(err:match("not a valid type name"), "got: " .. err)
end
