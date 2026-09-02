# Write examples and benchmarks

steps for writing `Example_*` and `Benchmark_*` functions and running them, for a
reader who has a module to document or time.

## write an example

an example is a function the runner extracts, runs, and grades by its output.

1. create or open the module's `<name>_example.tl` beside the module.
2. define `local function Example_<name>()`. the runner finds it by name, so nothing
   in the file calls it.
3. require what the body uses inside the function. the runner runs each body as its
   own chunk, so a file-level `local` is not in scope.
4. end the body with a `-- Output:` line followed by one comment line per expected
   line of stdout.
5. list every example in a trailing `local _ = {...}` so the checker sees them used.

this is `Example_decode` from `cosmic/json_example.tl`, as the runner sees it:

```teal example=cosmic/json_example.tl#Example_decode
local json = require("cosmic.json")
local result = json.decode('{"a":1}')
-- result is now a Lua table
print((json.encode(result)))
-- Output:
-- {"a":1}
```

and its neighbour that shows an error path:

```teal example=cosmic/json_example.tl#Example_decode_error
local json = require("cosmic.json")
local _, err = json.decode("{invalid}")
if err then
  print("decode error: " .. err)
end
-- Output:
-- decode error: illegal character
```

the trailing list has this shape:

```teal
local function Example_decode()
  local json = require("cosmic.json")
  local result = json.decode('{"a":1}')
  print((json.encode(result)))
  -- Output:
  -- {"a":1}
end

local _ = {Example_decode}
```

an example without a `-- Output:` block runs nothing and passes. write the block, or
the example checks nothing. `require("cosmo")` is refused in an example file. use
the `cosmic.*` module instead.

## run examples

check one file, or every `*_example.tl` in the project.

```bash
cosmic --check example cosmic/json_example.tl   # one file
cosmic --make example                           # the whole project
```

`--check example` runs every example in the file and prints one line per example,
`<file>: <name>: PASS`. it exits nonzero when any output differs. `--make example`
runs under the same sandbox as `--make test`. `cosmic --docs howto.test` says what it
allows.

to read the examples a module ships, browse them from the binary.

```bash
cosmic --examples          # every module with examples
cosmic --examples json     # one module's examples, with their output
```

## write a benchmark

a benchmark is a function the runner calls many times and reports a time per call for.

1. create or open `<name>_benchmark.tl` beside the module.
2. define `local function Benchmark_<name>()` with the work to time in its body.
3. require what the body uses inside the function, for the same reason as an example.
4. list every benchmark in a trailing `local _ = {...}`.

```teal
local function Benchmark_encode()
  local json = require("cosmic.json")
  local _out, _err = json.encode({a = 1, b = "hello"})
end

local _ = {Benchmark_encode}
```

## run benchmarks

run one file, one function, or every `*_benchmark.tl` in the project.

```bash
cosmic --benchmark cosmic/json_benchmark.tl          # one file
cosmic --benchmark cosmic/json_benchmark.tl:encode   # names containing a substring
cosmic --make benchmark                              # the whole project
```

the runner grows the iteration count until one timed run lasts at least
`COSMIC_BENCHMARK_MIN_MS` milliseconds, then prints one row per function: the name,
the iterations, and the time per call. the numbers differ between runs.

```text
pkg: cosmic/json_benchmark.tl
Benchmark_encode    904217    1.12 µs/op
PASS
```

the `:<substring>` suffix is a plain substring, not a pattern. no match is an error.
