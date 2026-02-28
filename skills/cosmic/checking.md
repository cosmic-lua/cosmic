# Type Checking

cosmic uses Teal's strict mode for type checking. all type errors must be resolved before code is merged.

## Running Type Checks

```bash
cosmic --check-types file.tl    # check a single file
cosmic --make . check           # generate Makefile and type-check all files
make check                      # if you have a saved Makefile
```

`--check-types` runs Teal in strict mode. it reports errors and warnings on stderr. exit code 0 means the file passes.

### Makefile Rules for Type Checking

`cosmic --make` generates this check rule (see `cosmic --skill make` for the full Makefile):

```makefile
## Type-check all source and test files
check: $(sources) $(tests) $(examples)
	@for f in $^; do \
	  echo "check $$f"; \
	  $(COSMIC) --check-types $$f || exit 1; \
	done
```

## Type Annotations

### Basic Types

```teal
local x: number = 42
local name: string = "hello"
local flag: boolean = true
local items: {string} = {"a", "b"}        -- array of strings
local map: {string: number} = {x = 1}     -- map
```

### Optional Types

```teal
local function read(path: string, size?: number): string, string
  -- size is optional (may be nil)
end

local value: string = nil  -- ERROR: string cannot be nil
```

use `?` on parameters to make them optional. for nullable local variables, use the nil-returning pattern from the function signature.

### Type Casting

use `as` to cast between types when you know more than the type checker:

```teal
local result = json.decode(input) as {string: any}
local errno = err as Errno
local count = value as integer
```

### Record Types

records define structured data with typed fields and methods:

```teal
local record Point
  x: number
  y: number
end

local record Handle
  pid: number
  wait: function(self: Handle): number, string
  read: function(self: Handle, size?: number): string, string
end
```

### Module Interface Records

every module declares its public API as a record:

```teal
local record JsonModule
  decode: function(str: string): any, string
  encode: function(value: any): string, string
end

local M: JsonModule = { decode = decode, encode = encode }
return M
```

### Function Types

```teal
-- standalone
local function add(a: number, b: number): number
  return a + b
end

-- multiple return values (the value, error pattern)
local function parse(s: string): number, string
  local n = tonumber(s)
  if not n then
    return nil, "not a number"
  end
  return n
end

-- generic functions
local function identity<T>(x: T): T
  return x
end
```

### Global Declarations

test files may declare globals that come from the test environment:

```teal
global TEST_TMPDIR: string
global TEST_BIN: string
```

## Common Type Errors

**"cannot use nil"**: Teal strict mode requires handling nil. check return values:

```teal
-- WRONG: data might be nil
local data = cio.slurp(path)
print(#data)  -- error if data is nil

-- RIGHT: handle the nil case
local data, err = cio.slurp(path)
if not data then
  error("read failed: " .. err)
end
print(#data)
```

**"unknown variable"**: all variables must be declared with `local` or `global`.

## Include Directories

`cosmic --check-types` searches for type definitions in the binary's bundled paths. if your project has its own `.d.tl` type definitions, place them in a `types/` directory and they will be found automatically.
