--- Types for the tests of [`lang.types`]: a fixture of declarations that recurse, nest, take
--- arguments and implement an interface, a generator of random types over them, and a parse of
--- a type's display by the parser and the lowering ([`lang.declarations`]).
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local DeclPrograms = require("lang.declarations_programs")
local Types = require("lang.types")

local record Programs
  --- The declarations of [`Programs.fixture`], by the name a type displays with.
  record Fixture
    decls: {string: Types.Decl}
    --- The names of the declarations without type parameters, and with them.
    plain: {string}
    generic: {string}
  end

  --- Declares and defines in `store`, in module `m` (and [`cosmic.stream`] for the nested one):
  --- `Node` (a record that holds itself and has an array part of itself), `Tree` and `Forest`
  --- (which hold each other), `List<T>` and `Pair<A, B>`, the interface [`Stream.Reader`], the class
  --- `File` that implements it, the enum `Color` and the userdata `Handle`.
  fixture: function(store: Types.Store): Fixture

  --- The type that the integers of `draws` build, in `store`. An integer is a choice; one past the
  --- end is the first choice, so a shorter list is a simpler type. The type is closed, and none of
  --- its parts is `invalid`.
  generate: function(store: Types.Store, fixture: Fixture, draws: {integer}): Types.Type

  --- The integers of `text`, separated by spaces.
  numbers: function(text: string): {integer}

  --- The type that the source `source` of a type, written as the alias `local type X = ...` in the module that
  --- declares the fixture (in the grammar), lowers to, as a type of `store`; or nil and why: a parse error, or the
  --- error code of a rule it breaks (`refused <code>`).
  parse: function(store: Types.Store, fixture: Fixture, source: string): Types.Type | nil, string
end

-- The fixture ----------------------------------------------------------------

local function declare_all(store: Types.Store): {string: Types.Decl}
  local d: {string: Types.Decl} = {}
  d["Node"] = store:declare("record", "m", { "Node" }, 0)
  d["Tree"] = store:declare("record", "m", { "Tree" }, 0)
  d["Forest"] = store:declare("record", "m", { "Forest" }, 0)
  d["List"] = store:declare("record", "m", { "List" }, 1)
  d["Pair"] = store:declare("record", "m", { "Pair" }, 2)
  d["Stream.Reader"] = store:declare("interface", "cosmic.stream", { "Stream", "Reader" }, 0)
  d["File"] = store:declare("class", "m", { "File" }, 0)
  d["Color"] = store:declare("enum", "m", { "Color" }, 0)
  d["Handle"] = store:declare("userdata", "m", { "Handle" }, 0)
  d["Odd"] = store:declare("enum", "m", { "Odd" }, 0)
  -- Named as the type parameters display writes, so that it must not take them for these.
  d["T"] = store:declare("record", "m", { "T" }, 0)
  d["T_1"] = store:declare("record", "m", { "T_1" }, 0)
  return d
end

function Programs.fixture(store: Types.Store): Programs.Fixture
  local d = declare_all(store)
  local function use(name: string, args?: {Types.Type}): Types.Type
    return store:named(d[name], args)
  end
  local node = use("Node")
  store:define(d["Node"], {
    tparams = {}, supers = {}, methods = {}, values = {},
    fields = {
      { name = "name", type = store.string },
      { name = "next", type = node, omittable = true },
    },
    array = node,
  })
  store:define(d["Tree"], {
    tparams = {}, supers = {}, methods = {}, values = {},
    fields = { { name = "kids", type = use("Forest") } },
  })
  store:define(d["Forest"], {
    tparams = {}, supers = {}, fields = {}, methods = {}, values = {},
    array = use("Tree"),
  })
  store:define(d["List"], {
    tparams = { { name = "T" } }, supers = {}, methods = {}, values = {},
    fields = {
      { name = "items", type = store:array(store:var(0, 0)) },
      { name = "size", type = store.integer, mut = true },
    },
  })
  store:define(d["Pair"], {
    tparams = { { name = "A" }, { name = "B" } }, supers = {}, methods = {}, values = {},
    fields = { { name = "first", type = store:var(0, 0) }, { name = "second", type = store:var(0, 1) } },
  })
  local reader = use("Stream.Reader")
  store:define(d["Stream.Reader"], {
    tparams = {}, supers = {}, methods = {}, values = {},
    fields = {
      { name = "read", type = store:fn({
        params = { { type = reader }, { type = store.integer, omittable = true } },
        rets = { { items = { store:optional(store.string) } }, { items = { store.never } } },
      }) },
    },
  })
  local file = use("File")
  store:define(d["File"], {
    tparams = {}, supers = { reader }, fields = { { name = "path", type = store.string },
      { name = "open", type = store.boolean, mut = true } }, values = {},
    methods = { { name = "close", type = store:fn({ params = { { type = file } },
      rets = { { items = { store.boolean } } } }) } },
  })
  for _, name in ipairs({ "T", "T_1" }) do
    store:define(d[name], { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} })
  end
  store:define(d["Color"], {
    tparams = {}, supers = {}, fields = {}, methods = {}, values = { "red", "green", "blue" },
  })
  -- Values are any strings, as Lua's are: the text must carry bytes that are not UTF-8.
  store:define(d["Odd"], {
    tparams = {}, supers = {}, fields = {}, methods = {}, values = { "\255", "ok", "a\"b" },
  })
  store:define(d["Handle"], {
    tparams = {}, supers = {}, fields = {}, values = {},
    methods = { { name = "release", type = store:fn({ params = { { type = use("Handle") } } }) } },
  })
  return {
    decls = d,
    plain = { "Node", "Tree", "Forest", "Stream.Reader", "File", "Color", "Handle", "Odd", "T", "T_1" },
    generic = { "List", "Pair" },
  }
end

-- The generator ------------------------------------------------------------------

local record Cursor
  values: {integer}
  at: integer
  store: Types.Store
  fixture: Programs.Fixture
  --- The number of type parameters of each enclosing binder, the nearest last.
  binders: {integer}
end

--- A choice from 0 to `n - 1`. Past the end of the draws it is 0.
local function pick(c: Cursor, n: integer): integer
  c.at = c.at + 1
  local v = c.values[c.at]
  if v == nil then
    return 0
  end
  return v % n
end

local MAX_DEPTH <const> = 4

local build: function(c: Cursor, depth: integer): Types.Type

local function plain_named(c: Cursor): Types.Type
  local names = c.fixture.plain
  local name = names[pick(c, #names) + 1]
  return c.store:named(c.fixture.decls[name])
end

local function a_variable(c: Cursor): Types.Type | nil
  if #c.binders == 0 then
    return nil
  end
  local depth = pick(c, #c.binders)
  local count = c.binders[#c.binders - depth]
  return c.store:var(depth, pick(c, count))
end

local function leaf(c: Cursor): Types.Type
  local store = c.store
  local n = pick(c, 16)
  if n <= 2 then
    return store.integer
  elseif n == 3 then
    return store.number
  elseif n == 4 then
    return store.string
  elseif n == 5 then
    return store.boolean
  elseif n == 6 then
    return store:atom("true")
  elseif n == 7 then
    return store:atom("false")
  elseif n == 8 then
    return store:atom("nil")
  elseif n == 9 then
    return store.never
  elseif n == 10 then
    return store.any
  elseif n == 11 then
    local v = a_variable(c)
    if v ~= nil then
      return v
    end
    return store.string
  end
  return plain_named(c)
end

local function members(c: Cursor, depth: integer, least: integer): {Types.Type}
  local out: {Types.Type} = {}
  for _ = 1, least + pick(c, 3) do
    out[#out + 1] = build(c, depth + 1)
  end
  return out
end

local a_function: function(c: Cursor, depth: integer): Types.Type

a_function = function(c: Cursor, depth: integer): Types.Type
  local store = c.store
  local tparams: {Types.TParam} = {}
  for i = 1, pick(c, 3) do
    local bound: Types.Type | nil
    if pick(c, 3) == 0 then
      bound = store:named(c.fixture.decls["Stream.Reader"])
    end
    tparams[i] = { bound = bound }
  end
  if #tparams > 0 then
    c.binders[#c.binders + 1] = #tparams
  end
  local params: {Types.Param} = {}
  for i = 1, pick(c, 4) do
    params[i] = { type = build(c, depth + 1), omittable = pick(c, 5) == 0 }
  end
  local rest: Types.Type | nil
  if pick(c, 6) == 0 then
    rest = build(c, depth + 1)
  end
  local rets: {Types.Alt} | nil
  local shape = pick(c, 5)
  if shape == 1 then
    rets = {}
  elseif shape >= 2 then
    rets = {}
    local alts = shape - 1
    for k = 1, alts do
      local alt: Types.Alt = { items = {} }
      if alts > 1 then
        -- Lists that several are told apart by a position that is `true` in one and `false` in the other.
        alt.items[1] = store:atom(k % 2 == 1 and "true" or "false")
        if alts == 3 then
          alt.items[2] = store:atom(k == 3 and "false" or "true")
        end
      end
      if alts == 1 and #params > 0 and pick(c, 5) == 0 then
        alt.narrows = { param = pick(c, #params) + 1, to = build(c, depth + 1), asserts = pick(c, 2) == 0 }
      else
        -- The grammar spells a list that is empty or ends in `T...` only as the one alternative.
        for _ = 1, pick(c, 3) do
          if depth + 1 < MAX_DEPTH and pick(c, 6) == 0 then
            -- A union of function types, which the grammar writes with parentheses around each.
            local first = a_function(c, depth + 1)
            alt.items[#alt.items + 1] = store:union({ first, a_function(c, depth + 1) })
          else
            alt.items[#alt.items + 1] = build(c, depth + 1)
          end
        end
        if alts == 1 and pick(c, 2) == 0 then
          alt.tail = build(c, depth + 1)
        end
      end
      rets[#rets + 1] = alt
    end
  end
  if #tparams > 0 then
    c.binders[#c.binders] = nil
  end
  return store:fn({ tparams = tparams, params = params, rest = rest, rets = rets })
end

build = function(c: Cursor, depth: integer): Types.Type
  local store = c.store
  if depth >= MAX_DEPTH then
    return leaf(c)
  end
  local n = pick(c, 26)
  if n <= 8 then
    return leaf(c)
  elseif n == 9 then
    return store:array(build(c, depth + 1))
  elseif n == 10 then
    return store:array(build(c, depth + 1), true)
  elseif n == 11 then
    local key = build(c, depth + 1)
    return store:map(key, build(c, depth + 1))
  elseif n == 12 then
    local key = build(c, depth + 1)
    return store:map(key, build(c, depth + 1), true)
  elseif n <= 15 then
    return store:union(members(c, depth, 2))
  elseif n <= 17 then
    return store:optional(build(c, depth + 1))
  elseif n == 18 then
    return store:named(c.fixture.decls["List"], { build(c, depth + 1) })
  elseif n == 19 then
    local a = build(c, depth + 1)
    -- Often the same type twice, which a type that shares its parts is made of.
    local b = pick(c, 3) == 0 and a or build(c, depth + 1)
    return store:named(c.fixture.decls["Pair"], { a, b })
  end
  return a_function(c, depth)
end

function Programs.generate(store: Types.Store, fixture: Programs.Fixture, draws: {integer}): Types.Type
  local c: Cursor = { values = draws, at = 0, store = store, fixture = fixture, binders = {} }
  return build(c, 0)
end

function Programs.numbers(text: string): {integer}
  local out: {integer} = {}
  for word in text:gmatch("%d+") do
    out[#out + 1] = math.tointeger(tonumber(word)) or 0
  end
  return out
end

-- The parser ------------------------------------------------------------------------

function Programs.parse(store: Types.Store, fixture: Programs.Fixture, source: string): Types.Type | nil, string
  local _ = fixture
  -- The fixture's declarations, in the grammar, with the type as the last alias of the module that declares them,
  -- lowered by [`lang.declarations`] in a store of their own and read back here by text.
  local program = Declarations.new()
  local stream = DeclPrograms.lower(program, "cosmic.stream", DeclPrograms.stream_source)
  local whole = DeclPrograms.lower(program, "m", DeclPrograms.fixture_source .. "local type X = " .. source .. "\n", "decl")
  if #stream.parse_errors > 0 then
    return nil, "the fixture does not parse: " .. stream.parse_errors[1].msg
  end
  local first = whole.parse_errors[1]
  if first ~= nil then
    return nil, "parse " .. first.code .. ": " .. first.msg
  end
  local refused = whole.lowered.errors[1]
  if refused ~= nil and refused.code == "store_refused" then
    return nil, "the store refused it: " .. refused.msg
  end
  if refused ~= nil then
    return nil, "refused " .. refused.code .. ": " .. refused.msg
  end
  local stats = whole.chunk.body.stats
  local alias = stats[#stats]
  if not (alias is Ast.TypeAlias) then
    return nil, "not an alias"
  end
  local lowered = whole.lowered.aliases[alias.id]
  if lowered == nil then
    return nil, "the alias was not lowered"
  end
  return store:decode(Types.encode(lowered))
end

return Programs
