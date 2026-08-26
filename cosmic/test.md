# test

 The in-process test runner: a test runs because it was defined.
 `main` takes the ordered cases a test file's toolchain-generated tail
 hands it, runs each under `xpcall` so one failure never hides the
 rest, prints the failures and a counts line, and RETURNS the exit
 code its caller turns into the process's status. It never exits and
 never throws: only `cosmic.check` may do either.

 Two spellings below are `_tool.records`' output grammar --- the
 failure row `✗ <name>` and the counts line `<N> checks: <P> passed`
 --- reproduced rather than imported, because `cosmic/**` is the strip
 floor and may not require the internal tree. `_tool/records_test.tl`
 asserts the two agree, the way it already does for
 `cosmic.check`'s EXIT_SKIP.

## Types

### Case

 One test to run: the name it reports under and the function itself.
 A test fails by throwing, which is the whole failure vocabulary
 (`assert`, `cosmic.check`); a test that returns has passed.

```teal
local record Case
  name: string
  fn: function()
end
```

### Options

 Options for `main`.

```teal
local record Options
  --  A plain SUBSTRING matched against a case name --- the contract the
  --  benchmark and example runners already honour, not a Lua pattern.
  --  When absent, COSMIC_TEST_FILTER is read instead.
  filter: string
end
```

### TestModule

```teal
local record TestModule
  main: function(cases: {Case}, opts?: Options): integer
end
```

## Functions

### main

```teal
function main(cases: {Case}, opts?: Options): integer
```

 Run an ordered list of test cases and report on them.
 Every selected case runs, in the order given, whatever the ones
 before it did: a throw is recorded against its case's name and the
 run continues. Output goes to stdout through `io.write` only --- no
 `print` --- so a caller can capture all of it by swapping that one
 function.
 1 otherwise

**Parameters:**

- `cases` ({Case}) - The cases, in source order
- `opts` (Options?) - A name filter; COSMIC_TEST_FILTER when absent

**Returns:**

- integer - 0 when every selected case passed, 2 when none ran,
