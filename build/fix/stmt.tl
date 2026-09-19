--- Statements and blocks, written from their own nodes.
---
--- A block's closing keyword is placed from the `yend`/`xend` its own
--- construct carries -- the only place a block's true close is
--- recorded, since an empty body has no token of its own that reaches
--- it -- so `if x then return end` on one line stays on one line and a
--- body spread over twenty stays spread over twenty.
---
--- Two statement kinds do not begin where tl stamped them. A `local`
--- declaration's node sits at its first NAME and a `local type`'s at
--- the name it binds, not at the `local` that opens either. `begins_at`
--- walks back over the token stream to the keyword, so the statement is
--- indented from where it really starts.

local ast = require("build.ast")
local ctx_mod = require("build.fix.ctx")
local emit = require("build.fix.emit")
local expr = require("build.fix.expr")
local sig = require("build.fix.sig")
local typescan = require("build.fix.typescan")

local type Node = ast.Node
local type Ctx = ctx_mod.Ctx

local statement: function(Ctx, Node)

--- Where a statement's first character really is. `local a = 1` and
--- `local type T = U` are stamped at `a` and at `T`; every other kind
--- is stamped at its own opening keyword or at its leftmost operand.
--- @param c Ctx
--- @param s Node
--- @return integer The 1-based line
--- @return integer The 1-based column
local function begins_at(c: Ctx, s: Node): integer, integer
  local anchor: Node | nil = nil
  local back = 0
  if s.kind == "local_declaration" then
    local vars = s.vars
    anchor = vars ~= nil and vars[1] or nil
    back = 1
  elseif s.kind == "local_type" then
    anchor = s.var
    back = 2
  end
  if anchor ~= nil then
    local i = typescan.index_at(c.scan, anchor.y, anchor.x)
    if i ~= nil and i > back then
      local t = c.scan.tokens[i - back]
      return t.y, t.x
    end
  end
  return ctx_mod.start_of(c, s)
end

--- Every statement of one block, each on the line the source gave it.
---
--- A `;` between two statements is not in the AST at all, and dropping
--- one can join two statements into something that reads differently
--- (`local t: T; i, t = f()`), so it is read back off the token stream:
--- when the token before a statement is a separator, it is written.
---
--- That token stream is the parser's, not the lexer's, which means one
--- `;` can appear that the source never wrote. Where a line ends in a
--- call and the next begins with a `(`, tl inserts a `;` to record
--- which of the two readings it took, and writing it out states in the
--- source what the compiler had already decided.
--- @param c Ctx
--- @param body Node A "statements" node
local function block(c: Ctx, body: Node)
  local outer = c.margin
  local outer_shift = c.shift
  for i, s in ipairs(body) do
    local y, x = begins_at(c, s)
    if i > 1 then
      local first = typescan.index_at(c.scan, y, x)
      if first ~= nil and typescan.tk(c.scan, first - 1) == ";" then
        emit.put(c.em, ";")
      end
    end
    -- A statement moves by the distance its own LINE moves, which is
    -- not the distance its first keyword moves once the source wrote a
    -- comment in front of it on that line.
    ctx_mod.place(c, outer + 2, emit.opening_column(c.em, y, x))
    ctx_mod.lead_to(c, y, x, outer + 2, " ")
    statement(c, s)
  end
  c.margin = outer
  c.shift = outer_shift
  c.em.shift = outer_shift
end

--- Write a keyword the AST records no position for -- a `then` after a
--- condition, a `do` after a loop header -- where the source put it.
--- @param c Ctx
--- @param from integer|nil The construct's own opening token
--- @param word string
local function keyword(c: Ctx, from: integer | nil, word: string)
  local at = from ~= nil and typescan.word_after(c.scan, from, word) or 0
  local t = c.scan.tokens[at]
  if t == nil then
    emit.put(c.em, " " .. word)
    return
  end
  ctx_mod.lead_at(c, t.y, t.x, " ")
  emit.text(c.em, word)
end

--- The closing keyword of a block-shaped construct: on the line the
--- parser recorded for it, so a one-line block stays on one line, and
--- lined up with the statement that opened the block rather than with
--- whatever column the source left it in.
local function closes(c: Ctx, n: Node, word: string)
  local y = n.yend
  if y == nil then
    expr.refuse(c, "a block with no recorded end")
    return
  end
  ctx_mod.lead_to(c, y, n.xend or 1, c.margin, " ")
  emit.put(c.em, word)
end

--- A function's signature and body, from its type parameters onward:
--- shared by a `local function` and a `function M.f`, and by nothing
--- else, since a function literal is an expression.
--- @param c Ctx
--- @param n Node
--- @param name Node The declared name, which any `<T>` follows
local function signature_and_body(c: Ctx, n: Node, name: Node)
  local args, body, rets = n.args, n.body, n.rets
  if args == nil or body == nil or rets == nil then
    expr.refuse(c, "a function with no signature")
    return
  end
  sig.typeargs(c, typescan.index_at(c.scan, name.y, name.x))
  sig.arguments(c, args)
  sig.returns(c, rets, args, body)
  block(c, body)
  closes(c, n, "end")
end

--- `local a <const>, b: integer, string = 1, "x"` -- names with their
--- attributes, then the one type list Teal writes after all of them,
--- then the values.
local function declaration(c: Ctx, n: Node)
  local vars = n.vars
  if vars == nil then
    expr.refuse(c, "a declaration with no names")
    return
  end
  emit.text(c.em, "local")
  for i, v in ipairs(vars) do
    if i > 1 then
      emit.put(c.em, ",")
    end
    ctx_mod.lead(c, v, " ")
    emit.text(c.em, v.tk or "")
    local attribute = v.attribute
    if attribute ~= nil then
      emit.put(c.em, " <" .. attribute .. ">")
    end
  end
  -- The type list follows all the names at once, which is how Teal
  -- writes it, and its region is anchored on that one `:` rather than
  -- on the first type's recorded position -- tl stamps a generic type
  -- at the end of the file, so anchoring on it swallows the rest of it.
  local declared = n.decltuple
  local listed = declared ~= nil and declared.tuple or nil
  if declared ~= nil and listed ~= nil and #listed > 0 then
    local colon = typescan.index_at(c.scan, declared.y, declared.x)
    if colon == nil or typescan.tk(c.scan, colon) ~= ":" then
      expr.refuse(c, "a type annotation with no ':' before it")
      return
    end
    local exps = n.exps
    local last = exps ~= nil
      and typescan.bounded_end(c.scan, exps.y, exps.x)
      or typescan.rets_end(c.scan, colon + 1)
    if not ctx_mod.annotation(c, colon + 1, last) then
      expr.refuse(c, "a type annotation with no tokens of its own")
    end
  end
  local exps = n.exps
  if exps ~= nil then
    emit.put(c.em, " =")
    expr.items(c, exps, " ")
  end
end

--- `local record R ... end`, `local enum E ... end`, `local type T = U`,
--- and `local type T = require(...)`.
---
--- A record or enum body is written as the original bytes of the whole
--- statement: it is type syntax, and tl keeps a record's fields as
--- types rather than as text, so the comments written between them
--- survive only by copying. The parser marks that form by giving the
--- `newtype` an end position; an alias has none.
local function type_declaration(c: Ctx, n: Node)
  local value, var = n.value, n.var
  if value == nil or var == nil then
    expr.refuse(c, "a type declaration with no name or value")
    return
  end
  local yend, xend = value.yend, value.xend
  if value.kind == "newtype" and yend ~= nil and xend ~= nil then
    ctx_mod.verbatim(c, value.y, value.x, yend, xend)
    return
  end
  emit.text(c.em, "local type")
  ctx_mod.lead(c, var, " ")
  emit.text(c.em, var.tk or "")
  sig.typeargs(c, typescan.index_at(c.scan, var.y, var.x))
  emit.put(c.em, " =")
  if value.kind ~= "newtype" then
    ctx_mod.lead(c, value, " ")
    expr.expression(c, value)
    return
  end
  local first = typescan.index_at(c.scan, value.y, value.x)
  if first == nil then
    expr.refuse(c, "a type alias with no token of its own")
    return
  end
  emit.put(c.em, " ")
  ctx_mod.region(c, first, typescan.type_end(c.scan, first))
end

--- `if` / `elseif` / `else`, one branch per recorded block.
local function conditional(c: Ctx, n: Node)
  local blocks = n.if_blocks
  if blocks == nil then
    expr.refuse(c, "an if with no branches")
    return
  end
  for i, b in ipairs(blocks) do
    if i > 1 then
      ctx_mod.lead_to(c, b.y, b.x, c.margin, " ")
    end
    emit.text(c.em, b.tk or "if")
    local condition = b.exp
    if condition ~= nil then
      local opens = typescan.index_at(c.scan, b.y, b.x)
      ctx_mod.lead(c, condition, " ")
      expr.expression(c, condition)
      keyword(c, opens, "then")
    end
    local body = b.body
    if body ~= nil then
      block(c, body)
    end
  end
  closes(c, n, "end")
end

--- `for i = a, b, c do ... end`.
local function numeric_for(c: Ctx, n: Node)
  local var, from, to = n.var, n.from, n.to
  if var == nil or from == nil or to == nil then
    expr.refuse(c, "a numeric for with no range")
    return
  end
  emit.text(c.em, "for")
  ctx_mod.lead(c, var, " ")
  emit.text(c.em, var.tk or "")
  emit.put(c.em, " =")
  ctx_mod.lead(c, from, " ")
  expr.expression(c, from)
  emit.put(c.em, ",")
  ctx_mod.lead(c, to, " ")
  expr.expression(c, to)
  local step = n.step
  if step ~= nil then
    emit.put(c.em, ",")
    ctx_mod.lead(c, step, " ")
    expr.expression(c, step)
  end
end

--- @param c Ctx
--- @param n Node The statement to write, already led to
statement = function(c: Ctx, n: Node)
  local kind = n.kind
  if kind == "local_declaration" then
    declaration(c, n)
  elseif kind == "local_type" then
    type_declaration(c, n)
  elseif kind == "local_function" then
    local name = n.name
    if name == nil then
      expr.refuse(c, "a local function with no name")
      return
    end
    emit.text(c.em, "local function")
    ctx_mod.lead(c, name, " ")
    emit.text(c.em, name.tk or "")
    signature_and_body(c, n, name)
  elseif kind == "record_function" then
    local owner, name = n.fn_owner, n.name
    if owner == nil or name == nil then
      expr.refuse(c, "a function with no name")
      return
    end
    emit.text(c.em, "function")
    ctx_mod.lead(c, owner, " ")
    expr.expression(c, owner)
    emit.put(c.em, n.is_method and ":" or ".")
    ctx_mod.lead(c, name, "")
    emit.text(c.em, name.tk or "")
    signature_and_body(c, n, name)
  elseif kind == "assignment" then
    local vars, exps = n.vars, n.exps
    if vars == nil or exps == nil then
      expr.refuse(c, "an assignment with no sides")
      return
    end
    expr.items(c, vars, "")
    emit.put(c.em, " =")
    expr.items(c, exps, " ")
  elseif kind == "return" then
    emit.text(c.em, "return")
    local exps = n.exps
    if exps ~= nil and #exps > 0 then
      expr.items(c, exps, " ")
    end
  elseif kind == "break" then
    emit.text(c.em, "break")
  elseif kind == "goto" then
    emit.text(c.em, "goto " .. (n.label or ""))
  elseif kind == "label" then
    emit.text(c.em, "::" .. (n.label or "") .. "::")
  elseif kind == "repeat" then
    local body = n.body
    if body == nil then
      expr.refuse(c, "a repeat with no body")
      return
    end
    emit.text(c.em, "repeat")
    block(c, body)
    -- The `until` keyword's own LINE is the body's recorded end; the
    -- repeat node's own end reaches past it, to the end of the
    -- condition that follows.
    closes(c, body, "until")
    local condition = n.exp
    if condition == nil then
      expr.refuse(c, "a repeat with no condition")
      return
    end
    ctx_mod.lead(c, condition, " ")
    expr.expression(c, condition)
  elseif kind == "do" then
    local body = n.body
    emit.text(c.em, "do")
    if body ~= nil then
      block(c, body)
    end
    closes(c, n, "end")
  elseif kind == "while" then
    local condition, body = n.exp, n.body
    if condition == nil or body == nil then
      expr.refuse(c, "a while with no condition or body")
      return
    end
    local opens = typescan.index_at(c.scan, n.y, n.x)
    emit.text(c.em, "while")
    ctx_mod.lead(c, condition, " ")
    expr.expression(c, condition)
    keyword(c, opens, "do")
    block(c, body)
    closes(c, n, "end")
  elseif kind == "fornum" or kind == "forin" then
    local body = n.body
    local opens = typescan.index_at(c.scan, n.y, n.x)
    if kind == "fornum" then
      numeric_for(c, n)
    else
      local vars, exps = n.vars, n.exps
      if vars == nil or exps == nil then
        expr.refuse(c, "a generic for with no names or values")
        return
      end
      emit.text(c.em, "for")
      expr.items(c, vars, " ")
      emit.put(c.em, " in")
      expr.items(c, exps, " ")
    end
    keyword(c, opens, "do")
    if body ~= nil then
      block(c, body)
    end
    closes(c, n, "end")
  elseif kind == "if" then
    conditional(c, n)
  else
    expr.expression(c, n)
  end
end

local record StmtModule
  block: function(c: Ctx, body: Node)
  statement: function(c: Ctx, n: Node)
  begins_at: function(c: Ctx, s: Node): integer, integer
end

local M: StmtModule = {
  block = block,
  statement = statement,
  begins_at = begins_at,
}

return M
