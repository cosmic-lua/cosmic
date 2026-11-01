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
record declares, and the fields written after it replace them. The source is not changed.

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
- Its source is a value of a record type, not nilable: test a `Config?` before spreading it. An array, a map, a class
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
