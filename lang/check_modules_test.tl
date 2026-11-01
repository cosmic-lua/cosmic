--- A value of another module's declaration ([`lang.check`], [`lang.declarations`]): what `require` gives and what a call of
--- `Mod.new()` answers is typed with the declaration, so a method call or a field read on it is held to the rules of a
--- value of a declaration written in the same module, and the table of the declaration's functions stays a type of its own.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ cpu_features = true }

--- Checks that `source` has exactly the errors `codes` (space separated), and that the message or the fix of the first says `msg`.
local function refused(source: string, codes: string, msg?: string, modules?: {string: string}, declared?: {string: string})
  local r = Programs.run(source, modules, declared)
  local first = assert(r.errors[1], "no error in\n" .. source)
  assert(#r.before == 0, table.concat(r.before, " ") .. " in\n" .. source)
  assert(Programs.codes(r) == codes, "wanted " .. codes .. ", got " .. Programs.codes(r) .. " in\n" .. source .. "\n" .. first.msg)
  if msg ~= nil then
    local said = first.msg .. "\n" .. first.fix
    assert(said:find(msg, 1, true) ~= nil, said .. "\nwanted " .. msg)
  end
end

--- Checks that `source` has no error.
local function accepted(source: string, modules?: {string: string}, declared?: {string: string})
  local r = Programs.run(source, modules, declared)
  local first = r.errors[1]
  local why = ""
  if first ~= nil then
    why = first.msg
  end
  assert(#r.before == 0 and #r.errors == 0, table.concat(r.before, " ") .. why .. " in\n" .. source)
end

--- A class with methods, a static that takes a value of it first, a static that does not, and a constructor.
local COUNTER <const> = [[
local class Counter
  mut n: integer
  tag?: string
  items: {integer}
  function bump(self, by: integer): integer
    self.n = self.n + by
    return self.n
  end
end
function Counter.new(): Counter
  return { n = 0, tag = nil, items = {} }
end
function Counter.twice(self: Counter): integer
  return self.n * 2
end
function Counter.zero(): integer
  return 0
end
return Counter
]]

--- A generic class.
local BOX <const> = [[
local class Box<T>
  mut item: T
  label: string
  function get(self): T
    return self.item
  end
  function find(self, key: string): T?
    return nil
  end
end
function Box.of<T>(v: T): Box<T>
  return { item = v, label = "x" }
end
return Box
]]

--- A record whose function is a field every value holds, and one whose functions are statements.
local QUEUE <const> = [[
local record Queue
  items: {integer}
  push: function(self: Queue, x: integer)
end
function Queue.new(): Queue
  return { items = {}, push = function(self: Queue, x: integer) end }
end
function Queue.size(self: Queue): integer
  return #self.items
end
function Queue.make(): integer
  return 0
end
return Queue
]]

--- A module that returns a value of the class of another.
local SHARED <const> = [[
local Counter = require("counter")
local shared: Counter = Counter.new()
return shared
]]

--- A declaration file: its table has the fields its record declares.
local RAW <const> = [[
local record raw
  digest: function(s: string): string
  size: integer
end
return raw
]]

local MODULES <const>: {string: string} = { counter = COUNTER, box = BOX, queue = QUEUE, shared = SHARED }
local HEAD <const> = "local type Counter = require(\"counter\")\nlocal type Box = require(\"box\")\n"

-- values of another module's declaration -------------------------------------------------------------------

local function test_a_method_call_and_a_field_read_on_a_value_the_module_made_are_typed()
  accepted(HEAD .. "local c = Counter.new()\nlocal n: integer = c:bump(2)\nlocal m: integer = c.n\nlocal t: string? = c.tag\n", MODULES)
end

local function test_an_annotated_parameter_a_returned_value_and_a_field_have_the_declarations_type()
  accepted(HEAD .. [[
local record Holder
  counter: Counter
end
local function bumped(c: Counter): integer
  return c:bump(1)
end
local function made(): Counter
  return Counter.new()
end
local h: Holder = { counter = made() }
local n: integer = bumped(h.counter) + h.counter:bump(1) + made().n
]], MODULES)
end

local function test_a_generic_container_of_values_of_another_module_keeps_their_type()
  accepted(HEAD .. [[
local b = Box.of(Counter.new())
local c: Counter = b:get()
local n: integer = b:get():bump(1) + b.item.n
local boxes: {Box<Counter>} = { b }
local first = boxes[1]
if first ~= nil then
  local again: integer = first:get():bump(1)
end
local k: string = b.label
]], MODULES)
  refused(HEAD .. "local b = Box.of(Counter.new())\nlocal s: string = b:get():bump(1)\n", "not_assignable", nil, MODULES)
  refused(HEAD .. "local b = Box.of(Counter.new())\nb:get():nope()\n", "field_unknown", "no field `nope`", MODULES)
end

local function test_a_function_field_that_takes_the_record_first_is_called_as_a_method()
  accepted("local Queue = require(\"queue\")\nlocal q = Queue.new()\nq:push(1)\nlocal n: integer = Queue.size(q)\n", MODULES)
end

local function test_a_function_of_a_class_that_takes_a_value_of_it_first_is_a_method_of_its_values()
  accepted(HEAD .. "local c = Counter.new()\nlocal a: integer = c:twice()\nlocal b: integer = Counter.twice(c)\n", MODULES)
  refused(HEAD .. "local c = Counter.new()\nlocal a: string = c:twice()\n", "not_assignable", nil, MODULES)
  refused(HEAD .. "local c = Counter.new()\nlocal a = c:twice(1)\n", "arity", nil, MODULES)
end

local function test_a_module_that_returns_a_value_of_a_class_gives_a_value_of_it()
  accepted("local shared = require(\"shared\")\nlocal n: integer = shared:bump(1) + shared:twice() + shared.n\n", MODULES)
  accepted(HEAD .. "local shared = require(\"shared\")\nlocal c: Counter = shared\n", MODULES)
  -- and not the table of the class's functions
  refused("local shared = require(\"shared\")\nlocal n = shared.zero()\n", "field_unknown", "is a function of the declaration", MODULES)
end

local function test_the_table_of_a_declaration_file_is_a_value_of_its_record()
  local head = "local type raw = require(\"raw\")\nlocal r: raw = require(\"raw\")\n"
  accepted(head .. "local s: string = r.digest(\"a\")\nlocal n: integer = r.size\nlocal x = require(\"raw\")\nlocal t: string = x.digest(\"b\")\n",
    MODULES, { raw = RAW })
  refused(head .. "local s: integer = r.digest(\"a\")\n", "not_assignable", nil, MODULES, { raw = RAW })
  refused(head .. "r.size = 2\n", "field_fixed", nil, MODULES, { raw = RAW })
  refused(head .. "local s = r.digestt(\"a\")\n", "field_unknown", "nearest `digest`", MODULES, { raw = RAW })
end

-- what is still refused ----------------------------------------------------------------------------------------

local function test_a_method_that_the_declaration_lacks_is_refused_with_the_nearest_name()
  refused(HEAD .. "local c = Counter.new()\nc:bumpp(1)\n", "field_unknown", "no field `bumpp`, nearest `bump`", MODULES)
  refused(HEAD .. "local c = Counter.new()\nlocal x = c.nmae\n", "field_unknown", "no field `nmae`", MODULES)
end

local function test_an_argument_of_the_wrong_type_is_refused()
  refused(HEAD .. "local c = Counter.new()\nc:bump(\"a\")\n", "not_assignable", "argument 1 of `c:bump`", MODULES)
  refused(HEAD .. "local c = Counter.new()\nc:bump()\n", "arity", nil, MODULES)
end

local function test_an_optional_field_and_a_result_that_may_be_nil_are_not_used_before_a_test()
  refused(HEAD .. "local c = Counter.new()\nlocal n: string = c.tag\n", "nil_not_allowed", nil, MODULES)
  refused(HEAD .. "local b = Box.of(Counter.new())\nlocal x = b:find(\"a\")\nx:bump(1)\n", "nil_not_allowed", "may be nil", MODULES)
  accepted(HEAD .. "local b = Box.of(Counter.new())\nlocal x = b:find(\"a\")\nif x ~= nil then\n  x:bump(1)\nend\n", MODULES)
  accepted(HEAD .. "local c = Counter.new()\nlocal t = c.tag\nif t ~= nil then\n  local n: string = t\nend\n", MODULES)
end

local function test_a_fixed_field_and_a_view_of_another_module_are_not_written()
  refused(HEAD .. "local b = Box.of(Counter.new())\nb.label = \"y\"\n", "field_fixed", nil, MODULES)
  accepted(HEAD .. "local b = Box.of(Counter.new())\nb.item = Counter.new()\nlocal c = Counter.new()\nc.n = 3\n", MODULES)
  refused(HEAD .. "local c = Counter.new()\nc.items[1] = 2\n", "view_written", nil, MODULES)
  refused(HEAD .. "local c = Counter.new()\nlocal xs: mut {integer} = c.items\n", "view_as_mut", nil, MODULES)
end

local function test_an_instance_method_on_the_table_of_the_declaration_is_refused()
  refused(HEAD .. "Counter:bump(1)\n", "declaration_value", "where a value of `Counter` is wanted as the receiver of `Counter:bump`", MODULES)
  refused(HEAD .. "local n = Counter.twice(Counter)\n", "declaration_value", "argument 1 of `Counter.twice`", MODULES)
  refused(HEAD .. "local c: Counter = Counter\n", "declaration_value", nil, MODULES)
  -- `push` is a field every value holds, so the table of the functions has none to call
  refused("local Queue = require(\"queue\")\nQueue:push(1)\n", "field_unknown", "`v:push(...)`", MODULES)
  refused("local Queue = require(\"queue\")\nlocal n = Queue.size(Queue)\n", "declaration_value", nil, MODULES)
end

--- A module stored where a value of its record belongs: the module is no value of the record.
local QUEUES <const> = "local Queues = require(\"queue\")\nlocal type Queue = require(\"queue\")\n" ..
  "local record Holder\n  mut Queue: Queue\nend\n"
local REQUIRE_QUEUE <const> = "require the module where you use it (`local Queue = require(\"queue\")`)"

local function test_a_module_stored_in_a_field_typed_with_its_record_is_refused_with_the_require_to_write()
  refused(QUEUES .. "Holder.Queue = Queues\n", "declaration_value", REQUIRE_QUEUE .. ", instead of passing it in the assignment to `Holder.Queue`", MODULES)
  refused(QUEUES .. "local h: Holder = { Queue = Queues }\n", "declaration_value",
    REQUIRE_QUEUE .. ", instead of passing it as the field `Queue` of", MODULES)
end

local function test_an_array_of_modules_and_a_module_passed_for_a_value_of_its_record_are_refused()
  refused(QUEUES .. "local all: {Queue} = { Queues }\n", "declaration_value", REQUIRE_QUEUE .. ", instead of passing it as an element of", MODULES)
  refused(QUEUES .. "local function take(q: Queue)\nend\ntake(Queues)\n", "declaration_value",
    REQUIRE_QUEUE .. ", instead of passing it as argument 1 of `take`", MODULES)
  refused(QUEUES .. "local one: Queue = Queues\n", "declaration_value", REQUIRE_QUEUE .. ", instead of passing it as the value of `one`", MODULES)
end

local function test_a_module_is_refused_by_the_return_value_the_map_and_a_require_into_a_typed_local()
  refused(QUEUES .. "local function f(): Queue\n  return Queues\nend\n", "declaration_value",
    REQUIRE_QUEUE .. ", instead of passing it as return value 1", MODULES)
  refused(QUEUES .. "local m: {string: Queue} = { a = Queues }\n", "declaration_value",
    REQUIRE_QUEUE .. ", instead of passing it as a value of", MODULES)
  refused(QUEUES .. "local one: Queue = require(\"queue\")\n", "declaration_value",
    REQUIRE_QUEUE .. ", instead of passing it as the value of `one`", MODULES)
end

--- The fix of a refusal of `source`, which must be `code` and say to require the module where it is used and never to
--- write the module's own type.
local function required(source: string, code: string): string
  local r = Programs.run(source, MODULES)
  assert(Programs.codes(r) == code, Programs.codes(r) .. " in\n" .. source)
  local first = assert(r.errors[1])
  local told = first.fix
  assert(told:find(REQUIRE_QUEUE, 1, true) ~= nil, told)
  assert(told:find("(declaration)", 1, true) == nil and told:find("change the declaration", 1, true) == nil, told)
  return told
end

local function test_a_module_stored_where_a_value_of_its_record_is_optional_or_inside_a_generic_says_to_require_it()
  local _ = required(QUEUES .. "local u: Queue | nil = Queues\n", "declaration_value")
  _ = required(QUEUES .. "local u: Queue | string = Queues\n", "declaration_value")
  _ = required(QUEUES .. "local function take(q?: Queue)\nend\ntake(Queues)\n", "declaration_value")
  _ = required(QUEUES .. "local function f(): Queue?\n  return Queues\nend\n", "declaration_value")
  -- an optional field, in a literal and assigned
  local optional = "local Queues = require(\"queue\")\nlocal type Queue = require(\"queue\")\n" ..
    "local record Opt\n  mut q?: Queue\nend\n"
  _ = required(optional .. "local o: Opt = { q = Queues }\n", "declaration_value")
  _ = required(optional .. "local o: Opt = {}\no.q = Queues\n", "declaration_value")
  -- a generic that holds the module's values, and a collection it is added to
  _ = required("local Bx = require(\"box\")\nlocal Queues = require(\"queue\")\nlocal type Queue = require(\"queue\")\n" ..
      "local type Box = require(\"box\")\nlocal b: Box<Queue> = Bx.of(Queues)\n", "declaration_value")
  _ = required(QUEUES .. "local a: mut {Queue} = {}\ntable.insert(a, Queues)\n", "declaration_value")
end

--- A class module stored where a value of the class belongs.
local COUNTERS <const> = "local Cs = require(\"counter\")\nlocal type Counter = require(\"counter\")\n"
local REQUIRE_COUNTER <const> = "require the module where you use it (`local Counter = require(\"counter\")`)"

local function test_a_class_module_stored_where_its_values_belong_says_to_require_it_and_where_a_value_is_made()
  local made = "to make a value, call a function of `Counter` that makes one (`Counter.new(...)`)"
  refused(COUNTERS .. "local record H\n  c: Counter\nend\nlocal h: H = { c = Cs }\n", "declaration_value",
    REQUIRE_COUNTER .. ", instead of passing it as the field `c` of", MODULES)
  refused(COUNTERS .. "local all: {Counter} = { Cs }\n", "declaration_value", REQUIRE_COUNTER .. ", instead of passing it as an element of", MODULES)
  refused(COUNTERS .. "local function take(c: Counter)\nend\ntake(Cs)\n", "declaration_value",
    REQUIRE_COUNTER .. ", instead of passing it as argument 1 of `take`; " .. made, MODULES)
  refused(COUNTERS .. "local record H\n  mut c: Counter\nend\nlocal h: H = { c = Counter.new() }\nh.c = Cs\n", "declaration_value",
    REQUIRE_COUNTER .. ", instead of passing it in the assignment to `h.c`", MODULES)
  refused(COUNTERS .. "local function f(): Counter\n  return Cs\nend\n", "declaration_value", REQUIRE_COUNTER, MODULES)
  refused(COUNTERS .. "local m: {string: Counter} = { a = Cs }\n", "declaration_value", REQUIRE_COUNTER, MODULES)
  refused(COUNTERS .. "local u: Counter? = Cs\n", "declaration_value", REQUIRE_COUNTER, MODULES)
  -- a class of this module has no module to require
  refused("local class K\n  n: integer\nend\nlocal k: K = K\n", "declaration_value", "make a value with a table literal")
end

local function test_a_record_declared_in_a_block_of_this_module_is_not_a_module_to_require()
  local told = assert(Programs.run("do\n  local record Circle\n    radius: number\n  end\n  local c: Circle = Circle\nend\n").errors[1]).fix
  assert(told:find("require", 1, true) == nil and told:find("call a function on the module (`Circle.f(...)`)", 1, true) ~= nil, told)
end

local function test_a_function_read_through_a_local_of_a_module_says_to_call_it_on_the_declaration()
  refused("local Queues = require(\"queue\")\nlocal q = Queues.new()\nlocal m = q.make\n", "field_unknown",
    "call it on the declaration: `Queue.make(...)`", MODULES)
end

local function test_a_module_required_where_it_is_used_is_called_for_its_functions()
  accepted("local Queue = require(\"queue\")\nlocal q = Queue.new()\nlocal n: integer = Queue.size(q)\nlocal m: integer = Queue.make()\n",
    MODULES)
  -- a function read through a field that holds the module is the form that was refused where the module was stored
  refused(QUEUES .. "local h: Holder = { Queue = Queue.new() }\nlocal m = h.Queue.make()\n", "field_unknown",
    REQUIRE_QUEUE .. " instead of reading it through a field", MODULES)
end

local function test_a_function_that_takes_no_value_is_not_reached_through_one()
  refused(HEAD .. "local c = Counter.new()\nlocal z = c.zero()\n", "field_unknown", "is a function of the declaration `Counter` used as a value", MODULES)
  refused(HEAD .. "local c = Counter.new()\nlocal z = c:new()\n", "field_unknown", nil, MODULES)
  refused("local Queue = require(\"queue\")\nlocal q = Queue.new()\nlocal z = q.make()\n", "field_unknown", nil, MODULES)
end

local function test_a_function_statement_of_a_record_is_not_a_method_of_its_values()
  -- a value of a record is a table of its fields, with no metatable, so `q:size()` would find no function at run time
  refused("local Queue = require(\"queue\")\nlocal q = Queue.new()\nlocal n = q:size()\n", "field_unknown",
    "declare `Queue` as a class, or declare `size` as a function field `size: function(Queue, ...)`", MODULES)
  refused("local Queue = require(\"queue\")\nlocal q = Queue.new()\nlocal f = q.size\n", "field_unknown", nil, MODULES)
end

-- what runs --------------------------------------------------------------------------------------------------

--- Runs `source` with `modules`, checking that it ran to its end.
local function ran(source: string): {string}
  local x = Programs.execute(source, false, MODULES)
  assert(x.fault == nil and x.ran, tostring(x.fault) .. " in\n" .. x.lua)
  return x.printed
end

local function test_the_methods_and_functions_of_another_modules_class_run()
  local printed = ran(HEAD .. [[
local c = Counter.new()
print(c:bump(2), c:twice(), Counter.twice(c), c.n)
local b = Box.of(c)
print(b:get():bump(1), b.item.n, b:find("k") == nil)
]])
  assert(printed[1] == "2\t4\t4\t2", printed[1])
  assert(printed[2] == "3\t3\ttrue", printed[2])
end

local function test_a_module_that_returns_a_value_of_a_class_runs_as_one()
  local printed = ran("local shared = require(\"shared\")\nprint(shared:bump(5), shared:twice())\n")
  assert(printed[1] == "5\t10", printed[1])
end

local function test_a_function_field_of_a_record_of_another_module_runs()
  local printed = ran("local Queue = require(\"queue\")\nlocal q = Queue.new()\nq:push(1)\nprint(Queue.size(q))\n")
  assert(printed[1] == "0", printed[1])
end

-- the generic and the other-class cases ---------------------------------------------------------------------

--- A generic class with a function that takes a value of it first, and a function of a class that takes another class.
local BOXMOD <const> = [[
local class Box<T>
  mut item: T
end
function Box.of<T>(v: T): Box<T>
  return { item = v }
end
function Box.size<T>(self: Box<T>): integer
  return 1
end
return Box
]]

local OTHER <const> = [[
local class B
  n: integer
end
local class C
  n: integer
end
function C.new(): C
  return { n = 1 }
end
function C.f(b: B): integer
  return 1
end
return C
]]

--- A module that returns a value of a generic class. Its name sorts after `box`, which the harness lowers first.
local INSTANCE <const> = [[
local type Box = require("box")
local BoxM = require("box")
local b: Box<integer> = BoxM.of(5)
return b
]]

local function test_a_function_of_a_generic_class_that_takes_a_value_of_it_is_not_yet_a_method()
  refused("local Box = require(\"box\")\nlocal b = Box.of(3)\nlocal n = b:size()\n", "field_unknown", nil, { box = BOXMOD })
  accepted("local Box = require(\"box\")\nlocal b = Box.of(3)\nlocal n: integer = Box.size(b)\n", { box = BOXMOD })
end

local function test_a_function_that_takes_a_value_of_another_class_first_is_no_method()
  refused("local C = require(\"c\")\nlocal c = C.new()\nlocal n = c:f()\n", "field_unknown", nil, { c = OTHER })
end

local function test_a_module_that_returns_a_value_of_a_generic_class_is_one()
  accepted("local b = require(\"zbi\")\nlocal n: integer = b.item\n", { box = BOXMOD, zbi = INSTANCE })
  refused("local b = require(\"zbi\")\nlocal n: string = b.item\n", "not_assignable", nil, { box = BOXMOD, zbi = INSTANCE })
end

local function test_a_generic_record_of_a_declaration_file_stays_the_table()
  local g = "local record g<T>\n  make: function(x: T): g<T>\nend\nreturn g\n"
  refused("local type g = require(\"g\")\nlocal r: g<integer> = require(\"g\")\n", "declaration_value", nil, nil, { g = g })
end

local PAIR <const> = [[
local record Pair<T>
  a: T
end
function Pair.swap<T>(self: Pair<T>): Pair<T>
  return self
end
function Pair.of<T>(a: T): Pair<T>
  return { a = a }
end
return Pair
]]

local function test_a_function_of_a_generic_record_that_takes_a_value_of_it_has_the_fix_of_a_record()
  refused("local Pair = require(\"pair\")\nlocal p = Pair.of(1)\nlocal q = p:swap()\n", "field_unknown",
    "declare `Pair` as a class, or declare `swap` as a function field", { pair = PAIR })
end

-- a function field the values hold --------------------------------------------------------------------------

local function test_the_table_of_the_functions_holds_no_function_field_that_every_value_holds()
  -- `push` is filled by `Queue.new()`, so `Queue.push` is nil at run time
  refused("local Queue = require(\"queue\")\nlocal q = Queue.new()\nQueue.push(q, 1)\n", "field_unknown",
    "call it on a value of `Queue`: `v:push(...)`", MODULES)
  refused("local Queue = require(\"queue\")\nlocal f = Queue.push\n", "field_unknown", "no statement of its module", MODULES)
  accepted("local Queue = require(\"queue\")\nlocal n: integer = Queue.size(Queue.new())\n", MODULES)
end

local function test_a_function_field_that_a_statement_gives_the_table_is_in_it()
  local given = {
    given = "local record Given\n  items: {integer}\n  push: function(self: Given, x: integer)\n  pull: function(self: Given)\nend\n" ..
      "function Given.push(self: Given, x: integer)\nend\nlocal function pull(self: Given)\nend\nGiven.pull = pull\nreturn Given\n",
  }
  accepted("local Given = require(\"given\")\nlocal g: Given = { items = {}, push = Given.push, pull = Given.pull }\ng:push(1)\n", given)
end

-- a function read before the statement that defines it --------------------------------------------------------

local FIRST <const> = "local class C\n  n: integer\nend\nlocal x: C = { n = 1 }\n"
local TWICE <const> = "function C.twice(self: C): integer\n  return self.n * 2\nend\n"

local function test_a_class_function_read_as_the_module_loads_is_defined_above_the_use()
  refused(FIRST .. "local k = x:twice()\n" .. TWICE, "static_before_definition", "before the statement that defines it")
  refused(FIRST .. "local k = C.twice(x)\n" .. TWICE, "static_before_definition")
  accepted(FIRST .. TWICE .. "local k: integer = x:twice()\n")
  -- a function that runs after the module has loaded may name it
  accepted(FIRST .. "local function later(): integer\n  return x:twice()\nend\n" .. TWICE .. "local k = later()\n")
end

local function test_a_record_function_read_as_the_module_loads_is_defined_above_the_use()
  local head = "local record R\n  n: integer\nend\n"
  local statement = "function R.size(self: R): integer\n  return self.n\nend\n"
  refused(head .. "local k = R.size({ n = 1 })\n" .. statement, "static_before_definition")
  accepted(head .. statement .. "local k: integer = R.size({ n = 1 })\n")
  -- the field of a value that is named like the function is the value's own
  accepted("local record F\n  size: function(self: F): integer\nend\nlocal f: F = { size = function(self: F): integer return 1 end }\n" ..
      "local k = f:size()\nfunction F.size(self: F): integer\n  return 2\nend\n")
end
