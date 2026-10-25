--- A fixture for the tests of [`lang.relation`]: the declarations of
--- [`lang.types_programs`] and those that the relation reads, which are interfaces and the
--- records, classes and generics that list them, a record with an array part that takes a type
--- parameter, and records that differ in whether a function never returns.
local Programs = require("lang.types_programs")
local Relation = require("lang.relation")
local Types = require("lang.types")

local record RelationPrograms
  type Fixture = Programs.Fixture

  --- [`Programs.fixture`] and, in module `m`: `Event` (an interface), `KeyEvent` and `MouseEvent`
  --- (records that list it); `Source<T>` (an interface), `IntSource` (a class that lists
  --- `Source<integer>`), `Box<T>` (lists `Source<T>`), `Wrapped<T>` (lists `Source<{T}>`) and
  --- `Gen<T>` (lists `Source<function<U>(U, T): U>`, whose argument holds `T` inside a binder);
  --- `ReadWriter` (an interface that extends [`Stream.Reader`]) and `Duplex` (a class that lists it);
  --- `Ordered` (an interface) and `Ranked` (a class that lists it); `Ring<T>` (a record
  --- whose array part is `T`); `Quiet` (a record whose `die` never returns) and `Loud` (whose
  --- `die` may). The names without type parameters are added to `plain`, so that
  --- [`Programs.generate`] draws them.
  fixture: function(store: Types.Store): Fixture

  --- A store, the fixture's declarations in it and a judge of it.
  record World
    store: Types.Store
    fixture: Fixture
    judge: Relation.Judge
  end

  world: function(): World

  --- The use of the fixture's declaration `name` with `args`.
  named: function(w: World, name: string, args?: {Types.Type}): Types.Type

  --- `function(params): returns`: one alternative.
  func: function(w: World, params: {Types.Type}, returns: {Types.Type}): Types.Type

  --- `function(params)`, which answers nothing.
  nothing: function(w: World, params: {Types.Type}): Types.Type

  --- The kinds and positions of the steps of a refusal, as `parameter 1 > element`.
  steps: function(r: Relation.Refusal): string

  --- `t` as an error would print it.
  shown: function(t: Types.Type): string

  --- Whether `a` is below `b`. It fails if the answer and the reason disagree.
  below: function(w: World, a: Types.Type, b: Types.Type): boolean

  --- The reason `a` is not below `b`. It fails if `a` is below `b`.
  refusal: function(w: World, a: Types.Type, b: Types.Type): Relation.Refusal

  --- Fails unless `a` is not below `b` for the rule `code`, at `path` (as [`RelationPrograms.steps`]
  --- writes it, "" for none). Answers the reason.
  refused: function(w: World, a: Types.Type, b: Types.Type, code: Relation.Code, path?: string): Relation.Refusal

  --- The code of a refusal, or "" for none.
  code_of: function(r: Relation.Refusal?): string
end

local function body(): Types.Body
  return { tparams = {}, supers = {}, fields = {}, methods = {}, values = {} }
end

function RelationPrograms.fixture(store: Types.Store): Programs.Fixture
  local fixture = Programs.fixture(store)
  local d = fixture.decls
  local function declare(kind: Types.DeclKind, name: string, arity: integer, plain: boolean): Types.Decl
    local decl = store:declare(kind, "m", { name }, arity)
    d[name] = decl
    if plain then
      fixture.plain[#fixture.plain + 1] = name
    end
    return decl
  end
  local function use(name: string, args?: {Types.Type}): Types.Type
    return store:named(d[name], args)
  end
  local event = declare("interface", "Event", 0, true)
  local key = declare("record", "KeyEvent", 0, true)
  local mouse = declare("record", "MouseEvent", 0, true)
  local source = declare("interface", "Source", 1, false)
  local int_source = declare("class", "IntSource", 0, true)
  local box = declare("class", "Box", 1, false)
  local wrapped = declare("class", "Wrapped", 1, false)
  local gen = declare("class", "Gen", 1, false)
  local read_write = declare("interface", "ReadWriter", 0, true)
  local duplex = declare("class", "Duplex", 0, true)
  local ordered = declare("interface", "Ordered", 0, true)
  local ranked = declare("class", "Ranked", 0, true)
  local ring = declare("record", "Ring", 1, false)
  local quiet = declare("record", "Quiet", 0, true)
  local loud = declare("record", "Loud", 0, true)

  local b = body()
  b.fields = { { name = "name", type = store.string } }
  store:define(event, b)
  b = body()
  b.supers = { use("Event") }
  b.fields = { { name = "name", type = store.string }, { name = "key", type = store.string } }
  store:define(key, b)
  b = body()
  b.supers = { use("Event") }
  b.fields = { { name = "name", type = store.string }, { name = "x", type = store.integer } }
  store:define(mouse, b)

  b = body()
  b.tparams = { { name = "T" } }
  b.fields = { { name = "last", type = store:var(0, 0) } }
  store:define(source, b)
  b = body()
  b.supers = { use("Source", { store.integer }) }
  b.fields = { { name = "last", type = store.integer } }
  store:define(int_source, b)
  b = body()
  b.tparams = { { name = "T" } }
  b.supers = { use("Source", { store:var(0, 0) }) }
  b.fields = { { name = "last", type = store:var(0, 0) } }
  store:define(box, b)
  b = body()
  b.tparams = { { name = "T" } }
  b.supers = { use("Source", { store:array(store:var(0, 0)) }) }
  b.fields = { { name = "last", type = store:array(store:var(0, 0)) } }
  store:define(wrapped, b)
  -- function<U>(U, T): U, where T is the variable of Gen and U the function's own.
  local generic = store:fn({
    tparams = { {} },
    params = { { type = store:var(0, 0) }, { type = store:var(1, 0) } },
    rets = { { items = { store:var(0, 0) } } },
  })
  b = body()
  b.tparams = { { name = "T" } }
  b.supers = { use("Source", { generic }) }
  b.fields = { { name = "last", type = generic } }
  store:define(gen, b)

  local reader_body = d["Stream.Reader"].body
  assert(reader_body ~= nil)
  local read = reader_body.fields[1].type
  b = body()
  b.supers = { use("Stream.Reader") }
  b.fields = { { name = "read", type = read } }
  store:define(read_write, b)
  b = body()
  b.supers = { use("ReadWriter") }
  b.fields = { { name = "read", type = read } }
  store:define(duplex, b)

  b = body()
  b.fields = { { name = "rank", type = store.integer } }
  store:define(ordered, b)
  b = body()
  b.supers = { use("Ordered") }
  b.fields = { { name = "rank", type = store.integer } }
  store:define(ranked, b)

  b = body()
  b.tparams = { { name = "T" } }
  b.array = store:var(0, 0)
  store:define(ring, b)

  b = body()
  b.fields = { { name = "die", type = store:fn({ rets = {} }) } }
  store:define(quiet, b)
  b = body()
  b.fields = { { name = "die", type = store:fn({}) } }
  store:define(loud, b)
  return fixture
end

function RelationPrograms.world(): RelationPrograms.World
  local store = Types.new()
  local fixture = RelationPrograms.fixture(store)
  return { store = store, fixture = fixture, judge = Relation.new(store) }
end

function RelationPrograms.named(w: RelationPrograms.World, name: string, args?: {Types.Type}): Types.Type
  return w.store:named(w.fixture.decls[name], args)
end

function RelationPrograms.func(w: RelationPrograms.World, params: {Types.Type}, returns: {Types.Type}): Types.Type
  local list: mut {Types.Param} = {}
  for i, p in ipairs(params) do
    list[i] = { type = p }
  end
  return w.store:fn({ params = list, rets = { { items = returns } } })
end

function RelationPrograms.nothing(w: RelationPrograms.World, params: {Types.Type}): Types.Type
  local list: mut {Types.Param} = {}
  for i, p in ipairs(params) do
    list[i] = { type = p }
  end
  return w.store:fn({ params = list })
end

function RelationPrograms.steps(r: Relation.Refusal): string
  local out: mut {string} = {}
  for _, step in ipairs(r.path) do
    local index = step.index
    out[#out + 1] = if index ~= nil then step.kind .. " " .. index else step.kind end
  end
  return table.concat(out, " > ")
end

function RelationPrograms.shown(t: Types.Type): string
  return Types.display(t)
end

function RelationPrograms.below(w: RelationPrograms.World, a: Types.Type, b: Types.Type): boolean
  local fast = w.judge:subtype(a, b)
  local reason = w.judge:refuse(a, b)
  assert(fast == (reason == nil), Types.display(a) .. " against " .. Types.display(b) ..
      ": the answer and the reason disagree")
  return fast
end

function RelationPrograms.refusal(w: RelationPrograms.World, a: Types.Type, b: Types.Type): Relation.Refusal
  local reason = w.judge:refuse(a, b)
  assert(reason ~= nil, Types.display(a) .. " is below " .. Types.display(b))
  assert(not w.judge:subtype(a, b), Types.display(a) .. " is below " .. Types.display(b))
  return reason
end

function RelationPrograms.refused(
    w: RelationPrograms.World, a: Types.Type, b: Types.Type, code: Relation.Code, path?: string
): Relation.Refusal
  local r = RelationPrograms.refusal(w, a, b)
  assert(r.code == code and RelationPrograms.steps(r) == (path or ""),
    Types.display(a) .. " against " .. Types.display(b) .. ": " .. Relation.trace(r) .. ", not " .. code ..
      " at " .. (path or "here"))
  return r
end

function RelationPrograms.code_of(r: Relation.Refusal?): string
  if r == nil then
    return ""
  end
  return r.code
end

return RelationPrograms
