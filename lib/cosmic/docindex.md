# docindex

 Generate a serialized documentation index from source files.
 Run directly as a script with source files as arguments.

## Types

### DocIndexModule

```teal
local record DocIndexModule
  generate: function(files: {string}): string, string
  main: function(args: {string}): integer
end
```

## Functions

### generate

```teal
function generate(files: {string}): string, string
```

 Generate serialized documentation index from source files.
 Merges examples from _example.tl files into their corresponding modules.

**Parameters:**

- `files` (List) - of .tl or .d.tl file paths to process

**Returns:**

- Encoded - Lua source for the index, or nil on error
- Error - message if generation failed

### main

```teal
function main(args: {string}): integer
```
