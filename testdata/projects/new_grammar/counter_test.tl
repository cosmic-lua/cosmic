local Counter = require("counter")
local Html = require("cosmic.html")
local report = require("report")

local function test_a_counter_counts_the_words_it_is_given()
  local counter = Counter.new("words")
  assert(counter:add("a") == 1 and counter:add("b") == 2)
  assert(counter:line() == "a,b")
end

local function test_a_template_of_the_project_renders_escaped()
  local out = Html.raw(report.render({ title = "a<b", words = { "x" }, note = nil }))
  assert(out:find("<h1>a&lt;b</h1>", 1, true) ~= nil, out)
  assert(out:find("<li>x</li>", 1, true) ~= nil, out)
end
