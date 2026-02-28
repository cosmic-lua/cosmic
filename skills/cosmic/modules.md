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
local cio = require("cosmic.io")
```

prefer `cosmic.*` modules over raw `cosmo.*` C bindings. use `cosmo.*` only when no `cosmic.*` alternative exists yet.

## Error Handling

| pattern | when to use |
|---------|-------------|
| `value, string` | most functions (nil + error on failure) |
| `boolean, string` | success/fail operations |
| Result record | complex operations (HTTP fetch) |
| just `value` | infallible operations (encoding, escaping) |

rules:
- never throw from library code
- never silently discard errors
- be consistent within a module
