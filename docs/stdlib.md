# Standard Library

the `cosmic.*` modules provide a typed, ergonomic layer over
Cosmopolitan Libc bindings:

```teal
local json = require("cosmic.json")
```

the module list is not maintained here — the binary renders it from its
own documentation index, so the list can never disagree with what ships:

```bash
cosmic --help                 # every module, one line each
cosmic --docs json            # one module's full docs
cosmic --docs sqlite.open     # one function
cosmic --examples json        # runnable examples for a module
```

(the same index drives the derived module table in
[AGENTS.md](../AGENTS.md); `bin/cosmic _docs/derive.tl` rewrites it.)

from the REPL:

```
$ cosmic -i
> help("json")
> help("fs.walk")
```

## Error Handling

what this page alone says is the doctrine — the type must admit
failure, and library code never throws:

- **fallible value**: `value | nil, string` — the primary pattern; the
  checker forces callers to narrow before use
- **fallible effect**: `boolean, string` — operations with nothing to
  return succeed `true` or fail `false, message`
- **result records**: complex operations with multiple error states
  return a record (`fetch.fetch`'s `ok`/`status`/`body`/`error`)
- **infallible**: encoding, compression, escaping return a bare value —
  no error channel to check

failed `cosmo.unix` calls carry a formatted message plus the numeric
errno; wrappers add context with `errno.wrap` and branch with
`errno.is`. the one throwing module is `cosmic.check` (tests and
examples only; D23).

each shape is runnable, and gated in CI:

```bash
cosmic --examples errors
```
