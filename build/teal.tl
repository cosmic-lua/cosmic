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
local work = require("build.work")
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
--- runtime surface: `environment_for` removes io, os and debug from the
--- checker, and `core/surface.c` removes the same names at execution.
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

--- Loads the compiler out of the store.
function teal.load(): compiler | nil, string
  local bytes, trouble = Store.bytecode("vendor.tl")
  if bytes == nil then
    return nil, "the compiler is not in this binary: " .. trouble
  end
  local chunk, why = load(bytes, "@vendor.tl", "b", compiler_environment())
  if chunk == nil then
    return nil, "the compiler would not load: " .. tostring(why)
  end
  -- The one boundary where an untyped chunk becomes a declared surface.
  local produced: any = chunk()
  return produced as compiler
end

--- A capsule that puts off `teal.load`'s ~5ms, ~291KB bytecode load
--- until something actually touches the compiler. Most runs never do:
--- when `build.importer` answers every module and every coverage line
--- from its own caches, nothing ever asks the compiler to parse, check
--- or generate anything, and loading it up front is pure waste on
--- exactly that (common) run. The capsule is an empty table whose
--- metatable loads the compiler on the first field anything reads or
--- writes and remembers it afterward, so the load happens at most
--- once. A write goes onto the loaded compiler itself, never onto the
--- capsule: tl reaches its own `search_module` and `path` through its
--- module table, so `serve`'s override below has to land there for
--- the checker to see it, and a capsule that kept the write for itself
--- would leave tl searching the filesystem. A load failure raises the
--- exact message `teal.load` would have returned, with `error(_, 0)`
--- so it reaches the top unprefixed by a location naming this line
--- rather than the real cause: a broken binary still says "the
--- compiler is not in this binary: ..." instead of a nil-index
--- traceback.
--- @return compiler a capsule usable everywhere `teal.load`'s own
---   result is: the same one boundary, an untyped table cast to the
---   declared surface, just deferred to the first real use
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

--- Points the checker at a staged tree: every module it asks for by
--- name is answered from the working database's `inputs`, a
--- declaration ahead of a source of the same name, under the name the
--- module would have on disk. A `cosmic.*` name the stage does not
--- hold is answered by the binary's own rows, which is how a project
--- outside this tree types its `require` of the standard library.
--- Nothing is read from a path, and nothing falls through to the
--- compiler's own search of the filesystem: a name neither the stage
--- nor the binary holds is not found, however a file of that name
--- may sit on disk, so a module reaches a build only by being staged.
local function serve(built: compiler, handle: work.Handle)
  local db = handle.db
  local root = handle.root
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

--- A checker environment pointed at a staged tree, with the strictness
--- this project holds itself to -- and without the names cosmic's own
--- runtime surface removes (`cosmic.removed`'s own fields): tl's
--- bundled standard-library declarations still carry `io`, `os` and
--- `debug` as ordinary globals, since tl has no way to know cosmic's
--- runtime does not, so a program that reaches for one would otherwise
--- type-check clean and only fail once it actually runs. Stripped from
--- both `globals` (a bare reference: `os.time()`) and `modules` (a
--- `require("io")`: `env.modules` is where `new_env` puts every global
--- that is itself a module, for `require` to resolve statically), each
--- becomes tl's own "unknown variable" or "module not found" instead.
function teal.environment_for(built: compiler, handle: work.Handle): compiler.Env | nil, string
  serve(built, handle)
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

--- What to write instead, when `msg` is the checker refusing a name
--- `environment_for` stripped: `unknown variable: os` at line `y`,
--- column `x` of `source`, read together with the field that follows
--- it there (`os.getenv` names `Env.get`), or `module not found: 'io'`
--- for a `require`. `cosmic.removed`'s `message` says it, the same
--- words `core/surface.c` raises with when a running program reaches
--- for the name. For `invalid key 'hex' in record 'Hash'`, where
--- `source` binds `Hash` to `require("cosmic.hash")` and
--- `cosmic.removed`'s `members` names `cosmic.hash.hex`, what to write
--- instead of that member. Nil for every other message.
function teal.replacement(msg: string, source: string, y: integer, x: integer): string | nil
  local key, alias = msg:match("^invalid key '([%a_][%w_]*)' in record '([%a_][%w_]*)'")
  if key ~= nil then
    local module = source:match("local%s+" .. alias .. "%s*=%s*require%(%s*[\"']([%w_.]+)[\"']%s*%)")
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
