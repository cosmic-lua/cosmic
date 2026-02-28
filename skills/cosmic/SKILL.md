# cosmic

cosmic is a batteries-included Lua distribution built on Cosmopolitan Libc. it produces fat-binary executables that run on Linux, macOS, Windows, FreeBSD, OpenBSD, and NetBSD from a single file. the source language is Teal (typed Lua) compiled to Lua 5.4.

## Quick Reference

source files use the `.tl` extension. formatting is 2-space indent, LF line endings. all `.tl` files must be <=500 lines.

```bash
cosmic script.tl              # run a Teal script
cosmic --check-types file.tl  # type check (strict)
cosmic --check-format file.tl # check formatting
cosmic --format file.tl       # format to stdout
cosmic --test <out> <cmd>     # run test, capture output
cosmic --docs [query]         # search documentation
```

## Language Essentials

naming: `snake_case` for functions/variables, `PascalCase` for record types. doc comments use `---` prefix with `@param` and `@return` tags.

error handling: return `value, string` (nil + error message on failure). never throw from library code.

imports: use `cosmic.*` modules (not raw `cosmo.*` C bindings).

```teal
local json = require("cosmic.json")
local data, err = json.decode(input)
if not data then
  io.stderr:write("error: " .. err .. "\n")
  os.exit(1)
end
```

## Module Pattern

```teal
--- Brief module description.
local cosmo = require("cosmo")

--- A record type.
local record Widget
  name: string
  size: number
end

--- Create a widget.
--- @param name string The widget name
--- @param size number The widget size
--- @return Widget
local function new(name: string, size: number): Widget
  return { name = name, size = size }
end

local record MyModule
  new: function(name: string, size: number): Widget
end

local M: MyModule = { new = new }
return M
```

## Dual-Use Modules

use `proc.is_main()` to write files that work as both scripts and importable modules:

```teal
local proc = require("cosmic.proc")
local function greet(name: string): string
  return "hello, " .. name
end
if proc.is_main() then
  print(greet(arg[1] or "world"))
end
return { greet = greet }
```

## Detailed Guides

run `cosmic --skill <topic>` or see the files below for deeper coverage:

- [testing](testing.md) — writing and running tests (`cosmic --test`, assert patterns)
- [checking](checking.md) — type checking with `cosmic --check-types`
- [formatting](formatting.md) — code formatting with `cosmic --format` / `--check-format`
- [makefile](makefile.md) — Makefile patterns and build targets
- [modules](modules.md) — the standard library (`cosmic.*` modules)
- [docs](docs.md) — accessing documentation and getting help
