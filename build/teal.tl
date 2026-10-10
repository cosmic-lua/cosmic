--- The vendored Teal compiler, loaded to run.
---
--- The compiler reaches outside the pure Lua libraries in a few places:
--- `io.open` and the handle it returns, `io.stderr`, `os.getenv`,
--- `package.path` and `package.searchers`. Those names are not in this
--- runtime's global environment, so the compiler is loaded in an
--- environment of its own that supplies them over the syscall table.
--- The compiler itself is unpatched and never observes that the names
--- are gone.

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local ast = require("build.ast")
local type compiler = require("build.compiler")

local record teal
  --- The globals cosmic's runtime removes, which [`environment_for`]
  --- strips from the checker: [`cosmic.removed`]'s `order`, which
  --- build/teal_catalog_test.tl holds this to. They are spelled here, not read
  --- from that module, so that what a compile accepts is decided by this
  --- module alone, which the compiler's identity holds
  --- ([`build.identity`]'s `compiler_identity`), and an edit to the rest of
  --- the catalog -- the replacements a refusal quotes -- compiles
  --- nothing again.
  withheld: {string}
  --- The fields of `package` the runtime removes
  --- ([`core/surface.c`]'s `clear_field` calls), which the checker is
  --- stripped of the same way. They are spelled here for the reason
  --- `withheld` is, and build/teal_catalog_test.tl holds them to the
  --- catalog's `package_fields`.
  withheld_package: {string}
  --- Removes from `env` the names [`withheld`] and `withheld_package`
  --- list, so the checker refuses each of them.
  strip: function(env: compiler.Env)

  --- What `io.open` gives back. It reads whole files and writes
  --- strings; the compiler asks nothing else of a handle.
  record Handle
    fd: integer
    read: function(Handle, what: string): string | nil, string
    write: function(Handle, ...: any): Handle | nil, string
    flush: function(Handle): Handle
    close: function(Handle): boolean
  end
end

local chunk_size = 1 << 16

local function make_handle(fd: integer): teal.Handle
  local handle: teal.Handle = {
    fd = fd,
    read = nil,
    write = nil,
    flush = nil,
    close = nil,
  }

  handle.read = function(self: teal.Handle, what: string): string | nil, string
    if what ~= "*a" and what ~= "a" then
      return nil, "this handle reads whole files only"
    end
    local parts: {string} = {}
    while true do
      local chunk, trouble = Fs.take(self.fd, chunk_size)
      if chunk == nil then
        return nil, trouble
      end
      if #chunk == 0 then
        break
      end
      parts[#parts + 1] = chunk
    end
    return table.concat(parts)
  end

  handle.write = function(self: teal.Handle, ...: any): teal.Handle | nil, string
    for index = 1, select("#", ...) do
      local put, trouble = Fs.put(self.fd, tostring((select(index, ...))))
      if not put then
        return nil, trouble
      end
    end
    return self
  end

  handle.flush = function(self: teal.Handle): teal.Handle
    return self
  end

  handle.close = function(self: teal.Handle): boolean
    local ok, _ = Fs.close(self.fd)
    return ok
  end

  return handle
end

local function open_file(path: string, mode: string): teal.Handle | nil, string
  local fd: integer | nil
  local trouble: string
  if mode ~= nil and mode:find("w") ~= nil then
    fd, trouble = Fs.open_write(path)
  else
    fd, trouble = Fs.open_read(path)
  end
  if fd == nil then
    return nil, trouble
  end
  return make_handle(fd)
end

--- The environment the compiler runs in. It is stated rather than
--- inherited: the pure libraries by name, the handful of outside
--- reaches over the syscall table, and nothing else. `io.type` is not
--- in it, because the compiler names it only inside the declaration
--- text it carries for Lua's own standard library and never calls it.
--- This is the compiler's private bootstrap environment, not a program's
--- runtime surface: [`environment_for`] removes io, os and debug from the
--- checker, and [`core/surface.c`] removes the same names at execution.
local function compiler_environment(): {string:any}
  local environment: {string:any} = {
    io = {
      stdout = make_handle(1),
      stderr = make_handle(2),
      open = open_file,
    },
    os = { getenv = Env.get },
    package = { path = "", searchers = {}, loaded = {} },

    _VERSION = _VERSION,
    assert = assert,
    collectgarbage = collectgarbage,
    coroutine = coroutine,
    error = error,
    getmetatable = getmetatable,
    ipairs = ipairs,
    load = load,
    math = math,
    next = next,
    pairs = pairs,
    pcall = pcall,
    print = print,
    rawequal = rawequal,
    rawget = rawget,
    rawlen = rawlen,
    rawset = rawset,
    require = require,
    select = select,
    setmetatable = setmetatable,
    string = string,
    table = table,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    utf8 = utf8,
    xpcall = xpcall,
  }
  environment["_G"] = environment
  return environment
end

--- Loads the compiler out of the store; with `strip`, without its
--- debug information: the same code, which compiles to the same Lua,
--- but whose errors and tracebacks name no line of it. Under Lua's line
--- hook -- a test's coverage -- the VM finds the line of each
--- instruction a function with line information runs, which is most of
--- what the hook costs ([`build/compiler_test.tl`]).
function teal.load(strip?: boolean): compiler | nil, string
  local bytes, trouble = Store.bytecode("vendor.tl")
  if bytes == nil then
    return nil, "the compiler is not in this binary: " .. trouble
  end
  local environment = compiler_environment()
  local chunk, why = load(bytes, "@vendor.tl", "b", environment)
  if strip and chunk ~= nil then
    chunk, why = load(string.dump(chunk, true), "=vendor.tl", "b", environment)
  end
  if chunk == nil then
    return nil, "the compiler would not load: " .. tostring(why)
  end
  -- The one boundary where an untyped chunk becomes a declared surface.
  local produced: any = chunk()
  return produced as compiler
end

--- A compiler that loads on first use. Most runs never touch it: when
--- [`build.importer`] answers every module and coverage line from its
--- caches, nothing asks the compiler to parse, check or generate, and
--- loading its bytecode up front is waste.
---
--- The result is an empty table whose metatable calls [`teal.load`] on the
--- first field read or written and keeps what it loaded. A write lands
--- on the loaded compiler, never the capsule: tl reaches its own
--- `search_module` and `path` through its module table, so `serve`'s
--- overrides must land there. A load failure raises [`teal.load`]'s
--- message through `error(_, 0)`, so a broken binary says "the compiler
--- is not in this binary: ..." rather than showing a nil-index
--- traceback.
--- @return compiler usable wherever [`teal.load`]'s result is: the same
---   untyped table cast to the declared surface, deferred to first use
function teal.lazy(): compiler
  local loaded: {any:any}
  local function real(): {any:any}
    if loaded == nil then
      local built, trouble = teal.load()
      if built == nil then
        error(trouble, 0)
      end
      loaded = built as {any:any}
    end
    return loaded
  end
  local capsule: any = {}
  setmetatable(capsule, {
    __index = function(_self: any, key: any): any
      return real()[key]
    end,
    __newindex = function(_self: any, key: any, value: any)
      real()[key] = value
    end,
  })
  return capsule as compiler
end

--- What the checker gets when it asks for a module by name: the source
--- as one string, then a close. It reads `inputs` rows and nothing
--- else; a path never enters into it.
local record Served
  text: string
  read: function(Served, what: string): string
  close: function(Served): boolean
end

local function served(text: string): Served
  return {
    text = text,
    read = function(self: Served, _what: string): string
      return self.text
    end,
    close = function(_self: Served): boolean
      return true
    end,
  }
end

--- A `cosmic.*` module from this binary's own sources, under the name
--- it would have on disk below `at`; nil for any other name.
local function standard(name: string, at: string): string | nil, any
  if name:sub(1, 7) ~= "cosmic." then
    return nil
  end
  local source, _ = Store.source(name)
  if source == nil then
    return nil
  end
  return at .. name:gsub("%.", "/") .. ".tl", served(source)
end

--- Points the checker at this binary's own `cosmic.*` sources and
--- nothing else: no path is searched, and any other name is not found.
function teal.serve_standard(built: compiler)
  built.path = ""
  built.search_module = function(name: string, _search_all: boolean): string | nil, any
    return standard(name, "")
  end
end

--- Points the checker at the tree staged at `root` in the working
--- database `db`. A module asked for by name is answered from `inputs`
--- (a declaration ahead of a source of the same name) under the name the
--- module would have on disk. A `cosmic.*` name the stage lacks is
--- answered by the binary's own rows, which is how a project outside
--- this tree types its `require` of the standard library. Nothing is
--- read from a path and nothing falls through to the compiler's own
--- search of the filesystem: a name neither holds is not found, however
--- a file of that name sits on disk, so a module reaches a build only by
--- being staged.
local function serve(built: compiler, db: Sqlite.Handle, root: string)
  built.path = ""
  built.search_module = function(name: string, _search_all: boolean): string | nil, any
    local rows, _ = Sqlite.text_rows(db,
      "SELECT kind, source FROM inputs WHERE path = ?1 " ..
        "ORDER BY kind = 'decl' DESC LIMIT 1", { { text = name } })
    local stem = name:gsub("%.", "/")
    if rows ~= nil and #rows > 0 then
      local kind, source = rows[1][1], rows[1][2]
      return root .. "/" .. stem .. (kind == "decl" and ".d.tl" or ".tl"),
        served(source)
    end
    return standard(name, root .. "/")
  end
end

teal.withheld = { "io", "os", "debug", "dofile", "loadfile" }
teal.withheld_package = { "path", "cpath", "loadlib", "searchpath" }

function teal.strip(env: compiler.Env)
  for _, name in ipairs(teal.withheld) do
    env.globals[name] = nil
    env.modules[name] = nil
  end
  -- new_env hands every environment the same `package` record (tl
  -- builds its standard globals once per process and copies them by
  -- reference), so this edits it for all of them, where the removal of
  -- `io` above touches only `env`. That is harmless while every
  -- environment cosmic makes is stripped, and the edit is idempotent; one
  -- made unstripped later in the same process would find the fields gone.
  --
  -- tl declares `package` as a global record; its fields are the
  -- declaration's `def.fields` and, in declaration order, `field_order`, and a
  -- key it lacks is refused as `invalid key 'path' in record 'package'`.
  local declared = env.globals["package"]
  local declaration = declared ~= nil and declared.t or nil
  local record_type = declaration ~= nil and declaration.def or nil
  local fields = record_type ~= nil and record_type.fields or nil
  local order = record_type ~= nil and record_type.field_order or nil
  for _, field in ipairs(teal.withheld_package) do
    if fields ~= nil then
      fields[field] = nil
    end
    if order ~= nil then
      for i = #order, 1, -1 do
        if order[i] == field then
          table.remove(order, i)
        end
      end
    end
  end
end

--- A checker environment pointed at a staged tree (see `serve`), with
--- the strictness this project holds itself to and without the names
--- cosmic's runtime surface removes (`withheld`). tl's
--- bundled standard-library declarations carry `io`, `os` and `debug`
--- as ordinary globals, since tl cannot know cosmic's runtime lacks
--- them, so a program reaching for one would type-check and fail only
--- when run. The names are removed from `globals` (a bare `os.time()`)
--- and from `modules` (a `require("io")`; `new_env` puts every global
--- that is a module there), so the checker reports tl's own "unknown
--- variable" or "module not found".
---
--- Takes the working database and the tree's root, not [`build.work`]'s
--- handle: a require of build.work would carry the rest of it into the
--- compiler's identity (`compiler_identity` in build.identity), of which
--- this module is a root.
function teal.environment_for(built: compiler, db: Sqlite.Handle,
                              root: string): compiler.Env | nil, string
  serve(built, db, root)
  local env, trouble = built.new_env({
    defaults = {
      feat_lax = "off",
      gen_compat = "off",
      gen_target = "5.4",
    },
  })
  if env == nil then
    return nil, trouble
  end
  teal.strip(env)
  return env
end

--- Line `y` of `source`, without its newline: nil past the last one.
local function line_at(source: string, y: integer): string | nil
  local start = 1
  for _ = 2, y do
    local newline = source:find("\n", start, true)
    if newline == nil then
      return nil
    end
    start = newline + 1
  end
  local stop = source:find("\n", start, true)
  return source:sub(start, stop ~= nil and stop - 1 or #source)
end

--- A `local type <name> = require("<module>")`.
local record TypeRequire
  name: string
  module: string
end

--- What [`declarations_of`] reads from a source.
local record Declarations
  --- Each `local type` require, by the position of its `require`
  --- (`"<y>:<x>"`), which is where the checker reports a refused one.
  typed: {string: TypeRequire}
  --- The module each local is bound to by a `require` of its own; none
  --- for a local bound to more than one.
  bound: {string: string}
  --- The kind of each type declared at the top level, as its keyword
  --- says: "record", "enum", "interface" or "type"; the first where a
  --- name is declared twice.
  kinds: {string: string}
end

--- The module the call `n` requires, `require("m")` however spelt, and
--- the node of its `require`: nil for any other expression.
local function required_module(n: ast.Node | nil): string | nil, ast.Node | nil
  local op = n ~= nil and n.op or nil
  if n == nil or op == nil or op.op ~= "@funcall" then
    return nil, nil
  end
  local callee, arguments = n.e1, n.e2
  local argument = arguments ~= nil and #arguments == 1 and arguments[1] or nil
  if callee == nil or callee.kind ~= "variable" or callee.tk ~= "require" or
      argument == nil or argument.kind ~= "string" then
    return nil, nil
  end
  return argument.conststr, callee
end

--- The expression a local's value `n` binds it to the module of: the
--- left side of an `or` (`require("m") or {}`), whose record the checker
--- still names the value after, and what parentheses hold.
local function bound_value(n: ast.Node | nil): ast.Node | nil
  local op = n ~= nil and n.op or nil
  while n ~= nil and (n.kind == "paren" or (op ~= nil and op.op == "or")) do
    n = n.e1
    op = n ~= nil and n.op or nil
  end
  return n
end

--- The source [`declarations_of`] last parsed, and what it found there.
local parsed_source: string | nil = nil
local parsed_declarations: Declarations | nil = nil

--- The requires and top-level types `source` parses into, however each
--- is spelt: over several lines, without parentheses (`require "x"`),
--- with comments between its tokens; text in a string or a comment is
--- none. A `local type` require under a `.` (`require("x").T`) is in
--- `typed` but binds no module, since its name is the type it reaches;
--- nor does a local declared with a type (`local X: T = require("x")`).
--- Empty when `source` does not parse. The last source's answer is kept:
--- a compile asks for each refusal's hint, and the hints of a file share
--- one parse.
local function declarations_of(source: string): Declarations
  if source == parsed_source and parsed_declarations ~= nil then
    return parsed_declarations
  end
  local found: Declarations = { typed = {}, bound = {}, kinds = {} }
  local ambiguous: {string: boolean} = {}
  local function bind(name: string | nil, module: string | nil)
    if name == nil or module == nil or ambiguous[name] then
      return
    end
    local before = found.bound[name]
    if before ~= nil and before ~= module then
      found.bound[name], ambiguous[name] = nil, true
    else
      found.bound[name] = module
    end
  end
  local built, _ = teal.load()
  local parsed: ast.Parsed | nil = nil
  if built ~= nil then
    parsed, _ = ast.parse(built, source, "hint")
  end
  if parsed ~= nil then
    ast.walk(parsed.node, function(n: ast.Node)
      local var = n.var
      if n.kind == "local_type" and var ~= nil and var.tk ~= nil then
        local call = n.value
        local op = call ~= nil and call.op or nil
        while call ~= nil and op ~= nil and op.op == "." do
          call = call.e1
          op = call ~= nil and call.op or nil
        end
        local module, callee = required_module(call)
        if module ~= nil and callee ~= nil then
          found.typed[callee.y .. ":" .. callee.x] = { name = var.tk, module = module }
          if call == n.value then
            bind(var.tk, module)
          end
        end
      elseif n.kind == "local_declaration" and n.vars ~= nil and n.exps ~= nil then
        local written = n.decltuple ~= nil and n.decltuple.tuple or nil
        if written == nil or #written == 0 then
          for i, name in ipairs(n.vars) do
            bind(name.tk, (required_module(bound_value(n.exps[i]))))
          end
        end
      end
    end)
    for _, statement in ipairs(parsed.node) do
      local var, value = statement.var, statement.value
      local name = statement.kind == "local_type" and var ~= nil and var.tk or nil
      if name ~= nil and var ~= nil and found.kinds[name] == nil then
        -- The parser places `local type X` at `X`, and `local record X`
        -- at `local`, with the declared type's own kind in its value.
        local declared = value ~= nil and value.newtype or nil
        local def = declared ~= nil and declared.def or nil
        if def ~= nil and def.typename == "generic" then
          def = def.t
        end
        local constructed = def ~= nil and def.typename or nil
        if statement.y == var.y and statement.x == var.x then
          found.kinds[name] = "type"
        elseif constructed == "record" or constructed == "enum" or constructed == "interface" then
          found.kinds[name] = constructed
        end
      end
    end
  end
  parsed_source, parsed_declarations = source, found
  return found
end

--- The module `source` binds to the local `name` by a `require` of its
--- own (`local Hash <const> = require("cosmic.hash")`, or `local type
--- Ledger = require("ledger")`), read by [`declarations_of`]: nil when none
--- does, or when the file binds it to more than one module.
local function module_bound(source: string, name: string): string | nil
  return declarations_of(source).bound[name]
end

--- What a name in scope is bound to, as far as a hint cares: the
--- declaration when it is one `name = <expression>` alone with no
--- annotation, the argument list of the function it was declared as
--- (`local function f`, `local f = function`), and the nominal type it
--- was declared of (`local r: R`, a parameter `r: R`, a method's `self`).
local record Binding
  declaration: ast.Node | nil
  args: ast.Node | nil
  type_name: string | nil
end

--- The name a nominal type `t` gives with one part (`R`, not `M.R`).
local function nominal_name(t: ast.TypeNode | nil): string | nil
  local names = t ~= nil and t.typename == "nominal" and t.names or nil
  return names ~= nil and #names == 1 and names[1] or nil
end

--- What [`scoped_walk`] calls on each node it reaches, with the binding
--- a name has in scope there; true ends the walk.
local type Visitor = function(n: ast.Node, lookup: function(string | nil): Binding | nil): boolean

--- Walks `root` through the block, function, loop and `repeat` scopes
--- the parser built, calling `visitor` on each node before the node's
--- own names are declared, so that a name resolves as Lua resolves it
--- there: a parameter, a loop variable or a closed block's local
--- answers only inside its scope.
local function scoped_walk(root: ast.Node, visitor: Visitor)
  local scopes: {{string: Binding}} = {}
  local done = false
  local function lookup(name: string | nil): Binding | nil
    for i = #scopes, 1, -1 do
      local found = name ~= nil and scopes[i][name] or nil
      if found ~= nil then
        return found
      end
    end
    return nil
  end
  local function declare(name: string | nil, binding: Binding)
    if name ~= nil then
      scopes[#scopes][name] = binding
    end
  end
  local visit: function(ast.Node)
  local function visit_all(n: ast.Node | nil)
    if n ~= nil then
      visit(n)
    end
  end
  local function descend(n: ast.Node)
    for _, child in ipairs(ast.children(n, { if_parent = true, fn_owner = true })) do
      visit(child)
    end
  end
  visit = function(n: ast.Node)
    if done then
      return
    end
    if visitor(n, lookup) then
      done = true
      return
    end
    local kind = n.kind
    if kind == "statements" then
      scopes[#scopes + 1] = {}
      for _, statement in ipairs(n) do
        visit(statement)
      end
      scopes[#scopes] = nil
    elseif kind == "local_declaration" then
      -- Its expressions are read before its names exist.
      visit_all(n.exps)
      local names = n.vars ~= nil and n.vars or {}
      -- The parser gives an unannotated declaration an empty tuple.
      local written = n.decltuple ~= nil and n.decltuple.tuple or nil
      local alone = #names == 1 and (written == nil or #written == 0)
      for i, name in ipairs(names) do
        local value = n.exps ~= nil and n.exps[i] or nil
        declare(name.tk, {
          declaration = alone and n or nil,
          args = value ~= nil and value.kind == "function" and value.args or nil,
          type_name = written ~= nil and #names == 1 and #written == 1 and nominal_name(written[1]) or nil,
        })
      end
    elseif kind == "local_type" then
      declare(n.var ~= nil and n.var.tk or nil, {})
      visit_all(n.value)
    elseif kind == "fornum" then
      visit_all(n.from)
      visit_all(n.to)
      visit_all(n.step)
      scopes[#scopes + 1] = {}
      declare(n.var ~= nil and n.var.tk or nil, {})
      visit_all(n.body)
      scopes[#scopes] = nil
    elseif kind == "forin" then
      visit_all(n.exps)
      scopes[#scopes + 1] = {}
      for _, name in ipairs(n.vars ~= nil and n.vars or {}) do
        declare(name.tk, {})
      end
      visit_all(n.body)
      scopes[#scopes] = nil
    elseif kind == "repeat" then
      -- `until` reads the body's own locals.
      scopes[#scopes + 1] = {}
      for _, statement in ipairs(n.body ~= nil and n.body or {}) do
        visit(statement)
      end
      visit_all(n.exp)
      scopes[#scopes] = nil
    elseif n.args ~= nil and n.body ~= nil then
      if kind == "local_function" and n.name ~= nil then
        declare(n.name.tk, { args = n.args })
      end
      scopes[#scopes + 1] = {}
      if n.is_method == true then
        local owner = n.fn_owner
        declare("self", { type_name = owner ~= nil and owner.e1 == nil and owner.tk or nil })
      end
      for _, argument in ipairs(n.args) do
        if not argument.is_self then
          declare(argument.tk, { type_name = nominal_name(argument.argtype) })
        end
      end
      visit_all(n.body)
      scopes[#scopes] = nil
    else
      descend(n)
    end
  end
  scopes[1] = {}
  visit(root)
end

--- The binding the assignment refused at `y`:`x` writes to. That
--- assignment is the one statement `name = <expression>`, one name and
--- one expression, whose expression the checker's position is (the
--- operator of a binary one, the literal itself). The name resolves
--- through the scopes [`scoped_walk`] keeps, so a parameter, a loop
--- variable, a closed block's local or a text that only looks like a
--- declaration never answers for it. Nil when there is no such
--- assignment, or its name is not a local (a global, a field).
local function target_of(root: ast.Node, y: integer, x: integer): Binding | nil
  local answer: Binding | nil = nil
  scoped_walk(root, function(n: ast.Node, lookup: function(string | nil): Binding | nil): boolean
    if n.kind ~= "assignment" then
      return false
    end
    local names, values = n.vars, n.exps
    local value = values ~= nil and values[1] or nil
    local target = names ~= nil and names[1] or nil
    -- The checker reports a binary expression at its operator, a
    -- parenthesized one inside the parentheses, and any other
    -- (a call, an index) at the target itself.
    local at = target ~= nil and target.y == y and target.x == x
    local inner = value
    while not at and inner ~= nil do
      at = inner.y == y and inner.x == x
      inner = inner.kind == "paren" and inner.e1 or nil
    end
    if names == nil or #names ~= 1 or values == nil or #values ~= 1 or target == nil or not at then
      return false
    end
    if target.kind == "variable" and target.tk ~= nil then
      answer = lookup(target.tk)
    end
    return true
  end)
  return answer
end

--- The hint for the assignment refused at `y`:`x` of `source` for a
--- number where an integer was expected: see [`teal.replacement`].
local function integer_hint(source: string, y: integer, x: integer): string | nil
  -- Each refused assignment reparses the file: only a file that already
  -- fails pays for it.
  local built, _ = teal.load()
  if built == nil then
    return nil
  end
  local parsed, _ = ast.parse(built, source, "hint")
  if parsed == nil then
    return nil
  end
  local binding = target_of(parsed.node, y, x)
  local declaration = binding ~= nil and binding.declaration or nil
  local names = declaration ~= nil and declaration.vars or nil
  local values = declaration ~= nil and declaration.exps or nil
  if names == nil or values == nil or #values ~= 1 then
    return nil
  end
  local target, value = names[1], values[1]
  local name, literal = target.tk, value.tk
  if name == nil or literal == nil or value.kind ~= "integer" or literal:match("^%d[%d_]*$") == nil then
    return nil
  end
  return name .. " is an integer, inferred from 'local " .. name .. " = " .. literal ..
    "' at line " .. target.y .. "; write 'local " .. name .. " = " .. literal ..
    ".0' or 'local " .. name .. ": number = " .. literal .. "' to hold a number"
end

--- What [`teal.replacement`] says of a number where an integer was
--- expected, when no declaration explains it: a cast is what a reader
--- reaches for, and it only silences the checker. tl declares
--- `math.tointeger` to return an integer, so the nil is the reader's to
--- check.
local integer_conversion <const> = "'as integer' converts nothing: math.tointeger(x) does, " ..
  "and is nil unless x is whole; // of two integers is an integer"

--- The set of `names`, less those [`teal.withheld`] strips from the
--- checker: a local named for one of those hides nothing.
local function present(names: {string}): {string:boolean}
  local set: {string:boolean} = {}
  for _, name in ipairs(names) do
    set[name] = true
  end
  for _, name in ipairs(teal.withheld) do
    set[name] = nil
  end
  return set
end

--- The functions and libraries tl's standard library declares as
--- globals (its prelude in vendor/tl/tl.tl), which a local of the same
--- name hides. `arg`, the program's arguments, is no library's.
local standard_globals <const> = present({
  "assert", "collectgarbage", "coroutine", "debug", "dofile", "error",
  "getmetatable", "io", "ipairs", "load", "loadfile", "math", "next", "os",
  "package", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen",
  "rawset", "require", "select", "setmetatable", "string", "table",
  "tonumber", "tostring", "type", "utf8", "xpcall",
})

--- Those of [`standard_globals`] that are libraries, each a record the
--- checker names after itself (`invalid key 'nope' in record 'table' of
--- type table`): one named so but of another type is a local hiding it.
local standard_libraries <const> = present({
  "coroutine", "debug", "io", "math", "os", "package", "string", "table", "utf8",
})

--- Whether the declared type `t` holds nil: nil itself, or a union
--- with nil among its members.
local function admits_nil(t: ast.TypeNode | nil): boolean
  if t == nil then
    return false
  end
  if t.typename == "nil" then
    return true
  end
  for _, member in ipairs(t.typename == "union" and t.types or {}) do
    if member.typename == "nil" then
      return true
    end
  end
  return false
end

--- The parameter `argument` (an "argument" node of a function `source`
--- declares) made optional: `b: string | nil` is `b?: string`. Its type
--- is the text from the `:` after its name to the `,` or `)` that ends
--- it outside brackets, less a first or last `nil` member; nil when no
--- such text is found, or what is left still names nil.
local function optional_spelling(source: string, starts: {integer}, argument: ast.Node): string | nil
  local name = argument.tk
  if name == nil then
    return nil
  end
  local after = ast.offset_of(starts, argument.y, argument.x) + #name
  local colon = source:match("^%s*():", after)
  if not (colon is integer) then
    return nil
  end
  -- The type's text, a comment in it (`b: string | nil -- why`) read
  -- as a space.
  local kept: {string} = {}
  local depth = 0
  local i = colon + 1
  while true do
    local c = source:sub(i, i)
    if c == "" then
      return nil
    elseif source:sub(i, i + 1) == "--" then
      local level = source:match("^%[(=*)%[", i + 2)
      local close: integer | nil = nil
      if level ~= nil then
        local _, last = source:find("]" .. level .. "]", i, true)
        close = last
      else
        close = source:find("\n", i, true)
      end
      if close == nil then
        return nil
      end
      i = close
      c = " "
    elseif c == "(" or c == "{" or c == "<" or c == "[" then
      depth = depth + 1
    elseif depth > 0 and (c == ")" or c == "}" or c == ">" or c == "]") then
      depth = depth - 1
    elseif depth == 0 and (c == "," or c == ")") then
      break
    end
    kept[#kept + 1] = c
    i = i + 1
  end
  local spelled = table.concat(kept):gsub("%s+", " "):match("^ ?(.-) ?$")
  spelled = spelled:gsub(" ?| ?nil$", ""):gsub("^nil ?| ?", "")
  if spelled == "" or spelled:match("%f[%w_]nil%f[^%w_]") ~= nil then
    return nil
  end
  return name .. "?: " .. spelled
end

--- A function a file declares as a field: `function R.name`, `function
--- R:name` (`self` first in `args`) or `R.name = function`, and what
--- `R` was bound to there.
local record Member
  owner: Binding
  name: string
  args: ast.Node
end

--- The argument lists of each function the call whose `(` is at
--- `y`:`x` of `root` may be calling, resolved through the scopes
--- [`scoped_walk`] keeps: `f(...)` the local `f` in scope, or, with
--- none, each `global function f`; `R.name(...)` and `r:name(...)` each
--- `function R.name` (or `R.name = function`) whose `R` is the
--- receiver's binding, or the type the receiver was declared of (`local
--- r: R`, a parameter `r: R`, a method's `self`). Empty when the callee
--- is any other local, a receiver that is no name in scope (a library
--- global, a string value) or a function the file does not declare.
local function callee_arguments(root: ast.Node, y: integer, x: integer): {ast.Node}
  local globals: {string: {ast.Node}} = {}
  local members: {Member} = {}
  local bare: string | nil = nil
  local bound: Binding | nil = nil
  local key: string | nil = nil
  local receivers: {Binding} = {}
  scoped_walk(root, function(n: ast.Node, lookup: function(string | nil): Binding | nil): boolean
    local function member(owner: ast.Node | nil, name: string | nil, args: ast.Node | nil)
      local binding = owner ~= nil and owner.e1 == nil and lookup(owner.tk) or nil
      if binding ~= nil and name ~= nil and args ~= nil then
        members[#members + 1] = { owner = binding, name = name, args = args }
      end
    end
    local kind = n.kind
    local name = n.name ~= nil and n.name.tk or nil
    if kind == "global_function" and name ~= nil and n.args ~= nil and lookup(name) == nil then
      local declared = globals[name] or {}
      declared[#declared + 1] = n.args
      globals[name] = declared
    elseif kind == "record_function" then
      member(n.fn_owner, name, n.args)
    elseif kind == "assignment" then
      for i, target in ipairs(n.vars ~= nil and n.vars or {}) do
        local value = n.exps ~= nil and n.exps[i] or nil
        local info = target.op
        if info ~= nil and info.op == "." and value ~= nil and value.kind == "function" then
          member(target.e1, target.e2 ~= nil and target.e2.tk or nil, value.args)
        end
      end
    elseif kind == "op" and n.y == y and n.x == x then
      local call = n.op
      local e1 = n.e1
      local info = e1 ~= nil and e1.op or nil
      local index = info ~= nil and info.op or nil
      local object = e1 ~= nil and e1.e1 or nil
      local field = e1 ~= nil and e1.e2 or nil
      if call == nil or call.op ~= "@funcall" then
        return false
      elseif e1 ~= nil and e1.kind == "variable" then
        bare, bound = e1.tk, lookup(e1.tk)
      elseif (index == "." or index == ":") and object ~= nil and object.kind == "variable" then
        key = field ~= nil and field.tk or nil
        local receiver = lookup(object.tk)
        if receiver ~= nil then
          receivers[1] = receiver
          -- The type is looked up where the call is, not where the
          -- receiver was declared: a record of the same name declared
          -- between the two would answer for it.
          receivers[2] = lookup(receiver.type_name)
        end
      end
    end
    return false
  end)
  local found: {ast.Node} = {}
  if bound ~= nil then
    found[1] = bound.args
  elseif bare ~= nil then
    found = globals[bare] or {}
  end
  for _, m in ipairs(key ~= nil and members or {}) do
    if m.name == key and (m.owner == receivers[1] or m.owner == receivers[2]) then
      found[#found + 1] = m.args
    end
  end
  return found
end

--- The hint for the call whose `(` is at `y`:`x` of `source`, given
--- `given` arguments where its callee takes `expected`: see
--- [`teal.replacement`].
local function arity_hint(source: string, y: integer, x: integer, given: integer,
                          expected: integer): string | nil
  -- As in [`integer_hint`], only a file that already fails reparses.
  local built, _ = teal.load()
  if built == nil then
    return nil
  end
  local parsed, _ = ast.parse(built, source, "hint")
  if parsed == nil then
    return nil
  end
  -- TODO: hint a callee the file declares no function body for -- a
  -- record field's function type (`run: function(a: string, b: string
  -- | nil)`), a module's function -- or declares on a `global record`,
  -- or calls on a receiver of an inferred type (`local r = make()`): it
  -- waits on a patch/tl record giving this error the callee's
  -- parameters, as patch/tl/33a gives a missing key's fields.
  local spelled: {string} | nil = nil
  local starts = ast.line_starts(source)
  for _, arguments in ipairs(callee_arguments(parsed.node, y, x)) do
    if #arguments == expected then
      -- Every function the call may reach must leave the missing
      -- parameters to nil, spelled alike, or the call is what is short.
      local these: {string} = {}
      for i = given + 1, expected do
        local argument = arguments[i]
        if not admits_nil(argument.argtype) then
          return nil
        end
        local optional = optional_spelling(source, starts, argument)
        if optional == nil then
          return nil
        end
        these[#these + 1] = optional
      end
      if spelled ~= nil and table.concat(spelled, ", ") ~= table.concat(these, ", ") then
        return nil
      end
      spelled = these
    end
  end
  if spelled == nil then
    return nil
  end
  if #spelled == 1 then
    return "a parameter a caller may leave out is written '" .. spelled[1] .. "'"
  end
  return "parameters a caller may leave out are written '" .. table.concat(spelled, ", ") .. "'"
end

--- The hint for the checker refusing one nominal type for another
--- whose last name is the same (`Store is not a Kv.Store`, or, both
--- shown alike, `Store (defined in :7) is not a Store (defined in
--- kv.tl:3)`): two declarations made two types, and only one of them
--- should be. Where one name is qualified and the other is not, the
--- bare one is the program's own declaration, and the qualified one
--- what to name instead; where both are qualified (`A.Node is not a
--- B.Node`) neither is the program's own, and nothing is said.
local function same_named(msg: string): string | nil
  -- TODO: hint a generic type too (`Box<integer> is not a C.Box<integer>`):
  -- the patterns here stop at an identifier, and a type's arguments may
  -- hold spaces and parentheses of their own.
  local given, wanted = msg:match(
    "([%a_][%w_.]*) %(defined in [^)]*%) is not a ([%a_][%w_.]*) %(defined in [^)]*%)$")
  if given == nil then
    given, wanted = msg:match("([%a_][%w_.]*) is not a ([%a_][%w_.]*)$")
  end
  if given == nil then
    return nil
  end
  local name = given:match("[%a_][%w_]*$")
  if name ~= wanted:match("[%a_][%w_]*$") then
    return nil
  end
  local said = "two distinct types are both named " .. name .. ": "
  local given_qualified = given:find(".", 1, true) ~= nil
  local wanted_qualified = wanted:find(".", 1, true) ~= nil
  if given_qualified and wanted_qualified then
    return nil
  end
  local qualified = given_qualified and given or wanted_qualified and wanted or nil
  if qualified ~= nil then
    return said .. "use " .. qualified .. " rather than declaring " .. name ..
      " again, as 'local type " .. name .. " = " .. qualified .. "'"
  end
  return said .. "declare it once and name that one everywhere, as 'local type " ..
    name .. " = Kv." .. name .. "' for one declared in a module required as Kv"
end

--- The members of a type the checker printed, less where it inferred
--- it from (`string | nil (inferred at :3:9)`): split at each top-level
--- ` | `, so the one inside `{string | integer}` or a function's
--- parameters splits nothing.
local function type_members(t: string): {string}
  local bare = t:gsub(" %(inferred at [^)]*%)$", "")
  local masked = bare:gsub("%b{}", function(m: string): string return ("x"):rep(#m) end):
    gsub("%b()", function(m: string): string return ("x"):rep(#m) end)
  local found: {string} = {}
  local start = 1
  while true do
    local at = masked:find(" | ", start, true)
    if at == nil then
      found[#found + 1] = bare:sub(start)
      return found
    end
    found[#found + 1] = bare:sub(start, at - 1)
    start = at + 3
  end
end

--- Whether a type the checker printed is one type or nil (`R | nil`):
--- the only kind of union a nil check alone makes usable.
local function one_or_nil(t: string): boolean
  local of = type_members(t)
  return #of == 2 and of[2] == "nil" and of[1] ~= "<any type>"
end

--- Whether a type the checker printed is `any`, or `any` or nil.
local function untyped(t: string): boolean
  local of = type_members(t)
  return of[1] == "<any type>" and (#of == 1 or (#of == 2 and of[2] == "nil"))
end

--- What to write for a value of `any`, which is what [`Json.decode`]
--- answers, and what a field of one reads as: check it against a record
--- with [`Shape.record_of`], or cast it unchecked. `value` is what the
--- code names it; `wanted` the type expected of it, when the message
--- says. A primitive is narrowed with `is`. A capitalized name may be a
--- record, or an enum or a function type, which `record_of` refuses, so
--- the check is offered only for a record; a qualified one (`L.Month`)
--- is named for `record_of` by the module `source` binds `L` to, which
--- is what it reads, and only cast where `source` binds none or a
--- `cosmic.*` one. Any other type is only cast.
local function untyped_answer(who: string, value: string, source: string, wanted?: string): string
  if wanted == nil then
    return who .. " is any (untyped, as Json.decode answers): check it against a record with " ..
      "`local spec, err = Shape.record_of(\"Spec\"):into(" .. value .. ")` " ..
      "(local Shape = require(\"cosmic.shape\")), or cast it unchecked: `" .. value .. " as Spec`"
  end
  if wanted == "string" or wanted == "number" or wanted == "integer" or wanted == "boolean" then
    return who .. " is any (untyped): narrow it with `if " .. value .. " is " .. wanted ..
      " then ... end`, or cast it unchecked: `" .. value .. " as " .. wanted .. "`"
  end
  local cast = who .. " is any (untyped): cast it unchecked: `" .. value .. " as " .. wanted .. "`"
  local named = wanted:match("^%u[%w_]*$")
  local alias, record_name = wanted:match("^([%a_][%w_]*)%.(%u[%w_]*)$")
  if alias ~= nil then
    local module = module_bound(source, alias)
    named = module ~= nil and module:match("^cosmic%.") == nil and module .. "." .. record_name or nil
  end
  if named == nil then
    return cast
  end
  return cast .. "; if " .. wanted .. " is a record, `Shape.record_of(\"" .. named ..
    "\"):into(" .. value .. ")` checks it (local Shape = require(\"cosmic.shape\"))"
end

--- What to write for a value that may be nil where none is taken:
--- check it, or take it through `assert`, which answers its arguments
--- with the nil gone and raises the message that came with a nil.
local function nil_answer(who: string, value: string): string
  return who .. " may be nil: check it first (`if " .. value ..
    " == nil then return nil, err end`), or, where a call answers it, take it with `local " ..
    value .. " = assert(<the call>)`"
end

--- The kind of type `source` declares as `name` at its top level
--- (`local record Month`, `local type Month = ...`), nil when none does,
--- as [`declarations_of`] reads it.
local function declared_kind(source: string, name: string): string | nil
  return declarations_of(source).kinds[name]
end

--- Types the checker prints that are no record to give a `__close`.
local not_records <const>: {string:boolean} = {
  ["nil"] = true, any = true, number = true, integer = true, string = true,
  boolean = true, thread = true, ["function"] = true, table = true,
}

--- What to declare for `<close>` on a value whose type `closing` the
--- checker refused as non-closable: a record names a `__close` metamethod
--- in its body and carries one in the metatable of each value. `closing`
--- must be a name, and not one `source` declares as anything but a record
--- (an enum, an alias); nil for any other type.
local function closable_hint(closing: string, source: string): string | nil
  if closing:match("^[%a_][%w_%.]*$") == nil or not_records[closing] then
    return nil
  end
  local kind = declared_kind(source, closing)
  if kind ~= nil and kind ~= "record" then
    return nil
  end
  return (kind == "record" and "" or "if " .. closing .. " is a record of yours, ") ..
    "`<close>` calls a `__close` the value's metatable holds: declare `metamethod __close: " ..
    "function(" .. closing .. ")` in the record and make the value with `setmetatable(v, mt)`, " ..
    "`local mt: metatable<" .. closing .. "> = { __close = function(self: " .. closing ..
    ") ... end }`; `cosmic docs Fs.Scratch.__close` shows one"
end

--- The hint for a value the checker refused because it is `any` or may
--- be nil (see [`teal.replacement`]), whose fix is a line every such
--- refusal shares: nil for any other message.
local function narrowing_hint(msg: string, source: string): string | nil
  local variable, seen = msg:match("^cannot index key '[^']*' in variable '([%a_][%w_]*)' of type (.+)$")
  local who = variable ~= nil and "'" .. variable .. "'" or "the value"
  local value = variable or "value"
  if seen == nil then
    seen = msg:match("^cannot index key '[^']*' in type (.+)$") or
      msg:match("^cannot index object of type (.+) with %a+$")
  end
  if seen ~= nil then
    if untyped(seen) then
      return untyped_answer(who, value, source)
    elseif one_or_nil(seen) then
      return nil_answer(who, value)
    end
    return nil
  end
  local closed, closing = msg:match("^to%-be%-closed variable ([%a_][%w_]*) has a non%-closable type (.+)$")
  if closed ~= nil then
    if one_or_nil(closing) then
      return "the call may answer nil: `local " .. closed .. " <close> = assert(<the call>)` " ..
        "closes what it answers, and raises its error in place of the nil"
    end
    return closable_hint(closing, source)
  end
  local iterated = msg:match("^attempting ipairs on something that's not an array: (.+)$")
  local iterator = "ipairs"
  if iterated == nil then
    iterated, iterator = msg:match("^cannot apply pairs on values of type: (.+)$"), "pairs"
  end
  if iterated ~= nil then
    if one_or_nil(iterated) then
      return "the table may be nil: check it first (`if t == nil then return nil, err end`) " ..
        "or loop over `" .. iterator .. "(t or {})`"
    end
    return nil
  end
  local given, wanted = msg:match("^in local declaration: [%a_][%w_]*: got (.+), expected (.+)$")
  if given == nil then
    given, wanted = msg:match("^argument %d+: got (.+), expected (.+)$")
  end
  if given == nil then
    given, wanted = msg:match("^in [%a ]+: got (.+), expected (.+)$")
  end
  -- A value that may be nil is handed on where nil is not taken
  -- without a refusal, so only `any` is answered here.
  if given ~= nil and wanted ~= nil and untyped(given) then
    local expected = type_members(wanted)
    return untyped_answer("the value", "value", source,
      #expected == 1 and expected[1] or table.concat(expected, " | "))
  end
  -- The first " and " parts the operands: only a string literal's type
  -- (`string "a and b"`) holds one, and parting there at worst says
  -- nothing of a union it misses.
  local left, right = msg:match("^cannot use operator '.-' for types (.-) and (.+)$")
  if left ~= nil and (#type_members(left) > 1 or #type_members(right) > 1) then
    return "an operand is a union: narrow it first, as `if v is string then ... end` " ..
      "or `type(v) == \"string\"` does"
  end
  return nil
end

--- The `local type` require of `source` whose `require` is at `y`:`x`,
--- where the checker reports a refused one: nil when there is none.
local function type_require_at(source: string, y: integer, x: integer): TypeRequire | nil
  return declarations_of(source).typed[y .. ":" .. x]
end

--- The checker's refusal of a `local type` require of a module that
--- returns no type.
local not_a_type <const> = "^'require' did not return a type, got "

--- The names `source` binds by a `local type` require the checker
--- refused in `result` ("'require' did not return a type"), for
--- [`teal.replacement`]'s `refused`: the module returns a value, so no
--- type is reached through the name, and a hint that blames a type it
--- names would mislead. Only the errors of `file` itself count.
function teal.refused_type_requires(file: string, source: string,
                                    result: compiler.Result): {string:boolean}
  local refused: {string:boolean} = {}
  for _, e in ipairs(result.type_errors or {}) do
    if (e.filename == nil or e.filename == "" or e.filename == file) and
        e.msg:match(not_a_type) ~= nil then
      local bound = type_require_at(source, e.y, e.x)
      if bound ~= nil then
        refused[bound.name] = true
      end
    end
  end
  return refused
end

--- What the refused `local type` require `bound`, on line `y` of
--- `source`, must change; `msg` is the refusal. In a template's module
--- (`file` a `.tmpl`) it is the record's module its `{{type}}` names,
--- whose type the declaration of `render` on that line gives. Elsewhere,
--- a module that returns a value of a record (`got record Ledger`) may be
--- required as a value instead, since the value's type holds the
--- record's types; a function or a map of the record holds none.
local function type_require_hint(msg: string, file: string, source: string, y: integer,
                                 bound: TypeRequire): string
  local name, module = bound.name, bound.module
  local return_type = "as `local record M ... end return M` or a `.d.tl` does"
  if file:match("%.tmpl$") ~= nil then
    local record_type = (line_at(source, y) or ""):match(
      "local function render%([%a_][%w_]*: " .. name .. "%.([%a_][%w_]*)%)") or "..."
    return module .. ", which {{type " .. record_type .. " from " .. module ..
      "}} names, must return its record type, " .. return_type .. ", not a value"
  end
  if msg:match(not_a_type .. "record ") ~= nil then
    return module .. " returns a value of its record, not the record type: a `local type` " ..
      "require needs the type, " .. return_type .. "; or require it as a value"
  end
  return module .. " returns a value, not a type: a `local type` require needs the module " ..
    "to return one, " .. return_type
end

--- The hint for `unknown type Owner.Member`, a type named as declared
--- inside `Owner` when it is not: told how to move it where `source`
--- declares both at its top level, and, where `source` binds `Owner` to
--- the `require` of a module of the program's own, that the name is
--- misspelt or that module must declare it inside the record it
--- returns. Otherwise nil. A `cosmic.*` module gets nil, since the
--- catalog answers its types. An `Owner` that `refused` holds gets nil
--- before anything else: its `local type` require was refused, since the
--- module returns a value, so it is no local record to move a type into,
--- and that value's record may well declare the member.
local function nesting_hint(source: string, owner: string, member: string,
                            refused: {string:boolean}): string | nil
  if refused[owner] then
    return nil
  end
  local kind = declared_kind(source, member)
  if kind ~= nil and declared_kind(source, owner) ~= nil then
    local declared = kind == "type" and "type " .. member .. " = ..." or
      kind .. " " .. member .. " ... end"
    return member .. " is declared beside " .. owner .. ", not inside it: move `" .. declared ..
      "` into `local record " .. owner .. " ... end` to name it " .. owner .. "." .. member
  end
  local module = module_bound(source, owner)
  if module == nil or module:match("^cosmic%.") ~= nil then
    return nil
  end
  -- TODO: name the members the module's record does declare, as a
  -- missing field is told them: it waits on the checker giving this
  -- error the required record's types, as patch/tl/33a gives a missing
  -- key's fields.
  return owner .. " has no type " .. member .. ": check its spelling, or declare `record " ..
    member .. " ... end` inside the record " .. module .. " returns (a `local record " ..
    member .. "` beside that record is its file's alone)"
end

--- What [`replacement`] reads of [`cosmic.removed`].
local record Catalog
  replacements: {string:string}
  names: {string:string}
  members: {string:string}
  arguments: {string:string}
  message: function(name: string, field: string): string
end

--- The module [`replacement`] quotes, named by a constant rather than
--- a literal so that no parse records a `require` of it: the catalog
--- decides only what a refusal says, and no compile keeps a refusal, so
--- it is no part of the compiler's identity, and a test whose import
--- closure reaches this module but not the catalog is not keyed by it.
--- A test worker, and a process one starts, refuses a module of the
--- tree outside its test's closure (build.test_worker's `refusal`,
--- core/store.c's `put_up_inherited`), so there a refusal says what to
--- write instead only where the test requires cosmic.removed itself,
--- which keys its verdict by the catalog it read.
local catalog_module <const> = "cosmic.removed"

--- [`cosmic.removed`], or nil where it cannot be loaded (a test that
--- does not require it).
local function catalog(): Catalog | nil
  local ok, loaded = pcall(require, catalog_module)
  if not ok or not (loaded is {string:any}) then
    return nil
  end
  local names, members, arguments, message = loaded.names, loaded.members, loaded.arguments, loaded.message
  local replacements = loaded.replacements
  if names is {string:string} and members is {string:string} and arguments is {string:string} and
      replacements is {string:string} and message is function(string, string): string then
    return {
      names = names, members = members, arguments = arguments,
      replacements = replacements, message = message,
    }
  end
  return nil
end

--- The edit distance between `a` and `b`, a swap of two neighbours
--- counting one edit (`alpah` is one from `alpha`).
local function distance(a: string, b: string): integer
  local before: {integer} = {}
  local previous: {integer} = {}
  for j = 0, #b do
    previous[j] = j
  end
  for i = 1, #a do
    local current: {integer} = { [0] = i }
    for j = 1, #b do
      local cost = a:byte(i) == b:byte(j) and 0 or 1
      local best = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
      if i > 1 and j > 1 and a:byte(i) == b:byte(j - 1) and a:byte(i - 1) == b:byte(j) then
        best = math.min(best, before[j - 2] + 1)
      end
      current[j] = best
    end
    before, previous = previous, current
  end
  return previous[#b]
end

--- The field a reader reaches for under another name, by the name. The
--- standard library calls which sort of thing a value is `kind` in every
--- record that says it (sys.Stat, an archive entry, an SQLite cell, an
--- HTTP download's result, a child's drain) and none has a `type`, the
--- word Lua's own `type()` puts in a reader's mind.
local synonyms <const>: {string:string} = {
  type = "kind",
}

--- How many fields [`field_hint`] lists before saying how many more.
local listed <const> = 10

--- `names` quoted, joined as a reader says a choice: 'a', 'b' or 'c'.
local function either(names: {string}): string
  local quoted: {string} = {}
  for i, name in ipairs(names) do
    quoted[i] = "'" .. name .. "'"
  end
  if #quoted == 1 then
    return quoted[1]
  end
  return table.concat(quoted, ", ", 1, #quoted - 1) .. " or " .. quoted[#quoted]
end

--- Whether `name` holds `part` as whole words of a snake_case name:
--- `from_string` holds `string`, `target` does not hold `get`.
local function holds(name: string, part: string): boolean
  local at = name:find(part, 1, true)
  while at ~= nil do
    local before, after = name:sub(at - 1, at - 1), name:sub(at + #part, at + #part)
    if (at == 1 or before == "_") and (after == "" or after == "_") then
      return true
    end
    at = name:find(part, at + 1, true)
  end
  return false
end

--- The hint for `key` refused on the record `owner` names, whose value
--- fields are `fields`: the fields nearest `key` by [`distance`], case
--- ignored and then not, within a third of its length and at most 2, or
--- the one [`synonyms`] names for it, or, with none so near, those
--- holding a `key` of three letters or more as whole words or held so
--- by it ([`holds`]); then the fields themselves, the first [`listed`]
--- alphabetically.
local function field_hint(key: string, owner: string, fields: {string}): string | nil
  if #fields == 0 then
    return nil
  end
  local sorted: {string} = {}
  local has: {string:boolean} = {}
  for i, name in ipairs(fields) do
    sorted[i] = name
    has[name] = true
  end
  table.sort(sorted)
  local near: {string} = {}
  local synonym = synonyms[key]
  if synonym ~= nil and has[synonym] then
    near[1] = synonym
  else
    -- Nearest ignoring case, then nearest as spelled: `sta` is `stat`
    -- before `Stat`, and `Kind` still finds `kind`.
    local limit = math.min(2, (#key + 1) // 3)
    local best, spelled = limit + 1, math.huge
    local lower = key:lower()
    for _, name in ipairs(sorted) do
      local d = distance(lower, name:lower())
      local e = d <= limit and distance(key, name) or math.huge
      if d <= limit and (d < best or (d == best and e < spelled)) then
        best, spelled, near = d, e, { name }
      elseif d <= limit and d == best and e == spelled then
        near[#near + 1] = name
      end
    end
    -- Failing that, a field holding the key or held by it, case
    -- ignored (`string` is `from_string`), shortest first: the list
    -- below is alphabetical and may stop before it.
    if #near == 0 and #key >= 3 then
      for _, name in ipairs(sorted) do
        local folded = name:lower()
        if holds(folded, lower) or (#name >= 3 and holds(lower, folded)) then
          near[#near + 1] = name
        end
      end
      table.sort(near, function(a: string, b: string): boolean
        if #a ~= #b then
          return #a < #b
        end
        return a < b
      end)
    end
  end
  local shown = table.concat(sorted, ", ", 1, math.min(#sorted, listed))
  if #sorted > listed then
    shown = shown .. " and " .. (#sorted - listed) .. " more"
  end
  local said = owner .. "'s fields: " .. shown
  -- More than a few equally near is no suggestion.
  if #near > 0 and #near <= 3 then
    said = "did you mean " .. either(near) .. "? " .. said
  end
  return said
end

--- A key the checker refused a record, read or written, and the
--- record's name.
local record MissingKey
  key: string
  owner: string
end

--- What [`MissingKey`] the checker's refusal `msg` names: `invalid key
--- 'type' in record 'st' of type sys.Stat`, the same `in 'st' of
--- interface type ...`, or `in type ...` for an expression that is no
--- variable. A record described rather than named (`of type record
--- Module`, cosmic.cli's) is named by the variable, or, with none, as
--- "the record".
local function missing_key(msg: string): MissingKey | nil
  local key, variable, owner = msg:match("^invalid key '(.-)' in record '([%a_][%w_]*)' of type (.+)$")
  if key == nil then
    key, variable, owner = msg:match("^invalid key '(.-)' in '([%a_][%w_]*)' of interface type (.+)$")
  end
  if key == nil then
    key, owner = msg:match("^invalid key '(.-)' in type (.+)$")
  end
  if key == nil then
    return nil
  end
  -- A type the checker inferred carries where (`string "x" (inferred
  -- at :2:9)`); the type is the name.
  owner = owner:gsub(" %(inferred at [^)]*%)$", "")
  if owner:match("^record ") then
    owner = variable or "the record"
  end
  return { key = key, owner = owner }
end

--- Whether `before`, the text of a line up to a `...`, ends inside a
--- function's parameter list: its nearest unmatched `(` follows `function`,
--- `function name`, `function a.b`, `function a:b`, with or without a
--- generic `<...>` after the name. A `(` of a call does not.
local function in_parameters(before: string): boolean
  local depth = 0
  for i = #before, 1, -1 do
    local c = before:sub(i, i)
    if c == ")" then
      depth = depth + 1
    elseif c == "(" then
      if depth == 0 then
        local head = before:sub(1, i - 1):gsub("%s+$", "")
        head = head:gsub("%b<>$", "")
        return head:match("%f[%w_]function$") ~= nil or
          head:match("%f[%w_]function%s+[%a_][%w_]*[%.:]?[%w_%.:]*$") ~= nil
      end
      depth = depth - 1
    end
  end
  return false
end

--- The type text of a parameter whose `:` starts `rest`, up to the `,` or
--- `)` that ends it outside any brackets; nil when none does on the line.
local function type_text(rest: string): string | nil
  local depth = 0
  local from = rest:match("^%s*:%s*()")
  if from == nil then
    return nil
  end
  for i = from, #rest do
    local c = rest:sub(i, i)
    if c == "(" or c == "{" or c == "[" or c == "<" then
      depth = depth + 1
    elseif depth > 0 and (c == ")" or c == "}" or c == "]" or c == ">") then
      depth = depth - 1
    elseif depth == 0 and (c == "," or c == ")") then
      local text = rest:sub(from, i - 1):gsub("%s+$", "")
      return text ~= "" and text or nil
    end
  end
  return nil
end

--- What to write for a vararg given a name (`...names: string`), when the
--- syntax error at `y`:`x` is on that name: the text before it on the line
--- ends in `...` inside a function's parameter list ([`in_parameters`]) and
--- an identifier starts there, followed by `:`, `?`, `,` or `)`. The type
--- is the one the line spells ([`type_text`]), else `<type>`. nil for any
--- other `expected one of: ')', ','` error, including a `...` that is an
--- expression (`f(...x)`) and a list whose `...` and name are on different
--- lines.
local function vararg_name_hint(source: string, y: integer, x: integer): string | nil
  local line = line_at(source, y)
  if line == nil or x < 1 then
    return nil
  end
  local before = line:sub(1, x - 1):match("^(.-)%.%.%.%s*$")
  if before == nil or not in_parameters(before) then
    return nil
  end
  local rest = line:sub(x)
  local name = rest:match("^[%a_][%w_]*")
  if name == nil or rest:sub(#name + 1):match("^%s*[:?,)]") == nil then
    return nil
  end
  local after = rest:sub(#name + 1):gsub("^%s*%?", "")
  local typed = type_text(after) or "<type>"
  return "a vararg takes no name: write `...: " .. typed ..
    "` and read it as `{ ... }`, or `select(\"#\", ...)` where a nil may be among them"
end

--- What to write for an interface method declared with an unnamed
--- receiver, when `msg` is a record's `function Rec:m` refused against it
--- (`type signature of 'm' does not match its declaration in Rec: argument
--- 0: Rec is not a Iface`): the unnamed `m: function(Iface, ...)` takes
--- the interface itself, which a method of the record taking the record is
--- no substitute for; `m: function(self: Iface, ...)` takes whatever
--- implements it. nil for any other message, and for one whose argument 0
--- is not the record named in it.
local function interface_self_hint(msg: string): string | nil
  local method, record, given, interface = msg:match(
    "^type signature of '([%a_][%w_]*)' does not match its declaration in " ..
      "([%a_][%w_%.]*): argument 0: ([%a_][%w_%.]*) is not an? ([%a_][%w_%.]*)$")
  if method == nil or record ~= given then
    return nil
  end
  return "if " .. interface .. " declares `" .. method .. "` with an unnamed receiver, that is " ..
    interface .. " itself, not the record that implements it: declare it in " .. interface ..
    " as `" .. method .. ": function(self: " .. interface .. ", ...)` so each implementer's " ..
    "`function " .. record .. ":" .. method .. "` is checked with its own type as self"
end

--- What to try for a call refused on a type parameter (`argument 2: type
--- parameter <T>: got R, expected R | nil`, `... R is not a I`): where the
--- call's result is expected to have a type, the checker may have bound the
--- parameter to it before the arguments, and patch/tl/40 could not bind it
--- from them instead. The hint says so conditionally, since the arguments
--- may simply disagree. nil for any other message.
local function type_parameter_hint(msg: string): string | nil
  if msg:match("^argument %d+: type parameter <[%w_]+>: ") == nil then
    return nil
  end
  return "if this call's result is expected to have a type (a return type or a declaration), " ..
    "that may have fixed the type parameter before the arguments did: bind the result in a local " ..
    "of the arguments' type (`local v: R = setmetatable(t, mt)`) and use that"
end

--- What to write for a generic record's method declared as `function
--- Rec:m`, when `msg` is the checker refusing `Rec` for its missing type
--- arguments at the `function` line `y` of `source`: Teal has no
--- `function Rec<K, V>:m`, so the method is a function of `Rec` taking
--- `self` explicitly, the type arguments on its own name. nil for any
--- other message, and for a line that does not declare a method of that
--- record.
local function method_type_arguments_hint(msg: string, source: string, y: integer): string | nil
  local arguments, name = msg:match("^missing type arguments in record<(.-)> ([%a_][%w_]*)$")
  local line = arguments ~= nil and line_at(source, y) or nil
  if line == nil then
    return nil
  end
  local owner, method = line:match("^%s*function%s+([%a_][%w_%.]*):([%a_][%w_]*)%s*[%(<]")
  if owner == nil or (owner ~= name and owner:sub(-#name - 1) ~= "." .. name) then
    return nil
  end
  return "a generic record's method takes its type arguments on its name, and `self` as an " ..
    "explicit first parameter: `function " .. owner .. "." .. method .. "<" .. arguments ..
    ">(self: " .. owner .. "<" .. arguments .. ">, ...)`, followed by the method's other " ..
    "parameters; `x:" .. method .. "(...)` still calls it"
end

--- What to declare instead of a string literal in a type position
--- (`local s: integer | "null"`), when the parser refused a type list at
--- `y`:`x` of `source`: the `:` or other token that should have been
--- followed by a type. nil for any other message, and where no string
--- literal follows one of the separators that precede a type before the
--- line's first `=`.
local function string_type_hint(source: string, y: integer, x: integer): string | nil
  local line = line_at(source, y)
  if line == nil or x < 1 then
    return nil
  end
  local rest = line:sub(x)
  local stop = rest:find("=", 1, true)
  local segment = stop ~= nil and rest:sub(1, stop - 1) or rest
  local literals: {string} = {}
  for quote, text in segment:gmatch("[:|<{,(?]%s*([\"'])(.-)%1") do
    literals[#literals + 1] = quote .. text .. quote
  end
  if #literals == 0 then
    return nil
  end
  return "a string literal is not a type: declare an enum, `local enum Name " ..
    table.concat(literals, " ") .. " end`, and write `Name` here"
end

--- What Teal does with type arguments given at a call, whichever
--- message the checker reads them as.
local call_type_arguments_answer <const> =
  "Teal has no type arguments at a call: `f<string>(x)` reads as a comparison. The " ..
  "call binds the function's type parameters from its arguments, so give the argument the " ..
  "type (`local v: string = ...`), or call through a typed local " ..
  "(`local g: function(string): string = f`)"

--- What to write for type arguments given at a call (`f<string>("a")`),
--- when `msg` is the checker refusing `<` for a generic function and a
--- type at `y`:`x` of `source`, which reads the line as a comparison; or
--- the type argument itself read as a variable (`f<integer>(1)`,
--- `unknown variable: integer`), with a callable name and `<` before it
--- and `>(` after. nil for any other message, and where the line has no
--- `>(` after the `<`.
local function call_type_arguments_hint(msg: string, source: string, y: integer, x: integer): string | nil
  local line = line_at(source, y)
  if line == nil then
    return nil
  end
  if msg:match("^cannot use operator '<' for types function<.- and ") ~= nil then
    if line:sub(x, x) == "<" and line:sub(x):match("^<.->%s*%(") ~= nil then
      return call_type_arguments_answer
    end
    return nil
  end
  local name = msg:match("^unknown variable: ([%a_][%w_]*)$")
  if name ~= nil and line:sub(x, x + #name - 1) == name and
      line:sub(1, x - 1):match("[%a_][%w_%.:]*<%s*$") ~= nil and
      line:sub(x + #name):match("^[%w_%s,%.]*>%s*%(") ~= nil then
    return call_type_arguments_answer
  end
  return nil
end

--- Where a function is defined, and how its name is written.
local record Definition
  line: integer
  --- ":" or "."
  separator: string
end

--- Where `source` defines `function Owner:key` or `function Owner.key`
--- below line `y`; nil when it does not.
local function defined_below(source: string, y: integer, owner: string,
                             key: string): Definition | nil
  local n = 0
  local at = owner:gsub("%p", "%%%0") .. "([:.])" .. key:gsub("%p", "%%%0")
  for line in (source .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n > y then
      local separator = line:match("^%s*function%s+" .. at .. "%f[^%w_]")
      if separator ~= nil then
        return { line = n, separator = separator }
      end
    end
  end
  return nil
end

--- What to do for a key a record lacks (`invalid key 'close' in record 's'
--- of type Store`) when `source` defines it below the use: the checker
--- reads a file top to bottom, so a method is known only from its
--- declaration on. The declaration offered is a template, to be given the
--- definition's own parameters. nil for any other message, and a key not
--- defined below.
local function later_method_hint(msg: string, source: string, y: integer): string | nil
  local key, owner = msg:match("^invalid key '([%a_][%w_]*)' in record '[%a_][%w_]*' of type ([%a_][%w_%.]*)$")
  if key == nil then
    return nil
  end
  local below = defined_below(source, y, owner, key)
  if below == nil then
    return nil
  end
  local separator = below.separator
  local template = separator == ":" and "function(self: " .. owner .. ", ...)" or "function(...)"
  return "`" .. key .. "` is defined below, at line " .. below.line .. ", and the checker reads a file " ..
    "top to bottom: define `function " .. owner .. separator .. key .. "` above this use, or " ..
    "declare `" .. key .. ": " .. template .. "` in the record, with the definition's own " ..
    "parameters, and keep the definition where it is"
end

--- What to write instead, when `msg` is the checker refusing a name
--- [`environment_for`] stripped or a member [`cosmic.removed`] lists; nil
--- for any other message, and for those where the catalog cannot be
--- loaded (`catalog_module`). `y` and `x` are the line and column in
--- `source` where the checker reported it.
---
--- `unknown variable: os` is read together with the field that follows
--- it there (`os.getenv` names [`Env.get`]); `module not found: 'io'`
--- answers a `require`. The answer is [`cosmic.removed`]'s `message`, the
--- words [`core/surface.c`] raises with when a running program reaches
--- for the name.
---
--- `invalid key 'hex' in record 'Digest' of type Hash` and `unknown
--- type Zip.ZipReader` (`cosmic.zip.ZipReader`, a type the module no
--- longer declares) are answered from [`cosmic.removed`]'s `members` when
--- `source` binds the type's own name (`Hash`) to `require("cosmic.hash")`.
--- The checker names a module's record after the local its `require` was
--- first bound to, whatever alias reads it now; one whose record is a local
--- of its own ([`cosmic.cli`]'s) is `of type record Module`, and the alias
--- answers for it. There is no answer for a record of the program's own,
--- a name bound to more than one module, or a binding whose value is more
--- than the `require` (`local Hash: T = ...`, a `global`, `require("m").sub`),
--- though the left side of an `or` and parentheses are read through. Scope
--- is not read: a `require` in a nested block counts as the file's own.
---
--- `argument 2: got boolean, expected Sqlite.OpenOptions` is answered from
--- [`cosmic.removed`]'s `arguments` the same way: a type that replaced a
--- boolean parameter says what to write for the boolean. The message
--- does not name the function, so the entry does.
---
--- `in assignment: got number, expected integer` names the variable when
--- `source` has, at that position, the single assignment
--- `name = <expression>` and `name` resolves through the lexical scopes
--- to `local name = <integer literal>` with no annotation
--- (`local peak = 0`). The checker inferred `integer` there, and the
--- answer is to spell the float or the type. The position is the
--- operator of a binary expression, the inside of parentheses, or the
--- target itself for any other expression (`x = f()`, `x = t.n`).
--- Nothing is said for a parameter, `self`, a loop variable, a
--- declaration with an annotation, a non-literal (or negative, or
--- hexadecimal) initializer or several names, a global, a field
--- (`t.n = ...`), a multiple assignment (`a, b = ...`), or a source that
--- does not parse. Any other number where an integer was expected (an
--- argument, a declaration, a return value, `tonumber(s)`, `a / b`) is
--- told the conversions, since `as integer` only silences the checker.
---
--- A local, argument or loop variable shadowing one of
--- [`standard_globals`] is told to rename it, and a refused index of one
--- named for a library but of another type (`table.insert` where `table`
--- is a local of the program's) that the name is a local hiding it.
---
--- A key a record lacks (`invalid key 'type' in record 'st' of type
--- sys.Stat`), where the checker gave the record's value `fields` with
--- the error, is told the nearest of them and the first few
--- ([`field_hint`]), after any removed member's answer.
---
--- A call given fewer arguments than its callee takes exactly
--- (`wrong number of arguments (given 1, expects 2)`, the checker's
--- position the call's `(`) is told how to declare the parameters it
--- leaves out optional (`b?: string`), when every function of the file
--- the call may reach ([`callee_arguments`]) admits nil for each of
--- them, spelled alike; nothing when one does not, since then the call
--- is short, nor when the file declares no function the call reaches.
---
--- A vararg given a name (`local function f(...names: string)`, the
--- parser's `syntax error, expected one of: ')', ','` at the name) is told
--- it takes none and to write `...: string` ([`vararg_name_hint`]); any other
--- such error is told nothing, nor is a name on a later line than its `...`.
---
--- A record's `function Rec:m` refused against an interface method declared
--- with an unnamed receiver (`m: function(Iface, ...)`) is told to declare
--- it `function(self: Iface, ...)` ([`interface_self_hint`]), and a call
--- whose type parameter the expected result type fixed before its arguments
--- is told to bind it in a local ([`type_parameter_hint`]).
---
--- A generic record's method declared `function Rec:m` (`missing type
--- arguments in record<K, V> Rec`) is told to write `function Rec.m<K, V>(self:
--- Rec<K, V>, ...)` ([`method_type_arguments_hint`]); a string literal in a
--- type position (`expected a type list`) to declare an enum
--- ([`string_type_hint`]); type arguments at a call (`f<string>(x)`, refused
--- as `cannot use operator '<' for types function<K>(K): K and string`) that
--- Teal has none ([`call_type_arguments_hint`]); a key a record lacks that
--- the file defines below the use as a method, to define it above or declare
--- it in the record ([`later_method_hint`]); and `<close>` on a record
--- type, to declare a `__close` ([`closable_hint`]).
---
--- One nominal type refused for another of the same last name
--- (`Store is not a Kv.Store`) is told they are two types, and an
--- `unknown type Kv.Kv` whose `Kv` `source` binds to a `require` that
--- `Kv` itself is the module's record type, unless `refused` holds `Kv`.
---
--- A `local type Ledger = require("ledger")` refused because the module
--- returns a value (`'require' did not return a type, got record
--- Ledger`) is told to return a type, and, for a value of a record, that
--- requiring the module as a value would do too. In a template's module (`file`, the file being compiled,
--- a `.tmpl`) that require is the one its `{{type Page from ledger}}`
--- makes, and the module is told to return the record type: a template
--- requires its record's module as a value only for a stage that reads it.
--- An `unknown type Ledger.Month` or `Ledger.Ledger` that follows from
--- such a refusal is told nothing where `refused`
--- ([`teal.refused_type_requires`]) holds `Ledger`, since no type is
--- reached through it.
function teal.replacement(msg: string, source: string, y: integer, x: integer,
                          fields?: {string}, file?: string,
                          refused?: {string:boolean}): string | nil
  if msg:match(not_a_type) ~= nil then
    local bound = type_require_at(source, y, x)
    return bound ~= nil and type_require_hint(msg, file or "", source, y, bound) or nil
  end
  if msg:match("got number, expected integer$") or
      msg:match("got number, expected integer | nil$") or
      msg:match("got number %(inferred at [^)]*%), expected integer$") then
    -- TODO: hint a table field too (`local t = {n = 0}; t.n = t.n + 0.5`,
    -- `t.n` an "op" node here): it waits on the checker's inferred type of
    -- a record field being readable from the AST; the parser alone does
    -- not give it.
    local inferred = msg == "in assignment: got number, expected integer" and
      integer_hint(source, y, x) or nil
    return inferred or integer_conversion
  end
  if msg == "syntax error, expected one of: ')', ','" then
    return vararg_name_hint(source, y, x)
  end
  if msg == "unknown type never" then
    return "`never` is no type: `: never` is the whole return list of a function that does not " ..
      "return, so `function(): never | nil` is a function returning `never | nil`. " ..
      "To allow nil, name the function type, `local type Fail = function(): never`, " ..
      "and write `Fail | nil`"
  end
  if msg == "expected a type list" then
    return string_type_hint(source, y, x)
  end
  local call_typed = call_type_arguments_hint(msg, source, y, x) or
    method_type_arguments_hint(msg, source, y)
  if call_typed ~= nil then
    return call_typed
  end
  local self_hint = interface_self_hint(msg) or type_parameter_hint(msg)
  if self_hint ~= nil then
    return self_hint
  end
  local passed, takes = msg:match("^wrong number of arguments %(given (%d+), expects (%d+)%)$")
  local short = passed ~= nil and math.tointeger(tonumber(passed)) or nil
  local count = takes ~= nil and math.tointeger(tonumber(takes)) or nil
  if short ~= nil and count ~= nil and short < count then
    return arity_hint(source, y, x, short, count)
  end
  local shadowed = msg:match("^%a+ shadows previous declaration of '([%a_][%w_]*)'$")
  if shadowed ~= nil and standard_globals[shadowed] then
    return "this hides the standard library's " .. shadowed .. " for the rest of its scope: rename it"
  end
  local hidden, seen = msg:match("^invalid key '[^']*' in record '([%a_][%w_]*)' of type (.+)$")
  if hidden == nil then
    hidden, seen = msg:match("^cannot index key '[^']*' in variable '([%a_][%w_]*)' of type (.+)$")
  end
  if hidden ~= nil and standard_libraries[hidden] and seen ~= hidden then
    return "'" .. hidden .. "' here is a local that hides the standard library's " ..
      hidden .. ": rename it"
  end
  local narrowed = narrowing_hint(msg, source)
  if narrowed ~= nil then
    return narrowed
  end
  local same = same_named(msg)
  if same ~= nil then
    return same
  end
  local outer, inner = msg:match("^unknown type ([%a_][%w_]*)%.([%a_][%w_]*)$")
  if outer ~= nil and outer == inner and module_bound(source, outer) ~= nil and
      not (refused or {})[outer] then
    return outer .. " is itself the type of the record its module returns: write " ..
      outer .. ", not " .. outer .. "." .. inner
  end
  local given, owner, option = msg:match(
    "^argument %d+: got (%a+), expected ([%a_][%w_]*)%.([%a_][%w_]*)$")
  if given == "boolean" and owner ~= nil and option ~= nil then
    local module = module_bound(source, owner)
    local removed = module ~= nil and catalog() or nil
    local instead = removed ~= nil and removed.arguments[module .. "." .. option] or nil
    if instead ~= nil then
      return owner .. "." .. option .. " replaced a boolean argument: " .. instead
    end
    return nil
  end
  local key, alias, typename = msg:match(
    "^invalid key '([%a_][%w_]*)' in record '([%a_][%w_]*)' of type ([%a_][%w_]*)$")
  if key ~= nil and alias == "package" and typename == "package" then
    -- tl's `package` has no field the runtime removed ([`strip`]), and
    -- the catalog says what to write for each.
    local removed = catalog()
    if removed ~= nil and removed.replacements["package." .. key] ~= nil then
      return removed.message("package", key)
    end
  end
  if key == nil then
    -- A module whose record is a local of its own (cosmic.cli's) is
    -- named by its description, `record Module`, not by the alias; the
    -- alias is then what the `require` was bound to.
    key, alias = msg:match(
      "^invalid key '([%a_][%w_]*)' in record '([%a_][%w_]*)' of type record [%a_][%w_]*$")
    typename = alias
  end
  if key == nil then
    -- A type's name is capitalized, so only a member spelled as one is
    -- offered for it: a removed function is never a type's answer.
    typename, key = msg:match("^unknown type ([%a_][%w_]*)%.(%u[%w_]*)$")
    alias = typename
  end
  if key ~= nil then
    local module = module_bound(source, typename)
    local removed = module ~= nil and catalog() or nil
    local instead = removed ~= nil and removed.members[module .. "." .. key] or nil
    if instead ~= nil then
      return alias .. "." .. key .. " was removed: " .. instead
    end
  end
  local holder, held = msg:match("^unknown type ([%a_][%w_]*)%.([%a_][%w_]*)$")
  if holder ~= nil then
    local nested = nesting_hint(source, holder, held, refused or {})
    if nested ~= nil then
      return nested
    end
  end
  -- TODO: hint a field a table literal names that its record lacks
  -- (`in local declaration: r: unknown field alpah`) the same way: it
  -- waits on a patch/tl record giving that error the record's fields too.
  -- TODO: hint a key a union's records lack (`cannot index key 'type'
  -- in type A | B`): the checker gives fields only for a single record
  -- (patch/tl/33d); the fix is fields for each record member. One
  -- record or nil is told to check for nil ([`narrowing_hint`]) even
  -- where the record lacks the key too, which its fields would tell.
  local later = later_method_hint(msg, source, y)
  if later ~= nil then
    return later
  end
  local missing = missing_key(msg)
  if missing ~= nil and fields ~= nil then
    return field_hint(missing.key, missing.owner, fields)
  end
  if key ~= nil then
    return nil
  end
  local name = msg:match("^unknown variable: ([%a_][%w_]*)$")
  local field: string | nil = nil
  if name ~= nil then
    local line = line_at(source, y)
    if line ~= nil and line:sub(x, x + #name - 1) == name then
      field = line:sub(x + #name):match("^%s*[%.:]%s*([%a_][%w_]*)")
    end
  else
    name = msg:match("^module not found: '(.-)'$")
  end
  if name == nil then
    return nil
  end
  local removed = catalog()
  if removed == nil or removed.names[name] == nil then
    return nil
  end
  return removed.message(name, field)
end

return teal
