# Formatting

cosmic enforces consistent code formatting via `cosmic --format` and `cosmic --check fmt`.

## Rules

- 2-space indent (tabs are not used)
- LF line endings (no CRLF)
- consistent spacing around operators and keywords
- all `.tl` files must be <=500 lines
- a trailing comment sits ONE space after the code (`x = 1 -- note`);
  aligned comment columns are collapsed by the formatter
- no spaces inside table braces:

```teal
local t = {a = 1}
print(t.a)
```

- a table constructor passed as a function argument indents its contents
  two levels (4 spaces) past the call, with the closing `})` one level in:

```teal
local function go(opts: {string: integer}): integer
  return opts.key
end

local f = go({
    key = 1,
  })
print(f)
```

- anonymous function bodies in argument lists follow the same shape —
  body two levels in, `end)` one level in:

```teal
local function walk(dir: string, visit: function(string))
  visit(dir)
end

walk(".", function(p: string)
    print(p)
  end)
```

when in doubt, write the file and run `cosmic --fix file.tl` — the
formatter is the source of truth for these rules.

## Commands

```bash
cosmic --format file.tl           # print formatted output to stdout
cosmic --fix file.tl              # format the file in place
cosmic --check fmt file.tl     # check if file matches formatted output
```

`--check fmt` compares the original file against the formatted output. if they differ, it reports the first mismatched line on stderr and exits nonzero:

```
file.tl:42: format mismatch
  have:     local x=1
  want:   local x = 1
```

## Build Integration

a project-wide `fmt` verb is part of `cosmic --make` (see
`cosmic --docs guide.make`); today it is `--check fmt` per file,
driven by whatever runs your build.

## Structural rewrite

`--rewrite PATTERN PATH...` is the same read-only structural search as
`--find`. Add a replacement and `--preview` to produce JSON evidence without
opening any source file for writing:

```bash
cosmic --rewrite 'os.execute($CMD)' 'assert(os.execute($CMD))' --preview . \
  > rewrite-preview.jsonl 2> rewrite-preview.err
status=$?
```

Preview prints one JSON object for each selected source, followed by a summary.
Each successful object carries the full formatted `code` that apply would
write, original-position `proposed` edits, comment-protection `refused` sites,
the original match count, and whether formatting or rewriting changes bytes.
This means formatter-only changes can be `changed: true` with no proposed
sites. Exit 0 means a clean plan with accepted edits; 1 means no accepted edits
or protected refusals; 2 means invalid input or a file failure. Syntax
validation checks the replacement template, not its semantic meaning or write
permission. Refresh preview evidence after source changes.

When a file cannot be planned, its line is a `rewrite-error` record rather
than a successful plan. It retains the original `matches` count when matching
succeeded but substitution or formatting failed. In the summary, M/E/R/F/N
mean original Matches, accepted Edits (called `proposed` in preview), Refusals,
failed plans, and selected file Number. A failed plan contributes to F and N,
never E; it makes the exit status 2 even if earlier files were planable.

After reviewing fresh evidence, run the matching partial apply:

```bash
cosmic --rewrite 'os.execute($CMD)' 'assert(os.execute($CMD))' --apply .
```

Apply writes each successful file as it is planned; a later file failure does
not roll back earlier files. Protected comment sites remain untouched in both
modes.

## Style Conventions

beyond what the formatter enforces:

- `snake_case` for functions and variables
- `PascalCase` for record types (e.g., `Widget`, `Handle`, `FetchResult`)
- `UPPER_SNAKE_CASE` for constants
- `Example_*` for example functions, `test_*` for test functions, `Benchmark_*` for benchmarks
- `---` for doc comments, `--` for regular comments
- `--- @param name type description` and `--- @return type description` for doc tags
- prefer `local` for all declarations; use `global` only for test environment variables
