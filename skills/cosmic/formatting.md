# Formatting

cosmic enforces consistent code formatting via `cosmic --format` and `cosmic --check format`.

## Rules

- 2-space indent (tabs are not used)
- LF line endings (no CRLF)
- consistent spacing around operators and keywords
- all `.tl` files must be <=500 lines
- no spaces inside table braces:

```teal
local t = { a = 1 }   -- wrong
local t = {a = 1}     -- right
```

- a table constructor passed as a function argument indents its contents
  two levels (4 spaces) past the call, with the closing `})` one level in:

```teal
local f = go({
    key = 1,
  })
```

- anonymous function bodies in argument lists follow the same shape —
  body two levels in, `end)` one level in:

```teal
walk(dir, function(p: string)
    print(p)
  end)
```

when in doubt, write the file and run `cosmic --fix file.tl` — the
formatter is the source of truth for these rules.

## Commands

```bash
cosmic --format file.tl           # print formatted output to stdout
cosmic --fix file.tl              # format the file in place
cosmic --check format file.tl     # check if file matches formatted output
```

`--check format` compares the original file against the formatted output. if they differ, it reports the first mismatched line on stderr and exits nonzero:

```
file.tl:42: format mismatch
  have:     local x=1
  want:   local x = 1
```

## Build Integration

a project-wide `fmt` verb is part of `cosmic --make` (see
`cosmic --docs guide.make`); today it is `--check format` per file,
driven by whatever runs your build.

## Style Conventions

beyond what the formatter enforces:

- `snake_case` for functions and variables
- `PascalCase` for record types (e.g., `Widget`, `Handle`, `FetchResult`)
- `UPPER_SNAKE_CASE` for constants
- `Example_*` for example functions, `test_*` for test functions, `Benchmark_*` for benchmarks
- `---` for doc comments, `--` for regular comments
- `--- @param name type description` and `--- @return type description` for doc tags
- prefer `local` for all declarations; use `global` only for test environment variables
