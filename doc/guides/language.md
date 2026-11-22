# the language

The rules of the Teal that cosmic reads, in the cases a program meets first. Each section gives the rule, a
program that follows it, and the checker code that names the mistake. `cosmic docs <code>` explains a code; `cosmic docs
project` shows a whole project.

## fields are fixed unless mut

A record's field is given its value where the record is made. It is not assigned afterward, unless the record declares it
`mut`. Assigning a fixed field is refused with `field_fixed` (`cosmic docs field_fixed`). The fix is `mut` in the
record, or a new record.

```teal
local record Counter
  name: string
  mut hits: integer
end

local counter: Counter = { name = "visits", hits = 0 }
counter.hits = counter.hits + 1
print(counter.name, counter.hits)
```

```output
visits	1
```

A record with one field changed is made with a spread, `{ ...r, field = v }`. The spread copies the fields that the
record declares, and the fields written after it replace them. The source is not changed. The copy is shallow: a field
that holds a record or an array holds the same one in both.

```teal
local record Config
  host: string
  port: integer
  mut retries: integer
end

local base: Config = { host = "a", port = 80, retries = 3 }
local staging = { ...base, host = "b", port = 8080 }
print(staging.host, staging.port, staging.retries)
print(base.host, base.port)
```

```output
b	8080	3
a	80
```

The rules of the spread (`literal_spread`, `cosmic docs literal_spread`):

- It is the first item of the literal, and the only one.
- Its source is a value of a record type, not a table literal and not nilable: test a `Config?` before spreading it. An array, a map, a class
  value and a value of a record with an array part are refused.
- The literal is a value of the record the source is, or of the record the literal is wanted as, when the source is a
  value of it. A source of another record type is `not_assignable`.
- Each field after it is checked as a field of a literal of the record is: an unknown field is `literal_unknown`, a value
  of the wrong type `not_assignable`. A literal with a spread leaves out no field.
- The source is evaluated once, before the values after it, which are evaluated in the order written. Only the declared
  fields are copied.

`readonly f: T` is a form of the old grammar. The parser refuses it (`expected_token`): write `f: T`.

## a keyword names a field

Every word Lua reserves names a field: after `.`, as a key of a table literal, as a field of a declaration, and as a
function of a record (`function M.end()`). Data from JSON or a protocol often has a field named `end`, `function` or `not`.
The Lua that the compiler makes writes such a field as a string index (`t["end"]`). A method call of a Lua keyword
(`t:end()`) cannot be written that way, so the parser refuses it (`reserved_method`), and a method of a class
cannot have one as its name. A word that only cosmic reserves (`match`, `continue`, `mut`, `is`, `as`, `asserts`,
`userdata`) is a name to Lua, so it may name a method: `function match(self, p: string)` is called as `r:match(p)`. A keyword after `.` or `:` is a field only on the line of the dot: on the next line it
begins a statement.

```teal
local record Span
  start: integer
  end: integer
end

local span: Span = { start = 2, end = 5 }
print(span.end - span.start)
```

```output
3
```

## narrowing

A test tells the checker what a value is, inside the branch it guards. After `if job.note ~= nil`, `job.note` is a `string`
there. A fixed field narrows, and so does a local, whether the test is `~= nil` or `is`. A comparison with a string
(`k == "abc"`) narrows a place that may hold strings, as the next section shows. A comparison with a number narrows nothing.

```teal
local record Job
  name: string
  note: string?
end

local function describe(job: Job): string
  if job.note ~= nil then
    return job.name .. ": " .. job.note
  end
  return job.name
end

print(describe({ name = "sort", note = "by size" }))
print(describe({ name = "pack", note = nil }))
```

```output
sort: by size
pack
```

Two things stop a narrowing. A `mut` field can change under the test, so it narrows nothing: copy it to a local and test
the local. Assigning the local a value that may itself be nil drops what the test showed, and `narrowing_dropped`
(`cosmic docs narrowing_dropped`) names the read that still needs it: test the value again after the assignment.

```teal
local record Slot
  mut note: string?
end

local function size(slot: Slot): integer
  local note = slot.note
  if note ~= nil then
    return #note
  end
  return 0
end

print(size({ note = "abc" }))
```

```output
3
```

A function that tells its callers what an argument is declares it, as `v is string`, and its body returns a test of that
argument and nothing else. A body that does not show it is refused with `narrows_unproved` (`cosmic docs narrows_unproved`).

```teal
local function is_text(v: string | integer): v is string
  return v is string
end

local value: string | integer = "abc"
if is_text(value) then
  print(#value)
end
```

```output
3
```

## a string is a type of its own

A string literal written as a type, `"circle"`, is the type of that one string. A union of them, `"on" | "off"`, is the
strings a value may be, as an enum is. A value of a literal type is a `string`. An enum is the set of its strings: it is
below another enum, or a union of literals, that holds each of them, so `"a"` is below `enum Kind "a" "b" end`, and
`Kind` is below `"a" | "b"`. A string that the type does not hold is `enum_member` (`cosmic docs enum_member`).

A field of a literal type tags a union of records, with no enum for each tag.

```teal
local record Circle
  kind: "circle"
  r: number
end

local record Square
  kind: "square"
  side: number
end

local type Shape = Circle | Square

local function area(s: Shape): number
  if s.kind == "circle" then
    return 3 * s.r * s.r
  end
  return s.side * s.side
end

print(area({ kind = "square", side = 2 }))
```

```output
4
```

`s is Circle` tests the tag too: where `s` is the union, it runs as a test of `s.kind` against the strings of
`Circle`'s tag, and narrows alike. `is` takes one type (`is_union`): test each record apart. A record that is
the one table a value may be (`R | string`) is told by `type(v) == "table"`. Where no tag tells a record from the other
tables a value may be, `is` is refused (`is_on_record`), and the fix is a tag field of a literal type in each record.

A test of a place against a string narrows it. Where `k == "a"` holds, `k` is `"a"`. Where it fails, an enum or a union
of literals keeps its other strings, so a chain of tests over every string of an enum ends the function, and the
checker needs no `return` after it. `k is "a"` narrows alike. A local the program assigns, and an element or field of
a table literal, takes back the enum the value was read as, or `string`, since the program may write another string there.

```teal
local enum Level
  "low"
  "high"
end

local function weight(level: Level): integer
  if level == "low" then
    return 1
  elseif level == "high" then
    return 10
  end
end

print(weight("high"))
```

```output
10
```

`match v do ... end` takes a value apart by its type. Each arm `| T name then` tests the value as `v is T` does and binds
`name` to it, of the type the arm takes: what the arms before it leave of `T`. The arms must take every type the value
may have (`match_missing`), and an arm that takes nothing the arms before it left never runs (`match_redundant`).
`| _ then` takes all the rest. So a `match` over a tagged union, an enum or a union of plain types ends the function
when each arm returns, and a member added to the union later is refused at each `match` that does not take it.

```teal
local record Circle
  kind: "circle"
  r: number
end

local record Square
  kind: "square"
  side: number
end

local function area(s: Circle | Square): number
  match s do
  | Circle c then
    return 3 * c.r * c.r
  | Square q then
    return q.side * q.side
  end
end

local function describe(v: string | integer | boolean): string
  match v do
  | string text then
    return "text " .. text
  | integer n then
    return "number " .. tostring(n + 1)
  | _ then
    return "other"
  end
end

print(area({ kind = "circle", r = 1 }), describe(41), describe(true))
```

```output
3	number 42	other
```

In an arm, a `|` that begins a line begins the next arm, so an expression that goes on to the next line keeps its
operator at the end of the line before. A `match` whose arms are lists, `| (true, v)`, takes a call apart by the lists it
may answer instead.

## an array with named fields

A table that holds an array part and named fields is a record that declares both: `is {string}` makes the array part, and
the body declares the fields. Its literal mixes the two, and `#r`, `r[1]`, `r.name` and a call of a function field, `r.run()`, all work. A map keyed by two
types, `{string | integer: T}`, is refused on purpose (`key_type`): declare the record instead.

```teal
local record Plugin is {string}
  name: string
  run: function(): string
end

local plugin: Plugin = { "a", "b", name = "demo", run = function(): string return "ran" end }
print(#plugin, plugin[1], plugin.name, plugin.run())
```

```output
2	a	demo	ran
```

A call with a string in place of its arguments, `f "x"`, is not in the grammar (`string_call`): write `f("x")`.

## an enum of integers

`enum E: integer` declares named integers, such as the values of a wire format. Each member is `NAME = n`, `n` an integer
literal or its negation; the least integer is written `-0x8000000000000000`, since Lua reads the decimal
`9223372036854775808` as a float. The declaration gives two things: the type `E`, and the table `E` of its members. `E.NAME` is a
value of `E`. A misspelled member is refused where it is written (`field_unknown`), with the nearest name. A name or an
integer written twice is refused (`repeated_value`).

A value of `E` is an `integer` wherever one is wanted, and every operator takes it as one. An integer is not a value of
`E`, so a function that takes an `E` gets a member. The enum's table is not a value of `E` (`declaration_value`).

```teal
local enum State: integer
  STOPPED = 0
  PLAYING = 1
  PAUSED = 2
end

local function label(s: State): string
  if s == State.PLAYING then
    return "playing"
  end
  return "not playing"
end

local wire: integer = State.PAUSED
print(label(State.PLAYING), wire, State.STOPPED + 1)
```

```output
playing	2	1
```

An integer that comes from outside, such as a field a decoder read off the wire, becomes a member through the table's
function `of`: `E.of(n)` answers the member `n` is, or nil where it is none, so the caller decides what an unknown integer
means. `E.name(v)` answers the name of a member. No member is called `of` or `name` (`repeated_value`).

```teal
local enum State: integer
  STOPPED = 0
  PLAYING = 1
end

local function described(n: integer): string
  local s = State.of(n)
  if s == nil then
    return "unknown " .. tostring(n)
  end
  return State.name(s)
end

print(described(1), described(7))
```

```output
PLAYING	unknown 7
```

An integer enum declared inside a record is read through the record's table, here and in a module that requires it:
`Messages.State.PLAYING` for `enum State: integer` inside `record Messages`. An enum of strings (`enum E "a" "b" end`)
has no table, since its values are the strings themselves.

## choosing a module by name

`require(name)` with a computed name is refused (`computed_require`), so that the build sees every module a program
loads. To choose a module at run time, require each candidate by its literal name into a table keyed by name, and pick from
the table.

```teal
local Json = require("cosmic.json")
local Csv = require("cosmic.csv")

local counters: {string: function(string): integer} = {
  json = function(text: string): integer
    local list = Json.decode_array(text)
    if list == nil then return 0 end
    return #list
  end,
  csv = function(text: string): integer
    local rows = Csv.parse(text)
    if rows == nil then return 0 end
    return #rows
  end,
}

local count = assert(counters["json"])
print(count("[1, 2, 3]"))
```

```output
3
```


## reading an array by index

`xs[i]` is `T?`: Lua answers nil for an index out of range. Write `xs[i] or 0` and an out-of-range read becomes a zero that
nothing reports. Four ways to read that name the case instead (`index_may_be_nil`, `cosmic docs index_may_be_nil`).

A loop `for i = 1, #xs do` counts the keys of `xs`, and in its body `xs[i]` is a `T`. It holds when the loop starts at a
literal of 1 or more, steps by 1 or not at all, and runs to `#xs` of a local `xs`, and the body cannot change `xs`: it
calls no function but one of `math` whose every argument is the loop variable, a literal, or an expression of operators other than `and` and `or`, with any call inside it held to the same rule (so `table.remove`, `table.insert`, `table.move`, a call that is given `xs`
and a method call all end it), assigns neither `xs` nor `i`, and writes `xs` only at `xs[i]`. A function made in the body
may run later, when `xs` is shorter, so a read inside one is still `T?`. `xs` is a name, not a field: `r.items` is not
counted, so copy it to a local. `ipairs` gives a `T` as well.

The loop holds the keys beside its index too. In `for i = a, #xs - b do`, with `a` and `b` literals, `xs[i - c]` and
`xs[i + c]` are a `T` for a literal `c` where the bounds of the loop keep the key inside the array: for `xs[i - c]`, `a - c`
is 1 or more; for `xs[i + c]`, `c` is at most `b`. So `for i = 2, #xs - 1 do` reads `xs[i - 1]`, `xs[i]` and `xs[i + 1]`.

```teal
local scores: mut {integer} = { 3, 1, 2 }
local total = 0
for i = 1, #scores do
  scores[i] = scores[i] * 2
  total = total + scores[i]
end
print(total)
```

```output
12
```

A test of the index says it for one read: in the block of `if i >= 1 and i <= #xs then`, `xs[i]` is a `T` for an integer
local `i`. The condition and the block are held to the rule of the loop's body: they call nothing but `math`, shorten
nothing, and assign neither `xs` nor `i`.

```teal
local heights = { 1.0, 4.0, 1.0, 4.0 }
local function height(i: integer): number
  if i >= 1 and i <= #heights then
    return heights[i]
  end
  return 0.0
end
local smooth = 0.0
for i = 2, #heights - 1 do
  smooth = smooth + (heights[i - 1] + heights[i] + heights[i + 1]) / 3
end
print(smooth, height(9))
```

```output
5.0	0.0
```

Where neither can say it (an index worked out, a loop that calls a function), `Array.at(xs, i)` of [`cosmic.array`] reads
the element or raises with the index and the length. It is for an index the caller has already bounded, so a miss is a bug
in the caller; a function whose caller may pass any index returns `xs[i]` as the `T?` it is, or `nil, why`.

```teal
local Array = require("cosmic.array")

local ranks = { 10, 20, 30 }
local middle = (#ranks + 1) // 2
print(Array.at(ranks, middle))
local ok, why = pcall(Array.at, ranks, 4)
print(ok, why)
```

```output
20
false	array: at(4) is outside the array of 3 (1 to 3)
```

`assert(xs[i])` reads it too, and says less when it fails (of a `{boolean}`, write `assert(xs[i] ~= nil)`). Do not write `xs[i] or <default>`: it turns an out-of-range read
into a wrong value.

## integers and floats

`local t = 0` is an `integer`. A later `t = t + 1.5` is `number`, which is not an `integer`, so the checker refuses it
with `not_assignable` (`cosmic docs not_assignable`). Start an accumulator that will hold fractions as `0.0`, or write
`local t: number = 0`. A `number` becomes an integer only on purpose: `math.tointeger(n)` or `math.floor(n)`.

```teal
local total = 0.0
for _, price in ipairs({ 1.5, 2.25 }) do
  total = total + price
end
print(total)
print(math.floor(total))
```

```output
3.75
3
```

## discarding a result on purpose

A result that may be a failure (`nil, why` or `false, why`) must be handled. Where the failure cannot matter, write
`local _, _ = call()`, one `_` for each value the call returns. `cosmic docs project` has the case and an example, in the
section "discarding a failure on purpose".

## optionals are written T?

A value that may be nil has the type `T?`: `string?` is a string or nil. `T | nil` is the old spelling and is refused. A
map holds `{string: string}`, not `{string: string?}`: a missing key already reads nil, and assigning nil deletes it
(`array_of_optional`). Use the value only after a test or `assert`, or the checker refuses it with `nil_not_allowed`
(`cosmic docs nil_not_allowed`).

An optional that may hold a boolean (`boolean?`, an element of a `{boolean}`, a decoded `Json.Value?`) is no condition
and no argument of `assert`: nil and false would not be told apart, and `assert(flags[1])` raises where the element is
there and false (`condition_type`). Write which is meant: `x ~= nil` says the value is there, `x == true` that it is
true. Either leaves a name, a field or an element of an array not nil where it holds; a read of a map stays optional, so
name it first (`local v = m[k]`).

```teal
local function first_word(text: string): string?
  return text:match("%S+")
end

local word = first_word("hello world")
if word == nil then
  error("no words")
end
print(word)
```

```output
hello
```

## a type has an interface by having its fields

An interface names fields that values of many types share. A record, class or interface is a `Named` when it has
each field `Named` declares, of exactly that type, `mut` where the interface's is and omittable where the interface's
is. A function field takes the value as its first parameter, so a class has it as a method. Two records, or two
classes, with the same fields stay two types: only an interface is met by fields.

```teal
local interface Named
  name: string
end

local record Dog
  name: string
  legs: integer
end

local function greet(n: Named): string
  return "hello, " .. n.name
end

local d: Dog = { name = "rex", legs = 4 }
print(greet(d))
```

```output
hello, rex
```

Writing `is Named` after the name is optional. It brings the interface's fields in: a record has each field it leaves
out, as the interface declares it, and a literal of the record gives the field a value. A class has each data field it
leaves out, and each function field that is `mut` or omittable or whose first parameter is not the interface itself,
but writes a method for each other function field. A field the type does declare must be the interface's
exactly, and a method a class lacks is reported where the class is declared (`interface_disagrees`), not where a value
is passed.

```teal
local interface Titled
  title: string
end

local record Page is Titled
  words: integer
end

local p: Page = { title = "intro", words = 120 }
print(p.title)
```

```output
intro
```

## a literal with no type is a record of its fields

A table literal of named items, with no type given where it is made, is a record of its own. It has a field for each
item, of the type of the item's value. A field is `mut` when the program assigns it through the local that holds the
literal, and fixed otherwise. The checker shows the record by its fields, `{ mut hits: integer, name: string }`. A field
the literal does not give is `field_unknown`, and the fix names the field to add or the type to declare.

```teal
local counter = { name = "visits", hits = 0 }
counter.hits = counter.hits + 1
print(counter.name, counter.hits)
```

```output
visits	1
```

The record is below a declared record that has the same fields: a fixed field of the declared record takes a field of a
type below its own, and a field it may leave out may be missing. A `mut` field of the declared record needs a `mut` field
of exactly its type, given in the literal and assigned through its local, since a write through the declared record
changes the literal's record too. So a `mut` field the declared record may leave out (`mut note?: string`), which a
write may set to nil, is not met by a literal's field, and neither is one the literal lacks.
A class, a record with methods, or a record with an array part is not met by fields: write the literal against it where
it is made (`local v: Config = { ... }`).

```teal
local record Point
  x: number
  y: number
end

local function norm(p: Point): number
  return math.sqrt(p.x * p.x + p.y * p.y)
end

local corner = { x = 3, y = 4 }
print(norm(corner))
```

```output
5.0
```

Two such records join to one with the fields of each: a field one of them lacks is optional (`{ x: integer, y: string? }`).
The record is also below a map that is not `mut`, `{string: V}`, when the value of each field is below `V`. Read that
way, a key the record lacks reads `nil`.

```teal
local colors = { red = 1, green = 2 }
local function total(m: {string: integer}): integer
  local sum = 0
  for _, v in pairs(m) do
    sum = sum + v
  end
  return sum
end
print(total(colors))
```

```output
3
```

A literal whose value is `nil` or of a type parameter has no record to make, and is `literal_needs_type`: declare the
type where the literal is made.

## comparing and adding values of a type parameter

A type parameter ranges over every type, so a generic body may not apply `<` or `+` to its values (`generic_op`). A
bound says which operators it takes. `T is Ordered` takes a number type, a string type, or a class that declares
`__lt` and `__le`: two values of `T` compare with `<`, `<=`, `>` and `>=`. `N is Numeric` takes `integer` or `number`:
two values of `N` take `+`, `-`, `*`, `%`, `//` and unary `-`, which answer `N`, and compare with any number. `/`
and `^` answer `number`, as they do for integers.

A type whose values may be a number or a string, such as `integer | string`, is no `Ordered`, because `1 < "a"` raises.
An integer enum is no `Numeric`, because the sum of two members need not be a member. `Ordered`, `Numeric` and `Key`
are bounds only: a value is declared `T`, not `Ordered` (`bound_as_type`).

```teal
local function largest<T is Ordered>(xs: {T}, first: T): T
  local best = first
  for _, x in ipairs(xs) do
    if best < x then
      best = x
    end
  end
  return best
end

local function total<N is Numeric>(xs: {N}, zero: N): N
  local sum = zero
  for _, x in ipairs(xs) do
    sum = sum + x
  end
  return sum
end

print(largest({ 3, 9, 4 }, 0), largest({ "pear", "fig" }, ""))
print(total({ 1, 2, 3 }, 0), total({ 0.5, 0.25 }, 0.0))
```

```output
9	pear
6	0.75
```

A class orders its values with the methods `__lt`, which `<` and `>` call, and `__le`, which `<=` and `>=` call. Each
takes the value and another of the class and answers a `boolean` (`metamethod_signature`). Two values of a class compare
with the operators whose methods it declares, and a class that declares both is `Ordered`, so `table.sort` of an array
of its values needs no comparator.

```text
local class Version
  major: integer
  minor: integer
  function __lt(self, other: Version): boolean
    return self.major < other.major or (self.major == other.major and self.minor < other.minor)
  end
  function __le(self, other: Version): boolean
    return not (other < self)
  end
end

local all: mut {Version} = { { major = 2, minor = 0 }, { major = 1, minor = 4 } }
table.sort(all) -- 1.4, then 2.0
```

## a class that releases what it holds

A class's method `__gc(self)` is its finalizer: Lua calls it once, some time after the last reference to a value is
gone, with the value alone, and drops what it answers. It suits a value that holds what the collector cannot free
itself, such as a child process or a descriptor. A finalizer runs only where the program calls a Lua function or
`collectgarbage`, never between two statements with no call, so the checker's facts about a value's fields and an
array's length hold across it as they hold across any call. A value whose release matters at a known point should
also be a `<close>` local; `__gc` is the release when no one closed it.

```text
local class Lease
  id: integer
  function __gc(self)
    release(self.id)
  end
end
```

## a method with type parameters of its own

A method of a class may take type parameters, written after its name as a function's are. Each call solves them from
its arguments, and a class's own parameters stay in scope. An interface's generic function field, such as
`get: function<T>(Store, Key<T>): T?`, is met by a generic method of the same type.

```text
local class Bag
  items: {integer}

  function map<U>(self, f: function(integer): U): {U}
    local out: mut {U} = {}
    for i, item in ipairs(self.items) do
      out[i] = f(item)
    end
    return out
  end
end

local b: Bag = { items = { 1, 2 } }
local names = b:map(function(n: integer): string return "#" .. tostring(n) end) -- { "#1", "#2" }
```

## keying a map by a type parameter

A map is keyed by `integer`, `string`, `boolean`, an enum, or a record, class, interface or userdata. A type parameter
keys a map only where `Key` bounds it, or an interface does: an unbounded `K` may be `number`, a union or a function,
which no key is (`key_type`). A generic record that keys a map by its parameter bounds it the same way, and a type
parameter passed on to a bounded one is bounded by it too (`bound_not_met`, `bound_unmet`). A declaration may take the
name `Key`, `Ordered` or `Numeric`; where it is in scope, the name is the declaration's.

```teal
local function index<K is Key, V>(xs: {V}, key: function(V): K): {K: V}
  local out: mut {K: V} = {}
  for _, x in ipairs(xs) do
    out[key(x)] = x
  end
  return out
end

local by_length = index({ "fig", "pear" }, function(s: string): integer return #s end)
print(by_length[3], by_length[4])
```

```output
fig	pear
```

## several bounds

A type parameter may have several bounds, written `T is A & B`. A type argument meets each of them, and the body
takes what each gives: the fields of each interface, `<` from `Ordered`, a map key from `Key`. The bounds are a set,
so `A & B` and `B & A` are one type. Where a type parameter is passed on to one bounded by more, the fix names the
bounds to write.

```teal
local function unique_sorted<T is Ordered & Key>(xs: {T}): {T}
  local seen: mut {T: boolean} = {}
  local out: mut {T} = {}
  for _, x in ipairs(xs) do
    if seen[x] ~= true then
      seen[x] = true
      out[#out + 1] = x
    end
  end
  table.sort(out)
  return out
end

print(table.concat(unique_sorted({ "pear", "fig", "pear" }), " "))
```

```output
fig pear
```

## a generic type is related by how it uses each parameter

Two uses of one generic declaration, `Box<integer>` and `Box<number>`, are related by how the body uses each type
parameter. The checker reads it from the fields, methods and listed interfaces, so nothing is written for it.

- A parameter that is only read out (a field that is not `mut`, a return, an element of `{T}`) is covariant:
  `Box<integer>` stands for `Box<number>`.
- A parameter that is only taken in (a parameter of a function field or method) is contravariant: a `Sink<number>`
  stands for a `Sink<integer>`, since it takes every integer.
- A parameter that is read and written (a `mut` field, a `mut {T}`, a map's key) is invariant: the arguments must be
  the same type, and the error says so.
- A parameter that is not used is invariant, since an opaque declaration (`Coroutine<Y, R, S>`) or a tag type
  (`Tagged<Meters>`) means it by its name alone.

The receiver of a class's method says nothing of the parameters, since a method is called on its own value. A function
field counts each parameter, its first too, since `b.f(other)` may pass it another value.

```teal
local record Box<T>
  value: T
end

local record Sink<T>
  put: function(T)
end

local ints: Box<integer> = { value = 2 }
local numbers: Box<number> = ints

local function feed(s: Sink<integer>)
  s.put(3)
end

feed({ put = function(n: number) print(n * 2) end })
print(numbers.value)
```

```output
6
2
```

## a value or a failure

A function that answers a value or a failure declares both lists: `(T) | (nil, E)`. The lists must be told apart by a
position, which is `true` in one and `false` in the other, or `nil` in one and never nil in the other. An optional,
`any`, a type parameter, or a union that holds one of them, may be nil, so `(integer?) | (nil, string)` is refused
(`lists_overlap`): a `nil` first value would not say which list the call answered.

The caller binds the values to locals and tests the first. The test narrows the others: where the value is nil, the
failure is an `E`, and where it is not, the failure is nil. A test of truth (`if n then`) tells the lists apart only where
the value is never `false`; where it may be `false` (a `boolean`), test it against `nil`. An assignment to any of the locals ends this.
A `match` takes the lists apart with a `nil` pattern, before the arm that names the value. A call that may answer
a failure is no statement (`failure_ignored`): bind its values, match it, or discard them on purpose with
`local _, _ = f()`. `assert(f())` answers the values of the one list whose first value is never nil or false, where the first
value of each other list is `nil` or `false`, and raises the failure of the others. Where a value may be either
(`(boolean) | (nil, E)`), `assert` does not tell the lists apart: test it against `nil`.

```teal
local function parse(s: string): (integer) | (nil, string)
  local n = math.tointeger(tonumber(s))
  if n == nil then
    return nil, "not a number: " .. s
  end
  return n
end

local n, why = parse("12")
if n == nil then
  print(why:upper())
else
  print(n + 1)
end

match parse("x") do
  | (nil, reason) then print(reason)
  | (value) then print(value * 2)
end
```

```output
13
not a number: x
```

Where `E` is a `string`, the failure carries words alone. A [`cosmic.failure`] keeps apart what went wrong (`message`), the
path it concerns (`path`) and the errno that says why (`errno`, 0 where no system call failed), so a caller tests the
cause and does not match the words. It is no string: `tostring` gives its text, `path: message`, and so do `print`, and
an `error` or `assert` that nothing catches. Where a string is wanted, the checker's fix names `tostring(why)`.

```teal
local Failure = require("cosmic.failure")
local sys = require("cosmic.sys")

local function open(path: string): (integer) | (nil, Failure)
  local fd, _, errno = sys.open(path, sys.O_RDONLY)
  if fd == nil then
    return nil, Failure.system(errno, path)
  end
  return fd
end

local fd, why = open("/no/such/file")
if fd == nil then
  print(why.errno == sys.ENOENT, tostring(why))
end
```

```output
true	/no/such/file: No such file or directory
```

[`cosmic.array`]: ../../cosmic/array.tl
[`cosmic.failure`]: ../../cosmic/failure.tl
