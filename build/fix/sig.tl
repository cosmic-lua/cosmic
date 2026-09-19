--- A function's signature: its type parameters, its argument list, and
--- its return types.
---
--- Shared, because the three places a function is written -- a `local
--- function`, a `function M.f`, and a function literal inside an
--- expression -- differ only in what comes before the `(`.
---
--- An argument is written from its own node: the name, a `?` when the
--- parser marked it optional, and then its type as original bytes. The
--- implicit `self` of a method is skipped rather than written, because
--- tl's parser puts one in the argument list at the `(`'s own position
--- and the source never spelled it.
---
--- Every type region here is anchored on PUNCTUATION -- the `:` after
--- an argument's name, the `:` after the argument list's `)` -- rather
--- than on the type object's own recorded position. A type object's
--- position is not always its own: tl stamps a generic type at the end
--- of the file it came from, so anchoring on it runs a region off the
--- end of the source and swallows whatever follows.

local ast = require("build.ast")
local ctx_mod = require("build.fix.ctx")
local emit = require("build.fix.emit")
local typescan = require("build.fix.typescan")

local type Node = ast.Node
local type TypeNode = ast.TypeNode
local type Ctx = ctx_mod.Ctx

local function refuse(c: Ctx, what: string)
  c.refused[#c.refused + 1] = what
end

--- The arguments the source actually wrote, in order: a method's
--- implicit `self` is in the parser's list but not in the text.
local function written(list: Node): {Node}
  local out: {Node} = {}
  for _, a in ipairs(list) do
    if a.kind == "argument" then
      out[#out + 1] = a
    end
  end
  return out
end

--- Where the type of argument `i` stops: at the next written argument,
--- or at the list's own closing parenthesis.
local function arg_bound(list: Node, args: {Node}, i: integer): integer, integer
  local next_arg = args[i + 1]
  if next_arg ~= nil then
    return next_arg.y, next_arg.x
  end
  return list.yend or list.y, list.xend or list.x
end

--- Write one argument's type annotation, when it has one.
local function arg_type(c: Ctx, list: Node, args: {Node}, i: integer)
  local a = args[i]
  if a.argtype == nil then
    return
  end
  local name = typescan.index_at(c.scan, a.y, a.x)
  if name == nil then
    refuse(c, "an argument with no token of its own")
    return
  end
  local colon = name + 1
  if typescan.tk(c.scan, colon) == "?" then
    colon = colon + 1
  end
  if typescan.tk(c.scan, colon) ~= ":" then
    refuse(c, "an argument type with no ':' before it")
    return
  end
  local by, bx = arg_bound(list, args, i)
  if not ctx_mod.annotation(c, colon + 1,
                            typescan.bounded_end(c.scan, by, bx)) then
    refuse(c, "an argument type with no tokens of its own")
  end
end

--- Write the type parameters of a generic function, when it has any.
--- They sit between `anchor` and the `(`, and the AST records them as
--- types rather than as text, so they are written as original bytes
--- like every other piece of type syntax.
--- @param c Ctx
--- @param anchor integer|nil The token a `<` would follow: a name, or `function`
local function typeargs(c: Ctx, anchor: integer | nil)
  if anchor == nil or typescan.tk(c.scan, anchor + 1) ~= "<" then
    return
  end
  ctx_mod.region(c, anchor + 1, typescan.closing_angle(c.scan, anchor + 1))
end

--- Write a whole argument list, parentheses and all. Nothing in this
--- tree writes `f( x )`, so the parentheses are closed up rather than
--- carrying a gap over.
--- @param c Ctx
--- @param list Node An "argument_list" node
local function arguments(c: Ctx, list: Node)
  emit.put(c.em, "(")
  local args = written(list)
  local close_y = list.yend or list.y
  local close_x = list.xend or list.x
  for i, a in ipairs(args) do
    if i > 1 then
      emit.put(c.em, ",")
    end
    ctx_mod.lead(c, a, i > 1 and " " or "")
    emit.text(c.em, a.tk or "")
    if a.opt and a.tk ~= "..." then
      emit.put(c.em, "?")
    end
    arg_type(c, list, args, i)
  end
  ctx_mod.lead_at(c, close_y, close_x, "")
  emit.put(c.em, ")")
end

--- Write a function's return types, when it declares any. The region
--- starts after the `:` that follows the argument list's own `)` and
--- runs to the last token before the body, so a parenthesized list
--- (`: (string, integer)`) carries its parentheses over with everything
--- else.
--- @param c Ctx
--- @param rets TypeNode The return tuple the parser built
--- @param list Node The argument list, whose `)` anchors the region
--- @param body Node The function's body, whose first token bounds it
local function returns(c: Ctx, rets: TypeNode, list: Node, body: Node)
  local declared = rets.tuple
  if declared == nil or #declared == 0 then
    return
  end
  local close = typescan.index_at(c.scan, list.yend or list.y, list.xend or list.x)
  if close == nil or typescan.tk(c.scan, close + 1) ~= ":" then
    refuse(c, "a return type with no ':' before it")
    return
  end
  if not ctx_mod.annotation(c, close + 2,
                            typescan.bounded_end(c.scan, body.y, body.x)) then
    refuse(c, "a return type with no tokens of its own")
  end
end

local record SigModule
  typeargs: function(c: Ctx, anchor: integer | nil)
  arguments: function(c: Ctx, list: Node)
  returns: function(c: Ctx, rets: TypeNode, list: Node, body: Node)
end

local M: SigModule = {
  typeargs = typeargs,
  arguments = arguments,
  returns = returns,
}

return M
