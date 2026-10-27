--- What the code generator and the translator take as true of a value from its syntax alone ([`lang.codegen`], [`lang.translate`]):
--- the rule that tells an `if` expression whose middle operand is never false, which is written `c and a or b`, from
--- one that needs a function called on the spot. The driver gives it for every source, the translated and the
--- written in the new grammar alike, so a file's `if` expression compiles to the same Lua whichever way the file came.
--- A build that keeps the types of its nodes adds the checker's: [`Truthy.may_be_false`] of the type of a name or a call.
local Ast = require("lang.ast")
local Types = require("lang.types")

local record Truthy
  --- Whether `e` can be neither false nor nil, from its syntax alone: a literal that is no `false`, a table, a function,
  --- an arithmetic or concatenation (the language has no metamethod to make one answer false), or a parenthesized or cast
  --- one of those. A cast does not make a value truthy: `v as string` is false or nil when `v` is. It is what the
  --- translator needs of a middle operand to write an `if` expression, and what a code generator may take as truthy.
  never_false: function(e: Ast.Exp): boolean
  --- Whether a value of the checker's type `t` can be false or nil: a boolean, `true`, `false`, `nil`, an optional, and
  --- a type that says nothing of the value (`any`, a variable, an invalid or empty one). Every other type is a kind of
  --- value that is neither, so the value of an expression the checker typed so is truthy.
  may_be_false: function(t: Types.Type): boolean
end

--- The operators that answer a number or a string.
local NUMBERY <const>: {string: boolean} = {
  ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true, ["^"] = true,
  [".."] = true, ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true,
}

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

function Truthy.may_be_false(whole: Types.Type): boolean
  -- A recursive alias is its body one level down (`type Json = boolean | {Json}` can be false): the body mentions the alias
  -- again only inside an array or a map, so one step is all there is.
  local t = Types.unfold(whole)
  local tag = t.tag
  if tag == "boolean" or tag == "true" or tag == "false" or tag == "nil" or tag == "any" or tag == "invalid" or
      tag == "never" or tag == "var" then
    return true
  end
  if (t.tag == "union") then
    if t.nilable then
      return true
    end
    for _, member in ipairs(t.members) do
      if Truthy.may_be_false(member) then
        return true
      end
    end
  end
  return false
end

return Truthy
