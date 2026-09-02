# Error return shapes

the four return shapes every `cosmic.*` function uses, what each slot carries,
and the places library code may throw. `cosmic --docs explanation.errors` says
why.

## The four shapes

| shape | returns | on failure |
|---|---|---|
| fallible value | `T \| nil, string` | `nil, message` |
| fallible effect | `boolean, string` | `false, message` |
| structured failure | `T \| nil, <Module>.Error` | `nil, err`, a record in slot 2 |
| infallible | `T` | cannot fail |

a fallible return has exactly two slots: the value, then the error. nothing
rides in a third slot. extras ride on the value's record, the way `fs.find`
carries `.errors`. the `fallible-returns` lint enforces the arity
(`cosmic --docs reference.lint`). a `cosmo.*` binding's tuple is exempt by
position: it is declared once, in the generated `.d.tl`.

every shape below is runnable with `cosmic --examples errors`.

### fallible value

the type admits failure. the caller narrows before using the value, and the
checker forces the guard at an index. `cosmic --docs howto.narrow-nil` has the
steps.

```teal example=cosmic/errors_example.tl#Example_value_error
local json = require("cosmic.json")
local data, err = json.decode("{ not json")
if not data then
  print("parse failed: " .. err)
end
-- Output:
-- parse failed: object key must be string
```

### fallible effect

an operation with nothing to return succeeds `true` or fails `false, message`.

```teal example=cosmic/errors_example.tl#Example_boolean_error
local fs = require("cosmic.fs")
local ok, err = fs.write("/no/such/dir/out.txt", "data")
if not ok then
  print("write failed: " .. (err and "yes" or "no message"))
end
-- Output:
-- write failed: yes
```

### structured failure

a module whose failures carry structure returns its own concrete error record in
slot 2, still two slots. `fetch.fetch` returns `Response | nil, fetch.Error`.

```teal example=cosmic/errors_example.tl#Example_structured_error
local fetch = require("cosmic.fetch")
local resp, err = fetch.fetch("ftp://example.com/file")
if not resp then
  if err.kind == "invalid_request" then
    print("not retryable: " .. err.message)
  end
  print(tostring(err))
end
-- Output:
-- not retryable: unsupported URL scheme: ftp
-- invalid_request: unsupported URL scheme: ftp
```

### infallible

encoding, compression and escaping cannot fail on any input, so they return a
bare value with no error channel.

```teal example=cosmic/errors_example.tl#Example_infallible
local codec = require("cosmic.codec")
local uuid = require("cosmic.uuid")
print(codec.encode_hex("hi"))
print(#uuid.v4())
-- Output:
-- 6869
-- 36
```

## What a `cosmo.unix` failure carries

a failed `cosmo.unix` call returns `nil, err, errno`: a formatted string such as
`"open: ENOENT: No such file or directory"`, plus the numeric errno. a wrapper
adds context with `errno.format(err, prefix)` and branches with
`errno.is_code(eno, name)`. `cosmic --docs errno` has the signatures.

## Structured errors

- a structured error is a record declared `is errors.Failure`, plus the typed
  fields its domain needs. `fetch.Error` carries `kind: ErrorKind`.
- classify by field value: `err.kind == "invalid_request"`. never classify with
  `is` on a concrete record. `is` compiles to `type(x) == "table"`, so it
  cannot tell one error record from another.
- render with `tostring(err)`, which gives the classified form
  `"<kind>: <detail>"`, or read `.message`, which has no prefix.
- `..` on an error record is a compile error, because no `__concat` is
  declared.
- one slot names one concrete record. a module that carries another module's
  structured failure translates it into its own error type at the boundary.

## `cosmic.errors.Failure`

`cosmic.errors.Failure` is the sink-side supertype. it is an interface with
`message: string` and a `__tostring` metamethod, and it is the one table type a
sink can name in a union. producers return their concrete record; a sink that
accepts every module's error names `string | errors.Failure` and narrows the
string arm with `is string`.

```teal example=cosmic/errors_example.tl#Example_sink
local errors = require("cosmic.errors")
local fetch = require("cosmic.fetch")
local function render(err: string | errors.Failure): string
  if err is string then
    return err
  else
    return tostring(err)
  end
end
print(render("plain message"))
local resp, err = fetch.fetch("ftp://example.com/file")
if not resp then
  print(render(err))
end
-- Output:
-- plain message
-- invalid_request: unsupported URL scheme: ftp
```

## Sinks

| sink | signature | behavior |
|---|---|---|
| `check.must` | `must(value: T \| nil, err?: string \| errors.Failure): T` | narrows nil only; throws the error's `tostring`; a `false` value passes through |
| `assert` | one declared return | narrows a `T \| nil`; throws on `nil` and on `false` |

both declare one return, so both compose in a return list and in an argument
list. `check.must(fs.read(path))` fails with `fs.read`'s own message. a slot-2
boolean passed to `check.must` is rejected by name.

## Where library code may throw

library code returns errors and never throws, with these exemptions. each
per-site exemption carries a marker comment the lint reads
(`cosmic --docs reference.lint`).

| site | licence | marker |
|---|---|---|
| `cosmic.check` assertions (`equal`, `not_equal`, `truthy`, `failed`, `must`) | throw at error level 2; the caller is the test runner | none (module-level) |
| `cosmic.check` `needs` and `reap` | exit the process, so a skip is never graded as a pass | none (module-level) |
| `cosmic.rand` | throws when the kernel CSPRNG fails or its contract is violated | none (module-level) |
| an `assert` on a `cosmo.*` return whose `\| nil` is unreachable for the arguments passed | the nil cannot occur | `-- assert: <why>` |
| an `error(` in a Lua protocol whose error channel is the throw | a package searcher, a `coroutine.wrap` shim, a require-time probe | `-- throws: <why>` |
| an `error(` on an infallible-by-type contract violated past the checker | a value smuggled through a cast | `-- throws: <why>` |
| an `os.exit(` or `unix.exit(` at a process boundary | a child after `fork`, or an entry helper answering to the OS | `-- exits: <why>` |

`cosmic.check` is for tests and examples only. library code never requires it.

## Module rules

- never throw from library code, except as the table above lists.
- never silently discard an error.
- one shape per module: pick a pattern and use it throughout.
- an infallible function returns just the value.
