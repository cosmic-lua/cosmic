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

## reading an array by index

`xs[i]` is `T?`: Lua answers nil for an index out of range. Write `xs[i] or 0` and an out-of-range read becomes a zero that
nothing reports. Three ways to read that name the case instead (`index_may_be_nil`, `cosmic docs index_may_be_nil`).

A loop `for i = 1, #xs do` counts the keys of `xs`, and in its body `xs[i]` is a `T`. It holds when the loop starts at a
literal of 1 or more, steps by 1 or not at all, and runs to `#xs` of a local `xs`, and the body cannot change `xs`: it
calls no function but one of `math` whose every argument is the loop variable, a literal, or an expression of operators other than `and` and `or`, with any call inside it held to the same rule (so `table.remove`, `table.insert`, `table.move`, a call that is given `xs`
and a method call all end it), assigns neither `xs` nor `i`, and writes `xs` only at `xs[i]`. A function made in the body
may run later, when `xs` is shorter, so a read inside one is still `T?`. `xs` is a name, not a field: `r.items` is not
counted, so copy it to a local. `ipairs` gives a `T` as well.

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

Where the loop cannot say it (an index worked out, a loop that calls a function), `Array.at(xs, i)` of [`cosmic.array`] reads
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

`assert(xs[i])` reads it too, and says less when it fails. Do not write `xs[i] or <default>`: it turns an out-of-range read
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
