--- Examples for the cosmic.template module.
--- Demonstrates compiling template text to typed Teal module source in
--- both text and HTML mode, and what a missing escaper looks like.

-- Example_compile demonstrates the whole shape: a template names its
-- data type up front, and compile() emits a Teal module that requires
-- it and exports render(d: T): string.
local function Example_compile()
  local template = require("cosmic.template")
  local src = "{{type Page from cosmic.template.testdata.fixture_page}}" ..
  "<h1>{{.title}}</h1>"
  local out = assert(template.compile(src, "page"))
  print(out)
  -- Output:
  -- local fixture_page = require("cosmic.template.testdata.fixture_page")
  --
  -- local function render(d: fixture_page.Page): string
  --   local parts: {string} = {}
  --   parts[#parts + 1] = "<h1>"
  --   -- page:1
  --   local v1: string = d.title
  --   parts[#parts + 1] = v1
  --   parts[#parts + 1] = "</h1>"
  --   return table.concat(parts)
  -- end
  --
  -- return {render = render}
  --
end

-- Example_compile_html demonstrates {{mode html}}: render returns
-- cosmic.html.SafeHtml, and every interpolation is typed through it —
-- here by piping .body through cosmic.html.safe, the explicit escaper.
-- A raw {{.body}} with no escaper would compile to the same shape but
-- with `d.body` (a plain string) where SafeHtml is required, which
-- cosmic --check types then refuses at that exact line.
local function Example_compile_html()
  local template = require("cosmic.template")
  local src = "{{type Page from cosmic.template.testdata.fixture_page}}\n" ..
  "{{mode html}}<p>{{.body | cosmic.html.safe}}</p>"
  local out = assert(template.compile(src, "page"))
  print(out)
  -- Output:
  -- local fixture_page = require("cosmic.template.testdata.fixture_page")
  -- local html = require("cosmic.html")
  --
  -- local function render(d: fixture_page.Page): html.SafeHtml
  --   local parts: {string} = {}
  --   parts[#parts + 1] = "<p>"
  --   -- page:2
  --   local v1: html.SafeHtml = html.safe(d.body)
  --   parts[#parts + 1] = v1.raw
  --   parts[#parts + 1] = "</p>"
  --   return html.trusted(table.concat(parts))
  -- end
  --
  -- return {render = render}
  --
end

-- Example_compile_rejects_malformed_template demonstrates the fallible
-- boundary: a template with no leading {{type}} declaration fails to
-- compile with a message carrying the template's own name and position.
local function Example_compile_rejects_malformed_template()
  local template = require("cosmic.template")
  local out, err = template.compile("<p>no type declaration</p>", "broken")
  print(out, err)
  -- Output:
  -- nil	broken:1:1: expected '{{type <Record> from <import.path>}}'
end

-- Suppress unused warnings for examples
local _ = {Example_compile, Example_compile_html,
  Example_compile_rejects_malformed_template}
