--- What the code generator takes as true of a value from its syntax alone ([`lang.codegen`]):
--- the rule that tells an `if` expression whose middle operand is never false, which is written `c and a or b`, from
--- one that needs a function called on the spot. The driver gives it for every source, so a file's `if` expression
--- compiles to the same Lua wherever it is compiled.
local Ast = require("lang.ast")

local record Truthy
  --- Whether `e` can be neither false nor nil, from its syntax alone: a literal that is no `false`, a table, a function,
  --- an arithmetic or concatenation (the language has no metamethod to make one answer false), or a parenthesized or cast
  --- one of those. A cast does not make a value truthy: `v as string` is false or nil when `v` is. It is what a middle operand needs for an `if`
  --- expression to be written as `c and a or b`, and what a code generator may take as truthy.
  never_false: function(e: Ast.Exp): boolean
end

--- The operators that answer a number or a string.
local NUMBERY <const>: {string: boolean} = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true, ["^"] = true,
  [".."] = true, ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true,
}

-- TODO: write the `if` expression for a middle operand that is neither boolean nor
-- optional by the type report and not by its syntax, once the new checker's
-- type report keyed by node id exists: a name or a call stays a ternary until then.
function Truthy.never_false(e: Ast.Exp): boolean
  local cur: Ast.Node = e
  while true do
    if (cur.kind == "Paren") then
      cur = cur.inner
    elseif (cur.kind == "Cast") then
      -- A cast is a promise about the type, not a value: `v as string` is false or nil when `v` is.
      cur = cur.value
    elseif (cur.kind == "Binary") then
      return NUMBERY[cur.op] == true
    elseif (cur.kind == "Unary") then
      local op = cur.op
      return op == "-" or op == "#" or op == "~"
    elseif (cur.kind == "Boolean") then
      return cur.value
    else
      return (cur.kind == "String") or (cur.kind == "Integer") or (cur.kind == "Float") or (cur.kind == "Table") or
        (cur.kind == "FunctionLit")
    end
  end
end

return Truthy
