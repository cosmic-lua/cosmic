# Narrowing rules

the forms that narrow a `T | nil`, the forms that do not, and the one
position where the checker demands a guard. for a reader who wants the
fact, not the procedure. `cosmic --docs howto.narrow-nil` has the steps.

## forms that narrow a plain variable

each row narrows `v: T | nil` to `T` for every `T`: records, maps,
arrays and scalars.

| form | where `v` is `T` |
|---|---|
| `if v then` | inside the branch |
| `if not v then <exit> end` | below the guard |
| `v and <expr>` | in `<expr>`, in a condition or in value position |
| `assert(v)` / `assert(v, msg)` | below the statement |
| `local x = assert(f())` | `x` is `T` |
| `if v ~= nil then` | inside the branch |
| `if v == nil then <exit> end` | below the guard |
| `if v == nil or <cond> then <exit> end` | below the guard |
| `v or fallback` (fallback not nilable) | the expression is `T` |
| `if v is T then` | inside the branch |
| `if not (v is T) then <exit> end` | below the guard |
| `check.must(f())` | the expression is `T` |

`<exit>` is any statement that ends the branch: `return`, `break`,
`goto`, `error(...)`, `os.exit(...)`.

## forms that do not narrow

| form | what stays a union |
|---|---|
| `if o.field then` | `o.field`, a record field, at every use |
| `if v then` on `boolean \| nil` | `v`; `false` is falsy, so truthiness is not a nil test |
| `assert(v)` on `boolean \| nil` | `v`, for the same reason |
| `first() or second()`, both nilable | the expression |
| a narrow read inside a closure that assigns `v` | `v` inside that closure and after it |
| an element read from a table, `t[i]` where `t: {T \| nil}` | the element |

a record field never narrows. the field must be copied to a local and
the local guarded.

## the position that demands a guard

the checker refuses an unnarrowed `T | nil` in exactly one position:
an index. `s:upper()`, `t.field`, `a[i]` and a method call all report
`cannot index key '<k>' in variable '<v>' of type T | nil`.

every other position admits the union without a message:

| position | example that compiles |
|---|---|
| assignment to a declared non-nil type | `local n: integer = size_of(p)` |
| argument to a non-nil parameter | `widen(size_of(p))` |
| arithmetic | `size_of(p) + 1` |
| concatenation | `name_of(p) .. "!"` |
| return from a non-nil declared return | `return name_of(p)` |

`cosmic --docs explanation.types` says what this means for where a
guard belongs.

a `for` loop over an unnarrowed fallible iterator reports
`expression in for loop does not return an iterator`, and `ipairs` over
an unnarrowed `{T} | nil` reports
`attempting ipairs on something that's not an array`.

## `is` on records

`v is R` compiles to one `type()` test at runtime.

| record | runtime test | `is` narrows |
|---|---|---|
| a plain-table record | `type(v) == "table"` | yes |
| a record declaring the `userdata` member | `type(v) == "userdata"` | yes |
| a record over userdata without the member | `type(v) == "table"`, always false | no |

`fs.Stat` and `re.Regex` declare `userdata`, so `st is fs.Stat` and
`rx is re.Regex` narrow. a `cosmo.*` class named in `is` resolves
through the cosmic searcher's `.d.tl` marker. user code that calls
`require("tl").loader()` replaces that searcher with tl's own, and `is`
on a `cosmo.*` class is unsupported there.

`is` on a structured error record is unsound for classification. a
module's error record is classified by its field.
`cosmic --docs reference.errors` has the shapes.

## casts

`v as T` narrows nothing; it asserts. every `as` carries a
`-- cast: <reason>` comment on the same line or the line above. the
`cast-justify` lint refuses a cast without one.
`cosmic --docs reference.lint` has the rule.

## the declared type of a nil local

`local x = nil` with no annotation has the type `nil`, not a union. no
guard narrows it, and every later assignment reports
`in assignment: got <T>, expected nil`. a nilable local is declared
`local x: T | nil = nil`. `cosmic --docs reference.teal` has the
annotation forms.
