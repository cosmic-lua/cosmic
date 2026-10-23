--- Tests of [`build.syntax_receivers`] against [`build.receivers`]: a program is read by the fork's compiler and by the new
--- checker, and the uses of a record's fields found through the type of the value are the same, use for use, in order.
local Fixture = require("build.syntax_typed_fixture")
local Receivers = require("build.syntax_receivers")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
    { path = "core/syscalls.h", letters = "r" }, { path = "core/process.h", letters = "r" }, { path = "core/socket.h", letters = "r" },
  },
}

--- A module with a record nested in its own, an interface that record lists, and a record it keeps to itself.
local ZIPX <const> = table.concat({
  "local record Zipx",
  "  interface Collector",
  "    write: function(Collector, string): boolean, string",
  "  end",
  "  record Writer is Collector",
  "    name: string",
  "    write: function(Writer, string): boolean, string",
  "    close: function(Writer): boolean, string",
  "  end",
  "  record Plain",
  "    size: integer",
  "    grow: function(Plain): integer",
  "  end",
  "  interface Base",
  "    tell: function(Base): string",
  "  end",
  "  interface Mid is Base",
  "    tell: function(Mid): string",
  "  end",
  "  record Deep is Mid",
  "    tell: function(Deep): string",
  "  end",
  "  open: function(): Writer",
  "  plain: function(): Plain",
  "  deep: function(): Deep",
  "end",
  "local record Private",
  "  secret: integer",
  "end",
  "local function secret(): Private return { secret = 1 } end",
  "function Zipx.open(): Zipx.Writer",
  "  local p = secret()",
  "  return {",
  "    name = 'w' .. tostring(p.secret),",
  "    write = function(_: Zipx.Writer, _s: string): boolean, string return true, '' end,",
  "    close = function(_: Zipx.Writer): boolean, string return true, '' end,",
  "  }",
  "end",
  "function Zipx.deep(): Zipx.Deep",
  "  return { tell = function(_: Zipx.Deep): string return 'd' end }",
  "end",
  "function Zipx.plain(): Zipx.Plain",
  "  return { size = 1, grow = function(p: Zipx.Plain): integer return p.size end }",
  "end",
  "return Zipx",
}, "\n")

local MODULES <const>: {string: string} = { zipx = ZIPX }

local function uses_of(said: Fixture.Said): string
  local out: {string} = {}
  for _, u in ipairs(said.refs) do
    out[#out + 1] = u.module .. " " .. u.member .. " " .. u.line
  end
  return table.concat(out, "\n")
end

--- The uses the fork and the port find in `source` after the prelude: the same; the fork's, as lines.
local function same(source: string): string
  local text = Fixture.PRELUDE .. source
  local fork, port = uses_of(Fixture.fork(text, MODULES)), uses_of(Fixture.port(text, MODULES))
  assert(fork == port, "in:\n" .. source .. "\nthe fork finds:\n" .. fork .. "\nthe port finds:\n" .. port)
  return fork
end

local function line(n: integer): integer
  local _, lines = Fixture.PRELUDE:gsub("\n", "\n")
  return n + lines
end

local function test_a_field_read_and_a_method_called_through_a_nested_record_are_uses_of_its_field()
  local found = same("local Z = require('zipx')\nlocal w = Z.open()\nlocal n = w.name\nlocal ok, _ = w:close()\nuse(n, ok)\n")
  assert(found == "zipx Writer.name " .. line(3) .. "\nzipx Writer.close " .. line(4), found)
end

local function test_a_name_the_record_does_not_take_is_found_by_the_type_of_the_value_not_by_its_name()
  local found = same("local Z = require('zipx')\nlocal p = Z.plain()\nlocal q = p\nuse(q.size, q:grow())\nuse(p.size)\n")
  assert(found == "zipx Plain.grow " .. line(4) .. "\nzipx Plain.size " .. line(4) .. "\nzipx Plain.size " .. line(5), found)
end

local function test_a_field_the_record_inherits_is_a_use_of_the_interface_that_declares_it()
  local found = same("local Z = require('zipx')\nlocal w = Z.open()\nlocal ok, _ = w:write('x')\nuse(ok)\n" ..
      "local c: Z.Collector = w\nlocal ok2, _ = c:write('y')\nuse(ok2)\n")
  assert(found:find("zipx Collector.write " .. line(3), 1, true) ~= nil, found)
  assert(found:find("zipx Collector.write " .. line(6), 1, true) ~= nil, found)
end

local function test_a_field_declared_by_each_of_a_chain_of_interfaces_is_a_use_of_the_deepest()
  local found = same("local Z = require('zipx')\nlocal d = Z.deep()\nuse(d:tell())\n")
  assert(found == "zipx Base.tell " .. tostring(line(3)), found)
end

local function test_an_assignment_to_a_field_is_no_use_and_the_value_it_is_reached_through_is()
  local found = same("local Z = require('zipx')\nlocal w = Z.open()\nw.name = 'x'\nlocal record Holder\n  w: Z.Writer\nend\nlocal box: Holder = { w = w }\n" ..
      "local ok, _ = box.w:close()\nuse(ok)\n")
  assert(found == "zipx Writer.close " .. line(8), found)
end

local function test_a_record_of_the_modules_own_and_one_it_keeps_to_itself_have_no_row()
  local found = same("local Z = require('zipx')\nuse(Z.open, Z.plain)\n")
  assert(found == "", found)
  -- the private record is no one's to name; a value typed as one in this program is a use of nothing
  assert(same("local record Mine\n  n: integer\nend\nlocal m: Mine = { n = 1 }\nuse(m.n)\n") == "")
end

local function test_a_use_on_each_line_is_found_once_and_a_line_with_two_is_found_in_order()
  local found = same("local Z = require('zipx')\nlocal w = Z.open()\nuse(w.name, w.name)\nlocal ok, _ = w:close()\n" ..
      "use(ok, w:write('a'))\n")
  assert(found:find("Writer.name " .. line(3), 1, true) ~= nil, found)
  local count = 0
  for _ in found:gmatch("Writer.name") do
    count = count + 1
  end
  assert(count == 1, found)
end

--- A deliberate difference: the fork types a table constructor with no declared type by its items, so a value reached
--- through one is a use; the new checker refuses such a literal (it has no type to make a record from), types the value
--- `invalid`, and finds no use through it. The refusal is the checker's error, which the ceilings count.
local function test_a_value_reached_through_a_table_constructor_with_no_type_is_a_use_for_the_fork_and_none_for_the_port()
  local text = Fixture.PRELUDE .. "local Z = require('zipx')\nlocal w = Z.open()\nlocal box = { w = w }\n" ..
    "local ok, _ = box.w:close()\nuse(ok)\n"
  assert(uses_of(Fixture.fork(text, MODULES)) == "zipx Writer.close " .. line(4))
  assert(uses_of(Fixture.port(text, MODULES)) == "")
end

--- The lines a use is not seen on are those where the value a field is read through is typed `invalid` (here a type that does
--- not exist); the places a known type speaks for are the names read through one that is not.
local function test_the_lines_the_port_cannot_see_a_use_on_and_the_places_a_known_type_speaks_for_are_told()
  local text = Fixture.PRELUDE .. "local Z = require('zipx')\nlocal w = Z.open()\nuse(w.name)\n" ..
    "local function f(u: Nowhere)\n  use(u.size)\nend\nuse(f)\n"
  local subject = Fixture.subject(text, MODULES)
  local blind = Receivers.blind(subject)
  assert(#blind == 1 and blind[1] == line(5), table.concat(blind, " "))
  local wanted: {string: boolean} = {}
  wanted[tostring(line(3)) .. " name"] = true
  wanted[tostring(line(5)) .. " size"] = true
  wanted[tostring(line(3)) .. " other"] = true
  local known = Receivers.known(subject, wanted)
  assert(#known == 1 and known[1] == tostring(line(3)) .. " name", table.concat(known, ", "))
end

--- A string method on an enum value is a method of strings, no use of a field of the enum.
local function test_a_string_method_on_an_enum_value_is_no_use_of_the_enum()
  local module = table.concat({
    "local record Enumx",
    "  enum Kind",
    "    'a'",
    "    'b'",
    "  end",
    "  record Tok",
    "    kind: Kind",
    "  end",
    "  make: function(): Tok",
    "end",
    "function Enumx.make(): Enumx.Tok",
    "  return { kind = 'a' }",
    "end",
    "return Enumx",
  }, "\n")
  local modules: {string: string} = { enumx = module }
  local text = Fixture.PRELUDE .. "local E = require('enumx')\nlocal t = E.make()\nuse(t.kind, t.kind:sub(1, 1), t.kind:upper())\n"
  local said = Fixture.port(text, modules)
  local found: {string} = {}
  for _, u in ipairs(said.refs) do
    found[#found + 1] = u.module .. " " .. u.member
  end
  assert(#found == 1 and found[1] == "enumx Tok.kind", table.concat(found, ", "))
end
