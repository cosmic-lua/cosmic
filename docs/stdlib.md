# Standard Library

the `cosmic.*` modules provide a typed, ergonomic layer over
Cosmopolitan Libc bindings:

```teal
local json = require("cosmic.json")
print((json.encode({ok = true})))
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
> help("fs.visit")
```

## Error Handling

what this page alone says is the doctrine — the type must admit
failure, and library code never throws:

- **fallible value**: `value | nil, string` — the primary pattern; callers
  must narrow before use, which the checker makes them do at an index and
  nowhere else
- **fallible effect**: `boolean, string` — operations with nothing to
  return succeed `true` or fail `false, message`
- **structured errors**: a module whose failures carry structure
  returns its own error record in slot 2 (`fetch.fetch` returns
  `Response | nil, fetch.Error`); branch on the typed field
  (`err.kind`), render with `tostring(err)`
- **infallible**: encoding, compression, escaping return a bare value —
  no error channel to check

failed `cosmo.unix` calls carry a formatted message plus the numeric
errno; wrappers add context with `errno.format` and branch with
`errno.is_code`. the one throwing module is `cosmic.check` (tests and
examples only).

each shape is runnable, and gated in CI:

```bash
cosmic --examples errors
```
