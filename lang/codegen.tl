--- The code generator of the new checker's grammar
--- ([`doc/plans/new-checker-grammar.md`], "departures from Teal, and what the
--- translator does"): the syntax tree [`lang.parser`] builds, written as Lua.
---
--- The Lua is the fork's. A statement on source line N lands on line N, types
--- are erased, and for every construct the plan classes as a respelling the
--- bytes are the ones [`checker/tl.tl`]'s `generate` writes for the Teal the
--- translator ([`lang.translate`]) started from: the same indent, the same
--- `; ` between statements on a line, a trailing `,` in a table that spans
--- lines, `type(x) == "string"` for `x is string`. A node is placed at the line
--- the fork's parser gave it, which is the line of its operator token for a
--- binary operator, a field, an index, a call and a test, and of its first token
--- for the rest. The fork writes no comment and no type, so neither does this.
--- A `;` that ends a statement in the Teal is not in the grammar and is not written, except where the next
--- statement begins a line with `(`, which would otherwise continue it.
---
--- Where the fork's Lua is not Lua, or not what the program means, this writes what it means:
---
--- * A `-` before a `-` gets a space, as `--` begins a comment.
--- * A test whose type is on a later line than its value is not broken inside the quotes of the type.
--- * A test of a union through an alias is a test for each member as what the member stands for (the fork tests
---   a named member for a table), and a value that is no name is evaluated once, in a function called on the spot.
---   An alias of `integer`, `true` or `false` tests for that.
--- * An operand of a comparison that is a test is in parentheses.
--- * An `if` expression is `c and a or b` only where every value is truthy ([`generate`]); otherwise it is a function
---   called on the spot, which is right for a value that is false or nil.
--- * A `return` that ends a loop a `continue` jumps to the end of is `do return ... end`, since a label may not follow
---   a `return`.
--- * A field, a key or a function of a record named `goto` or `global`, which Lua 5.5 reserves, is
---   `x["goto"]`, `["goto"] = v` and `R["goto"] = function() end`.
---
--- A layout construct differs in one place: a `continue` is `goto continue`,
--- and the loop around it ends with `::continue::` on the line of its `end`
--- (or of its `until`), where the fork's source had the label on a line of its
--- own. The `::continue::` is the only text that moves.
---
--- A `match` is plain Lua: the call's values are held in locals of a `do`
--- block, and each arm is an `if` on the `true` and `false` of its pattern that
--- binds the names of the rest.
---
--- * A `class` is its method table, which is also the metatable of its values: `local C = {}; C.__index = C`
---   on the line of the `class`, then each method as `function C.name(self, ...)` on its line. A method named
---   `__close` or `__tostring` is the metamethod of that name. The values are made by the reserved form of the
---   patched parser ([`patch/lua/`]): `{ ... } @ C` is the table the constructor makes with `C` as its metatable, and
---   `@v == C` is the test `v is C`, `@v` being the metatable of `v`. Which table literals make a value of a class
---   is the checker's to say ([`lang.check`]'s [`Checked.literals`]), so [`generate`] is told; a literal it is not told
---   of is a plain table.
---
--- What the tree holds and Lua cannot yet say is refused with an [`Error`], and the text then lacks it: a `class`
--- declared inside another type (`class_nested_refused`), which has no table of its own at run time.
---
--- [`generate`] needs the names the scope builder ([`lang.scopes`]) resolved:
--- the fork writes a `local record R` as `local R = {}` only where `R` is read
--- as a value, and an `is` of a local enum or alias writes the Lua type it
--- stands for. It reads nothing of other modules, so an `is` of an imported
--- type is a test for a table.
---
--- The generator keeps its state in a table of its own, so it is not
--- re-entrant: it runs one generation at a time, as the one thread of a cosmic
--- program does.

-- TODO: write the reserved form of the class only in the code the compiler writes, once the runtime cut takes text
-- `load` from programs (doc/plans/strict-teal.md, "no implicit conversion or hidden code"): a program cannot spell
-- `@` in Teal, but a chunk it loads from text is read by the patched parser, which takes both forms today
-- (`load("return @'abc'")` answers the string metatable), and `@v` reads a metatable whatever its `__metatable` says.
--
-- TODO: reach the table of a class of another module, for a class literal or an `is` of it there, once the checker
-- has a use for one ([`lang.check`]'s `class_scope` refuses both): the table is the module's own local.
--
-- TODO: take truthiness from the new checker's types, in place of the translator's syntactic rule
-- ([`lang.translate`]'s `never_false`), once expressions land (doc/plans/new-checker-types.md, "expressions
-- without flow"): a name or a call whose type is neither boolean nor optional is then truthy, and its `if`
-- expression is `c and a or b` and not a function called on the spot.
--
-- TODO: write `local _ = require("m")` as nothing where `m` returns a type, and an `is` of an imported enum as a
-- test for a string and of an imported userdata record as one for userdata, once the new checker's type report
-- reaches the generator: the fork knows what a required module returns, and this generator is given a single file.
local Ast = require("lang.ast")
local Lexer = require("lang.lexer")
local Scopes = require("lang.scopes")

local record Codegen
  --- What a refusal is, so that a reader does not parse its `msg`.
  enum Code
    -- a `class` declared inside another type, which has no table of its own at run time
    "class_nested_refused"
  end

  --- Something the tree holds that this generator does not write yet. `y` and `x` place its first token.
  record Error
    code: Code
    --- What is refused, in one line.
    msg: string
    --- How to write the program so that it is not refused.
    fix: string
    y: integer
    x: integer
  end

  --- What [`generate`] answers.
  record Generated
    --- The Lua. A refused construct is missing from it.
    text: string
    --- Every refusal, in source order.
    errors: {Error}
  end

  --- Writes `chunk`, a parse of a program that has no errors and is scoped as `scoped`
  --- ([`lang.scopes`]'s `build`), as Lua. `truthy` says of an expression whether it can be neither false nor nil;
  --- an `if` expression whose values all are is `c and a or b`, and any other is a function called on the spot, which
  --- is right for a value that is false or nil. By default only what the syntax shows is truthy (a literal other
  --- than `false` and `nil`, a table, a function, an arithmetic or a concatenation). `classes` names the class of each
  --- table literal that makes a value of one, by the id of its node: [`lang.check`]'s [`Checked.literals`] with the
  --- name of each class. `enums` gives the values of the enum a type node stands for, by the id of the node, and `v is E`
  --- is then a test of membership, `({["a"] = true, ...})[v] == true`, where the fork's is for the kind (`type(v) ==
  --- "string"`): a string is no member of an enum for being a string, and a program that is told otherwise is wrong.
  --- `wraps` names, by the id of an expression, the arguments after its value of a call of `__fact` that wraps it:
  --- `__fact(v, <arguments>)`, which a run that checks what [`lang.check`] concluded of a read defines. A chunk with any begins
  --- with a definition of it that answers `v`, where none is (a process that installed no hook, a module loaded before the
  --- worker installs its own), as the fork's `(__cosmic_tc or select)` answers it; a call that begins a line is no call of the
  --- line above.
  --- `kinds` says what [`lang.check`] resolved a type name to, by the id of the name: `integer`, `number`, `string`,
  --- `boolean`, `function`, `true`, `false` or `nil`. A test `v is T` of a name of another module, whose declaration
  --- this generator cannot see, is then a test for that, where without it the name is a table.
  --- `served` says the Lua is for a build that serves every module, as the fork compiles one: it drops every `local type`
  --- import that the file does not read or write as a value. A file compiled alone drops only the imports it uses as a type
  --- and keeps the `require` of the rest.
  generate: function(chunk: Ast.Chunk, scoped: Scopes.Scoped, truthy?: function(e: Ast.Exp): boolean,
                     classes?: {integer: string}, enums?: {integer: {string}}, wraps?: {integer: string},
                     kinds?: {integer: string}, served?: boolean): Generated

  --- `lua`, the Lua of this generator or of the fork's for the same Teal, once the layout of a `continue` is set
  --- aside: the `::continue::` that ends a loop is deleted, since the fork's source has it on a line of its own and
  --- this generator's on the line of the loop's `end`, and a line's trailing blanks are ignored. Two texts that
  --- are equal then are the same Lua, line for line.
  compared: function(lua: string): string

  --- `text`, the Lua this generator wrote for `chunk`, without the lines of its top-level classes and without blank
  --- lines: what is left to hold to the fork's Lua once [`fork_without_classes`] has cut the pattern of a class from
  --- that.
  without_classes: function(text: string, chunk: Ast.Chunk): string

  --- `lua`, the fork's Lua for the Teal [`lang.translate`] started from, without the pattern of a class, and without
  --- blank lines: the table `local C = {}` and the methods `function C:name()` of each top-level class of `chunk`, the
  --- metatable locals `metatables` names (the translator removed them) and `__index = C` of them, and the call
  --- `setmetatable(T, mt)` of such a metatable written as `T`, which is how the class literal reads without its class.
  fork_without_classes: function(lua: string, chunk: Ast.Chunk, metatables: {string}): string

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}
end

Codegen.codes = { "class_nested_refused" }

function Codegen.compared(lua: string): string
  return (lua:gsub("::continue:: ?", ""):gsub("[ \t]+\n", "\n"))
end

function Codegen.without_classes(text: string, chunk: Ast.Chunk): string
  local tokens = chunk.tokens
  local dropped: {integer: boolean} = {}
  for _, s in ipairs(chunk.body.stats) do
    if s is Ast.Class then
      for y = tokens.y[s.first], Lexer.yend(tokens, s.last) do
        dropped[y] = true
      end
    end
  end
  local kept: {string} = {}
  local y = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    y = y + 1
    if not dropped[y] and line:find("%S") ~= nil then
      kept[#kept + 1] = line
    end
  end
  return Codegen.compared(table.concat(kept, "\n"))
end

--- The index of the `,` that ends the argument of a call which begins at `from`, or nil: the first at no depth of
--- brackets, outside strings.
local function argument_end(text: string, from: integer): integer | nil
  local depth = 0
  local i = from
  local n = #text
  while i <= n do
    local c = text:sub(i, i)
    if c == "\"" or c == "'" then
      i = i + 1
      while i <= n and text:sub(i, i) ~= c do
        if text:sub(i, i) == "\\" then
          i = i + 1
        end
        i = i + 1
      end
    elseif c == "[" and text:find("^%[=*%[", i) ~= nil then
      local level = text:match("^%[(=*)%[", i) or ""
      local _, stop = text:find("]" .. level .. "]", i, true)
      if stop == nil then
        return nil
      end
      i = stop
    elseif c == "(" or c == "{" or c == "[" then
      depth = depth + 1
    elseif c == ")" or c == "}" or c == "]" then
      if depth == 0 then
        return nil
      end
      depth = depth - 1
    elseif c == "," and depth == 0 then
      return i
    end
    i = i + 1
  end
  return nil
end

--- The index of the `)` that ends a call of `setmetatable` whose first argument ends at `comma`, when its second is a
--- name of `metatables` or the literal `{ __index = C }` for a `C` of `classes`; nil for any other call.
local function metatable_call_end(text: string, comma: integer, classes: {string: boolean},
                                  metatables: {string: boolean}): integer | nil
  local name = text:match("^%s*([%a_][%w_]*)%s*%)", comma + 1)
  if name ~= nil and metatables[name] then
    local _, stop = text:find("^%s*[%a_][%w_]*%s*%)", comma + 1)
    return stop
  end
  local class = text:match("^%s*{%s*__index%s*=%s*([%a_][%w_]*)%s*,?%s*}%s*%)", comma + 1)
  if class ~= nil and classes[class] then
    local _, stop = text:find("^%s*{%s*__index%s*=%s*[%a_][%w_]*%s*,?%s*}%s*%)", comma + 1)
    return stop
  end
  return nil
end

--- `text` with each `setmetatable(T, mt)` of such a metatable written as `T`.
local function without_metatable_calls(text: string, classes: {string: boolean}, metatables: {string: boolean}): string
  local out: {string} = {}
  local at = 1
  while true do
    local s, e = text:find("setmetatable(", at, true)
    if s == nil then
      break
    end
    local comma = argument_end(text, e + 1)
    local stop = comma ~= nil and metatable_call_end(text, comma, classes, metatables) or nil
    local previous = s > 1 and text:sub(s - 1, s - 1) or ""
    if comma ~= nil and stop ~= nil and not previous:find("[%w_.:]") then
      out[#out + 1] = text:sub(at, s - 1)
      out[#out + 1] = without_metatable_calls(text:sub(e + 1, comma - 1), classes, metatables)
      at = stop + 1
    else
      out[#out + 1] = text:sub(at, e)
      at = e + 1
    end
  end
  out[#out + 1] = text:sub(at)
  return table.concat(out)
end

function Codegen.fork_without_classes(lua: string, chunk: Ast.Chunk, metatables: {string}): string
  local classes: {string: boolean} = {}
  for _, s in ipairs(chunk.body.stats) do
    if s is Ast.Class then
      classes[s.name.name] = true
    end
  end
  local removed: {string: boolean} = {}
  for _, name in ipairs(metatables) do
    removed[name] = true
  end
  local kept: {string} = {}
  local dropping = false
  -- How many brackets the lines so far have left open: the fork writes a table that spans lines with its last line
  -- in the first column.
  local depth = 0
  for line in (lua .. "\n"):gmatch("(.-)\n") do
    -- A statement of the top level begins in the first column, outside any bracket; what follows it is indented or
    -- closes it.
    local opens_here = depth == 0
    local bare = line:gsub("\\.", ""):gsub("\"[^\"]*\"", ""):gsub("'[^']*'", "")
    local _, opened = bare:gsub("[%({%[]", "")
    local _, closed = bare:gsub("[%)}%]]", "")
    depth = math.max(0, depth + opened - closed)
    if opens_here and line:find("^%S") ~= nil and line:find("^[%)}%]]") == nil and line:find("^end%f[^%w_]") == nil and
        line:find("^else") == nil and line:find("^until%f[^%w_]") == nil then
      local declared = line:match("^local ([%a_][%w_]*) =")
      local method = line:match("^function ([%a_][%w_]*):")
      local index = line:match("^([%a_][%w_]*)%.__index = ")
      dropping = (declared ~= nil and (classes[declared] == true or removed[declared] == true)) or
        (method ~= nil and classes[method] == true) or (index ~= nil and classes[index] == true)
    end
    if not dropping and line:find("%S") ~= nil then
      kept[#kept + 1] = line
    end
  end
  return Codegen.compared(without_metatable_calls(table.concat(kept, "\n"), classes, removed))
end

--- A piece of the Lua being written, with the lines of the source it spans: `y` is the line it begins on, `h` how
--- many line breaks it holds. A part is text or a piece inside it.
local record Output
  y: integer
  h: integer
  parts: {string | Output}
end

--- What one generation keeps. A function assigns a field of it, not a local of the module, so that every function
--- reads the one `G`.
local record State
  tokens: Lexer.Tokens
  scoped: Scopes.Scoped
  --- The indent the node being written is at, and the indents saved by the nodes written on one line.
  indent: integer
  saved: {integer}
  errors: {Codegen.Error}
  --- For each loop the function being written is inside, innermost last, whether a `continue` ends its pass.
  loops: {boolean}
  --- The declaration of each binding, by the id of its name, built when a test names a local type.
  declarations: {integer: Ast.Node} | nil
  --- How many `match` statements have been written, to name their temporaries apart.
  matches: integer
  --- The chunk's statements.
  body: Ast.Block | nil
  --- Whether an expression can be neither false nor nil.
  truthy: function(e: Ast.Exp): boolean
  --- The `return` that ends the body of a loop that a `continue` jumps to the end of: no label may follow a
  --- `return` in its block, so it is written `do return ... end`.
  guarded: Ast.Node | nil
  --- The name of the class each table literal makes a value of, by the id of the literal.
  classes: {integer: string}
  --- The values of the enum a type node stands for, by the id of the node.
  enums: {integer: {string}}
  --- The arguments, after the value, of the call of `__fact` that wraps the read at a node, by the id of the node.
  wraps: {integer: string}
  --- What the checker resolved a type name to, by the id of the name.
  kinds: {integer: string}
  --- Whether the build serves every module ([`Codegen.generate`]'s `served`).
  served: boolean
end

local NO_TOKENS <const>: Lexer.Tokens = Lexer.lex("", "").tokens

local G: State = {
  tokens = NO_TOKENS, scoped = { vars = {}, list = {}, resolved = {}, globals = {}, global_writes = {}, errors = {} },
  indent = 0, saved = {}, errors = {}, loops = {}, declarations = nil, matches = 0, body = nil,
  truthy = function(_e: Ast.Exp): boolean return false end, guarded = nil, classes = {}, enums = {}, wraps = {}, kinds = {}, served = false,
}

local function base_of(node: Ast.Node): Ast.Base
  return node
end

-- Output ----------------------------------------------------------------------------------------------------------

local function new(y: integer): Output
  return { y = y, h = 0, parts = {} }
end

local function put(out: Output, s: string)
  local parts = out.parts
  parts[#parts + 1] = s
end

--- Appends `s`, which may hold line breaks (a long string), and counts them.
local function put_counted(out: Output, s: string)
  put(out, s)
  local _, breaks = s:gsub("\n", "")
  out.h = out.h + breaks
end

--- A piece that is `s` alone, on line `y`.
local function text(y: integer, s: string): Output
  local out = new(y)
  put_counted(out, s)
  return out
end

--- Appends `child`, if it holds anything, on the line it begins on: a line break for each line it is below
--- where `out` has got to, else `space` between them. `indent` is written before the child where it is on a line of
--- its own, or where no space is.
local function add_child(out: Output, child: Output, space?: string, indent?: integer)
  if #child.parts == 0 then
    return
  end
  if child.y ~= -1 and child.y < out.y then
    out.y = child.y
  end
  if child.y > out.y + out.h then
    local delta = child.y - (out.y + out.h)
    out.h = out.h + delta
    put(out, ("\n"):rep(delta))
  elseif space ~= nil then
    if space ~= "" then
      put(out, space)
    end
    indent = nil
  end
  if indent ~= nil then
    put(out, ("   "):rep(indent))
  end
  local parts = out.parts
  parts[#parts + 1] = child
  out.h = out.h + child.h
end

--- Puts `(` before the piece and `)` after it.
local function parenthesize(out: Output)
  table.insert(out.parts, 1, "(")
  put(out, ")")
end

--- The text of `out` and what it holds, with an explicit stack: a chain of a hundred thousand operands nests that deep.
local function flatten(root: Output): string
  local pieces: {string} = {}
  local stack: {Output} = { root }
  local at: {integer} = { 1 }
  local top = 1
  while top > 0 do
    local out = stack[top]
    local i = at[top]
    local part = out.parts[i]
    if part == nil then
      stack[top] = nil
      at[top] = nil
      top = top - 1
    else
      at[top] = i + 1
      if part is string then
        pieces[#pieces + 1] = part
      else
        top = top + 1
        stack[top] = part
        at[top] = 1
      end
    end
  end
  return table.concat(pieces)
end

-- Indent ----------------------------------------------------------------------------------------------------------

--- Called on entering a node that holds a block, `y` the line it begins on and `child_y` the line its first child
--- begins on: a child on another line is one indent deeper, and one on the same line is written with none.
local function indent_in(y: integer, child_y: integer)
  if child_y ~= y then
    if G.indent == 0 and #G.saved > 0 then
      G.indent = G.saved[#G.saved] + 1
    else
      G.indent = G.indent + 1
    end
  else
    G.saved[#G.saved + 1] = G.indent
    G.indent = 0
  end
end

local function indent_out(y: integer, child_y: integer)
  if child_y ~= y then
    G.indent = G.indent - 1
  else
    G.indent = table.remove(G.saved)
  end
end

-- Places ------------------------------------------------------------------------------------------------------------

local function line_of(token: integer): integer
  return Lexer.y(G.tokens, token)
end

local function refuse(code: Codegen.Code, token: integer, msg: string, fix: string)
  G.errors[#G.errors + 1] = { code = code, msg = msg, fix = fix, y = Lexer.y(G.tokens, token), x = Lexer.x(G.tokens, token) }
end

--- The words Lua 5.5 reserves that the grammar lets name a field, a key or a function of a record.
local RESERVED_FIELDS <const>: {string: boolean} = { ["goto"] = true, ["global"] = true }

--- Whether the syntax of `e` shows it is neither false nor nil: a literal that is no `false` or `nil`, a table, a
--- function, an arithmetic or a concatenation (the language has no metamethod to make one answer false), or
--- a parenthesized or cast one. A comparison and a `not` answer false, and a name or a call can answer anything.
local function syntactically_truthy(e: Ast.Exp): boolean
  local cur: Ast.Exp = e
  while true do
    if cur is Ast.Paren then
      cur = cur.inner
    elseif cur is Ast.Cast then
      cur = cur.value
    elseif cur is Ast.Binary then
      local op = cur.op
      return op ~= "or" and op ~= "and" and op ~= "<" and op ~= ">" and op ~= "<=" and op ~= ">=" and op ~= "~=" and
        op ~= "=="
    elseif cur is Ast.Unary then
      return cur.op ~= "not"
    elseif cur is Ast.Boolean then
      return cur.value
    else
      return cur is Ast.String or cur is Ast.Integer or cur is Ast.Float or cur is Ast.Table or cur is Ast.FunctionLit
    end
  end
end

-- Types -------------------------------------------------------------------------------------------------------------

local LUA_TYPES <const>: {string: string} = {
  string = "string", number = "number", integer = "number", boolean = "boolean", thread = "thread",
}

--- The declaration of each binding of the chunk that is one: found once, when a test names a local type.
local function declarations_of(chunk_body: Ast.Block): {integer: Ast.Node}
  local found: {integer: Ast.Node} = {}
  local stack: {Ast.Node} = { chunk_body }
  while #stack > 0 do
    local node = table.remove(stack)
    if node is Ast.Record or node is Ast.Interface or node is Ast.Class or node is Ast.Enum or node is Ast.TypeAlias or
        node is Ast.Import then
      found[node.name.id] = node
    end
    Ast.children(node, function(child: Ast.Node)
      stack[#stack + 1] = child
    end)
  end
  return found
end

local lua_type: function(t: Ast.Type, hops: integer): string

--- The type a declaration stands for, as a test of a value of it writes it.
local function declared_type(declaration: Ast.Node, hops: integer): string
  if declaration is Ast.Enum then
    return "string"
  elseif declaration is Ast.TypeAlias then
    if hops > 0 then
      return lua_type(declaration.type, hops - 1)
    end
  end
  return "table"
end

--- The member of the type `holder` that is called `name`, if it declares a type of that name.
local function nested_type(holder: Ast.Node, name: string): Ast.Node | nil
  if holder is Ast.Record or holder is Ast.Interface or holder is Ast.Class then
    for _, m in ipairs(holder.members) do
      if (m is Ast.Record or m is Ast.Interface or m is Ast.Class or m is Ast.Enum or m is Ast.TypeAlias) and
          m.name.name == name then
        return m
      end
    end
  end
  return nil
end

--- The declaration the type name `t` names, found through the bindings the scope builder resolved and the
--- nested types of records; nil where it names none of this file's (a primitive, a global, a type of another module).
--- `resolved` tells whether the head of the name is a binding at all.
local function declaration_of(t: Ast.TypeName): Ast.Node | nil, boolean
  local path = t.path
  local var_id = G.scoped.resolved[t.id]
  if var_id == nil then
    return nil, false
  end
  local held = G.declarations
  local body = G.body
  if held == nil and body ~= nil then
    held = declarations_of(body)
    G.declarations = held
  end
  local declaration: Ast.Node | nil = held ~= nil and held[G.scoped.vars[var_id].id] or nil
  for i = 2, #path do
    if declaration == nil then
      break
    end
    declaration = nested_type(declaration, path[i])
  end
  return declaration, true
end

--- The Lua type a value of `t` has: what `type(v)` answers for it, as the fork writes it. A type the fork does not
--- resolve (one of another module) is a table. `hops` bounds the aliases followed.
lua_type = function(t: Ast.Type, hops: integer): string
  local kind = base_of(t).kind
  if kind == "TypeName" and t is Ast.TypeName then
    local declaration, resolved = declaration_of(t)
    if not resolved then
      return #t.path == 1 and LUA_TYPES[t.path[1]] or "table"
    end
    if declaration == nil then
      return "table"
    end
    return declared_type(declaration, hops)
  elseif kind == "TypeFunction" then
    return "function"
  elseif kind == "TypeNil" then
    return "nil"
  elseif kind == "TypeMut" and t is Ast.TypeMut then
    return lua_type(t.inner, hops)
  end
  return "table"
end

local union_members: function(t: Ast.Type, hops: integer): {Ast.Type} | nil

--- Appends `t` to `out`, or its members where it is a union.
local function append_members(out: {Ast.Type}, t: Ast.Type, hops: integer)
  local members = union_members(t, hops)
  if members == nil then
    out[#out + 1] = t
  else
    table.move(members, 1, #members, #out + 1, out)
  end
end

--- The types a union stands for, which `t` is where it is written as an alias of one (a program cannot write the
--- union in a test, which has one type): the fork tests a value of a union for each member in turn. Nil where `t` is
--- no union.
union_members = function(t: Ast.Type, hops: integer): {Ast.Type} | nil
  local kind = base_of(t).kind
  local out: {Ast.Type} = {}
  if kind == "TypeUnion" and t is Ast.TypeUnion then
    for _, member in ipairs(t.members) do
      append_members(out, member, hops)
    end
    return out
  elseif kind == "TypeOptional" and t is Ast.TypeOptional then
    append_members(out, t.inner, hops)
    local missing: Ast.TypeNil = { kind = "TypeNil", id = 0, first = t.last, last = t.last }
    out[#out + 1] = missing
    return out
  elseif kind == "TypeName" and t is Ast.TypeName and hops > 0 then
    local declaration = declaration_of(t)
    if declaration ~= nil and declaration is Ast.TypeAlias then
      return union_members(declaration.type, hops - 1)
    end
  end
  return nil
end

--- `t`, or the type it is an alias of where it names a local alias, however many hops: the type a test is for.
local function through_aliases(t: Ast.Type, hops: integer): Ast.Type
  local cur = t
  while hops > 0 and cur is Ast.TypeName do
    local declaration = declaration_of(cur)
    if declaration ~= nil and declaration is Ast.TypeAlias then
      cur = declaration.type
      hops = hops - 1
    else
      break
    end
  end
  return cur
end

-- Expressions -----------------------------------------------------------------------------------------------------

local PRECEDENCE <const>: {string: integer} = {
  ["or"] = 1, ["and"] = 2, ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3, ["|"] = 4,
  ["~"] = 5, ["&"] = 6, ["<<"] = 7, [">>"] = 7, [".."] = 8, ["+"] = 9, ["-"] = 9, ["*"] = 10, ["/"] = 10,
  ["//"] = 10, ["%"] = 10, ["^"] = 12,
}
local UNARY_PRECEDENCE <const> = 11
local IS_PRECEDENCE <const> = 3
local CAST_PRECEDENCE <const> = 50
local POSTFIX_PRECEDENCE <const> = 100

--- The precedence of the operator an expression ends in, or nil where it is not one (a name, a parenthesis, a table):
--- an operand of a higher precedence than the operator it stands under is written in parentheses.
local function precedence(e: Ast.Exp): integer | nil
  local kind = base_of(e).kind
  if kind == "Binary" and e is Ast.Binary then
    return PRECEDENCE[e.op]
  elseif kind == "Unary" then
    return UNARY_PRECEDENCE
  elseif kind == "IsTest" and e is Ast.IsTest then
    if union_members(e.type, 32) ~= nil then
      -- A test for each member, or a function called on the spot where the value is no name.
      local value = e.value
      return value is Ast.Name and PRECEDENCE["or"] or nil
    end
    return IS_PRECEDENCE
  elseif kind == "Cast" then
    return CAST_PRECEDENCE
  elseif kind == "Call" or kind == "MethodCall" or kind == "Field" or kind == "Index" then
    return POSTFIX_PRECEDENCE
  elseif kind == "IfExp" and e is Ast.IfExp then
    -- A function called on the spot is a primary expression.
    for _, arm in ipairs(e.arms) do
      if not G.truthy(arm.value) then
        return nil
      end
    end
    return PRECEDENCE["or"]
  end
  return nil
end

--- The expression that `e` is written to the left of, or nil where it has none.
local function left_of(e: Ast.Exp): Ast.Exp | nil
  local kind = base_of(e).kind
  if kind == "Binary" and e is Ast.Binary then
    return e.left
  elseif kind == "Call" and e is Ast.Call then
    return e.callee
  elseif kind == "Field" and e is Ast.Field then
    return e.object
  elseif kind == "Index" and e is Ast.Index then
    return e.object
  elseif kind == "MethodCall" and e is Ast.MethodCall then
    return e.object
  elseif kind == "IsTest" and e is Ast.IsTest then
    return e.value
  elseif kind == "Cast" and e is Ast.Cast then
    return e.value
  end
  return nil
end

--- Whether the expression begins with a long string, which an index brackets with spaces: `t[ [[k]] ]`.
local function begins_long(e: Ast.Exp): boolean
  local cur = e
  while true do
    local nxt = left_of(cur)
    if nxt == nil then
      break
    end
    cur = nxt
  end
  return cur is Ast.String and cur.long
end

local exp: function(e: Ast.Exp): Output
local block: function(b: Ast.Block): Output

--- The items of a list written with `,` between them, the list beginning on line `y`: the arguments of a call and
--- the values of a statement.
local function list(y: integer, items: {Output}): Output
  local out = new(y)
  local space: string | nil = nil
  for i, child in ipairs(items) do
    if i > 1 then
      put(out, ",")
      space = " "
    end
    add_child(out, child, space, child.y ~= y and G.indent or nil)
  end
  return out
end

local function exps(values: {Ast.Exp}, y: integer): Output
  local outs: {Output} = {}
  for i, value in ipairs(values) do
    outs[i] = exp(value)
  end
  return list(y, outs)
end

--- The number's text, as the fork writes it.
local function number_text(token: integer): string
  return (G.tokens.text[token]:gsub("_", ""))
end

--- The parameters of a function, as the `(`...`)` at token `open` has them.
local function params_of(open: integer, params: {Ast.Param}): Output
  local outs: {Output} = {}
  for i, p in ipairs(params) do
    local name = p.name
    outs[i] = text(line_of(p.first), name ~= nil and name.name or "...")
  end
  return list(line_of(open), outs)
end

--- The fields of a table literal, written as the fork writes them.
local function item(it: Ast.Item): Output
  local kind = base_of(it).kind
  local y = line_of(it.first)
  local out = new(y)
  if kind == "Named" and it is Ast.Named then
    add_child(out, text(y, RESERVED_FIELDS[it.name] and "[\"" .. it.name .. "\"]" or it.name))
    put(out, " = ")
    add_child(out, exp(it.value))
  elseif kind == "Keyed" and it is Ast.Keyed then
    put(out, "[")
    local key = exp(it.key)
    if begins_long(it.key) then
      table.insert(key.parts, 1, " ")
      put(key, " ")
    end
    add_child(out, key)
    put(out, "] = ")
    add_child(out, exp(it.value))
  elseif it is Ast.Positional then
    add_child(out, exp(it.value))
  end
  return out
end

local function table_literal(node: Ast.Table): Output
  local y = line_of(node.first)
  local yend = line_of(node.last)
  local items = node.items
  local out = new(y)
  local class = G.classes[node.id]
  local made = class ~= nil and " @ " .. class or ""
  if #items == 0 then
    put(out, "{}" .. made)
    return out
  end
  local child_y = line_of(items[1].first)
  indent_in(y, child_y)
  put(out, "{")
  local children: {Output} = {}
  for i, it in ipairs(items) do
    children[i] = item(it)
  end
  for i, child in ipairs(children) do
    add_child(out, child, " ", child.y ~= y and G.indent or nil)
    if i < #children or yend ~= y then
      put(out, ",")
    end
  end
  indent_out(y, child_y)
  add_child(out, text(yend, "}" .. made), " ", G.indent)
  return out
end

--- A function's parameters and body after its `function` token or name: `head` has been written, and the text
--- before the parameters is `(`.
local function function_rest(out: Output, y: integer, fn: Ast.Fn)
  local body = fn.body
  local body_y = line_of(body.first)
  add_child(out, params_of(fn.first, fn.params))
  put(out, ")")
  add_child(out, block(body), " ")
  indent_out(y, body_y)
  add_child(out, text(line_of(body.close), "end"), " ", G.indent)
end

local function function_literal(node: Ast.FunctionLit): Output
  local y = line_of(node.first)
  local fn = node.fn
  local outer = G.loops
  G.loops = {}
  indent_in(y, line_of(fn.body.first))
  local out = new(y)
  put(out, "function(")
  function_rest(out, y, fn)
  G.loops = outer
  return out
end

--- Wraps `child` in parentheses where an operator of precedence `own` stands over an operand that binds looser.
local function guard(own: integer, operand: Ast.Exp, child: Output)
  local inner = precedence(operand)
  -- `a == type(b) == "string"` is not `a == (b is string)`.
  if inner ~= nil and (own > inner or (own == IS_PRECEDENCE and inner == IS_PRECEDENCE and operand is Ast.IsTest)) then
    parenthesize(child)
  end
end

--- The class a type names, through the aliases of the file, or nil where it names none of this file's.
local function class_named(t: Ast.Type): Ast.Class | nil
  if t is Ast.TypeName then
    local declaration = declaration_of(t)
    if declaration ~= nil and declaration is Ast.Class then
      return declaration
    end
  end
  return nil
end

--- The test of `value` for the type `t`, on the line `y`: one of the three shapes the fork writes, for what `t`
--- stands for through its aliases, or for a class the test of its metatable: `@v == C`. `operand` is the
--- expression `value` writes, which a prefix operator takes in parentheses where it binds looser.
local function type_test(declared: Ast.Type, value: Output, y: integer, operand?: Ast.Exp): Output
  local t = through_aliases(declared, 32)
  local out = new(y)
  local kind = base_of(t).kind
  local class = class_named(t)
  local resolved = G.kinds[base_of(t).id]
  if class ~= nil then
    if operand ~= nil then
      guard(UNARY_PRECEDENCE, operand, value)
    end
    put(out, "@")
    add_child(out, value, "", G.indent)
    put(out, " == " .. class.name.name)
  elseif kind == "TypeName" and t is Ast.TypeName and #t.path == 1 and t.path[1] == "integer" then
    put(out, "math.type(")
    add_child(out, value, "", G.indent)
    put(out, ") == \"integer\"")
  elseif G.enums[base_of(t).id] ~= nil then
    -- A string that is the type's kind is no member of an enum: the test is for the values.
    local members: {string} = {}
    for i, v in ipairs(G.enums[base_of(t).id]) do
      members[i] = "[" .. string.format("%q", v):gsub("\\\n", "\\n") .. "] = true"
    end
    put(out, "({" .. table.concat(members, ", ") .. "})[")
    add_child(out, value, "", G.indent)
    put(out, "] == true")
  elseif resolved == "integer" then
    put(out, "math.type(")
    add_child(out, value, "", G.indent)
    put(out, ") == \"integer\"")
  elseif kind == "TypeNil" or resolved == "nil" then
    add_child(out, value, "", G.indent)
    put(out, " == nil")
  elseif resolved == "true" or resolved == "false" then
    add_child(out, value, "", G.indent)
    if resolved == "true" then
      put(out, " == true")
    else
      put(out, " == false")
    end
  elseif kind == "TypeBool" and t is Ast.TypeBool then
    add_child(out, value, "", G.indent)
    put(out, t.value and " == true" or " == false")
  else
    put(out, "type(")
    add_child(out, value, "", G.indent)
    -- The fork breaks the line inside the quotes where the type is on a later line than the test, which is no Lua.
    local word = resolved
    if word == nil then
      word = lua_type(t, 32)
    end
    put(out, ") == \"" .. word .. "\"")
  end
  return out
end

--- A test `v is T`. Where `T` is a union (through an alias), it is a test for each member, joined by `or`, as the
--- fork writes it for a name; any other value is held in the parameter of a function called on the spot, so that it
--- is evaluated once.
local function is_test(node: Ast.IsTest, value: Output): Output
  local value_node = node.value
  local members = union_members(node.type, 32)
  if members == nil then
    return type_test(node.type, value, line_of(node.value.last + 1), node.value)
  end
  local y = value.y
  local out = new(line_of(node.value.last + 1))
  local held = not (value_node is Ast.Name)
  if held then
    put(out, "(function(__v) return ")
  end
  for i, member in ipairs(members) do
    if i > 1 then
      put(out, " or ")
    end
    local operand: Output
    if held then
      operand = text(y, "__v")
    elseif i == 1 then
      operand = value
    else
      operand = exp(node.value)
    end
    add_child(out, type_test(member, operand, y, not held and node.value or nil), "", G.indent)
  end
  if held then
    put(out, " end)(")
    add_child(out, value, "", G.indent)
    put(out, ")")
  end
  return out
end

--- `e` given the output `left` of the expression to its left, the one [`left_of`] finds. The pieces of `e` are all
--- written before the indent is read, as the fork writes a node after its children.
local function combine(e: Ast.Exp, left: Output): Output
  local kind = base_of(e).kind
  if kind == "Binary" and e is Ast.Binary then
    local op = e.op
    local own = PRECEDENCE[op]
    local out = new(line_of(e.left.last + 1))
    local right = exp(e.right)
    guard(own, e.left, left)
    guard(own, e.right, right)
    add_child(out, left, "", G.indent)
    put(out, " ")
    put(out, op)
    add_child(out, right, " ", G.indent)
    return out
  elseif kind == "Field" and e is Ast.Field then
    local out = new(line_of(e.object.last + 1))
    add_child(out, left, "", G.indent)
    if RESERVED_FIELDS[e.name] then
      add_child(out, text(line_of(e.last), "[\"" .. e.name .. "\"]"), "", G.indent)
    else
      put(out, ".")
      add_child(out, text(line_of(e.last), e.name), "", G.indent)
    end
    return out
  elseif kind == "Index" and e is Ast.Index then
    local out = new(line_of(e.object.last + 1))
    local key = exp(e.key)
    if begins_long(e.key) then
      table.insert(key.parts, 1, " ")
      put(key, " ")
    end
    add_child(out, left, "", G.indent)
    put(out, "[")
    add_child(out, key, "", G.indent)
    put(out, "]")
    return out
  elseif kind == "Call" and e is Ast.Call then
    local y = line_of(e.callee.last + 1)
    local out = new(y)
    local args = exps(e.args, y)
    add_child(out, left, "", G.indent)
    put(out, "(")
    add_child(out, args, "", G.indent)
    put(out, ")")
    return out
  elseif kind == "MethodCall" and e is Ast.MethodCall then
    local colon = e.object.last + 1
    local y = line_of(colon + 2)
    local method = new(line_of(colon))
    add_child(method, left, "", G.indent)
    put(method, ":")
    add_child(method, text(line_of(colon + 1), e.name), "", G.indent)
    local out = new(y)
    local args = exps(e.args, y)
    add_child(out, method, "", G.indent)
    put(out, "(")
    add_child(out, args, "", G.indent)
    put(out, ")")
    return out
  elseif kind == "IsTest" and e is Ast.IsTest then
    return is_test(e, left)
  elseif kind == "Cast" and e is Ast.Cast then
    local out = new(line_of(e.value.last + 1))
    add_child(out, left, "", G.indent)
    return out
  end
  return new(1)
end

--- Whether `node` or a node under it, apart from those of a function inside, is a `...`.
local function holds_vararg(node: Ast.Node): boolean
  local stack: {Ast.Node} = { node }
  while #stack > 0 do
    local cur = table.remove(stack)
    if cur is Ast.Vararg then
      return true
    elseif not (cur is Ast.FunctionLit) then
      Ast.children(cur, function(child: Ast.Node)
        stack[#stack + 1] = child
      end)
    end
  end
  return false
end

--- An `if` expression whose values all are truthy as the `c and a or b` it stands for: each arm's `then` is the
--- `and` and each `elseif` and the `else` an `or`, at the lines the keywords are on. Any other is a function called
--- on the spot, since `c and a or b` is `b` when `a` is false or nil, and the function keeps each value to one.
local function if_expression(node: Ast.IfExp): Output
  local arms = node.arms
  local plain = true
  for _, arm in ipairs(arms) do
    plain = plain and G.truthy(arm.value)
  end
  local conds: {Output} = {}
  local values: {Output} = {}
  for i, arm in ipairs(arms) do
    conds[i] = exp(arm.cond)
    values[i] = exp(arm.value)
    if plain then
      guard(PRECEDENCE["and"], arm.cond, conds[i])
      guard(PRECEDENCE["and"], arm.value, values[i])
    end
  end
  local rest = exp(node.else_value)
  if not plain then
    local varargs = holds_vararg(node)
    local out = new(line_of(node.first))
    put(out, varargs and "(function(...)" or "(function()")
    for i, arm in ipairs(arms) do
      add_child(out, text(line_of(arm.first - 1), i == 1 and "if" or "elseif"), " ", G.indent)
      add_child(out, conds[i], " ", G.indent)
      add_child(out, text(line_of(arm.value.first - 1), "then return ("), " ", G.indent)
      add_child(out, values[i], "", G.indent)
      put(out, ")")
    end
    add_child(out, text(line_of(node.else_value.first - 1), "else return ("), " ", G.indent)
    add_child(out, rest, "", G.indent)
    put(out, ")")
    add_child(out, text(line_of(node.last), varargs and "end end)(...)" or "end end)()"), " ", G.indent)
    return out
  end
  local acc: Output | nil = nil
  for i, arm in ipairs(arms) do
    local both = new(line_of(arm.value.first - 1))
    add_child(both, conds[i], "", G.indent)
    put(both, " and")
    add_child(both, values[i], " ", G.indent)
    if acc == nil then
      acc = both
    else
      local joined = new(line_of(arm.first - 1))
      add_child(joined, acc, "", G.indent)
      put(joined, " or")
      add_child(joined, both, " ", G.indent)
      acc = joined
    end
  end
  local out = new(line_of(node.else_value.first - 1))
  if acc ~= nil then
    add_child(out, acc, "", G.indent)
  end
  put(out, " or")
  add_child(out, rest, " ", G.indent)
  return out
end

local function leaf(e: Ast.Exp): Output
  local kind = base_of(e).kind
  local first = base_of(e).first
  local y = line_of(first)
  if kind == "Name" and e is Ast.Name then
    return text(y, e.text)
  elseif kind == "String" then
    return text(y, Lexer.text(G.tokens, first))
  elseif kind == "Integer" or kind == "Float" then
    return text(y, number_text(first))
  elseif kind == "Nil" then
    return text(y, "nil")
  elseif kind == "Boolean" and e is Ast.Boolean then
    return text(y, e.value and "true" or "false")
  elseif kind == "Vararg" then
    return text(y, "...")
  elseif kind == "Paren" and e is Ast.Paren then
    local out = new(y)
    put(out, "(")
    add_child(out, exp(e.inner), "", G.indent)
    put(out, ")")
    return out
  elseif kind == "FunctionLit" and e is Ast.FunctionLit then
    return function_literal(e)
  elseif kind == "Table" and e is Ast.Table then
    return table_literal(e)
  elseif kind == "Unary" and e is Ast.Unary then
    local out = new(y)
    local own = UNARY_PRECEDENCE
    put(out, e.op)
    local operand = exp(e.operand)
    guard(own, e.operand, operand)
    if e.op == "not" then
      add_child(out, operand, " ", G.indent)
    else
      -- `--` would begin a comment.
      local inner = e.operand
      local nested = e.op == "-" and inner is Ast.Unary and inner.op == "-"
      add_child(out, operand, nested and " " or "", G.indent)
    end
    return out
  elseif kind == "IfExp" and e is Ast.IfExp then
    return if_expression(e)
  end
  return new(y)
end

--- `out`, the read at `e`, wrapped in a call of `__fact` where the caller asked for the read to be checked.
local function checked_read(e: Ast.Exp, out: Output): Output
  local arguments = G.wraps[base_of(e).id]
  if arguments == nil then
    return out
  end
  local result = new(out.y)
  put(result, "__fact(")
  add_child(result, out, "", G.indent)
  put(result, ", " .. arguments .. ")")
  return result
end

exp = function(e: Ast.Exp): Output
  local spine: {Ast.Exp} = {}
  local cur = e
  while true do
    local nxt = left_of(cur)
    if nxt == nil then
      break
    end
    spine[#spine + 1] = cur
    cur = nxt
  end
  local out = checked_read(cur, leaf(cur))
  for i = #spine, 1, -1 do
    out = checked_read(spine[i], combine(spine[i], out))
  end
  return out
end

-- Statements ------------------------------------------------------------------------------------------------------

local stat: function(s: Ast.Stat): Output

--- The text that closes a loop: `word`, after the `::continue::` that the loop's `continue` statements jump to.
local function close_text(word: string, y: integer, labelled: boolean): Output
  return text(y, labelled and "::continue:: " .. word or word)
end

--- Whether a `continue` ends a pass of the loop whose body is `body`: one in it, not in a loop or a function inside.
local function continues(body: Ast.Block): boolean
  local stack: {Ast.Node} = { body }
  while #stack > 0 do
    local cur = table.remove(stack)
    if cur is Ast.Continue then
      return true
    elseif not (cur is Ast.While or cur is Ast.Repeat or cur is Ast.ForNum or cur is Ast.ForIn or
        cur is Ast.FunctionLit or cur is Ast.LocalFunction or cur is Ast.Function or cur is Ast.Method) then
      Ast.children(cur, function(child: Ast.Node)
        stack[#stack + 1] = child
      end)
    end
  end
  return false
end

--- Writes a loop's body and closing, `body_of` giving the pieces between the opening and the close.
local function loop_body(body: Ast.Block): Output, boolean
  -- A `continue` of this loop, and a `return` that ends the body.
  local last = body.stats[#body.stats]
  local outer = G.guarded
  if last ~= nil and last is Ast.Return and continues(body) then
    G.guarded = last
  end
  G.loops[#G.loops + 1] = false
  local out = block(body)
  local labelled = table.remove(G.loops)
  G.guarded = outer
  return out, labelled
end

--- Whether the value of `s` ends in an expression, so that a line that begins with `(` after it would continue it.
local function ends_in_expression(s: Ast.Stat): boolean
  local kind = base_of(s).kind
  if kind == "Local" and s is Ast.Local then
    return #s.values > 0
  elseif kind == "Assign" or kind == "CallStat" then
    return true
  elseif kind == "Return" and s is Ast.Return then
    return #s.values > 0
  elseif kind == "Function" and s is Ast.Function then
    -- `R.goto = function() end` ends in an expression.
    return RESERVED_FIELDS[s.path[#s.path].text] == true
  end
  return false
end

block = function(b: Ast.Block): Output
  local out = new(line_of(b.first))
  local stats = b.stats
  local children: {Output} = {}
  for i = 1, #stats do
    children[i] = stat(stats[i])
  end
  local space: string | nil = nil
  for i = 1, #stats do
    add_child(out, children[i], space, G.indent)
    -- The fork's parser ends a statement with a `;` where the next begins a line with `(`, which would continue it.
    local s = stats[i]
    local following = stats[i + 1]
    local ends = following ~= nil and ends_in_expression(s) and G.tokens.text[base_of(following).first] == "(" and
      line_of(base_of(following).first) > Lexer.yend(G.tokens, base_of(s).last)
    if ends then
      put(out, ";")
      space = " "
    else
      space = "; "
    end
  end
  return out
end

--- The nested records of `members`, written as the table `{ A = {}, B = { C = {} } }`.
local function record_table(members: {Ast.Member}): string
  local pieces: {string} = {}
  for _, m in ipairs(members) do
    if m is Ast.Record then
      pieces[#pieces + 1] = " " .. m.name.name .. " = " .. record_table(m.members)
    end
  end
  if #pieces == 0 then
    return "{}"
  end
  return "{" .. table.concat(pieces, ",") .. " }"
end

--- Refuses each class declared in `members`, however deep in the types around it: only a class of the file's own
--- blocks has a table to name.
local function refuse_nested_classes(members: {Ast.Member})
  for _, m in ipairs(members) do
    if m is Ast.Class then
      refuse("class_nested_refused", m.first, "the class `" .. m.name.name .. "` is declared inside another type, and " ..
          "has no table of its own at run time",
        "declare `" .. m.name.name .. "` beside the type around it")
    end
    if m is Ast.Record or m is Ast.Class or m is Ast.Interface then
      refuse_nested_classes(m.members)
    end
  end
end

--- Whether the program reads or assigns the binding `name` as a value. A record the program names only in types
--- is not written.
local function used_as_value(name: Ast.Binding): boolean
  local var = G.scoped.vars[name.id]
  return var ~= nil and (#var.reads > 0 or #var.writes > 0)
end

--- A `local record` that the program uses as a value is `local R = {}`, holding its nested records.
local function record_statement(node: Ast.Record): Output
  refuse_nested_classes(node.members)
  if not used_as_value(node.name) then
    return new(1)
  end
  local y = line_of(node.first)
  local out = new(y)
  put(out, "local")
  add_child(out, text(line_of(node.name.first), node.name.name), " ")
  put(out, " =")
  add_child(out, text(y, #node.typeparams > 0 and "{}" or record_table(node.members)), " ")
  return out
end

--- `local type T = require("m")` is `local T = require("m")` where `T` is read or written as a value, and is erased where `T` is
--- used as a type alone. A file compiled alone also keeps the import of a name it does not use; a build that serves every module
--- (`G.served`) erases it, as the fork then erases every `local type`.
local function import_statement(node: Ast.Import): Output
  local var = G.scoped.vars[node.name.id]
  if G.served and (var == nil or (#var.reads == 0 and #var.writes == 0)) then
    return new(1)
  end
  if var ~= nil and #var.reads == 0 and #var.writes == 0 and #var.type_uses > 0 then
    return new(1)
  end
  local at = node.name.last + 2
  local y = line_of(node.name.first)
  local out = new(y)
  put(out, "local")
  add_child(out, text(y, node.name.name), " ")
  put(out, " =")
  local open = at + 1
  local call = new(line_of(open))
  add_child(call, text(line_of(at), "require"), "", G.indent)
  put(call, "(")
  add_child(call, list(line_of(open), { text(line_of(open + 1), Lexer.text(G.tokens, open + 1)) }), "", G.indent)
  put(call, ")")
  add_child(out, call, " ")
  return out
end

local function local_statement(s: Ast.Local): Output
  local out = new(line_of(s.bindings[1].first))
  put(out, "local ")
  for i, b in ipairs(s.bindings) do
    if i > 1 then
      put_counted(out, ", ")
    end
    put_counted(out, b.name)
    local attr = b.attr
    if attr ~= nil then
      put_counted(out, " <" .. attr .. ">")
    end
  end
  local values = s.values
  if #values > 0 then
    put(out, " =")
    add_child(out, exps(values, line_of(values[1].first - 1)), " ")
  end
  return out
end

local function assign_statement(s: Ast.Assign): Output
  local y = line_of(s.first)
  local out = new(y)
  add_child(out, exps(s.targets, y))
  put(out, " =")
  add_child(out, exps(s.values, line_of(s.values[1].first - 1)), " ")
  return out
end

local function if_statement(s: Ast.If): Output
  local y = line_of(s.first)
  local out = new(y)
  local pieces: {Output} = {}
  for i, arm in ipairs(s.arms) do
    local ay = line_of(arm.first - 1)
    local body_y = line_of(arm.body.first)
    indent_in(ay, body_y)
    local piece = new(ay)
    put(piece, i == 1 and "if" or "elseif")
    add_child(piece, exp(arm.cond), " ")
    put(piece, " then")
    add_child(piece, block(arm.body), " ")
    indent_out(ay, body_y)
    pieces[#pieces + 1] = piece
  end
  local else_body = s.else_body
  if else_body ~= nil then
    local ay = line_of(else_body.first - 1)
    local body_y = line_of(else_body.first)
    indent_in(ay, body_y)
    local piece = new(ay)
    put(piece, "else")
    add_child(piece, block(else_body), " ")
    indent_out(ay, body_y)
    pieces[#pieces + 1] = piece
  end
  for i, piece in ipairs(pieces) do
    add_child(out, piece, i > 1 and " " or nil, piece.y ~= y and G.indent or nil)
  end
  add_child(out, text(line_of(s.last), "end"), " ", G.indent)
  return out
end

local function while_statement(s: Ast.While): Output
  local y = line_of(s.first)
  local body_y = line_of(s.body.first)
  indent_in(y, body_y)
  local out = new(y)
  put(out, "while")
  add_child(out, exp(s.cond), " ")
  put(out, " do")
  local body, labelled = loop_body(s.body)
  add_child(out, body, " ")
  indent_out(y, body_y)
  add_child(out, close_text("end", line_of(s.last), labelled), " ", G.indent)
  return out
end

local function repeat_statement(s: Ast.Repeat): Output
  local y = line_of(s.first)
  local body_y = line_of(s.body.first)
  indent_in(y, body_y)
  local out = new(y)
  put(out, "repeat")
  local body, labelled = loop_body(s.body)
  add_child(out, body, " ")
  local cond = exp(s.cond)
  indent_out(y, body_y)
  add_child(out, close_text("until ", line_of(s.last), labelled), " ", G.indent)
  add_child(out, cond)
  return out
end

local function for_num_statement(s: Ast.ForNum): Output
  local y = line_of(s.first)
  local body_y = line_of(s.body.first)
  indent_in(y, body_y)
  local out = new(y)
  put(out, "for")
  add_child(out, text(line_of(s.var.first), s.var.name), " ")
  put(out, " =")
  add_child(out, exp(s.from), " ")
  put(out, ",")
  add_child(out, exp(s.to), " ")
  local step = s.step
  if step ~= nil then
    put(out, ",")
    add_child(out, exp(step), " ")
  end
  put(out, " do")
  local body, labelled = loop_body(s.body)
  add_child(out, body, " ")
  indent_out(y, body_y)
  add_child(out, close_text("end", line_of(s.last), labelled), " ", G.indent)
  return out
end

local function for_in_statement(s: Ast.ForIn): Output
  local y = line_of(s.first)
  local body_y = line_of(s.body.first)
  indent_in(y, body_y)
  local out = new(y)
  put(out, "for")
  local names: {Output} = {}
  for i, b in ipairs(s.vars) do
    names[i] = text(line_of(b.first), b.name)
  end
  add_child(out, list(line_of(s.vars[1].first), names), " ")
  put(out, " in")
  add_child(out, exps(s.iterators, line_of(s.iterators[1].first)), " ")
  put(out, " do")
  local body, labelled = loop_body(s.body)
  add_child(out, body, " ")
  indent_out(y, body_y)
  add_child(out, close_text("end", line_of(s.last), labelled), " ", G.indent)
  return out
end

--- A `match` as a `do` block that holds the values of its call and an `if` on them: an arm tests the `true` and
--- `false` of its patterns and binds the names of the others.
local function match_statement(s: Ast.Match): Output
  G.matches = G.matches + 1
  local prefix = "__m" .. G.matches .. "_"
  local width = 0
  for _, arm in ipairs(s.arms) do
    width = math.max(width, #arm.pats)
  end
  local y = line_of(s.first)
  local out = new(y)
  local names: {string} = {}
  for i = 1, width do
    names[i] = prefix .. i
  end
  put(out, "do local " .. table.concat(names, ", ") .. " =")
  add_child(out, exp(s.scrutinee), " ")
  local pieces: {Output} = {}
  for k, arm in ipairs(s.arms) do
    local ay = line_of(arm.first)
    local body_y = line_of(arm.body.first)
    indent_in(ay, body_y)
    local piece = new(ay)
    local tests: {string} = {}
    local bound: {string} = {}
    local values: {string} = {}
    for i, p in ipairs(arm.pats) do
      if p is Ast.PatBool then
        tests[#tests + 1] = names[i] .. " == " .. (p.value and "true" or "false")
      elseif p is Ast.PatBind then
        bound[#bound + 1] = p.name.name
        values[#values + 1] = names[i]
      end
    end
    if #tests == 0 then
      put(piece, k == 1 and "if true then" or "else")
    else
      put(piece, (k == 1 and "if " or "elseif ") .. table.concat(tests, " and ") .. " then")
    end
    if #bound > 0 then
      put(piece, " local " .. table.concat(bound, ", ") .. " = " .. table.concat(values, ", "))
    end
    add_child(piece, block(arm.body), " ")
    indent_out(ay, body_y)
    pieces[k] = piece
  end
  for _, piece in ipairs(pieces) do
    add_child(out, piece, " ", piece.y ~= y and G.indent or nil)
  end
  add_child(out, text(line_of(s.last), "end end"), " ", G.indent)
  return out
end

--- A method of the class `class`: `function C.name(self, ...)` on the line of the method.
local function method_statement(class: Ast.Class, m: Ast.Method): Output
  local y = line_of(m.first)
  local body = m.body
  local outer = G.loops
  G.loops = {}
  indent_in(y, line_of(body.first))
  local out = new(y)
  put(out, "function")
  add_child(out, text(y, class.name.name), " ")
  put(out, ".")
  add_child(out, text(line_of(m.name.first), m.name.name))
  put(out, "(")
  add_child(out, params_of(m.name.last + 1, m.params))
  put(out, ")")
  add_child(out, block(body), " ")
  indent_out(y, line_of(body.first))
  add_child(out, text(line_of(body.close), "end"), " ", G.indent)
  G.loops = outer
  return out
end

--- A `class` as its table, which is its methods' and the metatable of its values (`__index` is the table; a method
--- named `__close` or `__tostring` is that metamethod), and then each method.
local function class_statement(s: Ast.Class): Output
  local name = s.name.name
  local y = line_of(s.first)
  local out = new(y)
  put(out, "local")
  add_child(out, text(line_of(s.name.first), name), " ")
  put(out, " =")
  add_child(out, text(y, #s.typeparams > 0 and "{}" or record_table(s.members)), " ")
  put(out, "; " .. name .. ".__index = " .. name)
  refuse_nested_classes(s.members)
  for _, m in ipairs(s.members) do
    if m is Ast.Method then
      add_child(out, method_statement(s, m), "; ", G.indent)
    end
  end
  return out
end

stat = function(s: Ast.Stat): Output
  local kind = base_of(s).kind
  local first = base_of(s).first
  if kind == "Local" and s is Ast.Local then
    return local_statement(s)
  elseif kind == "Assign" and s is Ast.Assign then
    return assign_statement(s)
  elseif kind == "CallStat" and s is Ast.CallStat then
    return exp(s.call)
  elseif kind == "LocalFunction" and s is Ast.LocalFunction then
    local y = line_of(first)
    local outer = G.loops
    G.loops = {}
    indent_in(y, line_of(s.fn.body.first))
    local out = new(y)
    put(out, "local function")
    add_child(out, text(line_of(s.name.first), s.name.name), " ")
    put(out, "(")
    function_rest(out, y, s.fn)
    G.loops = outer
    return out
  elseif kind == "Function" and s is Ast.Function then
    local y = line_of(first)
    local outer = G.loops
    G.loops = {}
    indent_in(y, line_of(s.fn.body.first))
    local out = new(y)
    local name = s.path[#s.path]
    if RESERVED_FIELDS[name.text] then
      -- `function R.goto()` is no Lua 5.5.
      add_child(out, text(line_of(s.path[1].first), s.path[1].text))
      add_child(out, text(line_of(name.first), "[\"" .. name.text .. "\"]"))
      put(out, " = function(")
    else
      put(out, "function")
      add_child(out, text(line_of(s.path[1].first), s.path[1].text), " ")
      put(out, ".")
      add_child(out, text(line_of(name.first), name.text))
      put(out, "(")
    end
    function_rest(out, y, s.fn)
    G.loops = outer
    return out
  elseif kind == "Return" and s is Ast.Return then
    local out = new(line_of(first))
    local wrapped = G.guarded == s
    put(out, wrapped and "do return" or "return")
    local values = s.values
    if #values > 0 then
      add_child(out, exps(values, line_of(values[1].first)), " ")
    end
    if wrapped then
      add_child(out, text(line_of(s.last), "end"), " ", G.indent)
    end
    return out
  elseif kind == "Do" and s is Ast.Do then
    local y = line_of(first)
    local body_y = line_of(s.body.first)
    indent_in(y, body_y)
    local out = new(y)
    put(out, "do")
    add_child(out, block(s.body), " ")
    indent_out(y, body_y)
    add_child(out, text(line_of(s.last), "end"), " ", G.indent)
    return out
  elseif kind == "Break" then
    return text(line_of(first), "break")
  elseif kind == "Continue" then
    G.loops[#G.loops] = true
    return text(line_of(first), "goto continue")
  elseif kind == "While" and s is Ast.While then
    return while_statement(s)
  elseif kind == "Repeat" and s is Ast.Repeat then
    return repeat_statement(s)
  elseif kind == "If" and s is Ast.If then
    return if_statement(s)
  elseif kind == "ForNum" and s is Ast.ForNum then
    return for_num_statement(s)
  elseif kind == "ForIn" and s is Ast.ForIn then
    return for_in_statement(s)
  elseif kind == "Match" and s is Ast.Match then
    return match_statement(s)
  elseif kind == "Record" and s is Ast.Record then
    return record_statement(s)
  elseif kind == "Import" and s is Ast.Import then
    return import_statement(s)
  elseif kind == "Class" and s is Ast.Class then
    return class_statement(s)
  elseif kind == "Interface" and s is Ast.Interface then
    refuse_nested_classes(s.members)
  end
  -- An interface, an enum and an alias are types only; a failed production's [`Ast.Error`] node is a refusal the parser already made.
  return new(1)
end

function Codegen.generate(chunk: Ast.Chunk, scoped: Scopes.Scoped, truthy?: function(e: Ast.Exp): boolean,
                          classes?: {integer: string}, enums?: {integer: {string}}, wraps?: {integer: string},
                          kinds?: {integer: string}, served?: boolean): Codegen.Generated
  G.tokens, G.scoped = chunk.tokens, scoped
  G.served = served == true
  G.truthy = truthy or syntactically_truthy
  G.classes = classes or {}
  G.enums, G.wraps, G.kinds = enums or {}, wraps or {}, kinds or {}
  G.guarded = nil
  G.indent, G.saved, G.errors, G.loops, G.declarations, G.matches = 0, {}, {}, {}, nil, 0
  G.body = chunk.body
  local out = block(chunk.body)
  local whole = new(1)
  add_child(whole, out)
  local written = (flatten(whole):gsub(" *\n", "\n"))
  if next(G.wraps) ~= nil then
    -- On the first line, which moves none. A chunk with wraps defines the global the wraps call where it has none, so that
    -- it runs in a process where nothing else did.
    written = "if not __fact then __fact = function(v) return v end end " .. written
  end
  local errors = G.errors
  G.tokens, G.saved, G.errors, G.loops, G.declarations, G.body, G.classes =
    NO_TOKENS, {}, {}, {}, nil, nil, {}
  G.enums, G.wraps, G.kinds, G.served = {}, {}, {}, false
  return { text = written, errors = errors }
end

return Codegen
