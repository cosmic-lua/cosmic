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
local Removed = require("cosmic.removed")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local ast = require("build.ast")
local type compiler = require("build.compiler")

local record teal
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

--- A checker environment pointed at a staged tree (see `serve`), with
--- the strictness this project holds itself to and without the names
--- cosmic's runtime surface removes ([`cosmic.removed`]'s `order`). tl's
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
--- compiler's identity (`compiler_identity` in build.work), of which
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
  for _, name in ipairs(Removed.order) do
    env.globals[name] = nil
    env.modules[name] = nil
  end
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

--- The `cosmic.*` module `source` binds to the local `name` by a line
--- of its own (`local Hash <const> = require("cosmic.hash")`): nil when
--- no line does, or when lines bind it to more than one module.
local function module_bound(source: string, name: string): string | nil
  local module: string | nil = nil
  local head = "^%s*local%s+" .. name
  local tail = "%s*=%s*require%(%s*[\"']([%w_.]+)[\"']%s*%)"
  for line in source:gmatch("[^\n]+") do
    local named = line:match(head .. tail) or line:match(head .. "%s*<%s*%a+%s*>" .. tail)
    if named ~= nil then
      if module ~= nil and module ~= named then
        return nil
      end
      module = named
    end
  end
  return module
end

--- What a name in scope is bound to, as far as the hint cares: the
--- declaration when it is one `name = <integer literal>` alone.
local record Binding
  declaration: ast.Node | nil
end

--- The binding the assignment refused at `y`:`x` writes to. That
--- assignment is the one statement `name = <expression>`, one name and
--- one expression, whose expression the checker's position is (the
--- operator of a binary one, the literal itself). The name resolves
--- through the block, function, loop and `repeat` scopes the parser
--- built, so a parameter, a loop variable, a closed block's local or
--- a text that only looks like a declaration never answers for it.
--- Nil when there is no such assignment, or its name is not a local
--- (a global, a field).
local function target_of(root: ast.Node, y: integer, x: integer): Binding | nil
  local scopes: {{string: Binding}} = {}
  local answer: Binding | nil = nil
  local done = false
  local function lookup(name: string): Binding | nil
    for i = #scopes, 1, -1 do
      local found = scopes[i][name]
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
      for _, name in ipairs(names) do
        declare(name.tk, { declaration = alone and n or nil })
      end
    elseif kind == "assignment" then
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
      if names ~= nil and #names == 1 and values ~= nil and #values == 1
          and target ~= nil and at then
        if target.kind == "variable" and target.tk ~= nil then
          answer = lookup(target.tk)
        end
        done = true
      else
        descend(n)
      end
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
        declare(n.name.tk, {})
      end
      scopes[#scopes + 1] = {}
      if n.is_method == true then
        declare("self", {})
      end
      for _, argument in ipairs(n.args) do
        declare(argument.tk, {})
      end
      visit_all(n.body)
      scopes[#scopes] = nil
    else
      descend(n)
    end
  end
  scopes[1] = {}
  visit(root)
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
  if name == nil or literal == nil or value.kind ~= "integer" or literal:match("^%d+$") == nil then
    return nil
  end
  return name .. " is an integer, inferred from 'local " .. name .. " = " .. literal ..
    "' at line " .. target.y .. "; write 'local " .. name .. " = " .. literal ..
    ".0' or 'local " .. name .. ": number = " .. literal .. "' to hold a number"
end

--- What to write instead, when `msg` is the checker refusing a name
--- [`environment_for`] stripped or a member [`cosmic.removed`] lists; nil
--- for any other message. `y` and `x` are the line and column in
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
--- first bound to, whatever alias reads it now. There is no answer for a
--- record of the program's own, a name bound to more than one module, a
--- module bound among several names (`local A, Hash = ...`) or by a line
--- that does not start with its `local` (`do local Hash = ...`). Scope is
--- not read: a `require` in a nested block counts as the file's own.
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
--- does not parse.
function teal.replacement(msg: string, source: string, y: integer, x: integer): string | nil
  if msg == "in assignment: got number, expected integer" then
    -- TODO: hint a table field too (`local t = {n = 0}; t.n = t.n + 0.5`,
    -- `t.n` an "op" node here): it waits on the checker's inferred type of
    -- a record field being readable from the AST; the parser alone does
    -- not give it.
    return integer_hint(source, y, x)
  end
  local key, alias, typename = msg:match(
    "^invalid key '([%a_][%w_]*)' in record '([%a_][%w_]*)' of type ([%a_][%w_]*)$")
  if key == nil then
    -- A type's name is capitalized, so only a member spelled as one is
    -- offered for it: a removed function is never a type's answer.
    typename, key = msg:match("^unknown type ([%a_][%w_]*)%.(%u[%w_]*)$")
    alias = typename
  end
  if key ~= nil then
    local module = module_bound(source, typename)
    local instead = module ~= nil and Removed.members[module .. "." .. key] or nil
    if instead == nil then
      return nil
    end
    return alias .. "." .. key .. " was removed: " .. instead
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
  if name == nil or Removed.names[name] == nil then
    return nil
  end
  return Removed.message(name, field)
end

return teal
