# Code conventions

the facts about how a cosmic source file is shaped and named, for a reader writing
code the gates accept.

## files

| fact | value |
|---|---|
| source extension | `.tl` (Teal), `.lua` (Lua) |
| indent | 2 spaces, no tabs |
| line endings | LF |
| file length | at most 500 lines, checked by `--check lint` as `file-length` |
| column width | 90 is house style; no gate checks it |
| exempt from the length cap | `.d.tl` declaration files |

the length cap applies to every file the project walk sees, markdown included.
`testdata/` is exempt.

## formatter rules

`cosmic --check fmt` holds a file to the formatter's output. these are the shapes it
produces.

| rule | shape |
|---|---|
| operators and keywords | one space around them |
| trailing comment | one space after the code; aligned comment columns collapse |
| table braces | no space inside: `{a = 1}` |
| table constructor as an argument | contents two levels (4 spaces) past the call, closing `})` one level in |
| anonymous function as an argument | body two levels past the call, `end)` one level in |

a trailing comment:

```teal
local x = 1 -- note
print(x)
```

no spaces inside braces:

```teal
local t = {a = 1}
print(t.a)
```

a table constructor passed as an argument:

```teal
local function go(opts: {string: integer}): integer
  return opts.key
end

local f = go({
    key = 1,
  })
print(f)
```

an anonymous function passed as an argument:

```teal
local function walk(dir: string, visit: function(string))
  visit(dir)
end

walk(".", function(p: string)
    print(p)
  end)
```

## naming

| thing | form | example |
|---|---|---|
| functions and variables | `snake_case`, spelled out | `read_file`, `line_count` |
| record types | `PascalCase` | `Widget`, `Handle`, `FetchResult` |
| constants | `UPPER_SNAKE_CASE` | `MAX_RETRIES` |
| example functions | `Example_*` | `Example_decode` |
| test functions | `test_*` | `test_decode_error` |
| benchmark functions | `Benchmark_*` | `Benchmark_encode` |
| predicates | `is_*` | `is_main`, `is_present` |
| a value with a unit | the unit in the identifier | `timeout_ms`, `size_bytes` |
| an options record and its parameter | `Options` and `opts` | `function run(argv: {string}, opts?: Options)` |
| a deliberately unused local | a leading underscore | `local _out`, `_self: Poller` |

the `test_` prefix is reserved in a `*_test.tl` file. every top-level `local function
test_*` there is a test case.

```teal
local MAX_RETRIES < const > = 3

local record FetchResult
  status: integer
  body: string
end

local function is_ok(result: FetchResult): boolean
  return result.status == 200
end

local function wait_ms(timeout_ms: integer): integer
  return timeout_ms
end

print(MAX_RETRIES, is_ok({status = 200, body = ""}), wait_ms(10))
```

## doc comments

| fact | value |
|---|---|
| doc comment prefix | `---` |
| regular comment prefix | `--` |
| parameter tag | `--- @param <name> <type> <description>` |
| return tag | `--- @return <type> <description>` |

`cosmic --docs <module>` renders the doc comments, so a module's reference is its
doc comments.

```teal
--- Join two path components with a slash.
--- @param head string The leading component
--- @param tail string The trailing component
--- @return string The joined path
local function join_two(head: string, tail: string): string
  return head .. "/" .. tail
end

print(join_two("a", "b"))
```

## declarations

| fact | value |
|---|---|
| default scope | `local` for every declaration |
| `global` | test environment variables only |
| a warning | an error under `--check types` |

## error returns

| shape | meaning |
|---|---|
| `T \| nil, string` | a fallible value: the value, or nil and a message |
| `boolean, string` | a fallible effect: `true`, or `false` and a message |
| `T` | infallible: encoding, compression, escaping |
| `T \| nil, <Error record>` | a failure with structure; classify by field, render with `tostring` |

a fallible return has two slots and nothing in a third. `cosmic --docs
reference.errors` has the full table, and `cosmic --docs explanation.errors` says
why.

## imports

| in | use |
|---|---|
| examples, tests, scripts | `cosmic.*` only; `require("cosmo")` fails lint |
| a `cosmic.*` module's own implementation | `cosmo.*` where it wraps a binding |
