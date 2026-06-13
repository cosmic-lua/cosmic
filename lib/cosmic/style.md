# style

 Style-check module for cosmic --check-style.
 Mirrors the relevant parts of lib/build/lint.tl but is embedded in the
 cosmic binary under the cosmic.* namespace so require("cosmic.style") works.

## Types

### Diagnostic

```teal
local record Diagnostic
  file: string
  line: integer
  col: integer
  rule: string
  message: string
end
```

## Functions

### right

```teal
function right(path: string): {Diagnostic}
```
