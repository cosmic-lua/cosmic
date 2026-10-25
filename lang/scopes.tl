--- The scope builder of the new checker's grammar
--- ([`doc/plans/new-checker-grammar.md`], "the syntax tree"): it walks the tree
--- [`lang.parser`] builds and says, for every name that refers to something,
--- which [`Binding`](lang.ast) it refers to, and what the program does to each
--- binding: read it, assign it, capture it in a function.
---
--- [`Scopes.build`] sets `binding` on each [`Name`](lang.ast) it resolves, and
--- answers a [`Scoped`]: a [`Var`] for each binding, by the id of the
--- [`Binding`](lang.ast) node; `resolved`, which maps the id of each [`Name`](lang.ast),
--- [`TypeName`](lang.ast) and [`Narrows`](lang.ast) to the id of its [`Var`]; the
--- globals the program uses; and the [`Error`]s, each with a code, a place and
--- a fix written against the program's own names.
---
--- Scoping is Lua 5.5's. A local is visible from the statement after its
--- declaration, so the value of `local x = x` is the outer `x`. A `local
--- function`, a record, a class and the other type declarations see their own
--- name. A parameter is visible in the whole body, the control variables of a
--- `for` in its body, a `match` binding in its arm, and the locals of a
--- `repeat` body in its `until`. Type parameters are visible in the
--- declaration or function that declares them.
---
--- A name has one namespace, as in the fork. A [`Space`] says what a binding
--- is for: a variable is a value, an enum, an alias, an interface and a type
--- parameter are types, and a record, a class and an imported module are both.
--- A name that meets the wrong space is the error `not_a_value` or `not_a_type`.
--- A local is the head of a type path only if it holds a module
--- (`local Stream = require("cosmic.stream")`, then [`Stream.Reader`]).
---
--- A name that resolves to no binding is a global. The program's globals are
--- the ones a declaration file declares ([`Scopes.declared`]), which the caller
--- passes in. A global use that the declared names do not hold is the error
--- `unknown_variable` or [`unknown_type`]; the type names `integer`, `number`,
--- `string`, `boolean`, `any`, `thread` and `never` need no declaration
--- ([`Scopes.primitives`]).
---
--- What each [`Var`] records is what the rules of the plan read
--- ([`doc/plans/strict-teal.md`]): that a local is assigned after its declaration
--- (`writes`), that a function reads it from outside (`captures`) and, for each
--- such function, whether an assignment may run after that function is made
--- ([`Capture.after`]), which a test inside the function must know before it
--- narrows the local ("narrowing only what nothing else can change"). A write
--- from inside another function is the error `captured_assigned` ("captures
--- are read-only"). A declaration whose name is already visible, in an
--- enclosing scope, the same scope or the declared globals, is the error
--- `shadows`, as the fork's `redeclaration` warning is, with the same
--- exceptions: a name that begins with `_`, `self`, a nested type declaration
--- and `local x = x`, which copies the outer value ([`Var.copies`]).
---
--- A chain that leans left (`a + b + c`, `a.b.c`, `f()()`, `e is T`) is walked
--- without recursion, so one of any length is walked. What nests (blocks,
--- parentheses, unary operators, types, function literals and the right
--- operand of `..` and `^`) recurses as deep as the parser lets it (200).
--- The builder keeps its state in a table of its own, so it is not re-entrant.

local Ast = require("lang.ast")
local Lexer = require("lang.lexer")

local record Scopes
  --- What introduced a binding.
  enum Kind
    "local"
    "function"
    "param"
    "loop"
    "pattern"
    "typeparam"
    "record"
    "interface"
    "class"
    "enum"
    "alias"
    "import"
  end

  --- What a binding names: a `value`, a `type` or `both`.
  enum Space
    "value"
    "type"
    "both"
  end

  --- What an error is, so that a reader does not parse its `msg`.
  enum Code
    -- a name that no binding and no declared global holds
    "unknown_variable"
    -- a type name that no binding, declared global or primitive holds
    "unknown_type"
    -- a declaration whose name is already visible
    "shadows"
    -- a function that assigns a local declared outside it
    "captured_assigned"
    -- an assignment to a `<const>` or `<close>` variable or a loop's control variable
    "const_assigned"
    -- a type used as a value
    "not_a_value"
    -- a variable, parameter or function used as a type
    "not_a_type"
    -- a narrowing return that names no parameter
    "unknown_parameter"
    -- `_ENV` declared or assigned
    "env_reserved"
    -- a type declared with the name of a primitive type
    "primitive_type_name"
  end

  --- A place of a token.
  record Place
    y: integer
    x: integer
    offset: integer
    length: integer
  end

  --- An error, with the places of [`lang.parser`]'s: `y`, `x`, `offset` and
  --- `length` place the name at fault.
  record Error
    filename: string
    code: Code
    --- What is wrong, in one line.
    msg: string
    --- How to put it right, written against the program's own names.
    fix: string
    y: integer
    x: integer
    offset: integer
    length: integer
    --- The second place the error involves: the declaration a name shadows
    --- or a function assigns, nil where it is a declared global.
    other?: Place
  end

  --- A global a declaration file declares.
  record Global
    space: Space
    --- Declared `<const>`: a program cannot assign it.
    const: boolean
  end

  --- A function that reads a local declared outside it.
  record Capture
    --- The id of the function ([`Ast.Fn`](lang.ast) or [`Ast.Method`](lang.ast))
    --- that holds the reads and is made by the code that declares the local: the
    --- outermost function nested in the declaring one, when a read is in a function
    --- inside it.
    fn: integer
    --- The ids of the names in it that read the local.
    uses: {integer}
    --- Whether an assignment to the local may run after the function is made:
    --- one that follows it in the source, one in the same statement, or one in a
    --- loop that holds both and is inside the local's scope.
    after: boolean
  end

  --- A binding, and what the program does with it.
  record Var
    --- The id of its [`Binding`](lang.ast) node. The implicit `self` of the refused form `function R:m()`
    --- has the id of that [`Function`](lang.ast) statement.
    id: integer
    name: string
    kind: Kind
    space: Space
    attr?: Ast.Attr
    --- Whether it is declared with `global`: the globals of a declaration file.
    exported: boolean
    --- Whether the chunk's own scope holds it.
    top: boolean
    --- The index of the token of its name, in [`Ast.Chunk.tokens`](lang.ast).
    declared: integer
    --- The first and last token it is visible at. A local is visible from the
    --- token after its statement; a function, a type, a parameter and a loop
    --- variable from their own name.
    from: integer
    to: integer
    --- The id of the function that declares it, 1 for the chunk, and how many
    --- functions deep that is (1 for the chunk).
    owner: integer
    depth: integer
    --- The id of the innermost loop of its function that it is declared inside, 0 for none.
    loop: integer
    --- For `local m = require("module")`, the module; "" for any other binding.
    module: string
    --- For `local x = a.b`, the text `a.b`: what `local type x = a.b` would name.
    alias?: string
    --- For `local x = x`, the id of the [`Var`] whose value it copies. Nil
    --- where the right side is a global.
    copies?: integer
    --- A loop's control variable, a `<const>` and a `<close>` are read-only.
    readonly: boolean
    --- The ids of the names that read it, that assign it, and of the type
    --- names whose head it is, in source order.
    reads: {integer}
    writes: {integer}
    type_uses: {integer}
    --- Whether anything assigns it after its declaration: `#writes > 0`.
    assigned: boolean
    --- The functions that read it from outside, in source order.
    captures: {Capture}
    --- Whether it is a type declared in the body of another type, named through it (`Outer.Inner`).
    nested: boolean
    --- For `local function f`, the id of the [`Ast.Fn`](lang.ast) it binds: the reads inside it are the function's own
    --- (a recursive call), which [`lang.warnings`] does not count as use.
    fn?: integer
  end

  --- What [`Scopes.build`] answers.
  record Scoped
    --- Every binding, by the id of its [`Binding`](lang.ast) node.
    vars: {integer: Var}
    --- Every binding, in the order the walk declared them.
    list: {Var}
    --- The id of each name, type name and narrowing return that resolved to a
    --- binding, to the id of the [`Var`].
    resolved: {integer: integer}
    --- For each global the program uses, the ids of the names and type names
    --- that use it, in source order; the names that are assigned are also in `global_writes`.
    globals: {string: {integer}}
    global_writes: {string: {integer}}
    --- Every error, in source order.
    errors: {Error}
  end

  --- Resolves the names of `chunk`, which is the parse of a source named
  --- `name`, against the globals `declared`: sets `binding` on each [`Name`](lang.ast)
  --- that refers to a binding (and clears it on one that does not) and answers the
  --- facts. The chunk must be numbered, as [`lang.parser`] answers it. It never raises.
  build: function(chunk: Ast.Chunk, name: string, declared: {string: Global}): Scoped

  --- The globals a declaration file declares: its `global` declarations,
  --- including those in a `do` block.
  declared: function(chunk: Ast.Chunk): {string: Global}

  --- The bindings visible at the token `at` (an index of [`Ast.Chunk.tokens`](lang.ast)),
  --- by name: the innermost of each, as Lua reads it there. It looks at every binding, so it
  --- costs the number of bindings; ask it for a few places, not for every token.
  in_scope: function(scoped: Scoped, at: integer): {string: Var}

  --- The type names a program may use with no declaration.
  primitives: {string: boolean}

  --- Every [`Code`], in the order the enum lists them.
  codes: {Code}
end

Scopes.primitives = {
  any = true, boolean = true, integer = true, never = true, number = true, string = true, thread = true,
}

-- A function being walked.
local record Frame
  id: integer
  --- The innermost loop of this function the walk is in, 0 for none.
  loop: integer
end

-- A name that no binding or declared global holds, whose error is made at the end so
-- that it can say the name is declared later.
local record Unknown
  token: integer
  name: string
  --- "variable", "assigned" or "type".
  what: string
  --- The nearest name there is, and the place of its declaration, "" where it is a declared global.
  guess: string
  guess_at: Scopes.Place?
end

-- A type name that no declaration holds yet, waiting for the scope it is in to end.
local record Pending
  node: Ast.TypeName
  name: string
  --- The innermost scope that has not ended where it may be declared.
  depth: integer
end

local record State
  mut tokens: Lexer.Tokens
  mut filename: string
  mut declared: {string: Scopes.Global}
  --- For each name, its bindings in scope, the innermost last.
  mut visible: mut {string: {Scopes.Var}}
  --- The names declared in the open scopes, innermost last; `marks` holds how
  --- many there were when each scope opened and `ends` the token it ends at.
  mut names: mut {string}
  mut marks: mut {integer}
  mut ends: mut {integer}
  mut frames: mut {Frame}
  --- The loop a loop is inside and how deep it is, by the id of its node.
  mut loop_parent: mut {integer: integer}
  mut loop_level: mut {integer: integer}
  mut vars: mut {integer: Scopes.Var}
  mut list: mut {Scopes.Var}
  mut resolved: mut {integer: integer}
  mut globals: {string: {integer}}
  mut global_writes: {string: {integer}}
  mut errors: mut {Scopes.Error}
  mut unknown: mut {Unknown}
  --- How many nearest-name searches have been made; they stop at `GUESSES`.
  mut guessed: integer
  --- The names of the parameters a narrowing return may name, with the id of the binding, 0 for a function type's.
  mut params: {string: integer}?
  --- Where the assignment being walked ends.
  mut assign_end: integer
  --- When each variable was assigned: the token its statement ends at, and the loop.
  mut write_end: mut {Scopes.Var: {integer}}
  mut write_loop: mut {Scopes.Var: {integer}}
  --- The variables with a capture, to settle at the end.
  mut captured: mut {Scopes.Var}
  --- Where each function ends, and the loop of the function around it that it is made inside.
  mut made: mut {integer: integer}
  mut entry_of: mut {integer: integer}
  --- The nodes of an expression whose left side is being walked down.
  mut spine: {Ast.Exp}
  mut top: integer
  --- The sorted names of the declared globals, when a search wants them.
  mut global_names: {string}?
  --- The `local function` whose type parameters and parameters are being declared: they do not shadow its name.
  mut own: Scopes.Var?
  --- The deepest scope a type name may wait in: a function's signature waits outside the function.
  mut floor: integer
  --- Whether a type name met now may be declared later in an enclosing scope: it is inside a
  --- function's signature, a type declaration or a function type.
  mut defer: boolean
  --- The type names met so far that no declaration holds, to look for in the scope that ends.
  mut pending: mut {Pending}
end

-- The most nearest-name searches a run makes: a run of many unknown names does not cost a scan of the scope for each.
local GUESSES <const> = 50

local NO_TOKENS <const>: Lexer.Tokens = Lexer.lex("", "").tokens

local S: State = {
  tokens = NO_TOKENS, filename = "", declared = {}, visible = {}, names = {}, marks = {}, ends = {}, frames = {},
  loop_parent = {}, loop_level = {}, vars = {}, list = {}, resolved = {}, globals = {}, global_writes = {},
  errors = {}, unknown = {}, guessed = 0, assign_end = 0, write_end = {}, write_loop = {}, captured = {},
  made = {}, entry_of = {}, spine = {}, top = 0, defer = false, pending = {}, own = nil, floor = math.maxinteger,
}

local function base_of(node: Ast.Node): Ast.Base
  return node
end

local function reset(tokens: Lexer.Tokens, name: string, declared: {string: Scopes.Global})
  S.tokens, S.filename, S.declared = tokens, name, declared
  S.visible, S.names, S.marks, S.ends, S.frames = {}, {}, {}, {}, {}
  S.loop_parent, S.loop_level = {}, {}
  S.vars, S.list, S.resolved, S.globals, S.global_writes = {}, {}, {}, {}, {}
  S.errors, S.unknown, S.guessed, S.params, S.assign_end = {}, {}, 0, nil, 0
  S.write_end, S.write_loop, S.captured, S.made, S.entry_of = {}, {}, {}, {}, {}
  S.spine, S.top, S.global_names, S.defer, S.pending, S.own = {}, 0, nil, false, {}, nil
  S.floor = math.maxinteger
end

local function quoted(name: string): string
  return "`" .. name .. "`"
end

local function place_of(token: integer): Scopes.Place
  local tokens = S.tokens
  return {
    y = Lexer.y(tokens, token), x = Lexer.x(tokens, token), offset = Lexer.offset(tokens, token),
    length = Lexer.length(tokens, token),
  }
end

local function shown(token: integer): string
  return Lexer.y(S.tokens, token) .. ":" .. Lexer.x(S.tokens, token)
end

local function report(code: Scopes.Code, token: integer, msg: string, fix: string, other?: Scopes.Place)
  local tokens = S.tokens
  S.errors[#S.errors + 1] = {
    filename = S.filename, code = code, msg = msg, fix = fix, y = Lexer.y(tokens, token), x = Lexer.x(tokens, token),
    offset = Lexer.offset(tokens, token), length = Lexer.length(tokens, token), other = other,
  }
end

-- Scopes -------------------------------------------------------------------

-- Opens a scope that ends at the token `last`.
local function open(last: integer)
  S.marks[#S.marks + 1] = #S.names
  S.ends[#S.ends + 1] = last
end

local resolve_pending: function(depth: integer)

local function close()
  local mark = S.marks[#S.marks]
  if #S.pending > 0 then
    resolve_pending(#S.marks)
  end
  local names, visible = S.names, S.visible
  for i = #names, mark + 1, -1 do
    local stack = visible[names[i]]
    stack[#stack] = nil
    names[i] = nil
  end
  S.marks[#S.marks] = nil
  S.ends[#S.ends] = nil
end

local function frame(): Frame
  return S.frames[#S.frames]
end

local function push_frame(id: integer, last: integer)
  local current = S.frames[#S.frames]
  local entry = current ~= nil and current.loop or 0
  S.frames[#S.frames + 1] = { id = id, loop = 0 }
  S.made[id] = last
  S.entry_of[id] = entry
end

local function pop_frame()
  S.frames[#S.frames] = nil
end

-- Enters the loop `id`, whose node is `id`.
local function enter_loop(id: integer)
  local f = frame()
  S.loop_parent[id] = f.loop
  S.loop_level[id] = (S.loop_level[f.loop] or 0) + 1
  f.loop = id
end

local function leave_loop(id: integer)
  frame().loop = S.loop_parent[id]
end

local function lookup(name: string): Scopes.Var?
  local stack = S.visible[name]
  if stack == nil then
    return nil
  end
  return stack[#stack]
end

-- Edit distance --------------------------------------------------------------

-- The edit distance between `a` and `b` if it is at most `limit`, else `limit + 1`.
local function distance(a: string, b: string, limit: integer): integer
  local la, lb = #a, #b
  if la - lb > limit or lb - la > limit then
    return limit + 1
  end
  local previous: mut {integer} = {}
  for j = 0, lb do
    previous[j] = j
  end
  for i = 1, la do
    local row: mut {integer} = { [0] = i }
    local least = i
    local ca = a:byte(i)
    for j = 1, lb do
      local cost = if ca == b:byte(j) then 0 else 1 end
      local best = previous[j - 1] + cost
      local up = previous[j] + 1
      if up < best then best = up end
      local left = row[j - 1] + 1
      if left < best then best = left end
      row[j] = best
      if best < least then least = best end
    end
    if least > limit then
      return limit + 1
    end
    previous = row
  end
  return previous[lb]
end

-- How far from a name another may be to be taken for what was meant.
local function allowed(name: string): integer
  local n = #name
  if n <= 2 then
    return 0
  elseif n <= 5 then
    return 1
  end
  return 2
end

-- Whether `other` is near enough to `name` to be what was meant.
local function near(name: string, other: string, limit: integer): integer
  if other == name then
    return limit + 1
  end
  local d = distance(name, other, limit)
  if d > limit and other:lower() == name:lower() then
    return 1
  end
  return d
end

-- Whether a binding of `space` can stand where a type (`types`) or a value goes.
local function fits(space: Scopes.Space, types: boolean): boolean
  if types then
    return space ~= "value"
  end
  return space ~= "type"
end

-- The sorted names of the declared globals and the primitives.
local function global_names(): {string}
  local held = S.global_names
  if held ~= nil then
    return held
  end
  local made: mut {string} = {}
  for each in pairs(S.declared) do
    made[#made + 1] = each
  end
  for primitive in pairs(Scopes.primitives) do
    made[#made + 1] = primitive
  end
  table.sort(made)
  S.global_names = made
  return made
end

-- The name nearest to `name` among those in scope, the declared globals and, for a type, the
-- primitives, with the place it is declared (nil for a global or a primitive); "" where
-- none is near.
local function nearest(name: string, types: boolean): string, Scopes.Place?
  if S.guessed >= GUESSES then
    return "", nil
  end
  S.guessed = S.guessed + 1
  local limit = allowed(name)
  local best, best_distance = "", limit + 1
  local best_at: Scopes.Place? = nil
  local seen: mut {string: boolean} = {}
  for i = #S.names, 1, -1 do
    local other = S.names[i]
    if not seen[other] then
      seen[other] = true
      local v = lookup(other)
      if v ~= nil and (fits(v.space, types) or (types and v.kind == "local")) then
        local d = near(name, other, limit)
        if d < best_distance then
          best, best_distance, best_at = other, d, place_of(v.declared)
        end
      end
    end
  end
  local globals = global_names()
  for _, other in ipairs(globals) do
    local declared = S.declared[other]
    local space: Scopes.Space = declared ~= nil and declared.space or "type"
    if not seen[other] and fits(space, types) then
      local d = near(name, other, limit)
      if d < best_distance then
        best, best_distance, best_at = other, d, nil
      end
    end
  end
  return best, best_at
end

-- Declarations ---------------------------------------------------------------

local SPACES <const>: {Scopes.Kind: Scopes.Space} = {
  ["local"] = "value", ["function"] = "value", param = "value", loop = "value", pattern = "value",
  typeparam = "type", record = "both", interface = "type", class = "both", enum = "type", alias = "type",
  import = "both",
}

local KIND_WORDS <const>: {Scopes.Kind: string} = {
  ["local"] = "variable", ["function"] = "function", param = "parameter", loop = "loop variable",
  pattern = "match binding", typeparam = "type parameter", record = "record", interface = "interface",
  class = "class", enum = "enum", alias = "type", import = "imported module",
}

-- The kinds of binding that declare a type.
local TYPE_KINDS <const>: {Scopes.Kind: boolean} = {
  typeparam = true, record = true, interface = true, class = true, enum = true, alias = true, import = true,
}

-- `word` with its indefinite article.
local function with_article(word: string): string
  local first = word:sub(1, 1)
  return if (first == "a" or first == "e" or first == "i" or first == "o") then "an " .. word else "a " .. word end
end

-- The error for a declaration of `name` that hides `prior`, or a declared global where there is none.
local function shadowed(token: integer, name: string, kind: Scopes.Kind, prior: Scopes.Var?)
  local word = KIND_WORDS[kind]
  if prior == nil then
    local declared = S.declared[name]
    local what = if declared ~= nil and declared.space == "type" then "type" else "global" end
    report("shadows", token, word .. " " .. quoted(name) .. " shadows the " .. what .. " " .. quoted(name),
      "rename it: it would hide the declared " .. what .. " " .. quoted(name) .. " for the rest of its scope. " ..
        "To keep the " .. what .. " under its name in a local, write `local " .. name .. " = " .. name .. "`")
    return
  end
  local msg = word .. " " .. quoted(name) .. " shadows the " .. KIND_WORDS[prior.kind] .. " " .. quoted(name) ..
    " declared at " .. shown(prior.declared)
  local assignable = kind == "local" and not prior.readonly and prior.depth == #S.frames and
    (prior.kind == "local" or prior.kind == "param" or prior.kind == "pattern")
  local fix: string
  if kind == "typeparam" then
    fix = "rename the type parameter: it hides the " .. KIND_WORDS[prior.kind] .. " " .. quoted(name) ..
      " in scope here"
  elseif assignable then
    fix = "to change the existing " .. quoted(name) .. " write `" .. name .. " = ...` without `local`; " ..
      "to keep both, rename the new one"
  else
    fix = "rename the new " .. quoted(name) .. " (the old one is declared at " .. shown(prior.declared) ..
      " and stays visible if this one has another name)"
  end
  report("shadows", token, msg, fix, place_of(prior.declared))
end

-- Whether a declaration of `name` hides a global: a type that is declared (`thread`) is hidden by no value.
local function hides_global(name: string, kind: Scopes.Kind): boolean
  local declared = S.declared[name]
  return declared ~= nil and (declared.space ~= "type" or SPACES[kind] ~= "value")
end

-- Declares `binding` as a `kind` of `space`, visible from the token `from` to
-- the end of the open scope. `check` is whether it can shadow, `copy` the name it
-- copies in `local x = x`.
local function declare(binding: Ast.Binding, kind: Scopes.Kind, from: integer, check: boolean,
                       copy: Ast.Name?, is_global: boolean): Scopes.Var
  local name = binding.name
  local token = binding.first
  local f = frame()
  local prior = lookup(name)
  if prior ~= nil and prior == S.own then
    -- The parameters of `local function f` are declared before `f`: they shadow what `f` hid.
    local stack = S.visible[name]
    prior = stack[#stack - 1]
  end
  local primitive = not is_global and TYPE_KINDS[kind] and Scopes.primitives[name]
  if primitive then
    report("primitive_type_name", token, quoted(name) .. " is a primitive type, so " .. with_article(KIND_WORDS[kind]) ..
        " of that name could never be named",
      "rename the " .. KIND_WORDS[kind] .. ", for example to `" .. name:sub(1, 1):upper() .. name:sub(2) ..
        "`: in a type, `" .. name .. "` always means the primitive")
  elseif name == "_ENV" then
    report("env_reserved", token, "`_ENV` is reserved and cannot be declared",
      "choose another name for the " .. KIND_WORDS[kind])
  elseif check and not is_global and copy == nil and name:sub(1, 1) ~= "_" and name ~= "self" and
      (prior ~= nil or hides_global(name, kind)) then
    shadowed(token, name, kind, prior)
  end
  local attr = binding.attr
  local space = SPACES[kind]
  local top = #S.frames == 1 and #S.marks == 1
  local v: Scopes.Var = {
    id = binding.id, name = name, kind = kind, space = space, attr = attr, exported = is_global, top = top,
    declared = token, from = from, to = math.max(from, S.ends[#S.ends]), owner = f.id, depth = #S.frames,
    loop = f.loop,
    module = "", readonly = attr ~= nil, reads = {}, writes = {}, type_uses = {},
    assigned = false, captures = {}, nested = false,
  }
  if copy ~= nil then
    local copied = copy.binding
    if copied ~= nil then
      v.copies = copied
    end
  end
  -- A binding with no name is one the parser refused and reported.
  if name == "" then
    return v
  end
  S.vars[v.id] = v
  S.list[#S.list + 1] = v
  local stack = S.visible[name]
  if stack == nil then
    stack = {}
    S.visible[name] = stack
  end
  stack[#stack + 1] = v
  S.names[#S.names + 1] = name
  return v
end

-- Uses ------------------------------------------------------------------------

local function add_global(table_of: mut {string: {integer}}, name: string, id: integer)
  local held = table_of[name]
  if held == nil then
    held = {}
    table_of[name] = held
  end
  held[#held + 1] = id
end

-- A read of the value `name`, or an assignment to it (`write`).
local function use_name(n: Ast.Name, write: boolean)
  local name = n.text
  local id = n.id
  local token = n.first
  local v = lookup(name)
  if v == nil then
    n.binding = nil
    local declared = S.declared[name]
    if declared == nil then
      local guess, at = nearest(name, false)
      S.unknown[#S.unknown + 1] = {
        token = token, name = name, what = if write then "assigned" else "variable" end, guess = guess, guess_at = at,
      }
    elseif declared.space == "type" then
      report("not_a_value", token, quoted(name) .. " is a type declared by a declaration file and has no value",
        "write it where a type goes; a value of that type is a variable or a parameter")
    elseif write and declared.const then
      report("const_assigned", token, "the global " .. quoted(name) .. " is declared `<const>` and cannot be assigned",
        "keep the new value in a local of your own: `local " .. name .. "_new = ...`")
    end
    add_global(S.globals, name, id)
    if write then
      add_global(S.global_writes, name, id)
    end
    if name == "_ENV" and write then
      report("env_reserved", token, "`_ENV` is reserved and cannot be assigned", "assign a local of another name")
    end
    return
  end
  n.binding = v.id
  S.resolved[id] = v.id
  if v.space == "type" then
    report("not_a_value", token, quoted(name) .. " is " .. with_article(KIND_WORDS[v.kind]) .. ", a type, and has no value",
      "write " .. quoted(name) .. " where a type goes (`x: " .. name .. "`) and a variable or a literal where a value goes",
      place_of(v.declared))
  end
  local f = frame()
  local depth = #S.frames
  if write then
    local writes = v.writes
    writes[#writes + 1] = id
    v.assigned = true
    if v.readonly then
      local why: string
      local fix: string
      if v.kind == "loop" then
        why = "the control variable " .. quoted(name) .. " of a `for` is read-only in Lua 5.5"
        fix = "copy it to a local and change that: `local " .. name .. "_copy = " .. name .. "` in the loop body"
      elseif v.attr == "close" then
        why = quoted(name) .. " is declared `<close>` and cannot be assigned"
        fix = "keep the changing value in another local; a `<close>` variable holds one value until its scope ends"
      else
        why = quoted(name) .. " is declared `<const>` and cannot be assigned"
        fix = "declare it without `<const>` (`local " .. name .. " = ...`) if it changes, or assign a new local"
      end
      report("const_assigned", token, why, fix, place_of(v.declared))
    elseif v.depth < depth and not v.exported then
      report("captured_assigned", token,
        quoted(name) .. " is a local of the code around this function, which a function may read but not assign",
        "return the value from the function, or keep it in a field of a table both read: `local held = { " ..
          name .. " = <the value> }`, then `held." .. name .. " = ...` in the function", place_of(v.declared))
    else
      local ends, loops = S.write_end[v], S.write_loop[v]
      if ends == nil or loops == nil then
        ends, loops = {}, {}
        S.write_end[v], S.write_loop[v] = ends, loops
      end
      ends[#ends + 1] = S.assign_end
      loops[#loops + 1] = f.loop
    end
    if name == "_ENV" then
      report("env_reserved", token, "`_ENV` is reserved and cannot be assigned", "assign a local of another name")
    end
    return
  end
  local reads = v.reads
  reads[#reads + 1] = id
  if v.depth < depth and not v.exported then
    local inside = S.frames[v.depth + 1]
    local captures = v.captures
    local last = captures[#captures]
    if last == nil or last.fn ~= inside.id then
      last = { fn = inside.id, uses = {}, after = false }
      captures[#captures + 1] = last
      if #captures == 1 then
        S.captured[#S.captured + 1] = v
      end
    end
    last.uses[#last.uses + 1] = id
  end
end

-- Records that `t` names the binding `v`.
local function type_use(t: Ast.TypeName, v: Scopes.Var)
  S.resolved[t.id] = v.id
  local uses = v.type_uses
  uses[#uses + 1] = t.id
  if v.space == "value" and (v.kind ~= "local" or v.module == "") then
    local head = v.name
    local alias = v.alias
    local fix = "write a type here: declare it with `local record " .. head .. " ... end`, `local type " .. head ..
      " = ...` or import it with `local type " .. head .. " = require(\"...\")`"
    if alias ~= nil then
      fix = "declare the type instead of the variable: `local type " .. head .. " = " .. alias .. "`"
    end
    report("not_a_type", t.first, quoted(head) .. " is " .. with_article(KIND_WORDS[v.kind]) .. ", a value, and names no type",
      fix, place_of(v.declared))
  end
end

-- The type name `t` that nothing declares.
local function unknown_type(t: Ast.TypeName, head: string)
  local guess, at = nearest(head, true)
  S.unknown[#S.unknown + 1] = { token = t.first, name = head, what = "type", guess = guess, guess_at = at }
end

-- Looks for the pending type names that the scope at `depth`, which ends, declares; what it does not
-- declare waits for the scope around it, and at the chunk's end is unknown.
resolve_pending = function(depth: integer)
  local pending = S.pending
  local n = #pending
  local first = n + 1
  while first > 1 and pending[first - 1].depth >= depth do
    first = first - 1
  end
  local kept = first - 1
  for i = first, n do
    local p = pending[i]
    local v = lookup(p.name)
    pending[i] = nil
    if v ~= nil then
      type_use(p.node, v)
    elseif depth > 1 then
      p.depth = depth - 1
      kept = kept + 1
      pending[kept] = p
    else
      unknown_type(p.node, p.name)
    end
  end
end

-- The head of the type name `t`.
local function use_type(t: Ast.TypeName)
  local path = t.path
  local head = path[1]
  if head == nil then
    return
  end
  if #path == 1 and Scopes.primitives[head] then
    return
  end
  local v = lookup(head)
  if v ~= nil then
    type_use(t, v)
    return
  end
  local declared = S.declared[head]
  if declared ~= nil and (declared.space ~= "value" or #path > 1) then
    add_global(S.globals, head, t.id)
  elseif S.defer then
    S.pending[#S.pending + 1] = { node = t, name = head, depth = math.min(#S.marks, S.floor) }
  else
    unknown_type(t, head)
  end
end

-- Walking ---------------------------------------------------------------------

local ty: function(t: Ast.Type)
local exp: function(e: Ast.Exp)
local stats: function(list: {Ast.Stat})
local stat: function(s: Ast.Stat)
local typedecl: function(d: Ast.Node, nested: boolean)

local function walk_types(list: {Ast.Type})
  for i = 1, #list do
    ty(list[i])
  end
end

local function narrows(n: Ast.Narrows)
  local params = S.params
  local bound = params ~= nil and params[n.param] or nil
  if bound == nil then
    report("unknown_parameter", n.first, "the narrowing return names " .. quoted(n.param) ..
        ", which is no parameter of this function",
      "write the name of a parameter before `is`: `" .. (if n.asserts then "asserts " else "" end) .. "v is T` for a parameter `v`")
    return
  end
  if bound > 0 then
    S.resolved[n.id] = bound
  end
  ty(n.type)
end

local function walk_rets(r: Ast.Rets?, params: {string: integer})
  if r == nil then
    return
  end
  local saved = S.params
  S.params = params
  local lists = r.lists
  for i = 1, #lists do
    local list = lists[i]
    for j = 1, #list do
      local item = list[j]
      if (item.kind == "Narrows") then
        narrows(item)
      else
        ty(item)
      end
    end
  end
  S.params = saved
end

local function walk_typeparams(list: {Ast.TypeParam})
  for i = 1, #list do
    local p = list[i]
    declare(p.name, "typeparam", p.name.first, true, nil, false)
  end
  for i = 1, #list do
    local constraint = list[i].constraint
    if constraint ~= nil then
      ty(constraint)
    end
  end
end

ty = function(t: Ast.Type)
  local kind = base_of(t).kind
  if kind == "TypeName" and (t.kind == "TypeName") then
    use_type(t)
    walk_types(t.args)
  elseif kind == "TypeArray" and (t.kind == "TypeArray") then
    ty(t.element)
  elseif kind == "TypeMap" and (t.kind == "TypeMap") then
    ty(t.key)
    ty(t.value)
  elseif kind == "TypeUnion" and (t.kind == "TypeUnion") then
    walk_types(t.members)
  elseif kind == "TypeOptional" and (t.kind == "TypeOptional") then
    ty(t.inner)
  elseif kind == "TypeMut" and (t.kind == "TypeMut") then
    ty(t.inner)
  elseif kind == "TypeFunction" and (t.kind == "TypeFunction") then
    local deferring = S.defer
    S.defer = true
    open(t.last)
    walk_typeparams(t.typeparams)
    local named: mut {string: integer} = {}
    for _, p in ipairs(t.params) do
      ty(p.type)
      local name = p.name
      if name ~= nil then
        named[name] = 0
      end
    end
    walk_rets(t.rets, named)
    close()
    S.defer = deferring
  end
end

-- Walks a function: its parameters, return list and body. `typeparams` are declared by the
-- construct that holds it, in a scope around `id`'s. `implicit` is the function statement
-- whose refused colon form gives it a `self`.
local function walk_function(id: integer, last: integer, params: {Ast.Param}, rets: Ast.Rets?,
                             body: Ast.Block, implicit: Ast.Function?)
  push_frame(id, last)
  open(last)
  local deferring = S.defer
  S.defer = true
  -- The names of the signature are looked for outside the function, not among its parameters and locals.
  local floor = S.floor
  S.floor = #S.marks - 1
  local named: mut {string: integer} = {}
  for _, p in ipairs(params) do
    local t = p.type
    if t ~= nil then
      ty(t)
    end
    local binding = p.name
    if binding ~= nil then
      named[binding.name] = binding.id
    end
  end
  walk_rets(rets, named)
  S.floor = floor
  if implicit ~= nil then
    local path = implicit.path
    local at = path[#path].first - 1
    local self_binding: Ast.Binding = { kind = "Binding", id = implicit.id, first = at, last = at, name = "self" }
    declare(self_binding, "param", at, false, nil, false)
  end
  for _, p in ipairs(params) do
    local binding = p.name
    if binding ~= nil then
      declare(binding, "param", binding.first, true, nil, false)
    end
  end
  S.own = nil
  S.defer = false
  stats(body.stats)
  S.defer = deferring
  close()
  pop_frame()
end

local function walk_block(b: Ast.Block)
  open(b.close)
  stats(b.stats)
  close()
end

local function walk_fn(fn: Ast.Fn, typeparams: {Ast.TypeParam}, implicit: Ast.Function?)
  -- Type parameters are visible in the signature and the body.
  open(fn.last)
  -- A constraint may name a type declared later, as the types of the signature may.
  local deferring = S.defer
  S.defer = true
  walk_typeparams(typeparams)
  S.defer = deferring
  walk_function(fn.id, fn.last, fn.params, fn.rets, fn.body, implicit)
  close()
end

local function walk_items(items: {Ast.Item})
  for i = 1, #items do
    local item = items[i]
    local kind = base_of(item).kind
    if kind == "Positional" and (item.kind == "Positional") then
      exp(item.value)
    elseif kind == "Named" and (item.kind == "Named") then
      exp(item.value)
    elseif kind == "Keyed" and (item.kind == "Keyed") then
      exp(item.key)
      exp(item.value)
    end
  end
end

local function walk_exps(list: {Ast.Exp})
  for i = 1, #list do
    exp(list[i])
  end
end

-- The expression `e` when it is not one of the kinds that has a left side the walk goes down.
local function leaf(e: Ast.Exp)
  local kind = base_of(e).kind
  if kind == "Name" and (e.kind == "Name") then
    use_name(e, false)
  elseif kind == "Paren" and (e.kind == "Paren") then
    exp(e.inner)
  elseif kind == "FunctionLit" and (e.kind == "FunctionLit") then
    walk_fn(e.fn, {}, nil)
  elseif kind == "Table" and (e.kind == "Table") then
    walk_items(e.items)
  elseif kind == "Unary" and (e.kind == "Unary") then
    exp(e.operand)
  elseif kind == "IfExp" and (e.kind == "IfExp") then
    for _, arm in ipairs(e.arms) do
      exp(arm.cond)
      exp(arm.value)
    end
    exp(e.else_value)
  end
end

-- The rest of an expression whose left side has been walked.
local function finish(e: Ast.Exp)
  local kind = base_of(e).kind
  if kind == "Binary" and (e.kind == "Binary") then
    exp(e.right)
  elseif kind == "Call" and (e.kind == "Call") then
    walk_exps(e.args)
  elseif kind == "MethodCall" and (e.kind == "MethodCall") then
    walk_exps(e.args)
  elseif kind == "Index" and (e.kind == "Index") then
    exp(e.key)
  elseif (kind == "IsTest" and (e.kind == "IsTest")) or (kind == "Cast" and (e.kind == "Cast")) then
    ty(e.type)
  end
end

exp = function(e: Ast.Exp)
  local spine = S.spine
  local floor = S.top
  local top = floor
  local cur = e
  while true do
    local kind = base_of(cur).kind
    local nxt: Ast.Exp = nil
    if kind == "Binary" and (cur.kind == "Binary") then
      nxt = cur.left
    elseif kind == "Call" and (cur.kind == "Call") then
      nxt = cur.callee
    elseif kind == "Field" and (cur.kind == "Field") then
      nxt = cur.object
    elseif kind == "Index" and (cur.kind == "Index") then
      nxt = cur.object
    elseif kind == "MethodCall" and (cur.kind == "MethodCall") then
      nxt = cur.object
    elseif kind == "IsTest" and (cur.kind == "IsTest") then
      nxt = cur.value
    elseif kind == "Cast" and (cur.kind == "Cast") then
      nxt = cur.value
    end
    if nxt == nil then
      break
    end
    top = top + 1
    spine[top] = cur
    cur = nxt
  end
  S.top = top
  leaf(cur)
  for i = top, floor + 1, -1 do
    local node = spine[i]
    spine[i] = nil
    finish(node)
  end
  S.top = floor
end

-- The `require("module")` a call is, with `require` not shadowed: the module, else "".
local function required(e: Ast.Exp?): string
  if e ~= nil and (e.kind == "Call") then
    local callee = e.callee
    local args = e.args
    if (callee.kind == "Name") and callee.text == "require" and callee.binding == nil and #args == 1 then
      local first = args[1]
      if (first.kind == "String") then
        return first.value
      end
    end
  end
  return ""
end

-- The text `a.b.c` of a name or a chain of fields on one, nil for any other expression.
local function dotted(e: Ast.Exp?): string?, Ast.Name?
  local parts: mut {string} = {}
  local head: Ast.Name = nil
  local cur = e
  while cur ~= nil and (cur.kind == "Field") do
    parts[#parts + 1] = cur.name
    cur = cur.object
    if #parts > 8 then
      return nil
    end
  end
  if cur ~= nil and (cur.kind == "Name") and #parts > 0 then
    head = cur
    parts[#parts + 1] = cur.text
    local n = #parts
    for i = 1, n // 2 do
      parts[i], parts[n + 1 - i] = parts[n + 1 - i], parts[i]
    end
    return table.concat(parts, "."), head
  end
  return nil, nil
end

local function stat_local(s: Ast.Local)
  walk_types(s.types)
  local values = s.values
  walk_exps(values)
  local bindings = s.bindings
  local is_global = s.scope == "global"
  for i = 1, #bindings do
    local b = bindings[i]
    local value = values[i]
    local copy: Ast.Name? = nil
    if value ~= nil and (value.kind == "Name") and value.text == b.name then
      copy = value
    end
    local v = declare(b, "local", s.last + 1, true, copy, is_global)
    if #bindings == 1 and #values == 1 then
      v.module = required(value)
      -- Offered as the fix only where the chain starts at a module or a type.
      local text, head = dotted(value)
      local bound = head ~= nil and head.binding ~= nil and S.vars[head.binding] or nil
      if bound ~= nil and (bound.module ~= "" or bound.space ~= "value") then
        v.alias = text
      end
    end
  end
end

local function stat_assign(s: Ast.Assign)
  walk_exps(s.values)
  local targets = s.targets
  for i = 1, #targets do
    local target = targets[i]
    if (target.kind == "Name") then
      -- Set here: a target before this one may hold a function with assignments of its own.
      S.assign_end = s.last
      use_name(target, true)
    else
      exp(target)
    end
  end
end

local KINDS <const>: {string: Scopes.Kind} = {
  Record = "record", Interface = "interface", Class = "class", Enum = "enum", Alias = "alias", Import = "import",
}

typedecl = function(d: Ast.Node, nested: boolean)
  local kind = base_of(d).kind
  local name: Ast.Binding = nil
  local scope: Ast.Scope? = nil
  local typeparams: {Ast.TypeParam} = {}
  local supers: {Ast.TypeName} = {}
  local array: Ast.Type? = nil
  local members: {Ast.Member} = {}
  local aliased: Ast.Type? = nil
  if kind == "Record" and (d.kind == "Record") then
    name, scope, typeparams, supers, array, members = d.name, d.scope, d.typeparams, d.supers, d.array, d.members
  elseif kind == "Interface" and (d.kind == "Interface") then
    name, scope, typeparams, supers, members = d.name, d.scope, d.typeparams, d.supers, d.members
  elseif kind == "Class" and (d.kind == "Class") then
    name, scope, typeparams, supers, members = d.name, d.scope, d.typeparams, d.supers, d.members
  elseif kind == "Enum" and (d.kind == "Enum") then
    name, scope = d.name, d.scope
  elseif kind == "Alias" and (d.kind == "Alias") then
    name, scope, typeparams, aliased = d.name, d.scope, d.typeparams, d.type
  elseif kind == "Import" and (d.kind == "Import") then
    name, scope = d.name, d.scope
  else
    return
  end
  -- An alias does not see its own name, so that `type Node = Node` inside a record names the `Node`
  -- around it; the name is declared once its type is walked.
  local v: Scopes.Var? = nil
  if kind ~= "Alias" then
    v = declare(name, KINDS[kind], name.first, not nested, nil, scope == "global")
    v.nested = nested
  end
  if kind == "Import" and (d.kind == "Import") and v ~= nil then
    v.module = d.module
  end
  if kind == "Enum" or kind == "Import" then
    return
  end
  local deferring = S.defer
  S.defer = true
  open(base_of(d).last)
  walk_typeparams(typeparams)
  walk_types(supers)
  if array ~= nil then
    ty(array)
  end
  if aliased ~= nil then
    ty(aliased)
  end
  for i = 1, #members do
    local m = members[i]
    local mkind = base_of(m).kind
    if mkind == "FieldDecl" and (m.kind == "FieldDecl") then
      ty(m.type)
    elseif mkind == "Method" and (m.kind == "Method") then
      walk_function(m.id, m.last, m.params, m.rets, m.body, nil)
    elseif KINDS[mkind] ~= nil then
      typedecl(m, true)
    end
  end
  close()
  S.defer = deferring
  if kind == "Alias" then
    local alias = declare(name, KINDS[kind], name.first, not nested, nil, scope == "global")
    alias.nested = nested
  end
end

local function stat_function(s: Ast.Function)
  local path = s.path
  local first = path[1]
  local colon = false
  if #path == 2 then
    use_name(first, false)
    colon = S.tokens.text[path[2].first - 1] == ":"
  end
  walk_fn(s.fn, s.typeparams, colon and s or nil)
end

local function stat_if(s: Ast.If)
  for _, arm in ipairs(s.arms) do
    exp(arm.cond)
    walk_block(arm.body)
  end
  local other = s.else_body
  if other ~= nil then
    walk_block(other)
  end
end

local function stat_match(s: Ast.Match)
  exp(s.scrutinee)
  for _, arm in ipairs(s.arms) do
    open(arm.body.close)
    for _, p in ipairs(arm.pats) do
      if (p.kind == "PatBind") then
        declare(p.name, "pattern", p.name.first, true, nil, false)
      end
    end
    stats(arm.body.stats)
    close()
  end
end

local function stat_for_num(s: Ast.ForNum)
  exp(s.from)
  exp(s.to)
  local step = s.step
  if step ~= nil then
    exp(step)
  end
  enter_loop(s.id)
  open(s.body.close)
  local v = declare(s.var, "loop", s.body.first, true, nil, false)
  v.readonly = true
  stats(s.body.stats)
  close()
  leave_loop(s.id)
end

local function stat_for_in(s: Ast.ForIn)
  walk_exps(s.iterators)
  enter_loop(s.id)
  open(s.body.close)
  for i, binding in ipairs(s.vars) do
    local v = declare(binding, "loop", s.body.first, true, nil, false)
    v.readonly = i == 1
  end
  stats(s.body.stats)
  close()
  leave_loop(s.id)
end

stat = function(s: Ast.Stat)
  local kind = base_of(s).kind
  if kind == "Local" and (s.kind == "Local") then
    stat_local(s)
  elseif kind == "Assign" and (s.kind == "Assign") then
    stat_assign(s)
  elseif kind == "CallStat" and (s.kind == "CallStat") then
    exp(s.call)
  elseif kind == "LocalFunction" and (s.kind == "LocalFunction") then
    local own = declare(s.name, "function", s.name.first, true, nil, false)
    own.fn = s.fn.id
    S.own = own
    walk_fn(s.fn, s.typeparams, nil)
    S.own = nil
  elseif kind == "Function" and (s.kind == "Function") then
    stat_function(s)
  elseif kind == "Return" and (s.kind == "Return") then
    walk_exps(s.values)
  elseif kind == "Do" and (s.kind == "Do") then
    walk_block(s.body)
  elseif kind == "If" and (s.kind == "If") then
    stat_if(s)
  elseif kind == "While" and (s.kind == "While") then
    enter_loop(s.id)
    exp(s.cond)
    walk_block(s.body)
    leave_loop(s.id)
  elseif kind == "Repeat" and (s.kind == "Repeat") then
    enter_loop(s.id)
    open(s.last)
    stats(s.body.stats)
    exp(s.cond)
    close()
    leave_loop(s.id)
  elseif kind == "ForNum" and (s.kind == "ForNum") then
    stat_for_num(s)
  elseif kind == "ForIn" and (s.kind == "ForIn") then
    stat_for_in(s)
  elseif kind == "Match" and (s.kind == "Match") then
    stat_match(s)
  elseif KINDS[kind] ~= nil then
    typedecl(s, false)
  end
end

stats = function(list: {Ast.Stat})
  for i = 1, #list do
    stat(list[i])
  end
end

-- The end of a run -------------------------------------------------------------

-- Settles whether an assignment to `v` may run after each function that captures it is made.
local function settle(v: Scopes.Var)
  local ends, loops = S.write_end[v], S.write_loop[v]
  if ends == nil or loops == nil then
    return
  end
  local newest = 0
  for i = 1, #ends do
    newest = math.max(newest, ends[i])
  end
  -- The loops inside the scope of `v` that hold an assignment, and so any function made in one of them.
  local level, parent = S.loop_level, S.loop_parent
  local floor = level[v.loop] or 0
  local holding: mut {integer: boolean} = {}
  for i = 1, #loops do
    local loop = loops[i]
    while loop ~= 0 and level[loop] > floor and not holding[loop] do
      holding[loop] = true
      loop = parent[loop]
    end
  end
  for _, c in ipairs(v.captures) do
    if newest >= S.made[c.fn] then
      c.after = true
    else
      local loop = S.entry_of[c.fn]
      while loop ~= 0 and level[loop] > floor and not c.after do
        c.after = holding[loop] == true
        loop = parent[loop]
      end
    end
  end
end

-- The errors of the names no binding or declared global holds.
local function unknown_errors()
  if #S.unknown == 0 then
    return
  end
  -- The bindings by token, of the names that are unknown somewhere, to find the one declared after a use.
  local by_name: mut {string: {Scopes.Var}} = {}
  for _, u in ipairs(S.unknown) do
    if u.what ~= "type" then
      by_name[u.name] = {}
    end
  end
  for _, v in ipairs(S.list) do
    local held = by_name[v.name]
    if held ~= nil then
      held[#held + 1] = v
    end
  end
  for _, held in pairs(by_name) do
    table.sort(held, function(a: Scopes.Var, b: Scopes.Var): boolean
      return a.declared < b.declared
    end)
  end
  for _, u in ipairs(S.unknown) do
    local name = u.name
    local later: Scopes.Var? = nil
    if u.what ~= "type" then
      -- The first declaration after the use, then the next few: one whose scope holds the use.
      local held = by_name[name] or {}
      local low, high = 1, #held + 1
      while low < high do
        local middle = (low + high) // 2
        if held[middle].declared > u.token then
          high = middle
        else
          low = middle + 1
        end
      end
      for i = low, math.min(#held, low + 49) do
        local v = held[i]
        if v.to >= u.token and v.space ~= "type" then
          later = v
          break
        end
      end
    end
    local hint = ""
    if u.guess ~= "" then
      local at = u.guess_at
      hint = "if you meant " .. quoted(u.guess) .. (if at ~= nil then " (declared at " .. at.y .. ":" .. at.x .. ")" else
        ", which is declared for every program" end) .. ", write that; otherwise "
    end
    local msg: string
    local fix: string
    local other: Scopes.Place? = nil
    local code: Scopes.Code = "unknown_variable"
    if u.what == "type" then
      code = "unknown_type"
      msg = "the type " .. quoted(name) .. " is not declared"
      fix = hint .. "declare it above with `local record " .. name .. " ... end`, `local enum " .. name ..
        " ... end` or `local type " .. name .. " = ...`, or import it with `local type " .. name ..
        " = require(\"...\")`; a program may use `any`, `boolean`, `integer`, `never`, `number`, `string` " ..
        "and `thread` with no declaration"
    elseif later ~= nil then
      msg = quoted(name) .. " is used before the " .. KIND_WORDS[later.kind] .. " " .. quoted(name) ..
        " that is declared at " .. shown(later.declared)
      fix = "Lua sees only what is declared above a use: move the declaration of " .. quoted(name) ..
        " (line " .. S.tokens.y[later.declared] .. ") above this line, or declare `local " .. name ..
        ": <its type>` here and assign it where it is declared now"
      other = place_of(later.declared)
    elseif u.what == "assigned" then
      msg = quoted(name) .. " is assigned but declared nowhere"
      fix = hint .. "declare it with `local " .. name .. " = ...` above this assignment; a program has no " ..
        "globals except the ones a declaration file declares"
    else
      msg = quoted(name) .. " is not declared"
      fix = hint .. "declare it with `local " .. name .. " = ...` above this use, or require its module with " ..
        "`local " .. name .. " = require(\"...\")`; a program has no globals except the ones a declaration " ..
        "file declares"
    end
    report(code, u.token, msg, fix, other)
  end
end

function Scopes.build(chunk: Ast.Chunk, name: string, declared: {string: Scopes.Global}): Scopes.Scoped
  local tokens = chunk.tokens
  reset(tokens, name, declared)
  push_frame(chunk.id, chunk.last)
  open(chunk.last)
  stats(chunk.body.stats)
  close()
  pop_frame()
  for _, v in ipairs(S.captured) do
    settle(v)
  end
  unknown_errors()
  local order: mut {Scopes.Error: integer} = {}
  local errors = S.errors
  for i, e in ipairs(errors) do
    order[e] = i
  end
  table.sort(errors, function(a: Scopes.Error, b: Scopes.Error): boolean
    if a.offset ~= b.offset then
      return a.offset < b.offset
    end
    return order[a] < order[b]
  end)
  local answer: Scopes.Scoped = {
    vars = S.vars, list = S.list, resolved = S.resolved, globals = S.globals, global_writes = S.global_writes,
    errors = errors,
  }
  reset(NO_TOKENS, "", {})
  return answer
end

function Scopes.declared(chunk: Ast.Chunk): {string: Scopes.Global}
  local scoped = Scopes.build(chunk, "", {})
  local out: mut {string: Scopes.Global} = {}
  for _, v in ipairs(scoped.list) do
    if v.exported then
      out[v.name] = { space = v.space, const = v.attr == "const" }
    end
  end
  return out
end

function Scopes.in_scope(scoped: Scopes.Scoped, at: integer): {string: Scopes.Var}
  local out: mut {string: Scopes.Var} = {}
  for _, v in ipairs(scoped.list) do
    if v.from <= at and at <= v.to then
      local held = out[v.name]
      if held == nil or v.from >= held.from then
        out[v.name] = v
      end
    end
  end
  return out
end

Scopes.codes = {
  "unknown_variable", "unknown_type", "shadows", "captured_assigned", "const_assigned", "not_a_value", "not_a_type",
  "unknown_parameter", "env_reserved", "primitive_type_name",
}

return Scopes
