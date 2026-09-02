# Run the type checker

how to type-check one file, a whole project, or a subtree, and read
the result. for a reader who has a `.tl` file and a cosmic binary.

## check one file

1. run the checker on the file:

   ```bash
   cosmic --check types main.tl
   # Type check passed: main.tl
   ```

2. read the exit code. `0` means the file passes. `1` means at least
   one error or warning. every issue prints on stderr as
   `file:line:col: error: <message>`, often with a `hint:` line under
   it.

3. fix every line the checker names, then run the command again.

`cosmic --docs howto.type-errors` lists the common messages and their
fixes.

## check a whole project

1. run the check verb from anywhere inside the project:

   ```bash
   cosmic --make check
   ```

2. read the verdict line at the end of the output:

   ```text
   make: root=/home/you/myapp
   check: PASS (12 files)
   ```

   `check: FAIL (2 of 12 files)` names the count that failed. the
   issues themselves print on stderr above the verdict.

3. read the exit code when a script runs the check. `0` is PASS, `1` is
   FAIL. do not pipe the command into `tail`; the pipe returns
   `tail`'s status.

`--make check` validates the project's shape first. an import path or
a filename the project model refuses prints as a validation error and
the verdict is `check: FAIL (1 validation error)`.
`cosmic --docs howto.build` has the project rules.

## check a subtree

1. add one or more paths after the verb:

   ```bash
   cosmic --make check db/
   cosmic --make check cosmic/string.tl cosmic/fs/
   ```

2. read the verdict the same way. the count is the number of files the
   selection holds.

## clear a warning

warnings are errors. an unused local, a shadowed name, or an unused
argument fails the check.

1. read the warning:

   ```text
   main.tl:6:7: warning: unused variable out: string
   ```

2. remove the value if nothing needs it.

3. keep the value and prefix its name with `_` when the position is
   required, for example a discarded return or an unused `self`:

   ```teal
   local fs = require("cosmic.fs")

   local record Poller
     close: function(self: Poller)
   end

   local _out, err = fs.read("notes.txt")
   local p: Poller = {
     close = function(_self: Poller)
     end,
   }
   p:close()
   print(err)
   ```

4. rename a local that shadows a Lua builtin such as `load`, `type`, or
   `error`. the warning reads
   `function shadows previous declaration of 'load'`.

## find a project's own `.d.tl` files

`--check types` on one file searches the binary's bundled paths and the
current directory. it does not search other directories on its own.

1. pass each directory that holds `.d.tl` declarations with
   `--include-dir`. the flag repeats:

   ```bash
   cosmic --include-dir types --check types main.tl
   ```

2. under `--make check` no flag is needed. the project root is the
   module root, so a `types/ext.d.tl` in the project resolves as
   `require("types.ext")` and a `ext.d.tl` at the root as
   `require("ext")`.

## compile with the same strictness

`--compile-strict` runs the same check before it writes Lua to stdout:

```bash
cosmic --compile-strict main.tl > main.lua
```

`cosmic --docs explanation.types` says which checker answers and why
the checked file never runs.
