--- What the code generator and the translator take as true of a value from its syntax alone ([`lang.codegen`], [`lang.translate`]):
--- the rule that tells an `if` expression whose middle operand is never false, which is written `c and a or b`, from
--- one that needs a function called on the spot. The driver gives it for every source, the translated and the
--- written in the new grammar alike, so a file's `if` expression compiles to the same Lua whichever way the file came.
local Ast = require("lang.ast")

local record Truthy
  --- Whether `e` can be neither false nor nil, from its syntax alone: a literal that is no `false`, a table, a function,
  --- an arithmetic or concatenation (the language has no metamethod to make one answer false), or a parenthesized or cast
  --- one of those. A cast does not make a value truthy: `v as string` is false or nil when `v` is. It is what the
  --- translator needs of a middle operand to write an `if` expression, and what a code generator may take as truthy.
  never_false: function(e: Ast.Exp): boolean
end

--- The operators that answer a number or a string.
local NUMBERY <const>: {string: boolean} = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true, ["^"] = true,
  [".."] = true, ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true,
}

-- TODO: write the `if` expression for a middle operand that is neither boolean nor
-- optional by the type report and not by its syntax, once the new checker's
-- type report keyed by node id exists (doc/plans/new-checker-grammar.md, "the
-- interface"): a name or a call stays a ternary until then.
function Truthy.never_false(e: Ast.Exp): boolean
  local cur: Ast.Node = e
  while true do
    if cur is Ast.Paren then
      cur = cur.inner
    elseif cur is Ast.Cast then
      -- A cast is a promise about the type, not a value: `v as string` is false or nil when `v` is.
      cur = cur.value
    elseif cur is Ast.Binary then
      return NUMBERY[cur.op] == true
    elseif cur is Ast.Unary then
      local op = cur.op
      return op == "-" or op == "#" or op == "~"
    elseif cur is Ast.Boolean then
      return cur.value
    else
      return cur is Ast.String or cur is Ast.Integer or cur is Ast.Float or cur is Ast.Table or
        cur is Ast.FunctionLit
    end
  end
end

return Truthy
