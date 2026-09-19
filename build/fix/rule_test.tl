--- That a rule registered in `build.fix.rule` actually reaches a file,
--- end to end.
---
--- Each case temporarily registers a real rule and runs the whole
--- pipeline: pattern compiled, tree matched, replacement spliced,
--- result rendered, and the render checked against its tree.
---
--- The fixtures are deliberately mangled around the part a rule
--- touches. A pipeline that spliced and returned would give the mangled
--- spacing straight back; only one that renders produces the text these
--- cases expect.

local fix = require("build.fix")
local rule = require("build.fix.rule")
local teal = require("build.teal")

local type Rule = rule.Rule

local built, load_trouble = teal.load()
if built == nil then
  error("could not load the compiler: " .. tostring(load_trouble))
end

--- Run `body` with `probe` as the one registered rule, and put the list
--- back the way it was found afterwards, however `body` ends. The list
--- is module state shared with every other test in this run; preserve
--- its identity and any production rules already registered.
--- @param probe Rule
--- @param body function(): (any...)
local function with_rule(probe: Rule, body: function(): (any...))
  local registered = rule.rules
  local saved: {Rule} = {}
  for i, r in ipairs(registered) do
    saved[i] = r
  end
  for i = #registered, 1, -1 do
    registered[i] = nil
  end
  registered[1] = probe
  local ok, trouble = pcall(body)
  for i = #registered, 1, -1 do
    registered[i] = nil
  end
  for i, r in ipairs(saved) do
    registered[i] = r
  end
  assert(ok, tostring(trouble))
end

--- The probe itself: one call rewritten into another, keeping whatever
--- the call was passed.
local probe: Rule = {
  name = "probe",
  pattern = "print($X)",
  replacement = "log($X)",
}

--- Run the whole verb over `source` with `probe` registered, asserting
--- it succeeded, and hand back what it would write.
--- @param source string
--- @return string
local function fixed(source: string): string
  local out = ""
  with_rule(probe, function()
    local result, trouble = fix.source(built, source, "probe.tl")
    assert(result ~= nil, "fix refused it: " .. tostring(trouble))
    out = result.source
  end)
  return out
end

--- A registered rule reaches the file, and what comes back is rendered:
--- the table literal beside the rewritten call is spaced the way the
--- renderer spaces one, not the way the fixture wrote it.
local function test_a_registered_rule_rewrites_and_the_result_is_rendered()
  local got = fixed("local t = {1,2}\nprint( t )\n")
  assert(got == "local t = { 1, 2 }\nlog(t)\n", "got:\n" .. got)
end

--- Every hit, not just the first, and the capture carries its own
--- expression across rather than its text.
local function test_every_hit_is_rewritten_and_captures_carry_over()
  local got = fixed("print(a)\nprint(b + 1)\nprint(f(c))\n")
  assert(got == "log(a)\nlog(b + 1)\nlog(f(c))\n", "got:\n" .. got)
end

--- A file with nothing to match comes back as the renderer would have
--- written it anyway, and reports itself unchanged when it already is.
local function test_a_file_with_no_hit_is_left_to_the_renderer()
  local got = fixed("local t = {1,2}\nreport(t)\n")
  assert(got == "local t = { 1, 2 }\nreport(t)\n", "got:\n" .. got)
  local unchanged = fixed("local t = { 1, 2 }\nreport(t)\n")
  assert(unchanged == "local t = { 1, 2 }\nreport(t)\n", "got:\n" .. unchanged)
end

--- Matching is structural, not textual: the pattern finds a call the
--- source spread over three lines, and does not find a name that merely
--- contains the one it names, or that name used as something other than
--- a call.
---
--- What replaces the hit is the replacement's own shape, not the
--- match's: the template is written on one line, so the call comes back
--- on one. A rule that wants otherwise writes its template that way.
local function test_the_match_is_structural_and_not_textual()
  local got = fixed("print(\n  a\n)\nsprint(b)\nprint = 1\n")
  assert(got == "log(a)\nsprint(b)\nprint = 1\n", "got:\n" .. got)
end

--- A rule whose pattern will not compile stops the file and is reported
--- under its own name, rather than silently applying nothing.
local function test_a_rule_that_will_not_compile_is_named()
  with_rule({ name = "broken", pattern = "local local", replacement = "x" },
    function()
      local result, trouble = fix.source(built, "print(a)\n", "probe.tl")
      assert(result == nil, "a pattern that does not parse should refuse")
      assert(trouble:find("broken", 1, true) ~= nil, "got: " .. trouble)
    end)
end

--- A hit whose replacement would swallow a comment is left unmodified,
--- comment and all, which is `build.ast.rewrite`'s own refusal reaching
--- through this stage. `rule.apply` reads only the spliced code and
--- does not pass the refusal list on, so the file's other hits are
--- rewritten around it and nothing is said -- what matters, and what
--- this pins, is that the comment is still there afterwards.
local function test_a_hit_that_would_eat_a_comment_is_left_alone()
  local got = fixed("print( -- why\n  a)\nprint(b)\n")
  assert(got == "print( -- why\n  a)\nlog(b)\n", "got:\n" .. got)
end

--- Nested probes restore a nonempty registry, including after a body
--- changes the list and raises an error.
local function test_temporary_rules_restore_the_existing_registry()
  local registered = rule.rules
  local other: Rule = {
    name = "other",
    pattern = "log($X)",
    replacement = "report($X)",
  }
  with_rule(probe, function()
    registered[2] = other
    with_rule(other, function()
      assert(rule.rules == registered)
      assert(#registered == 1 and registered[1] == other)
      registered[2] = probe
      registered[3] = other
    end)
    assert(rule.rules == registered)
    assert(#registered == 2)
    assert(registered[1] == probe and registered[2] == other)
    local ok, trouble = pcall(function(): (any...)
      with_rule(other, function()
        registered[1] = nil
        error("probe failure")
      end)
    end)
    assert(not ok and tostring(trouble):find("probe failure", 1, true) ~= nil)
    assert(rule.rules == registered)
    assert(#registered == 2)
    assert(registered[1] == probe and registered[2] == other)
  end)
end
