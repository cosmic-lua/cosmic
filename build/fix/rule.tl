--- The structural rewrite stage of `cosmic fix`, and the list of rules
--- it applies.
---
--- The list is empty today, on purpose. The rules worth writing are
--- lint fixes, and those lint rules have not yet been implemented.
--- What matters now is
--- that the stage is real and sits where it belongs: a rule matches a
--- structural PATTERN over the parsed tree and replaces it with another
--- (`build.ast.match` and `build.ast.rewrite`), and whatever it
--- produces goes through the renderer before it reaches a file. A fix
--- is therefore never a hand-rolled patch over source text, and its
--- result is never a raw splice -- adding a rule here is the whole cost
--- of a new fix, with no part of the pipeline to restructure around it.
---
--- `build.ast.rewrite` refuses any single hit that would silently drop
--- a comment, reporting it rather than applying it, so a rule that
--- would eat a comment leaves the file alone and says so.

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
--- @return string|nil The rewritten source, or nil when a rule failed
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
