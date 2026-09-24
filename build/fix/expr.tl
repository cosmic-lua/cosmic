--- Expressions, written from their own nodes.
---
--- Every operator, separator and bracket here comes from the node's
--- kind: a call is a `(` because the node says `@funcall`, an index is
--- a `[` because it says `@index`. Nothing is decided by looking at
--- which two tokens ended up next to each other, which is the class of
--- bug this whole module exists to be incapable of.
---
--- One thing IS read off the source: where a line break goes, and where
--- one does not (`ctx.lead`). The renderer never adds a break and never
--- removes one, because doing either means deciding where to wrap, and
--- a wrap is a judgement about the whole line that no rule here is in a
--- position to make. Everything a line HOLDS is the renderer's.
---
--- Type syntax is written as original bytes: `x as {string: any}` keeps
--- its own spelling, since tl's parser keeps a type's meaning and not
--- its text.

local ast = require("build.ast")
local ctx_mod = require("build.fix.ctx")
local emit = require("build.fix.emit")
local sig = require("build.fix.sig")
local typescan = require("build.fix.typescan")

local type Node = ast.Node
local type Ctx = ctx_mod.Ctx

local expression: function(Ctx, Node)

local refuse = ctx_mod.refuse

--- What follows an `as` or an `is`, as original bytes. `anchor` is the
--- operator's own token when there is one: the type begins right after
--- it, which is a surer place to start than the type object's recorded
--- position, since tl stamps a generic type at the end of its file.
local function cast_type(c: Ctx, n: Node, anchor: integer | nil)
  local declared = n.casttype
  if declared == nil then
    refuse(c, "a cast with no type")
    return
  end
  local first = anchor ~= nil and anchor + 1
    or typescan.index_at(c.scan, declared.y, declared.x)
  if first == nil then
    refuse(c, "a cast whose type has no token of its own")
    return
  end
  ctx_mod.region(c, first, typescan.type_end(c.scan, first))
end

--- A comma-separated run of expressions, each moved to its own line
--- wherever the source put it there.
local function items(c: Ctx, list: Node, first_inline: string)
  for i, item in ipairs(list) do
    local inline = first_inline
    if i > 1 then
      emit.put(c.em, ",")
      inline = " "
    end
    ctx_mod.lead(c, item, inline)
    expression(c, item)
  end
end

--- A bracketed run of expressions: a call's arguments or a table
--- literal.
---
--- `table_like` is what separates the two. A table literal's entries
--- stand off its braces, `{ a, b }`, and a call's arguments sit against
--- its parentheses, `f(a, b)`; an empty table is `{}` either way. A
--- table whose closing brace ended up on a line of its own gets a comma
--- after its last entry, so the next entry added is one line changed
--- and not two -- and a table that closes on the same line as its last
--- entry does not, because `a, b, }` reads like something is missing.
local function bracketed(c: Ctx, list: Node, open: string, close: string,
                         table_like: boolean)
  local close_y = list.yend or list.y
  local close_x = list.xend or list.x
  local gap = table_like and " " or ""
  emit.put(c.em, open)
  if #list == 0 then
    ctx_mod.lead_at(c, close_y, close_x, "")
    emit.put(c.em, close)
    return
  end
  items(c, list, gap)
  if table_like and close_y > c.em.line then
    emit.put(c.em, ",")
  end
  ctx_mod.lead_at(c, close_y, close_x, gap)
  emit.put(c.em, close)
end

--- A call's arguments. `f{...}` and `f"..."` pass their one argument
--- with no parentheses at all, which the parser records by leaving the
--- argument list opening on something other than a `(`, and the
--- argument sits against the name the same way a parenthesized one
--- does.
local function call(c: Ctx, list: Node)
  if list.tk ~= "(" then
    for _, item in ipairs(list) do
      ctx_mod.lead(c, item, "")
      expression(c, item)
    end
    return
  end
  bracketed(c, list, "(", ")", false)
end

--- A function literal, signature and body.
---
--- This is the one construct that opens a block from inside an
--- expression, and so the one whose block does not necessarily open on
--- the grid its enclosing statement sits on. Its body is indented from
--- the column the `function` keyword is actually being WRITTEN at --
--- the indentation of the output line in progress, whether that line
--- was opened by the statement itself or is a continuation of it -- and
--- its `end` lines up with that same column.
---
--- Taking the enclosing statement's own indentation instead is wrong
--- exactly where a literal opens a line of its own: an argument on its
--- own line, a table value, a callback nested inside another. The body
--- would then be written level with its own `function` keyword and the
--- `end` two columns further left again, which for a top-level call
--- means an `end` in column zero in the middle of an argument list.
local function literal_function(c: Ctx, n: Node)
  local args, body, rets = n.args, n.body, n.rets
  if args == nil or body == nil or rets == nil then
    refuse(c, "a function with no signature")
    return
  end
  local base = c.em.indent
  local outer = c.margin
  emit.text(c.em, "function")
  sig.typeargs(c, typescan.index_at(c.scan, n.y, n.x))
  sig.arguments(c, args)
  sig.returns(c, rets, args, body)
  c.margin = base
  c.block(c, body)
  ctx_mod.lead_to(c, n.yend or body.y, n.xend or 1, base, " ")
  emit.put(c.em, "end")
  c.margin = outer
end

--- One entry of a table literal, in whichever of the three spellings
--- the parser recorded.
local function table_item(c: Ctx, n: Node)
  local value = n.value
  if value == nil then
    refuse(c, "a table entry with no value")
    return
  end
  if n.key_parsed == "short" then
    local key = n.key
    emit.text(c.em, key ~= nil and key.conststr or "")
    emit.put(c.em, " =")
  elseif n.key_parsed == "long" then
    local key = n.key
    if key == nil then
      refuse(c, "a bracketed table key with no key")
      return
    end
    emit.put(c.em, "[")
    ctx_mod.lead(c, key, "")
    expression(c, key)
    emit.put(c.em, "] =")
  else
    expression(c, value)
    return
  end
  ctx_mod.lead(c, value, " ")
  expression(c, value)
end

--- An `op` node: a call, an index, a cast, or an operator.
local function operator(c: Ctx, n: Node)
  local o, e1, e2 = n.op, n.e1, n.e2
  if o == nil or e1 == nil then
    refuse(c, "an operator with no operands")
    return
  end
  if e2 == nil then
    emit.text(c.em, o.op)
    ctx_mod.lead(c, e1, o.op:match("^%a") ~= nil and " " or "")
    expression(c, e1)
    return
  end
  expression(c, e1)
  if o.op == "@funcall" or o.op == "@method" then
    call(c, e2)
    return
  end
  if o.op == "@index" then
    emit.put(c.em, "[")
    ctx_mod.lead(c, e2, "")
    expression(c, e2)
    emit.put(c.em, "]")
    return
  end
  if o.op == "." or o.op == ":" then
    emit.put(c.em, o.op)
    ctx_mod.lead(c, e2, "")
    expression(c, e2)
    return
  end
  local anchor = typescan.index_at(c.scan, o.y, o.x)
  ctx_mod.lead_at(c, o.y, o.x, " ")
  emit.text(c.em, o.op)
  ctx_mod.lead(c, e2, " ")
  if o.op == "as" or o.op == "is" then
    cast_type(c, e2, anchor)
  else
    expression(c, e2)
  end
end

--- Leaves whose own token text IS the source: a name, a number, a
--- string with its quotes or long brackets, `true`, `nil`, `...`.
local verbatim_kinds: {string:boolean} = {
  ["variable"] = true,
  ["identifier"] = true,
  ["type_identifier"] = true,
  ["string"] = true,
  ["number"] = true,
  ["integer"] = true,
  ["boolean"] = true,
  ["nil"] = true,
  ["..."] = true,
}

--- @param c Ctx
--- @param n Node The expression to write, already led to
expression = function(c: Ctx, n: Node)
  local kind = n.kind
  if verbatim_kinds[kind] then
    emit.text(c.em, n.tk or kind)
    return
  end
  if kind == "op" then
    operator(c, n)
  elseif kind == "expression_list" then
    items(c, n, "")
  elseif kind == "literal_table" then
    bracketed(c, n, "{", "}", true)
  elseif kind == "literal_table_item" then
    table_item(c, n)
  elseif kind == "function" then
    literal_function(c, n)
  elseif kind == "paren" then
    local inner = n.e1
    if inner == nil then
      refuse(c, "an empty parenthesis")
      return
    end
    local open = typescan.index_at(c.scan, n.y, n.x)
    emit.put(c.em, "(")
    ctx_mod.lead(c, inner, "")
    expression(c, inner)
    if open ~= nil then
      local close = typescan.closing(c.scan, open)
      local t = c.scan.tokens[close]
      if t ~= nil then
        ctx_mod.lead_at(c, t.y, t.x, "")
      end
    end
    emit.put(c.em, ")")
  elseif kind == "cast" then
    cast_type(c, n, nil)
  else
    refuse(c, "an expression of kind '" .. kind .. "'")
  end
end

local record ExprModule
  expression: function(c: Ctx, n: Node)
  items: function(c: Ctx, list: Node, first_inline: string)
end

local M: ExprModule = {
  expression = expression,
  items = items,
}

return M
