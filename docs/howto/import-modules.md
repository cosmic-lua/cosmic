# Import modules

steps for importing a standard library module or a module of your own, for a reader
writing a script.

## import a standard library module

every standard library module imports as `cosmic.<name>`.

```teal
local json = require("cosmic.json")
local fs = require("cosmic.fs")

print((json.encode({ok = true})))
print(fs.join("a", "b"))
```

`cosmic --docs` lists every module. `cosmic --docs cosmic.fs` has one module's
signatures. `cosmic --docs howto.find-docs` has the other lookups.

prefer a `cosmic.*` module over a `cosmo.*` binding. `cosmo.*` is the low-level C
surface the `cosmic.*` modules wrap. use it only when no `cosmic.*` module covers
the call. a test or an example that requires `cosmo` fails lint.

## import a local module

`require` resolves a local module against the script's own directory, not the
current working directory.

1. put `mymod.tl` beside the script.
2. require it by name. the `./` prefix is accepted and means the same thing.

```teal
local m = require("mymod")
local m2 = require("./mymod")
print(m.value, m2.value)
```

a module in a subdirectory is required with dots for the path separators.

```teal
local m = require("subdir.mymod") -- loads subdir/mymod.tl
print(m.value)
```

## write a module that also runs as a script

`proc.is_main()` is true when the file is the script cosmic ran, and false when
another file required it.

1. define the module's functions.
2. guard the script behaviour with `if proc.is_main() then`.
3. return the module table last.

```teal
local proc = require("cosmic.proc")

local function greet(name: string): string
  return "hello, " .. name
end

if proc.is_main() then
  print(greet(arg[1] or "world"))
end

return {greet = greet}
```

run it as `cosmic greet.tl ada` and it prints. require it and it returns the table.
