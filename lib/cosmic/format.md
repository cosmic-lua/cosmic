# format

 Code formatter for Teal and Lua files.
 Produces deterministic, consistently-indented output while preserving
 all information including comments. Uses the Teal lexer for tokenization
 and parser for syntax validation.

## Types

### Issue

 A formatting issue (syntax error preventing formatting).

```teal
local record Issue
  file: string
  line: integer
  column: integer
  message: string
  severity: string
end
```

### FormatResult

 Result from formatting a file.

```teal
local record FormatResult
  ok: boolean
  code: string
  errors: {Issue}
end
```

### Item

```teal
local record Item
  y: integer
  x: integer
  tk: string
  kind: string
end
```

### Line

```teal
local record Line
  items: {Item}
  y: integer
end
```

### FormatModule

```teal
local record FormatModule
  format: function(input: string, filename: string): FormatResult
  format_file: function(input_path: string): FormatResult
  format_issues: function(issues: {Issue}): string
end
```

## Functions

### format

```teal
function format(input: string, filename: string): FormatResult
```

 Format source code.
 Lexes and parses the input to validate it, then re-emits with
 deterministic formatting.

**Parameters:**

- `input` (string) - The source code to format
- `filename` (string) - The filename (used for error messages and language detection)

**Returns:**

- FormatResult - Result with ok status, formatted code, and any errors

### format_file

```teal
function format_file(input_path: string): FormatResult
```

 Format a file from disk.
 Reads the file, formats it, and returns the result.

**Parameters:**

- `input_path` (string) - Path to the file to format

**Returns:**

- FormatResult - Result with ok status, formatted code, and any errors

### format_issues

```teal
function format_issues(issues: {Issue}): string
```

 Format issues for human-readable output.
