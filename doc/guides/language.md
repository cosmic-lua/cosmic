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

## narrowing

A test tells the checker what a value is, inside the branch it guards. After `if job.note ~= nil`, `job.note` is a `string`
there. A fixed field narrows, and so does a local, whether the test is `~= nil` or `is`. A comparison with a literal (`n == "abc"`) narrows nothing.

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
true. Either leaves `x` not nil where it holds.

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

[`cosmic.array`]: ../../cosmic/array.tl
