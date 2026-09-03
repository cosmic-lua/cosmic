#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")
local template = require("cosmic.template")

--- Fixture data module used by the tests below: `cosmic --docs teal`'s
--- `check_file` resolves `require("cosmic.template.testdata.fixture_page")`
--- against it directly (the module graph does not care that
--- `testdata/` is never embedded — only the shipped binary skips it).
local FIXTURE < const > = "cosmic.template.testdata.fixture_page"

local function test_compile_rejects_a_malformed_template()
  local out, err = template.compile("no type declaration", "t")
  assert(not out, "expected an error for a template with no {{type}}")
  assert(err:match("^t:1:1:"), "got: " .. err)
end

local function test_compile_emits_a_render_module()
  local out, err = template.compile(
    "{{type Page from " .. FIXTURE .. "}}<h1>{{.title}}</h1>", "page")
  assert(out, "expected generated source, got error: " .. tostring(err))
  assert(out:match("local function render"), out)
  assert(out:match("return {render = render}"), out)
end

--- The whole safety claim, gate 1: a template that escapes every
--- interpolation compiles to a module that type-checks against the
--- fixture's real record — control flow, pipelines and all.
local function test_generated_html_module_type_checks_against_fixture_data()
  local tmpdir = os.getenv("TEST_TMPDIR")
  assert(tmpdir, "TEST_TMPDIR must be set")
  local src = table.concat({
      "{{type Page from " .. FIXTURE .. "}}",
      "{{mode html}}",
      "<h1>{{.title | cosmic.html.safe}}</h1>",
      "{{if .show_body}}<p>{{.body | cosmic.html.safe}}</p>{{end}}",
      "<ul>{{range .items}}<li>{{.label | cosmic.html.safe}}</li>{{end}}</ul>",
    }, "\n")
  local out, err = template.compile(src, "page")
  assert(out, "expected generated source, got error: " .. tostring(err))

  local path = fs.join(tmpdir, "page_render.tl")
  assert(fs.write(path, out))
  local result = teal.check_file(path, {include_dirs = {"."}})
  assert(result.ok, "generated module does not type-check:\n" ..
    teal.format_issues(result.errors))
end

--- The whole safety claim, gate 2: an html-mode template that
--- interpolates a raw `string` with no escaper MUST fail to
--- type-check. A test that only exercises the happy path (gate 1
--- above) proves nothing about the actual safety property — this one
--- is the mutation-testable guard: comment out the SafeHtml annotation
--- in codegen.tl's html branch and this is the test that catches it.
local function test_html_mode_raw_string_interpolation_fails_to_type_check()
  local tmpdir = os.getenv("TEST_TMPDIR")
  assert(tmpdir, "TEST_TMPDIR must be set")
  local src = table.concat({
      "{{type Page from " .. FIXTURE .. "}}",
      "{{mode html}}",
      "<p>{{.body}}</p>", -- no escaper: .body is a raw string
    }, "\n")
  local out, err = template.compile(src, "unsafe")
  assert(out, "expected generated source, got error: " .. tostring(err))

  local path = fs.join(tmpdir, "unsafe_render.tl")
  assert(fs.write(path, out))
  local result = teal.check_file(path, {include_dirs = {"."}})
  assert(not result.ok,
    "an unescaped string interpolation in HTML mode must fail to type-check")
  local msg = (result.errors[1] and result.errors[1].message) or ""
  assert(msg:match("SafeHtml"),
    "expected the error to name SafeHtml, got: " .. msg)
end

--- Gate 1 for the non-default contexts: a template that escapes with
--- each context's own module type-checks against the fixture.
local function test_generated_html_module_type_checks_with_every_context()
  local tmpdir = os.getenv("TEST_TMPDIR")
  assert(tmpdir, "TEST_TMPDIR must be set")
  local src = table.concat({
      "{{type Page from " .. FIXTURE .. "}}",
      "{{mode html}}",
      '<a href="{{url .title | cosmic.url.safe_path}}"',
      ' data-x="{{attr .body | cosmic.html.safe_attr}}">',
      "<script>var t = \"{{js .title | cosmic.js.safe}}\";</script>",
      "<style>a { color: {{css .body | cosmic.css.safe}}; }</style>",
      "</a>",
    }, "\n")
  local out, err = template.compile(src, "contexts")
  assert(out, "expected generated source, got error: " .. tostring(err))

  local path = fs.join(tmpdir, "contexts_render.tl")
  assert(fs.write(path, out))
  local result = teal.check_file(path, {include_dirs = {"."}})
  assert(result.ok, "generated module does not type-check:\n" ..
    teal.format_issues(result.errors))
end

--- Gate 2 for the non-default contexts, and the mutation-testable
--- guard this item adds: an interpolation bound to one context's Safe*
--- type MUST NOT be satisfiable by another context's escaper — a
--- `{{js ...}}` slot fed `cosmic.html.safe` fails to type-check, naming
--- SafeJs (what was needed) at the template's own line.
local function test_html_mode_wrong_context_escaper_fails_to_type_check()
  local tmpdir = os.getenv("TEST_TMPDIR")
  assert(tmpdir, "TEST_TMPDIR must be set")
  local src = table.concat({
      "{{type Page from " .. FIXTURE .. "}}",
      "{{mode html}}",
      "<script>var t = \"{{js .title | cosmic.html.safe}}\";</script>",
    }, "\n")
  local out, err = template.compile(src, "mismatched")
  assert(out, "expected generated source, got error: " .. tostring(err))

  local path = fs.join(tmpdir, "mismatched_render.tl")
  assert(fs.write(path, out))
  local result = teal.check_file(path, {include_dirs = {"."}})
  assert(not result.ok,
    "an html.safe value in a {{js}} slot must fail to type-check")
  local msg = (result.errors[1] and result.errors[1].message) or ""
  assert(msg:match("SafeJs"), "expected the error to name SafeJs, got: " .. msg)
end

local function test_text_mode_needs_no_escaper()
  local tmpdir = os.getenv("TEST_TMPDIR")
  assert(tmpdir, "TEST_TMPDIR must be set")
  local out, err = template.compile(
    "{{type Page from " .. FIXTURE .. "}}<h1>{{.title}}</h1>", "plain")
  assert(out, "expected generated source, got error: " .. tostring(err))
  local path = fs.join(tmpdir, "plain_render.tl")
  assert(fs.write(path, out))
  local result = teal.check_file(path, {include_dirs = {"."}})
  assert(result.ok, "text-mode module does not type-check:\n" ..
    teal.format_issues(result.errors))
end
