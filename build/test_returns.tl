--- The places a test returns early, which [`build.tree_checks`]'s `test_returns` refuses: a test that cannot check its
--- subject on this host declares `requires` or calls `Test.skip(reason)` (doc/testing.md, "skipping"), because a bare
--- `return` passes having checked nothing and keeps a verdict that stands on a host it never ran on.
---
--- Read off the tree of the new checker ([`lang.ast`]), only the statements that stand directly in the body of a
--- top-level `local function test_*`: `if <condition> then return end` (one arm, no `else`, nothing but a bare `return`
--- in it) and a bare `return`, except one that follows a call of [`Test.skip`] (the idiom for the platform that is not
--- the test's). A `return` deeper in the test, in a branch that also asserts, in a loop, a callback or a helper, is no
--- skip and is not read.
local Ast = require("lang.ast")
local Node = require("build.syntax_node")

local record TestReturns
  --- Every early return of a test in the tree `chunk` ([`Node.parse`]), as `{line, test, shape}` in source order: the
  --- line of the `return`, the name of the test, and `if ... then return end` or `return`.
  of_chunk: function(chunk: Ast.Chunk): {{string}}
end

--- Whether `stat` is a call of [`Test.skip`].
local function is_skip(stat: Ast.Stat): boolean
  if stat.kind ~= "CallStat" then return false end
  local call = stat.call
  if call.kind ~= "Call" then return false end
  local callee = call.callee
  return callee.kind == "Field" and callee.name == "skip" and callee.object.kind == "Name" and
    callee.object.text == "Test"
end

--- Whether `stat` is a `return` of no value.
local function is_bare_return(stat: Ast.Stat): boolean
  return stat.kind == "Return" and #stat.values == 0
end

--- The shape of the early return `stat` is, or nil where it is none: `if ... then return end`, or a bare `return`.
--- `before` is the statement in front of it, if any.
local function early(stat: Ast.Stat, before: Ast.Stat?): string?
  if stat.kind == "If" then
    if #stat.arms == 1 and stat.else_body == nil then
      local arm = stat.arms[1]
      if #arm.body.stats == 1 and is_bare_return(assert(arm.body.stats[1])) then
        return "if ... then return end"
      end
    end
    return nil
  end
  if is_bare_return(stat) and not (before ~= nil and is_skip(before)) then return "return" end
  return nil
end

function TestReturns.of_chunk(chunk: Ast.Chunk): {{string}}
  local sites: mut {{string}} = {}
  for _, top in ipairs(chunk.body.stats) do
    if top.kind == "LocalFunction" and top.name.name:match("^test_") ~= nil then
      local before: Ast.Stat? = nil
      for _, stat in ipairs(top.fn.body.stats) do
        local shape = early(stat, before)
        if shape ~= nil then
          table.insert(sites, { tostring(Node.span(chunk, stat).y), top.name.name, shape })
        end
        before = stat
      end
    end
  end
  return sites
end

return TestReturns
