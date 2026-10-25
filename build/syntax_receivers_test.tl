--- Tests of [`build.syntax_receivers`] against the fork's receivers: a program is read by the new checker, and the uses of a
--- record's fields found through the type of the value are the same as the fork found (kept as text, [`lang.forked`]), use
--- for use, in order.
local Fixture = require("build.syntax_typed_fixture")
local Receivers = require("build.syntax_receivers")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" },
    { path = "testdata/forked/typed_fixture.txt", letters = "r" },
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

--- A module that returns a record whose functions are fields called with `:` through a value of it, and a record of another
--- module that has a method of the same name.
local TALLY <const> = table.concat({
  "local record Tally",
  "  count: integer",
  "  add: function(Tally, integer): integer",
  "  bump: function(Tally)",
  "  new: function(): Tally",
  "end",
  "local function add(self: Tally, n: integer): integer",
  "  self:bump()",
  "  return self.count + n",
  "end",
  "local function bump(self: Tally)",
  "  self.count = self.count + 1",
  "end",
  "function Tally.new(): Tally",
  "  return { count = 0, add = add, bump = bump }",
  "end",
  "return Tally",
}, "\n")

local DECOY <const> = table.concat({
  "local record Decoy",
  "  record Pile",
  "    add: function(Pile, integer): integer",
  "  end",
  "  pile: function(): Pile",
  "end",
  "function Decoy.pile(): Decoy.Pile",
  "  return { add = function(_: Decoy.Pile, n: integer): integer return n end }",
  "end",
  "return Decoy",
}, "\n")

--- A module whose returned record lists an interface of its own file, which no one else can name.
local TOLD <const> = table.concat({
  "local interface Told",
  "  tell: function(Told): string",
  "end",
  "local record Teller is Told",
  "  n: integer",
  "  new: function(): Teller",
  "end",
  "function Teller.new(): Teller",
  "  return { n = 1, tell = function(_: Teller): string return 't' end }",
  "end",
  "return Teller",
}, "\n")

local MODULES <const>: {string: string} = { zipx = ZIPX, tally = TALLY, decoy = DECOY, told = TOLD }

local function uses_of(said: Fixture.Said): string
  local out: mut {string} = {}
  for _, u in ipairs(said.refs) do
    out[#out + 1] = u.module .. " " .. u.member .. " " .. u.line
  end
  return table.concat(out, "\n")
end

--- The uses the fork and the port find in `source` after the prelude: the same; the fork's, as lines.
local function same(source: string): string
  local text = Fixture.PRELUDE .. source
  local fork, port = uses_of(Fixture.forked(text, MODULES)), uses_of(Fixture.port(text, MODULES))
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
  assert(uses_of(Fixture.forked(text, MODULES)) == "zipx Writer.close " .. line(4))
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
  local wanted: mut {string: boolean} = {}
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
  local found: mut {string} = {}
  for _, u in ipairs(said.refs) do
    found[#found + 1] = u.module .. " " .. u.member
  end
  assert(#found == 1 and found[1] == "enumx Tok.kind", table.concat(found, ", "))
end

--- A method called through a value of the record its module returns is a use of that method, whatever the value is called
--- and however it is held; a method of that name on a record another module declares is not.
local function test_a_method_called_through_a_value_of_the_record_a_module_returns_is_a_use_of_it()
  local found = same(table.concat({
    "local type Tally = require('tally')",
    "local D = require('decoy')",
    "local t = Tally.new()",
    "use(t:add(1))",
    "local function take(p: Tally): integer",
    "  return p:add(2)",
    "end",
    "use(take)",
    "local record Holder",
    "  held: Tally",
    "end",
    "local box: Holder = { held = t }",
    "use(box.held:add(3))",
    "use(D.pile():add(4))",
    "use(t.count)",
    "",
  }, "\n"))
  -- `D.pile():add(4)` is a use of the other module's `Pile.add`, not of the `add` of `Tally`
  assert(found == "tally add " .. tostring(line(4)) .. "\ntally add " .. tostring(line(6)) .. "\ntally add " .. tostring(line(13)) ..
      "\ndecoy Pile.add " .. tostring(line(14)), found)
end

--- A value the checker has no record for, or a union, is the use of nothing. The fork keys the type of a value by its position
--- and finds the call through the `any` too, so only the port is asked.
local function test_a_value_of_no_known_record_is_a_use_of_nothing()
  local text = Fixture.PRELUDE .. table.concat({
    "local type Tally = require('tally')",
    "local t = Tally.new()",
    "local a: any = t",
    "use(a:add(1))",
    "local u: Tally | nil = t",
    "use(u and u:add(1))",
    "",
  }, "\n")
  local found = uses_of(Fixture.port(text, MODULES))
  assert(found == "tally add " .. tostring(line(6)), found)
end

--- A record, class or interface at the top of a module's file, which is not the record the module returns, has its methods
--- used by a call through a value of it: the fork names no module for it, so the reference says so (`top`).
local function test_a_method_called_through_a_record_at_the_top_of_a_file_is_a_use_of_it()
  local text = Fixture.PRELUDE .. table.concat({
    "local record Mine",
    "  n: integer",
    "  add: function(Mine, integer): integer",
    "  bump: function(Mine)",
    "end",
    "local record Other",
    "  add: function(Other, integer): integer",
    "end",
    "local function make(): Mine",
    "  return { n = 0, add = function(self: Mine, by: integer): integer self:bump() return by end, bump = function(_: Mine) end }",
    "end",
    "local m = make()",
    "use(m:add(1), m.n)",
    "local function other(o: Other)",
    "  use(o:add(2))",
    "end",
    "use(other)",
    "local a: any = m",
    "use(a:add(3))",
    "",
  }, "\n")
  local out = ""
  for _, r in ipairs(Receivers.references(Fixture.subject(text, MODULES))) do
    assert(r.top == true)
    out = out .. r.member .. " " .. tostring(r.line) .. "\n"
  end
  -- `self:bump()` inside the record's own method, `m:add(1)`, and the call through `other`'s parameter
  assert(out == "Mine.bump " .. tostring(line(10)) .. "\nMine.add " .. tostring(line(13)) .. "\nOther.add " .. tostring(line(15)) .. "\n", out)
end

--- A method an interface declares, called through a value of a record that lists it, is a use of the interface's method.
local function test_a_method_a_top_level_interface_declares_is_a_use_of_the_interface()
  local text = Fixture.PRELUDE .. table.concat({
    "local interface Base",
    "  tell: function(Base): string",
    "end",
    "local record Mine is Base",
    "  n: integer",
    "end",
    "local m: Mine = { n = 1, tell = function(_: Mine): string return 'm' end }",
    "use(m:tell())",
    "",
  }, "\n")
  local out = ""
  for _, r in ipairs(Receivers.references(Fixture.subject(text, MODULES))) do
    out = out .. r.member .. " " .. tostring(r.line) .. "\n"
  end
  assert(out == "Base.tell " .. tostring(line(8)) .. "\n", out)
end

--- A record declared inside a function has no module to name: a call through a value of it is the use of nothing.
local function test_a_method_of_a_record_declared_inside_a_function_is_a_use_of_nothing()
  local text = Fixture.PRELUDE .. table.concat({
    "local function f(): integer",
    "  local record Inner",
    "    add: function(Inner, integer): integer",
    "  end",
    "  local i: Inner = { add = function(_: Inner, n: integer): integer return n end }",
    "  return i:add(1)",
    "end",
    "use(f)",
    "",
  }, "\n")
  assert(#Receivers.references(Fixture.subject(text, MODULES)) == 0)
end

--- A method declared by an interface nested in a record that is no module's own is the use of nothing: the record lists
--- an interface no module names.
local function test_a_method_from_an_interface_no_module_names_is_a_use_of_nothing()
  local text = Fixture.PRELUDE .. table.concat({
    "local record Outer",
    "  interface Told",
    "    tell: function(Told): string",
    "  end",
    "end",
    "local record Mine is Outer.Told",
    "  n: integer",
    "end",
    "local m: Mine = { n = 1, tell = function(_: Mine): string return 'm' end }",
    "use(m:tell())",
    "",
  }, "\n")
  assert(#Receivers.references(Fixture.subject(text, MODULES)) == 0)
end

--- A method the record a module returns inherits from an interface of the module's own file is a use of that interface's, which
--- the fork (it would say the record's own) cannot name.
local function test_a_method_the_returned_record_inherits_from_an_interface_of_its_file_is_the_interfaces()
  local text = Fixture.PRELUDE .. "local type Teller = require('told')\nlocal t = Teller.new()\nuse(t:tell())\n"
  local out = ""
  for _, r in ipairs(Receivers.references(Fixture.subject(text, MODULES))) do
    out = out .. r.module .. " " .. r.member .. " " .. tostring(r.top) .. "\n"
  end
  assert(out == "told Told.tell true\n", out)
end

--- A record nested in one module's own that is also the record another module returns (a value typed as it) is used under the
--- nesting, whichever module the fork walks first (the order of a table, so there are several of each).
local function test_the_record_nested_in_a_module_is_not_taken_for_the_one_another_module_returns()
  local nested <const> = "local record Types\n  record Def\n    name: string\n  end\nend\nreturn Types\n"
  local function returns(types: string): string
    return "local types = require('" .. types .. "')\nlocal def: types.Def = { name = 'd' }\nreturn def\n"
  end
  local modules: {string: string} = {
    a_types = nested, b_types = nested, c_types = nested, d_types = nested, e_types = nested, f_types = nested,
    g_def = returns("a_types"), h_def = returns("b_types"), i_def = returns("c_types"), j_def = returns("d_types"),
    k_def = returns("e_types"), l_def = returns("f_types"),
  }
  local text = Fixture.PRELUDE .. "local a, b, c = require('g_def'), require('h_def'), require('i_def')\n" ..
    "local d, e, f = require('j_def'), require('k_def'), require('l_def')\nuse(a.name, b.name, c.name, d.name, e.name, f.name)\n"
  local found = uses_of(Fixture.forked(text, modules))
  local want = ""
  for _, types in ipairs({ "a", "b", "c", "d", "e", "f" }) do
    want = want .. (if want == "" then "" else "\n" end) .. types .. "_types Def.name " .. tostring(line(3))
  end
  assert(found == want, found)
end
