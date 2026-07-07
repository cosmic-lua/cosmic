# run

 Script execution helpers for the cosmic CLI.
 Provides require-hint augmentation for compile-time errors and
 user-facing traceback trimming for runtime errors.

## Types

### RunModule

```teal
local record RunModule
  augment_module_errors: function(err: string): string
  trim_traceback: function(err: any): string
end
```

## Functions

### augment_module_errors

```teal
function augment_module_errors(err: string): string
```

 Augment a Teal compile-time error message with require hints.
 When Teal reports "module not found: 'x'", appends the same Did-you-mean
 suggestions produced by the runtime hint engine so users see them
 regardless of whether the error is detected at compile or run time.
 Returns the original message unchanged when hints are disabled or
 no suggestion is available.

**Parameters:**

- `err` (string) - Compile error message (may be multi-line)

**Returns:**

- string - Possibly augmented error message

### trim_traceback

```teal
function trim_traceback(err: any): string
```

 Build a traceback for user-visible errors, trimming internal frames.
 Strips frames at and below the cosmic entry point (/zip/main.lua) so users
 see only their own stack. Set COSMIC_FULL_TRACEBACK=1 to disable trimming.

**Parameters:**

- `err` (any) - The error value

**Returns:**

- string - Trimmed traceback string
