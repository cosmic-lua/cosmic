--- The structural rewrite stage of `cosmic fix`, and the list of rules
--- it applies.
---
--- A rule matches a structural pattern over the parsed tree and replaces
--- it with another (`build.ast.match` and `build.ast.rewrite`), and
--- whatever it produces goes through the renderer before it reaches a
--- file. A fix is therefore never a hand-rolled patch over source text
--- and its result is never a raw splice. Adding a rule to the list is
--- the whole cost of a new fix.
---
--- The list is empty, because the rules worth writing are lint fixes.
---
--- `build.ast.rewrite` refuses any single hit that would drop a comment.
--- `apply` fails on such a hit, naming the rule, the line and the
--- comments, so the file is reported and left as it was rather than
--- half fixed with nothing said.

local ast = require("build.ast")
local type compiler = require("build.compiler")

--- One rewrite: a pattern in `build.ast.match`'s own `$NAME`/`$$$NAME`
--- surface syntax, and what to put in its place.
local record Rule
  --- What the rule is for, named in whatever the pipeline reports.
  name: string
  pattern: string
  replacement: string
end

local rules: {Rule} = {}

--- Apply every rule to `source`, in order.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source string
--- @param name string Filename used in diagnostics
--- @return string|nil The rewritten source, or nil when a rule failed or
--- had a hit refused
--- @return string Error message on failure
local function apply(built: compiler, source: string,
                     name: string): string | nil, string
  local out = source
  for _, r in ipairs(rules) do
    local pattern, why = ast.compile_pattern(built, r.pattern)
    if pattern == nil then
      return nil, r.name .. ": " .. why
    end
    local result, trouble = ast.rewrite(built, out, name, pattern, r.replacement)
    if result == nil then
      return nil, r.name .. ": " .. trouble
    end
    if #result.refused > 0 then
      local said: {string} = {}
      -- `refused` runs last hit first; report in source order.
      for i = #result.refused, 1, -1 do
        local refusal = result.refused[i]
        said[#said + 1] = "line " .. ast.span_start(refusal.node).y ..
          " would drop " .. table.concat(refusal.comments, ", ")
      end
      return nil, r.name .. ": hit refused, " .. table.concat(said, "; ")
    end
    out = result.code
  end
  return out
end

local record RuleModule
  type Rule = Rule
  rules: {Rule}
  apply: function(built: compiler, source: string, name: string): string | nil, string
end

local M: RuleModule = {
  rules = rules,
  apply = apply,
}

return M
