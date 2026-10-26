--- Tests of [`lang.ast`]: the kind of each record of the syntax tree is an enum of its own, which tells the members of
--- [`Ast.Node`] apart, and [`Ast.Kind`], which the tables [`Ast.fields`] and [`Ast.depths`] are keyed by, lists exactly
--- those values. The records are read from the source of lang/ast.tl as [`lang.parser`] gives them, since a type is
--- erased at run time.
local Ast = require("lang.ast")
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
-- source, and hold `Ast.Kind` and the tables to the same records.
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
