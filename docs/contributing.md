# Contributing

## Development Setup

```bash
git clone https://github.com/whilp/cosmic
cd cosmic
bin/make build    # downloads bootstrap, fetches deps, builds cosmic
bin/make test     # run tests
```

`bin/make` is a shell script that, on first run, downloads the sha-pinned bootstrap cosmic and uses it to extract `make` from the sha-pinned cosmos.zip (`_build/make-boot.tl`). all build artifacts go to `o/`.

## Workflow

1. create a branch from `main`
2. make changes to `.tl` files in `cosmic/`
3. run checks:
   ```bash
   bin/make format        # check formatting
   bin/make teal          # type check
   bin/make test          # run tests
   ```
4. open a PR against `main`

CI runs `make ci` which includes format + teal + test + example checks.

## Writing a Module

create `cosmic/mymod.tl`:

```teal
--- Brief module description.
--- Longer explanation of what this module does.

--- A useful record type.
local record Widget
  name: string
  size: number
end

--- Create a new widget.
--- @param name string The widget name
--- @param size number The widget size
--- @return Widget The new widget
local function new(name: string, size: number): Widget
  return { name = name, size = size }
end

local record MyModule
  new: function(name: string, size: number): Widget
end

local M: MyModule = {
  new = new,
}

return M
```

create `cosmic/mymod_test.tl`:

```teal
#!/usr/bin/env cosmic
local mymod = require("cosmic.mymod")

local function test_new()
  local w = mymod.new("test", 42)
  assert(w.name == "test")
  assert(w.size == 42)
end
test_new()
```

the test file must have a shebang line and call test functions directly.

## Writing Examples

create `cosmic/mymod_example.tl`:

```teal
local function Example_basic()
  local mymod = require("cosmic.mymod")
  local w = mymod.new("hello", 10)
  print(w.name, w.size)
  -- Output:
  -- hello	10
end

local _ = Example_basic
```

functions named `Example_*` are discovered and run by `cosmic --check examples`. the `-- Output:` comment block is compared against actual stdout.

## Error Handling Rules

see `AGENTS.md` for the complete guide. key rules:

- return `value, string` for fallible operations
- never throw exceptions from library code
- never silently discard errors
- be consistent within a module

## Formatting

cosmic enforces formatting via `cosmic --check format`:

- 2-space indent
- LF line endings
- consistent spacing

run `cosmic --format file.tl` to see the formatted output. the check compares original against formatted and reports the first differing line.

## Type Checking

cosmic uses Teal's strict mode for type checking:

```bash
cosmic --check types cosmic/mymod.tl
```

all type errors must be resolved. warnings are reported but don't fail the build.

## Adding a 3p Dependency

1. create `3p/mylib/mylib_pin.tl` — a **pin**: one `return { … }` of
   literals, read as data by `cosmic.literal` and never executed, so a
   file that declares a dependency cannot also do anything:
   ```lua
   return {
     version = "1.0.0",
     format = "tar.gz",
     strip_components = 1,
     url = "https://github.com/org/repo/releases/download/v{version}/archive.tar.gz",
     platforms = {
       ["*"] = { sha = "..." },
     },
   }
   ```

   `url` and a digest are required — a pin without one is a download.
   `{version}` (and `{platform}`) substitution is the only templating
   the grammar allows, which is what makes a bump a one-line diff. A
   digest that is the same everywhere goes under `platforms["*"]`; one
   that differs per host gets a row per `os-arch` tag. `format` (with
   `strip_components`) unpacks the archive after the digest matches —
   never before, since an archive is a program for a decompressor.

2. create `3p/mymk/modules.mk`:
   ```makefile
   modules += mylib
   mylib_version := 3p/mylib/mylib_pin.tl
   ```

3. include in `Makefile`:
   ```makefile
   include 3p/mymk/modules.mk
   ```

4. declare dependency from your module:
   ```makefile
   mymod_deps := mylib
   ```
