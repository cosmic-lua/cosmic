--- Tests of inferred variance in [`lang.relation`]: two uses of one declaration are related by how its body uses each
--- type parameter. One it only reads out is covariant, one it only takes in is contravariant, one it reads and writes
--- is invariant, and so is one it does not use. Every program the checker takes is also run.
local Programs = require("lang.check_programs")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "lang/stdlib.d.tl", letters = "r" }, { path = "lang/prelude.d.tl", letters = "r" } } }

local function test_a_parameter_read_out_only_is_covariant()
  Programs.stands("local record Box<T>\n  value: T\nend\nlocal ib: Box<integer> = { value = 1 }\nlocal nb: Box<number> = ib\n" ..
      "print(nb.value)\n", "1")
  -- through a view of an array, a return, and a nested use of a covariant declaration
  Programs.stands("local record Bag<T>\n  items: {T}\n  first: function(): T\nend\nlocal record Outer<T>\n  bag: Bag<T>\nend\n" ..
      "local o: Outer<integer> = { bag = { items = { 2 }, first = function(): integer return 2 end } }\n" ..
      "local p: Outer<number> = o\nprint(p.bag.first())\n", "2")
  Programs.says("local record Box<T>\n  value: T\nend\nlocal nb: Box<number> = { value = 1.5 }\nlocal ib: Box<integer> = nb\n" ..
      "print(ib.value)\n", "not_assignable", "`nb` is `Box<number>`")
end

local function test_a_parameter_taken_in_only_is_contravariant()
  Programs.stands("local record Sink<T>\n  put: function(T)\nend\nlocal ns: Sink<number> = { put = function(n: number) print(n) end }\n" ..
      "local function feed(s: Sink<integer>)\n  s.put(3)\nend\nfeed(ns)\n", "3")
  Programs.says("local record Sink<T>\n  put: function(T)\nend\nlocal function feed(s: Sink<number>)\n  s.put(1.5)\nend\n" ..
      "local si: Sink<integer> = { put = function(n: integer) print(n) end }\nfeed(si)\n", "not_assignable")
end

local function test_a_parameter_read_and_written_is_invariant()
  Programs.says("local record Cell<T>\n  mut value: T\nend\nlocal ic: Cell<integer> = { value = 1 }\n" ..
      "local function store(c: Cell<number>)\n  c.value = 1.5\nend\nstore(ic)\n", "not_assignable",
    "a type argument the declaration both reads and writes")
  -- a `mut` collection, a map's key, and a function that takes and returns it
  Programs.says("local record List<T>\n  items: mut {T}\nend\nlocal il: List<integer> = { items = {} }\n" ..
      "local nl: List<number> = il\nprint(#nl.items)\n", "not_assignable")
  Programs.says("local record Index<K is Key>\n  keys: {K: boolean}\nend\nlocal i: Index<\"a\"> = { keys = {} }\n" ..
      "local n: Index<string> = i\nprint(n)\n", "not_assignable")
  Programs.says("local record Map<T>\n  f: function(T): T\nend\nlocal m: Map<integer> = { f = function(x: integer): integer return x end }\n" ..
      "local n: Map<number> = m\nprint(n.f(1))\n", "not_assignable")
end

local function test_a_parameter_not_used_is_invariant()
  -- an opaque declaration, or a tag, means its parameter by its name alone
  Programs.says("local record Tagged<T>\n  name: string\nend\nlocal a: Tagged<integer> = { name = \"a\" }\n" ..
      "local b: Tagged<number> = a\nprint(b.name)\n", "not_assignable")
end

local function test_a_function_field_counts_its_first_parameter_and_a_method_its_receiver_not()
  -- the receiver of a method or a function field says nothing of the parameters
  -- a function field may be called with another value as its first argument, so its first parameter counts, the
  -- declaring type there too: `Box<integer>` is no `Box<number>`, or `b.f(other)` would run `f` on a `Box<number>`
  Programs.says("local record Box<T>\n  value: T\n  f: function(self: Box<T>): integer\nend\n" ..
      "local function use(b: Box<number>, other: Box<number>): integer\n  return b.f(other)\nend\n" ..
      "local a: Box<integer> = { value = 1, f = function(self: Box<integer>): integer return self.value + 1 end }\n" ..
      "print(use(a, a))\n", "not_assignable not_assignable")
  -- the receiver of a class's method is the value it is called on, and says nothing of the parameters
  Programs.stands("local class Holder<T>\n  value: T\n  function get(self): T\n    return self.value\n  end\nend\n" ..
      "local function read(h: Holder<number>): number\n  return h:get()\nend\nlocal function make(): Holder<integer>\n" ..
      "  return { value = 5 }\nend\nprint(read(make()))\n", "5")
end

local function test_a_declaration_that_names_itself_is_read_until_its_uses_hold()
  Programs.stands("local record Chain<T>\n  value: T\n  next?: Chain<T>\nend\nlocal c: Chain<integer> = { value = 1, next = { value = 2 } }\n" ..
      "local d: Chain<number> = c\nlocal n = d.next\nif n ~= nil then\n  print(n.value)\nend\n", "2")
  -- a type that both takes in and gives out its own parameter through itself is invariant
  Programs.says("local record Flip<T>\n  give: function(): T\n  take: function(n: integer, other: Flip<T>)\nend\n" ..
      "local function f(x: Flip<integer>): Flip<number>\n  return x\nend\nprint(f)\n", "not_assignable")
end
