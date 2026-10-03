--- Expressions, written from their own nodes.
---
--- Every operator, separator and bracket here comes from the node's
--- kind: a call is a `(` because the node says `@funcall`, an index is
--- a `[` because it says `@index`. Nothing is decided by which two
--- tokens ended up next to each other.
---
--- One thing is read off the source: where a line break goes, and where
--- one does not (`ctx.lead`). The renderer never adds or removes a
--- break, because that means deciding where to wrap, a judgement about
--- the whole line that no rule here can make. Everything a line holds
--- is the renderer's.
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

--- The text of the token `n` starts on, or "" when no token starts there.
local function first_token(c: Ctx, n: Node): string
  local at = ctx_mod.start_of(c, n)
  local i = typescan.index_at(c.scan, at.y, at.x)
  return i ~= nil and typescan.tk(c.scan, i) or ""
end

--- What stands between a `[` and the key or index inside it: a space
--- when the key opens with a long string, since `[[` would open one.
local function inside_brackets(c: Ctx, key: Node): string
  return first_token(c, key):sub(1, 1) == "[" and " " or ""
end

--- A key or index between brackets, the `]` where the source put it: a
--- line break before it is kept, so a comment ending the line before
--- does not take the `]` into it.
local function in_brackets(c: Ctx, key: Node)
  local inside = inside_brackets(c, key)
  local at = ctx_mod.start_of(c, key)
  local first = typescan.index_at(c.scan, at.y, at.x)
  emit.put(c.em, "[")
  ctx_mod.opens(c, nil, true)
  c.starting = true
  ctx_mod.lead(c, key, inside)
  expression(c, key)
  if first ~= nil and typescan.tk(c.scan, first - 1) == "[" then
    local t = c.scan.tokens[typescan.closing(c.scan, first - 1)]
    if t ~= nil then
      c.closing = true
      ctx_mod.lead_at(c, t.y, t.x, inside)
      inside = ""
    end
  end
  emit.put(c.em, inside .. "]")
  ctx_mod.closes(c)
end

--- The index of the first token of a cast's type, or nil when it has
--- none of its own. `anchor` is the operator's own token when there is
--- one: the type begins right after it, which is a surer place to start
--- than the type object's recorded position, since tl stamps a generic
--- type at the end of its file.
local function cast_start(c: Ctx, n: Node, anchor: integer | nil): integer | nil
  local declared = n.casttype
  if declared == nil then
    return nil
  end
  return anchor ~= nil and anchor + 1 or
    typescan.index_at(c.scan, declared.y, declared.x)
end

--- What follows an `as` or an `is`, as original bytes.
local function cast_type(c: Ctx, n: Node, anchor: integer | nil)
  if n.casttype == nil then
    refuse(c, "a cast with no type")
    return
  end
  local first = cast_start(c, n, anchor)
  if first == nil then
    refuse(c, "a cast whose type has no token of its own")
    return
  end
  ctx_mod.region(c, first, typescan.type_end(c.scan, first))
end

--- Whether `n` ends in a cast whose type's return types a `,` after it
--- would continue ([`typescan.open_returns`]).
local function ends_in_open_returns(c: Ctx, n: Node): boolean
  if n.kind == "literal_table_item" then
    local value = n.value
    return value ~= nil and ends_in_open_returns(c, value)
  end
  local o, e1, e2 = n.op, n.e1, n.e2
  if n.kind ~= "op" or o == nil then
    return false
  end
  if e2 == nil then
    return e1 ~= nil and ends_in_open_returns(c, e1)
  end
  if o.op == "as" or o.op == "is" then
    local first = cast_start(c, e2, typescan.index_at(c.scan, o.y, o.x))
    return first ~= nil and typescan.open_returns(c.scan, first)
  end
  if o.op == "@funcall" or o.op == "@method" or o.op == "@index" or o.op == "." or o.op == ":" then
    return false
  end
  return ends_in_open_returns(c, e2)
end

--- A comma-separated run of expressions, each moved to its own line
--- wherever the source put it there. A table's entries (`table_like`)
--- are separated by a `;` after one that [`ends_in_open_returns`].
--- `inside` says the run is a bracket's, so each item starts an entry.
local function items(c: Ctx, list: Node, first_inline: string, table_like?: boolean,
                     inside?: boolean)
  for i, item in ipairs(list) do
    local inline = first_inline
    if i > 1 then
      emit.put(c.em, table_like and ends_in_open_returns(c, list[i - 1]) and ";" or ",")
      inline = " "
    end
    c.starting = inside == true
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
  ctx_mod.opens(c)
  if #list == 0 then
    c.closing = true
    ctx_mod.lead_at(c, close_y, close_x, "")
    emit.put(c.em, close)
    ctx_mod.closes(c)
    return
  end
  items(c, list, gap, table_like, true)
  if table_like and close_y > c.em.line then
    emit.put(c.em, ends_in_open_returns(c, list[#list]) and ";" or ",")
  end
  c.closing = true
  ctx_mod.lead_at(c, close_y, close_x, gap)
  emit.put(c.em, close)
  ctx_mod.closes(c)
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
--- This is the one construct that opens a block inside an expression,
--- so its block need not open on the grid its enclosing statement sits
--- on. Its body is indented from the column the `function` keyword is
--- written at, the indentation of the output line in progress, whether
--- the statement or a continuation of it opened that line. Its `end`
--- lines up with that column.
---
--- The enclosing statement's indentation is wrong where a literal opens
--- a line of its own: an argument on its own line, a table value, a
--- callback nested in another. The body would be level with its own
--- `function` keyword and the `end` two columns further left, which for
--- a top-level call is an `end` in column zero in the middle of an
--- argument list.
local function literal_function(c: Ctx, n: Node)
  local args, body, rets = n.args, n.body, n.rets
  if args == nil or body == nil or rets == nil then
    refuse(c, "a function with no signature")
    return
  end
  local base = c.em.indent
  local outer, header = c.margin, c.header
  emit.text(c.em, "function")
  -- Its signature is a block's header, apart from the body.
  c.header = 4
  sig.typeargs(c, typescan.index_at(c.scan, n.y, n.x))
  sig.arguments(c, args)
  sig.returns(c, rets, args, body.y, body.x)
  c.header = header
  c.margin = base
  c.block(c, body)
  local closing = n.yend or body.y
  local inline = closing <= c.em.line
  local xend = n.xend
  -- A comment before the `end` that is not lined up with it moves as
  -- the literal's own line moved, not as the statement around it did.
  -- TODO: move it as the body's last statement moved instead, here and
  -- before a block's closing keyword in build.fix.stmt: a body read at
  -- other than two columns past its line moves by a different amount
  -- than the line, and a comment lined up with the body is left out of
  -- line with it (`f(function()\n        g()\n        -- c\n    end)`).
  local shift = c.shift
  -- Spaces alone, as the buffer counts a line's indentation.
  local read = (c.source:sub(c.starts[n.y] or 1):match("^ *") or "")
  c.shift = base - #read
  c.em.shift = c.shift
  ctx_mod.lead_to(c, closing, xend ~= nil and xend - #"end" + 1 or 1, base, " ")
  c.shift = shift
  c.em.shift = shift
  emit.put(c.em, "end")
  ctx_mod.ended(c, n, inline)
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
    in_brackets(c, key)
    emit.put(c.em, " =")
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
    -- A worded operator needs its space to stay a word, and a `-` in
    -- front of another to stay out of a comment.
    local apart = o.op:match("^%a") ~= nil or (o.op == "-" and first_token(c, e1):sub(1, 1) == "-")
    emit.text(c.em, o.op)
    ctx_mod.lead(c, e1, apart and " " or "")
    expression(c, e1)
    return
  end
  expression(c, e1)
  if o.op == "@funcall" or o.op == "@method" then
    call(c, e2)
    return
  end
  if o.op == "@index" then
    in_brackets(c, e2)
    return
  end
  if o.op == "." or o.op == ":" then
    emit.put(c.em, o.op)
    ctx_mod.lead(c, e2, "")
    expression(c, e2)
    return
  end
  local anchor = typescan.index_at(c.scan, o.y, o.x)
  if anchor ~= nil and o.y > c.em.line and o.op ~= "as" and o.op ~= "is" then
    c.leading[#c.leading + 1] = anchor
  end
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
    ctx_mod.opens(c, nil, true)
    c.starting = true
    ctx_mod.lead(c, inner, "")
    expression(c, inner)
    if open ~= nil then
      local close = typescan.closing(c.scan, open)
      local t = c.scan.tokens[close]
      if t ~= nil then
        c.closing = true
        ctx_mod.lead_at(c, t.y, t.x, "")
      end
    end
    emit.put(c.em, ")")
    ctx_mod.closes(c)
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
