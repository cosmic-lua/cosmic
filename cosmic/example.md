# example

 Go-style executable example testing.
 Parses Example_* functions from Teal files, runs them, and verifies output.

## Types

### Example

 A parsed example function with its expected output.

```teal
local record Example
  name: string
  body: string
  expected_output: string
  line: integer
end
```

### ExampleResult

 Result from running a single example.

```teal
local record ExampleResult
  name: string
  passed: boolean
  expected: string
  actual: string
  error: string
end
```

### RunResult

 Result from running all examples in a file.

```teal
local record RunResult
  exit_code: integer
  results: {ExampleResult}
  error: string
end
```

### ExampleModule

```teal
local record ExampleModule
  run: function(file_path: string): RunResult
  parse_examples: function(source: string): {Example}
  format_results: function(file_path: string, run_result: RunResult): string
end
```

## Functions

### parse_examples

```teal
function parse_examples(source: string): {Example}
```

 Parse a .tl file and extract Example_* functions with their expected output.
 Finds all local functions named Example_* and extracts their code and -- Output: comments.

**Parameters:**

- `source` (string) - The source code to parse

**Returns:**

- {Example} - List of parsed examples

### run

```teal
function run(file_path: string): RunResult
```

 Run all examples in a file.
 Parses and executes all Example_* functions, returning aggregated results.

**Parameters:**

- `file_path` (string) - Path to the Teal file containing examples

**Returns:**

- RunResult - Result with exit code (0=pass, 1=fail, 2=skip), results, and errors

### format_results

```teal
function format_results(file_path: string, run_result: RunResult): string
```

 Format results for human-readable output.
 Creates formatted test output showing PASS/FAIL/SKIP with expected vs actual output.

**Parameters:**

- `file_path` (string) - Path to the file that was tested
- `run_result` (RunResult) - Results from running examples

**Returns:**

- string - Formatted output for display
