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
