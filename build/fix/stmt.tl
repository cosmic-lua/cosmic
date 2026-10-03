--- Statements and blocks, written from their own nodes.
---
--- A block's closing keyword is placed from the `yend`/`xend` of its
--- construct, the only place a block's close is recorded, since an
--- empty body has no token that reaches it. So `if x then return end`
--- on one line stays on one line and a body spread over twenty stays
--- spread over twenty.
---
--- Some statement kinds do not begin where tl stamped them. A `local`
--- or `global` declaration's node sits at its first name, a `local
--- type`'s or `global type`'s at the name it binds, a `local
--- macroexp`'s at its name, a `global function`'s at its `function` and
--- a pragma's at its name, not at the keyword that opens each.
--- [`begins_at`] walks back over the token stream to that keyword, so
--- the statement is indented from where it starts.

local ast = require("build.ast")
local ctx_mod = require("build.fix.ctx")
local emit = require("build.fix.emit")
local expr = require("build.fix.expr")
local sig = require("build.fix.sig")
local typescan = require("build.fix.typescan")

local type compiler = require("build.compiler")
local type Node = ast.Node
local type Ctx = ctx_mod.Ctx

local statement: function(Ctx, Node)

--- Where a statement's first character really is. `local a = 1` and
--- `local type T = U` are stamped at `a` and at `T`, `local macroexp
--- m` at `m`, `global function f` at `function` and `--#pragma k v` at
--- `k`; every other kind is stamped at its own opening keyword or at its
--- leftmost operand.
--- @param c Ctx
--- @param s Node
--- @return integer The 1-based line
--- @return integer The 1-based column
local function begins_at(c: Ctx, s: Node): integer, integer
  local anchor: Node | nil = nil
  local back = 0
  local kind = s.kind
  if kind == "local_declaration" or kind == "global_declaration" then
    local vars = s.vars
    anchor = vars ~= nil and vars[1] or nil
    back = 1
  elseif kind == "local_type" or kind == "global_type" then
    anchor = s.var
    back = 2
  elseif kind == "local_macroexp" then
    anchor = s
    back = 2
  elseif (kind == "global_function" and not s.implicit_global_function) or
      kind == "pragma" then
    anchor = s
    back = 1
  end
  if anchor ~= nil then
    local i = typescan.index_at(c.scan, anchor.y, anchor.x)
    if i ~= nil and i > back then
      local t = c.scan.tokens[i - back]
      return t.y, t.x
    end
  end
  local at = ctx_mod.start_of(c, s)
  return at.y, at.x
end

--- The first of the `;` run after statement `i` of `body`: the last
--- token before the next statement, or before the token closing the
--- block (its keyword, or the end of the file), walked back over the
--- run. Nil when no `;` stands there.
local function semicolon(c: Ctx, body: Node, i: integer): compiler.Token | nil
  local j: integer
  local next_one = body[i + 1]
  if next_one ~= nil then
    local y, x = begins_at(c, next_one)
    j = typescan.index_before(c.scan, y, x)
  else
    local yend, xend = body.yend, body.xend
    j = (yend ~= nil and xend ~= nil) and typescan.index_before(c.scan, yend, xend) or #c.scan.tokens
    if typescan.tk(c.scan, j) ~= ";" then
      j = j - 1
    end
  end
  if typescan.tk(c.scan, j) ~= ";" then
    return nil
  end
  while j > 1 and typescan.tk(c.scan, j - 1) == ";" do
    j = j - 1
  end
  return c.scan.tokens[j]
end

--- Every statement of one block, each on the line the source gave it.
---
--- A `;` after a statement is a flag on it (`semicolon`), however many
--- the source wrote, and it is written right after the statement: one
--- between two statements keeps them from reading as one
--- (`local t: T; i, t = f()`), and one after a block's last statement
--- is still part of the tree.
---
--- The flag is set from the parser's token stream, not the lexer's, so
--- it can stand for a `;` the source never wrote. Where a line ends in
--- a call and the next begins with a `(`, tl inserts a `;` to record
--- which of the two readings it took, and writing it out states in the
--- source what the compiler had decided.
--- @param c Ctx
--- @param body Node A "statements" node
local function block(c: Ctx, body: Node)
  local outer = c.margin
  local outer_shift = c.shift
  local outer_opens, outer_header = c.opens, c.header
  if body.tk == ";" then
    -- A `;` in front of the first statement flags none: the block's own
    -- node opens on it, and keeps it only as its first token.
    ctx_mod.owns(c, body.y, body.x)
    ctx_mod.lead_at(c, body.y, body.x, " ")
    emit.put(c.em, ";")
  end
  for i, s in ipairs(body) do
    local y, x = begins_at(c, s)
    if y <= c.em.line then
      if i == 1 then
        c.continues[body] = true
      else
        c.parted[#c.parted + 1] = s
      end
    end
    -- A statement moves by the distance its line moves, which differs
    -- from its first keyword's when a comment precedes it on that line.
    local opening = emit.opening_column(c.em, y, x)
    ctx_mod.place(c, outer + 2, opening)
    ctx_mod.lead_to(c, y, x, outer + 2, " ")
    if opening == x and not c.em.bare then
      -- It continues a line, after another statement or a `]]`, so it
      -- moves by where that line has reached instead.
      c.shift = emit.column(c.em) - (x - 1)
      c.em.shift = c.shift
    end
    -- Each statement opens no bracket of the expression a function
    -- literal holding it sits in.
    c.opens = {}
    c.header = 2
    statement(c, s)
    if s.semicolon then
      local t = semicolon(c, body, i)
      if t ~= nil then
        -- One that opens its line is the statement's, at its column.
        ctx_mod.lead_to(c, t.y, t.x, c.margin, "")
      end
      emit.put(c.em, ";")
    end
  end
  c.margin = outer
  c.shift = outer_shift
  c.opens, c.header = outer_opens, outer_header
  c.em.shift = outer_shift
end

--- Write `texts`, the tokens after the one statement `n` opens on, each
--- where the source put it: on its line, or `inline` after what came
--- before. A `goto`'s label and a label's name and closing `::` have no
--- node of their own, and the source may break a line between them.
local function words(c: Ctx, n: Node, texts: {string}, inline: string)
  local at = typescan.index_at(c.scan, n.y, n.x)
  for i, text in ipairs(texts) do
    local t = at ~= nil and c.scan.tokens[at + i] or nil
    if t ~= nil then
      ctx_mod.lead_at(c, t.y, t.x, inline)
    else
      emit.put(c.em, inline)
    end
    emit.text(c.em, text)
  end
end

--- Write a keyword the AST records no position for, such as a `then`
--- after a condition or a `do` after a loop header, where the source
--- put it.
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
--- @return boolean Whether it was written on the line already open
local function closes(c: Ctx, n: Node, word: string): boolean
  local y = n.yend
  if y == nil then
    ctx_mod.refuse(c, "a block with no recorded end")
    return false
  end
  local inline = y <= c.em.line
  -- The recorded end is the keyword's last column; a comment is placed
  -- against its first.
  local xend = n.xend
  ctx_mod.lead_to(c, y, xend ~= nil and xend - #word + 1 or 1, c.margin, " ")
  emit.put(c.em, word)
  if word == "end" then
    ctx_mod.ended(c, n, inline)
  end
  return inline
end

--- A function's signature and body, from its type parameters onward:
--- shared by a `local function`, a `global function`, a bare
--- `function f` and a `function M.f`, and by nothing else, since a
--- function literal is an expression.
--- @param c Ctx
--- @param n Node
--- @param name Node The declared name, which any `<T>` follows
local function signature_and_body(c: Ctx, n: Node, name: Node)
  local args, body, rets = n.args, n.body, n.rets
  if args == nil or body == nil or rets == nil then
    ctx_mod.refuse(c, "a function with no signature")
    return
  end
  -- A signature is a block's header, its lines set apart from the body.
  c.header = 4
  sig.typeargs(c, typescan.index_at(c.scan, name.y, name.x))
  sig.arguments(c, args)
  sig.returns(c, rets, args, body.y, body.x)
  c.header = 2
  block(c, body)
  closes(c, n, "end")
end

--- `local a <const>, b: integer, string = 1, "x"`: names with their
--- attributes, then the one type list Teal writes after all of them,
--- then the values. A `global` declaration is the same under its own
--- keyword.
local function declaration(c: Ctx, n: Node, word: string)
  local vars = n.vars
  if vars == nil then
    ctx_mod.refuse(c, "a declaration with no names")
    return
  end
  emit.text(c.em, word)
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
  -- The type list follows all the names at once. Its region is anchored
  -- on that one `:`, not on the first type's recorded position, since
  -- tl stamps a generic type at the end of the file and anchoring on it
  -- would swallow the rest.
  local declared = n.decltuple
  local listed = declared ~= nil and declared.tuple or nil
  if declared ~= nil and listed ~= nil and #listed > 0 then
    local colon = typescan.index_at(c.scan, declared.y, declared.x)
    if colon == nil or typescan.tk(c.scan, colon) ~= ":" then
      ctx_mod.refuse(c, "a type annotation with no ':' before it")
      return
    end
    local exps = n.exps
    local last = exps ~= nil and
      typescan.bounded_end(c.scan, exps.y, exps.x) or
      typescan.rets_end(c.scan, colon + 1)
    if not ctx_mod.annotation(c, colon + 1, last) then
      ctx_mod.refuse(c, "a type annotation with no tokens of its own")
    end
  end
  local exps = n.exps
  if exps ~= nil then
    emit.put(c.em, " =")
    expr.items(c, exps, " ")
  end
end

--- `local record R ... end`, `local enum E ... end`, `local type T = U`,
--- and `local type T = require(...)`, and each of them `global`; and
--- `global type T`, which declares a name and gives it no value.
---
--- A record or enum body is written as the original bytes of the whole
--- statement, from its `local` or `global` on, whether it was spelled
--- `local record R` or `local type R = record`. It is type syntax, and
--- tl keeps a record's fields as types, not text, so the comments
--- between them survive only by copying. The parser marks that form by
--- giving the `newtype` an end position; an alias has none.
local function type_declaration(c: Ctx, n: Node, word: string)
  local value, var = n.value, n.var
  if var == nil then
    ctx_mod.refuse(c, "a type declaration with no name")
    return
  end
  if value ~= nil then
    local yend, xend = value.yend, value.xend
    if value.kind == "newtype" and yend ~= nil and xend ~= nil then
      local y, x = begins_at(c, n)
      ctx_mod.verbatim(c, y, x, yend, xend)
      return
    end
  end
  emit.text(c.em, word .. " type")
  ctx_mod.lead(c, var, " ")
  emit.text(c.em, var.tk or "")
  sig.typeargs(c, typescan.index_at(c.scan, var.y, var.x))
  if value == nil then
    return
  end
  emit.put(c.em, " =")
  if value.kind ~= "newtype" then
    ctx_mod.lead(c, value, " ")
    expr.expression(c, value)
    return
  end
  local first = typescan.index_at(c.scan, value.y, value.x)
  if first == nil then
    ctx_mod.refuse(c, "a type alias with no token of its own")
    return
  end
  local t = c.scan.tokens[first]
  ctx_mod.lead_at(c, t.y, t.x, " ")
  ctx_mod.region(c, first, typescan.type_end(c.scan, first))
end

--- `local macroexp m(a: integer): integer return a + 1 end`: a
--- signature, then one `return`, laid out as the body of a `local
--- function` holding only that statement would be.
---
--- tl keeps the returned expression and not the `return`, whose token
--- is the one just before the expression. The body is written as the
--- block that `return` spells, so it is indented and led to like any
--- other.
local function macroexp(c: Ctx, n: Node)
  local name, def = n.name, n.macrodef
  local args = def ~= nil and def.args or nil
  local rets = def ~= nil and def.rets or nil
  local exp = def ~= nil and def.exp or nil
  if name == nil or def == nil or args == nil or rets == nil or exp == nil then
    ctx_mod.refuse(c, "a macroexp with no name, signature or body")
    return
  end
  local at = ctx_mod.start_of(c, exp)
  local first = typescan.index_at(c.scan, at.y, at.x)
  local t = first ~= nil and c.scan.tokens[first - 1] or nil
  if t == nil or t.tk ~= "return" then
    ctx_mod.refuse(c, "a macroexp with no 'return' before its expression")
    return
  end
  emit.text(c.em, "local macroexp")
  ctx_mod.lead(c, name, " ")
  emit.text(c.em, name.tk or "")
  c.header = 4
  sig.typeargs(c, typescan.index_at(c.scan, name.y, name.x))
  sig.arguments(c, args)
  sig.returns(c, rets, args, t.y, t.x)
  c.header = 2
  local listed: Node = { kind = "expression_list", f = n.f, y = at.y, x = at.x }
  listed[1] = exp
  local body: Node = { kind = "statements", f = n.f, y = t.y, x = t.x }
  body[1] = { kind = "return", f = n.f, y = t.y, x = t.x, exps = listed }
  block(c, body)
  closes(c, def, "end")
end

--- `if` / `elseif` / `else`, one branch per recorded block.
local function conditional(c: Ctx, n: Node)
  local blocks = n.if_blocks
  if blocks == nil then
    ctx_mod.refuse(c, "an if with no branches")
    return
  end
  for i, b in ipairs(blocks) do
    if i > 1 then
      if b.y <= c.em.line then
        c.continues[b] = true
      end
      ctx_mod.lead_to(c, b.y, b.x, c.margin, " ")
    end
    emit.text(c.em, b.tk or "if")
    local condition = b.exp
    if condition ~= nil then
      local opens = typescan.index_at(c.scan, b.y, b.x)
      c.header = 4
      ctx_mod.lead(c, condition, " ")
      expr.expression(c, condition)
      keyword(c, opens, "then")
      c.header = 2
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
    ctx_mod.refuse(c, "a numeric for with no range")
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
    declaration(c, n, "local")
  elseif kind == "global_declaration" then
    declaration(c, n, "global")
  elseif kind == "local_type" then
    type_declaration(c, n, "local")
  elseif kind == "global_type" then
    type_declaration(c, n, "global")
  elseif kind == "local_macroexp" then
    macroexp(c, n)
  elseif kind == "pragma" then
    emit.text(c.em, "--#pragma " .. (n.pkey or "") .. " " .. (n.pvalue or ""))
  elseif kind == "global_function" then
    local name = n.name
    if name == nil then
      ctx_mod.refuse(c, "a global function with no name")
      return
    end
    emit.text(c.em, n.implicit_global_function and "function" or "global function")
    ctx_mod.lead(c, name, " ")
    emit.text(c.em, name.tk or "")
    signature_and_body(c, n, name)
  elseif kind == "local_function" then
    local name = n.name
    if name == nil then
      ctx_mod.refuse(c, "a local function with no name")
      return
    end
    emit.text(c.em, "local function")
    ctx_mod.lead(c, name, " ")
    emit.text(c.em, name.tk or "")
    signature_and_body(c, n, name)
  elseif kind == "record_function" then
    local owner, name = n.fn_owner, n.name
    if owner == nil or name == nil then
      ctx_mod.refuse(c, "a function with no name")
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
      ctx_mod.refuse(c, "an assignment with no sides")
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
    elseif exps ~= nil and exps.tk == ";" then
      -- `return;` with no values: the empty list opens on the `;`, and
      -- keeps it only as its first token.
      ctx_mod.owns(c, exps.y, exps.x)
      emit.put(c.em, ";")
    end
  elseif kind == "break" then
    emit.text(c.em, "break")
  elseif kind == "goto" then
    emit.text(c.em, "goto")
    words(c, n, { n.label or "" }, " ")
  elseif kind == "label" then
    emit.text(c.em, "::")
    words(c, n, { n.label or "", "::" }, "")
  elseif kind == "repeat" then
    local body = n.body
    if body == nil then
      ctx_mod.refuse(c, "a repeat with no body")
      return
    end
    emit.text(c.em, "repeat")
    block(c, body)
    -- The body's recorded end is the `until` keyword's line; the repeat
    -- node's end reaches past it, to the end of the condition.
    local inline = closes(c, body, "until")
    local condition = n.exp
    if condition == nil then
      ctx_mod.refuse(c, "a repeat with no condition")
      return
    end
    c.header = 4
    ctx_mod.lead(c, condition, " ")
    expr.expression(c, condition)
    ctx_mod.ended(c, n, inline)
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
      ctx_mod.refuse(c, "a while with no condition or body")
      return
    end
    local opens = typescan.index_at(c.scan, n.y, n.x)
    emit.text(c.em, "while")
    c.header = 4
    ctx_mod.lead(c, condition, " ")
    expr.expression(c, condition)
    keyword(c, opens, "do")
    c.header = 2
    block(c, body)
    closes(c, n, "end")
  elseif kind == "fornum" or kind == "forin" then
    local body = n.body
    local opens = typescan.index_at(c.scan, n.y, n.x)
    c.header = 4
    if kind == "fornum" then
      numeric_for(c, n)
    else
      local vars, exps = n.vars, n.exps
      if vars == nil or exps == nil then
        ctx_mod.refuse(c, "a generic for with no names or values")
        return
      end
      emit.text(c.em, "for")
      expr.items(c, vars, " ")
      emit.put(c.em, " in")
      expr.items(c, exps, " ")
    end
    keyword(c, opens, "do")
    c.header = 2
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

--- Where statement `s`'s first character really is ([`begins_at`]).
local function start(c: Ctx, s: Node): ast.Position
  local y, x = begins_at(c, s)
  return { y = y, x = x }
end

local record StmtModule
  start: function(c: Ctx, s: Node): ast.Position
  block: function(c: Ctx, body: Node)
  statement: function(c: Ctx, n: Node)
end

local M: StmtModule = {
  start = start,
  block = block,
  statement = statement,
}

return M
