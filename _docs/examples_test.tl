#!/usr/bin/env cosmic
-- The derived example fence: a fence naming an `Example_*` function
-- carries exactly that function's body, and a fence naming nothing that
-- exists is reported rather than left as typed.

local check = require("cosmic.check")
local examples = require("_docs.examples")
local fs = require("cosmic.fs")

local tmpdir = check.must(os.getenv("TEST_TMPDIR"))

--- An example file with two functions: one plain, one holding a record
--- whose own `end` must not close the body early.
local SOURCE < const > = [[
--- Examples for a fixture module.

local function Example_plain()
  local x = 1
  print(x)
  -- Output:
  -- 1
end

-- Example_nested keeps a record inside the body.
local function Example_nested()
  local record Point
    x: integer
  end
  local p: Point = {x = 2}
  print(p.x)
  -- Output:
  -- 2
end

local _ = {Example_plain, Example_nested}
]]

local function fixture(): string
  local path = fs.join(tmpdir, "fixture_example.tl")
  assert(fs.write(path, SOURCE))
  return path
end

local function test_parse_ref_reads_path_and_name()
  local ref = examples.parse_ref(" example=cosmic/json_example.tl#Example_decode")
  assert(ref, "a fence with example= is derived")
  check.equal(ref.path, "cosmic/json_example.tl", "path")
  check.equal(ref.name, "Example_decode", "name")
  assert(examples.parse_ref(" file=greet/text.tl") == nil, "file= is not a derivation")
  assert(examples.parse_ref("") == nil, "a bare fence is not a derivation")
end

local function test_body_is_dedented_and_trimmed()
  local path = fixture()
  local body = check.must(examples.body_of({path = path, name = "Example_plain"}))
  check.equal(body, "local x = 1\nprint(x)\n-- Output:\n-- 1", "body")
end

local function test_a_record_inside_the_body_does_not_close_it()
  local path = fixture()
  local body = check.must(examples.body_of({path = path, name = "Example_nested"}))
  assert(body:find("-- Output:\n-- 2$"), "the body runs to the function's own end: " .. body)
  assert(body:find("^local record Point\n  x: integer\nend"),
    "the nested record keeps its relative indentation: " .. body)
end

local function test_a_missing_function_is_reported()
  local path = fixture()
  local body, err = examples.body_of({path = path, name = "Example_absent"})
  assert(body == nil, "no body for a function that is not there")
  assert(err:find("no `local function Example_absent()`", 1, true), err)
  local body2, err2 = examples.body_of({path = fs.join(tmpdir, "gone.tl"), name = "Example_x"})
  assert(body2 == nil and err2:find("cannot read", 1, true), tostring(err2))
end

local function test_fences_carry_line_indent_and_body()
  local text = "# t\n\n```teal example=a.tl#Example_a\nold\n```\n\n- item\n" ..
  "  ```teal example=b.tl#Example_b\n  x\n  ```\n\n```teal\nplain\n```\n"
  local found = examples.fences(text)
  check.equal(#found, 2, "two derived fences, the plain one skipped")
  check.equal(found[1].line, 3, "first fence line")
  check.equal(found[1].body, "old", "first body")
  check.equal(found[2].indent, "  ", "list indentation")
  check.equal(found[2].body, "x", "indentation stripped from the body")
  check.equal(found[2].ref.name, "Example_b", "second ref")
end

local function test_render_fills_fences_and_keeps_prose()
  local path = fixture()
  local text = "before\n\n```teal example=" .. path .. "#Example_plain\nstale\n```\n\nafter\n" ..
  "- ```teal example=" .. path .. "#Example_nested\n  ```\n"
  local out, problems = examples.render(text)
  check.equal(#problems, 0, "every reference resolves")
  assert(out:find("before\n\n```teal example=", 1, true), "prose before survives")
  assert(out:find("\nlocal x = 1\nprint(x)\n-- Output:\n-- 1\n```\n\nafter\n", 1, true),
    "the stale body is replaced: " .. out)
  assert(out:find("\n- ```teal example=", 1, true), "an indented fence keeps its position")
  assert(out:find("\n  local record Point\n    x: integer\n  end\n", 1, true),
    "an indented fence's body carries the indentation: " .. out)
  local again, _ = examples.render(out)
  check.equal(again, out, "rendering is idempotent")
end

local function test_render_reports_an_unresolvable_reference()
  local path = fixture()
  local text = "```teal example=" .. path .. "#Example_absent\nkept\n```\n"
  local out, problems = examples.render(text)
  check.equal(#problems, 1, "one problem")
  assert(problems[1]:find("Example_absent", 1, true), problems[1])
  check.equal(out, text, "an unresolvable fence is left as written")
end

local function test_documents_are_the_gated_population()
  local docs = examples.documents()
  assert(#docs > 0, "documents found")
  local seen_readme = false
  for _, path in ipairs(docs) do
    assert(path:sub(-3) == ".md", "markdown only: " .. path)
    if path == "README.md" then seen_readme = true end
  end
  assert(seen_readme, "README.md is in the population")
end
