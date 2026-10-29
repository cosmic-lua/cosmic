--- The tests of [`build.alias_members`]: a reference that names no type answers nil beside an empty reason, and a source
--- that cannot be read answers nil beside why.
local Test = require("cosmic.test")
local alias_members = require("build.alias_members")

Test.policy{}

local record Row is alias_members.Declared
  mut module: string
  mut symbol: string
  mut source_symbol: string
  kind: string
  signature: string
end

local function source_with(bound: function(module: string, name: string): string?, string):
    alias_members.Source<Row>
  return {
    declared = function(_module: string, _name: string): Row?, string
      return nil, ""
    end,
    exported = function(_module: string, _name: string): Row?, string
      return nil, ""
    end,
    bound = bound,
    under = function(_target: Row): {Row}?, string
      return {}, ""
    end,
    as_member = function(_owner: Row, member: Row,
                         _name: string): Row
      return member
    end,
  }
end

local alias: Row = { module = "m", symbol = "A", source_symbol = "A",
  kind = "alias", signature = "type A = Mod.Thing" }

local function test_a_reference_naming_no_type_answers_nil_and_no_reason()
  local source = source_with(function(_module: string, _name: string): string?, string
    return nil, ""
  end)
  local found, why = alias_members.resolved(source, alias, "Mod.Thing")
  assert(found == nil and why == "", why)
  local named, named_why = alias_members.named(source, { alias }, "member")
  assert(named ~= nil and #named == 0 and named_why == "", tostring(named_why))
end

local function test_a_source_that_cannot_be_read_says_why()
  local source = source_with(function(_module: string, _name: string): string?, string
    return nil, "rows unreadable"
  end)
  local found, why = alias_members.resolved(source, alias, "Mod.Thing")
  assert(found == nil and why == "rows unreadable", why)
  local named, named_why = alias_members.named(source, { alias }, "member")
  assert(named == nil and named_why == "rows unreadable", tostring(named_why))
end
