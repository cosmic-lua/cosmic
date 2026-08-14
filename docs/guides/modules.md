# Modules

use `cosmic --docs` to browse the full list of available modules and their APIs.

```bash
cosmic --docs              # list all modules
cosmic --docs json         # look up a specific module
cosmic --docs fs.join      # look up a specific function
```

## Importing Modules

all standard library modules are imported as `cosmic.*`:

```teal
local json = require("cosmic.json")
local fs = require("cosmic.fs")

print((json.encode({ok = true})))
print(fs.join("a", "b"))
```

prefer `cosmic.*` modules over raw `cosmo.*` C bindings. use `cosmo.*` only when no `cosmic.*` alternative exists yet.

## Local Modules — `require` path resolution

`require("mymod")` resolves relative to the script's directory, not the
current working directory. you do not need a `./` prefix (both work).

```teal
-- both are equivalent when mymod.tl is in the same directory:
local m = require("mymod")
local m2 = require("./mymod") -- also works
print(m.value, m2.value)
```

if your module is in a subdirectory:
```teal
local m = require("subdir.mymod") -- loads subdir/mymod.tl
print(m.value)
```

## Error Handling

| pattern | when to use |
|---------|-------------|
| `value, string` | most functions (nil + error on failure) |
| `boolean, string` | success/fail operations |
| `value, Error record` | structured failures (`fetch.Error`: branch on `err.kind`, render with `tostring(err)`) |
| just `value` | infallible operations (encoding, escaping) |

rules:
- never throw from library code
- never silently discard errors
- be consistent within a module
