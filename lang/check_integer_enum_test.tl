--- Integer enums in [`lang.check`]: `enum E: integer` declares the type `E`, whose values are integers to every operator
--- and in every place an `integer` or a `number` is wanted, and the table `E` of its members, each a value of `E`. No
--- integer is a value of `E` but a member read from the table, and a name the table does not hold is refused where it is
--- written. A program the checker takes is also run as the Lua [`lang.codegen`] writes ([`Programs.stands`]).
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{}

local HEAD <const> = [[
local enum State: integer
  UNKNOWN = 0
  PLAYING = 1
  PAUSED = 2
  LOST = -1
end
]]

--- Checks that `source` has exactly the errors `codes` (space separated), and that the message or the fix of the first says
--- each of `says`.
local function refused(source: string, codes: string, says: {string}, modules?: {string: string})
  local r = Programs.run(source, modules)
  local first = assert(r.errors[1], "no error in\n" .. source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source .. "\n" .. first.msg)
  local said = first.msg .. "\n" .. first.fix
  for _, part in ipairs(says) do
    assert(said:find(part, 1, true) ~= nil, said .. "\nwanted " .. part)
  end
end

local function test_a_member_is_a_value_of_the_enum_an_integer_and_a_number()
  Programs.stands(HEAD .. [[
local s: State = State.PLAYING
local n: integer = s
local f: number = State.LOST
local function named(x: State): string
  if x == State.PAUSED then
    return "paused"
  end
  return "other"
end
print(s, n, f, named(State.PAUSED), named(s))
]], "1\t1\t-1\tpaused\tother")
end

local function test_operators_take_a_value_as_the_integer_it_is()
  Programs.stands(HEAD .. [[
local s = State.PAUSED
local sum: integer = s + 1
local bits: integer = s | 1
print(sum, bits, -s, s < State.PLAYING, s >= State.PLAYING, 2 == s)
]], "3\t3\t-2\tfalse\ttrue\ttrue")
end

local function test_a_map_is_keyed_by_values_of_the_enum()
  Programs.stands(HEAD .. [[
local names: {State: string} = { [State.PLAYING] = "playing", [State.LOST] = "lost" }
print(names[State.PLAYING], names[State.LOST], names[State.PAUSED] or "none")
]], "playing\tlost\tnone")
end

local function test_a_member_the_table_lacks_is_refused_with_the_nearest()
  refused(HEAD .. "print(State.PLAYNG)\n", "field_unknown",
    { "`State` has no field `PLAYNG`, nearest `PLAYING`", "add the member `PLAYNG = n` to `State`" })
end

local function test_an_integer_is_no_value_of_the_enum()
  refused(HEAD .. "local s: State = 1\nprint(s)\n", "not_assignable", { "`1` is `integer`, where `State` is wanted" })
  refused(HEAD .. "local n: integer = 2\nlocal s: State = n\nprint(s)\n", "not_assignable", { "where `State` is wanted" })
  refused(HEAD .. "local function f(s: State): State return s end\nprint(f(0))\n", "not_assignable", { "`State`" })
end

local function test_the_table_is_no_value_of_the_enum_and_a_value_has_no_fields()
  refused(HEAD .. "local s: State = State\nprint(s)\n", "declaration_value",
    { "the table of the members of the integer enum `State`", "pass a member (`State.NAME`)" })
  refused(HEAD .. "local n: integer = State\nprint(n)\n", "not_assignable", { "`integer`" })
  refused(HEAD .. "print(State.PLAYING.name)\n", "field_unknown",
    { "`State` is an integer enum, whose values are integers and have no fields" })
end

local function test_a_string_is_no_member_of_an_integer_enum()
  refused(HEAD .. "local s: State = \"PLAYING\"\nprint(s)\n", "not_assignable", { "where `State` is wanted" })
end

local function test_is_cannot_tell_an_integer_enum_from_another_integer()
  refused(HEAD .. "local n: integer | string = 1\nif n is State then\n  print(n)\nend\n", "is_on_record",
    { "an integer enum leaves nothing to test" })
end

local function test_a_union_with_integer_is_integer()
  assert(Programs.type_of(HEAD .. "local u: State | integer = State.PLAYING\nprint(u)\n", "u") == "integer")
  assert(Programs.type_of(HEAD .. "local u: State | number = State.PLAYING\nprint(u)\n", "u") == "number")
end

--- A module whose record declares an integer enum and uses it in a nested record and a function.
local MESSAGES <const> = [[
local record Messages
  enum State: integer
    UNKNOWN = 0
    PLAYING = 1
  end
  record Status
    state: State
  end
  name: function(s: State): string
end
function Messages.name(s: Messages.State): string
  if s == Messages.State.PLAYING then
    return "playing"
  end
  return "unknown"
end
return Messages
]]

local function test_a_nested_enum_is_read_through_its_record_here_and_in_another_module()
  Programs.stands(MESSAGES:gsub("return Messages\n$", "") ..
      "local st: Messages.Status = { state = Messages.State.PLAYING }\nprint(Messages.name(st.state), st.state + 0)\n",
    "playing\t1")
  local r = Programs.run([[
local Messages = require("messages")
local st: Messages.Status = { state = Messages.State.PLAYING }
local n: integer = st.state
print(Messages.name(Messages.State.UNKNOWN), n)
]], { messages = MESSAGES })
  local first = r.errors[1]
  assert(#r.errors == 0, if first ~= nil then first.msg else "" end)
  refused("local Messages = require(\"messages\")\nprint(Messages.State.PLAYNG)\n", "field_unknown",
    { "`Messages.State` has no field `PLAYNG`, nearest `PLAYING`" }, { messages = MESSAGES })
end
