--- Tests of [`lang.ast`]: the kind of each record of the syntax tree is an enum of its own, which tells the members of
--- [`Ast.Node`] apart, and [`Ast.Kind`], which the tables [`Ast.fields`] and [`Ast.depths`] are keyed by, lists exactly
--- those values. The records are read from the source of lang/ast.tl as [`lang.parser`] gives them, since a type is
--- erased at run time.
local Ast = require("lang.ast")
local Dump = require("lang.ast_dump")
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Parser = require("lang.parser")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/ast.tl", letters = "r" } } }

local record Declared
  --- The values of the enum `Kind`.
  mut kinds: {string}
  --- The records that have a `kind`, to the values of their kind's enum.
  mut tags: mut {string: {string}}
  --- The enum of each record's `kind`, by the record's name.
  mut enums: mut {string: string}
  --- The members of the union `Node`.
  mut members: mut {string}
  --- The records whose `kind` is declared `mut`.
  mut mutable: mut {string}
end

--- Every node of the tree the walkers are tried on.
local CORPUS <const> = [[
local x <const>, y <close>: integer = 1, 2
local function f<T>(a: T, b?: T, ...: any): T, string
  while a do break end
  repeat if b then continue end until a
  return a, b
end
function R.m<T>(s: R) end
x, y.k, y[1] = 1.5, "s", nil
f(x)
do local z = not x or -y ~= #t end
for i = 1, 10, 2 do end
for k, v in pairs(t) do end
for j = 1, 3 do end
local p = if x then 1 elseif y then 2 else 3 end
local q = (x is T) and (y as U) and (...) and { 1, k = 2, [3] = f(), function() end }
s:m(1).f.g[2]()
if x then elseif y then else end
match f() do
  | (true, v) then print(v)
  | (false, _) then print(x)
end
local record Pair<K, V is Ordered> is Base<K>
  key: K
  mut value?: V
  record Inner
    userdata
  end
  enum Kind "a" "b" end
  type Alias = {K: V}
  array: {integer}
  fn: function<A>(self: Pair, n?: integer, ...: any): (true, A) | (false, nil), asserts n is integer
  m: function(): string?, mut {string}
  bad: {{K}}
  boo: boolean
  nothing: nil
end
local interface Conn is Stream.Reader
  name: string
end
local class Counter is Resettable
  function bump(self, by: integer): integer return by end
end
local enum Mode "r" "w" end
local type Key<T> = Types.Key<T>
local type sqlite = require("cosmic.internal.sqlite")
local function g(v: any): v is Reader end
local u: A | B? = true
local oops: = false
]]

--- The values of `values`, in order.
local function values_of(enum: Ast.Enum): {string}
  local out: mut {string} = {}
  for _, v in ipairs(enum.values) do
    out[#out + 1] = v.value
  end
  return out
end

--- What lang/ast.tl declares inside `record Ast`: its enums, the `kind` of each record and the members of `Node`.
local function declared(): Declared
  local source = assert(Fs.read("lang/ast.tl"))
  local parsed = Parser.parse(Lexer.lex(source, "lang/ast.tl"), "lang/ast.tl", "tl")
  assert(#parsed.errors == 0, "lang/ast.tl does not parse")
  local enums: mut {string: {string}} = {}
  local out: Declared = { kinds = {}, tags = {}, enums = {}, members = {}, mutable = {} }
  local top: Ast.Record? = nil
  for _, stat in ipairs(parsed.chunk.body.stats) do
    if (stat.kind == "Record") and stat.name.name == "Ast" then
      top = stat
    end
  end
  assert(top ~= nil, "lang/ast.tl declares no `record Ast`")
  for _, m in ipairs(top.members) do
    if (m.kind == "Enum") then
      enums[m.name.name] = values_of(m)
      if m.name.name == "Kind" then
        out.kinds = values_of(m)
      end
    end
  end
  for _, m in ipairs(top.members) do
    if (m.kind == "Record") then
      for _, field in ipairs(m.members) do
        if (field.kind == "FieldDecl") and field.name.name == "kind" then
          local t = field.type
          assert((t.kind == "TypeName") and #t.path == 1, m.name.name .. ".kind is not the name of an enum")
          local enum = enums[assert(t.path[1])]
          assert(enum ~= nil, m.name.name .. ".kind is " .. assert(t.path[1]) .. ", which is no enum of `Ast`")
          out.tags[m.name.name] = enum
          out.enums[m.name.name] = assert(t.path[1])
          if field.mut then
            out.mutable[#out.mutable + 1] = m.name.name
          end
        end
      end
    elseif (m.kind == "Alias") and m.name.name == "Node" then
      local union = m.type
      assert((union.kind == "TypeUnion"), "`Node` is not a union")
      for _, member in ipairs(union.members) do
        assert((member.kind == "TypeName") and #member.path == 1, "a member of `Node` is not a name")
        out.members[#out.members + 1] = assert(member.path[1])
      end
    end
  end
  return out
end

--- The names of `set`, sorted.
local function sorted(set: {string: boolean}): {string}
  local out: mut {string} = {}
  for name in pairs(set) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

-- The checker (`untagged_union`, `interface_disagrees`) and the seed build already refuse a kind two records share and a
-- `mut` kind, so the two tests below that say so cannot fail on their own: they name the rule where it is read from the
-- source, and hold [`Ast.Kind`] and the tables to the same records.
local function test_each_record_with_a_kind_has_one_value_of_its_own()
  local d = declared()
  local owner: mut {string: string} = {}
  local count = 0
  for record, values in pairs(d.tags) do
    count = count + 1
    assert(#values == 1, record .. " has " .. tostring(#values) .. " kinds, not one")
    local value = assert(values[1])
    assert(owner[value] == nil, record .. " and " .. tostring(owner[value]) .. " both have the kind " .. value)
    owner[value] = record
  end
  assert(count > 70, "only " .. tostring(count) .. " records have a kind")
end

local function test_the_kinds_of_the_records_are_the_values_of_kind()
  local d = declared()
  local tagged: mut {string: boolean} = {}
  for _, values in pairs(d.tags) do
    for _, value in ipairs(values) do
      tagged[value] = true
    end
  end
  local listed: mut {string: boolean} = {}
  for _, kind in ipairs(d.kinds) do
    assert(listed[kind] == nil, "Ast.Kind lists " .. kind .. " twice")
    listed[kind] = true
  end
  assert(table.concat(sorted(tagged), " ") == table.concat(sorted(listed), " "),
    "the kinds of the records differ from Ast.Kind:\n" .. table.concat(sorted(tagged), " ") .. "\n" .. table.concat(sorted(listed), " "))
end

local function test_the_tables_by_kind_have_the_kinds_of_the_records()
  local d = declared()
  local listed: mut {string: boolean} = {}
  for _, kind in ipairs(d.kinds) do
    listed[kind] = true
  end
  local fields: mut {string: boolean} = {}
  for kind in pairs(Ast.fields) do
    fields[kind] = true
  end
  local depths: mut {string: boolean} = {}
  for kind in pairs(Ast.depths) do
    depths[kind] = true
  end
  assert(table.concat(sorted(fields), " ") == table.concat(sorted(listed), " "), "Ast.fields is not keyed by Ast.Kind")
  assert(table.concat(sorted(depths), " ") == table.concat(sorted(listed), " "), "Ast.depths is not keyed by Ast.Kind")
end

local function test_node_is_the_union_of_the_records_with_a_kind()
  local d = declared()
  local members: mut {string: boolean} = {}
  for _, name in ipairs(d.members) do
    assert(members[name] == nil, "Node lists " .. name .. " twice")
    members[name] = true
  end
  local records: mut {string: boolean} = {}
  for name in pairs(d.tags) do
    records[name] = true
  end
  assert(table.concat(sorted(members), " ") == table.concat(sorted(records), " "),
    "Node differs from the records that have a kind:\n" .. table.concat(sorted(members), " ") .. "\n" .. table.concat(sorted(records), " "))
end

local function test_a_record_names_its_own_enum()
  local d = declared()
  for record, enum in pairs(d.enums) do
    assert(enum == record .. "_kind", record .. ".kind is " .. enum .. ", not " .. record .. "_kind")
  end
end

local function test_a_kind_is_never_mut()
  local d = declared()
  assert(#d.mutable == 0, "the kind of " .. table.concat(d.mutable, ", ") .. " is `mut`")
end

--- The dumps of the nodes that `text`, the dump of a node, holds directly: what the fields [`Ast.fields`] lists hold.
local function dumped_children(text: string): {string}
  local out: mut {string} = {}
  local depth, start, i = 0, 1, 1
  while i <= #text do
    local c = text:sub(i, i)
    if c == '"' then
      i = i + 1
      while text:sub(i, i) ~= '"' do
        i = i + (if text:sub(i, i) == "\\" then 2 else 1 end)
      end
    elseif c == "(" then
      depth = depth + 1
      if depth == 2 then
        start = i
      end
    elseif c == ")" then
      if depth == 2 then
        out[#out + 1] = text:sub(start, i)
      end
      depth = depth - 1
    end
    i = i + 1
  end
  return out
end

--- Tries [`Ast.children`] on `node` and what is below it against the dump, which is written from [`Ast.fields`] and
--- [`Ast.depths`], and notes the kinds met.
local function same_children(node: Ast.Node, seen: mut {string: boolean})
  seen[tostring(node.kind)] = true
  local got: mut {string} = {}
  Ast.children(node, function(child: Ast.Node)
    got[#got + 1] = Dump.dump(child)
    same_children(child, seen)
  end)
  local want = dumped_children(Dump.dump(node))
  assert(table.concat(got, "\n") == table.concat(want, "\n"),
    tostring(node.kind) .. " has the children\n" .. table.concat(got, "\n") .. "\nand its fields hold\n" .. table.concat(want, "\n"))
end

local function test_children_are_what_the_fields_of_each_kind_hold()
  local parsed = Parser.parse(Lexer.lex(CORPUS, "corpus.tl"), "corpus.tl", "tl")
  local seen: mut {string: boolean} = {}
  same_children(parsed.chunk, seen)
  local d = declared()
  local missing: mut {string} = {}
  for _, kind in ipairs(d.kinds) do
    if seen[kind] == nil then
      missing[#missing + 1] = kind
    end
  end
  assert(#missing == 0, "CORPUS has no " .. table.concat(missing, ", ") .. ": add one of each, so that the children of every kind are tried")
end

local record Counter
  mut n: integer
end

local function test_numbering_is_a_pre_order_walk_from_one()
  local parsed = Parser.parse(Lexer.lex(CORPUS, "corpus.tl"), "corpus.tl", "tl")
  local chunk = parsed.chunk
  local count = Ast.number(chunk)
  local seen: Counter = { n = 0 }
  local function walk(node: Ast.Node)
    seen.n = seen.n + 1
    local base: Ast.Base = node
    assert(base.id == seen.n, tostring(node.kind) .. " is numbered " .. tostring(base.id) .. ", not " .. tostring(seen.n))
    Ast.children(node, walk)
  end
  walk(chunk)
  assert(count == seen.n, "Ast.number counts " .. tostring(count) .. " nodes, a walk " .. tostring(seen.n))
end

--- The fields of each record that has a `kind`, by the record's name, each to how deep it holds nodes (0 a node, 1 a
--- list of them, 2 a list of lists) or -1 for a field that holds none.
local function node_depths(): {string: {string: integer}}
  local source = assert(Fs.read("lang/ast.tl"))
  local parsed = Parser.parse(Lexer.lex(source, "lang/ast.tl"), "lang/ast.tl", "tl")
  local top: Ast.Record? = nil
  for _, stat in ipairs(parsed.chunk.body.stats) do
    if (stat.kind == "Record") and stat.name.name == "Ast" then
      top = stat
    end
  end
  assert(top ~= nil, "lang/ast.tl declares no `record Ast`")
  -- The names that stand for a node: the records with a kind, and the unions of such names ([`Ast.Stat`], ...).
  local nodes: mut {string: boolean} = {}
  for _, m in ipairs(top.members) do
    if (m.kind == "Record") then
      for _, field in ipairs(m.members) do
        if (field.kind == "FieldDecl") and field.name.name == "kind" then
          nodes[m.name.name] = true
        end
      end
    end
  end
  local grown = true
  while grown do
    grown = false
    for _, m in ipairs(top.members) do
      if (m.kind == "Alias") and nodes[m.name.name] == nil and (m.type.kind == "TypeUnion") then
        local all = true
        for _, member in ipairs(m.type.members) do
          all = all and (member.kind == "TypeName") and #member.path == 1 and nodes[assert(member.path[1])] == true
        end
        if all then
          nodes[m.name.name] = true
          grown = true
        end
      end
    end
  end
  local function depth_of(t: Ast.Type): integer
    if (t.kind == "TypeName") then
      if #t.path == 1 and nodes[assert(t.path[1])] == true then
        return 0
      end
      return -1
    elseif (t.kind == "TypeArray") then
      local inner = depth_of(t.element)
      return if inner >= 0 then inner + 1 else -1 end
    end
    return -1
  end
  local out: mut {string: {string: integer}} = {}
  for _, m in ipairs(top.members) do
    if (m.kind == "Record") and nodes[m.name.name] == true then
      local fields: mut {string: integer} = {}
      for _, field in ipairs(m.members) do
        if (field.kind == "FieldDecl") then
          fields[field.name.name] = depth_of(field.type)
        end
      end
      out[m.name.name] = fields
    end
  end
  return out
end

local function test_the_fields_of_each_kind_are_the_node_fields_of_its_record()
  local d = declared()
  local depths = node_depths()
  for record, fields in pairs(depths) do
    local kind = assert(assert(d.tags[record])[1])
    local names = assert(Ast.fields[kind], record .. " has no entry in Ast.fields")
    local listed: mut {string: integer} = {}
    for i, name in ipairs(names) do
      listed[name] = assert(assert(Ast.depths[kind])[i], "Ast.depths has no depth for " .. name)
      assert(fields[name] ~= nil, "Ast.fields lists " .. name .. " of " .. kind .. ", which " .. record .. " does not declare")
    end
    for name, depth in pairs(fields) do
      if depth >= 0 then
        assert(listed[name] == depth, record .. "." .. name .. " holds nodes (depth " .. tostring(depth) .. ") but Ast.fields does not list it so, and Ast.children would not visit it")
      end
    end
  end
end
