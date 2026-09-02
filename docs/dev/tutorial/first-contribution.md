# your first contribution

clone cosmic, build it, add a small public module with its test and its
example, pass the gate under the binary you built, and open a pull
request. for a reader who has `git`, `curl`, `gh` and a POSIX shell and
has never built cosmic. the whole page takes about twenty minutes.

## 1. clone and fetch

```bash
git clone https://github.com/cosmic-lua/cosmic
cd cosmic
bin/cosmic --make fetch
```

`bin/cosmic` is a shell script. on a cold tree it downloads the one
cosmic release named in `bin/cosmic.pin`, checks its sha256, and runs
it. `fetch` resolves the two pins under `3p/` and unpacks them into
`o/3p/cosmos/` and `o/3p/tl/`. it is the only verb that uses the
network.

## 2. build

```bash
bin/cosmic --make build
# build: PASS
```

the build generates the `cosmo.*` type declarations into
`o/_types/types_gen/`, compiles every `.tl` file, and writes
`o/bin/cosmic`. that binary is the one you test with from here on.
`bin/cosmic` runs it too, once it exists.

## 3. run the gate

```bash
o/bin/cosmic --make ci
# ci: PASS
```

`ci` runs five stages in order: formatting, types, examples, lint, and
the tests with coverage. run it once on the clean tree, so a later
failure is yours.

## 4. make a branch

```bash
git checkout -b add-mymod
```

## 5. write the module

create `cosmic/mymod.tl`. a file at `cosmic/<name>.tl` is the public
module `cosmic.<name>`. the header is a `---` doc comment, and its
first line is the description `cosmic --docs` lists. the public
surface is one record, returned at the bottom of the file:

```teal file=cosmic/mymod.tl
--- Widgets: named things with a size.
--- The smallest module with the shape every `cosmic.*` module has.

--- The module's public surface.
local record MyModule
  --- A named thing with a size.
  record Widget
    name: string
    size: integer
  end
  new: function(name: string, size: integer): Widget
end

local type Widget = MyModule.Widget

--- Create a widget.
--- @param name string The widget's name
--- @param size integer The widget's size
--- @return Widget The new widget
local function new(name: string, size: integer): Widget
  return {name = name, size = size}
end

local M: MyModule = {
  new = new,
}

return M
```

check the file on its own:

```bash
o/bin/cosmic --check types cosmic/mymod.tl
# Type check passed: cosmic/mymod.tl
```

## 6. write the test

create `cosmic/mymod_test.tl`. a test is a top-level `local function`
whose name starts with `test_`. the compile step finds every such
function and calls each one in source order. do not call it yourself:

```teal file=cosmic/mymod_test.tl
#!/usr/bin/env cosmic
local mymod = require("cosmic.mymod")

local function test_new()
  local w = mymod.new("bolt", 42)
  assert(w.name == "bolt", "got: " .. w.name)
  assert(w.size == 42, "got: " .. tostring(w.size))
end
```

run it:

```bash
o/bin/cosmic --make test cosmic/mymod_test.tl
# test: PASS
```

## 7. write the example

create `cosmic/mymod_example.tl`. an `Example_*` function prints, and
its `-- Output:` block says what it prints. the example runner compares
the two:

```teal file=cosmic/mymod_example.tl
--- Examples for the cosmic.mymod module.

-- Example_new makes one widget and prints it.
local function Example_new()
  local mymod = require("cosmic.mymod")
  local w = mymod.new("bolt", 42)
  print(string.format("%s %d", w.name, w.size))
  -- Output:
  -- bolt 42
end

local _ = {Example_new}
```

the last line keeps the checker quiet. an unused local is an error, and
the runner finds `Example_new` by name, not through a call.

run it:

```bash
o/bin/cosmic --check example cosmic/mymod_example.tl
```

## 8. record the new public name

every `cosmic.<name>` is a promise, so a gate holds the set of public
names against `_build/public_surface_baseline.tl`. rewrite the set so
it carries `cosmic.mymod`:

```bash
o/bin/cosmic --make run _build/public_surface.tl --baseline
git diff _build/public_surface_baseline.tl
```

the diff is one added line.

## 9. record the coverage floor

the coverage stage compares every file against `.cosmic-coverage`. a
new file has no row there, and the stage refuses a file it has no floor
for. write the floor:

```bash
o/bin/cosmic --make coverage --baseline
git diff .cosmic-coverage
```

read the diff like any other change: three new rows, one per file you
wrote.

## 10. run the gate again

```bash
o/bin/cosmic --make ci
# ci: PASS
```

the gate rebuilt the binary before it ran, so `o/bin/cosmic` now
carries your module. read the page your doc comments make:

```bash
o/bin/cosmic --docs mymod
```

## 11. commit and open the pull request

```bash
git add cosmic/mymod.tl cosmic/mymod_test.tl cosmic/mymod_example.tl
git add _build/public_surface_baseline.tl .cosmic-coverage
git commit -m "cosmic.mymod: widgets, with a test and an example"
git push -u origin add-mymod
gh pr create --fill
```

CI runs four lanes on the pull request. the `ci` lane runs the same
`--make ci` you ran, with the network turned off.
[reference/ci.md](../reference/ci.md) has all four.

this pull request is practice. close it when the four lanes report,
and delete the branch. your next one carries a real change and follows
the same path.

## when a step fails

- a type error names the file, the line, and the types. `--check types`
  treats a warning as an error, so an unused local fails. give a
  deliberately unused value a name that starts with `_`.
- a formatting failure prints a have/want diff. run
  `o/bin/cosmic --fix cosmic/mymod.tl` and commit the result.
- a lint failure names its rule. `o/bin/cosmic --docs reference.lint`
  has every rule and its fix.
- the public-surface test names a `cosmic.*` module the baseline does
  not have. step 8 is the fix.
- the coverage stage says a file is `not in baseline`. step 9 is the
  fix.

## what you learned

- `bin/cosmic` reaches for the pinned release only on a cold tree. the
  gate runs under `o/bin/cosmic`, the binary the tree builds.
- a public module is a position, `cosmic/<name>.tl`. its surface is a
  record returned at the bottom of the file.
- a test is defined, not called. an example prints what its
  `-- Output:` block says.
- two committed floors move with a new module: the public surface and
  the coverage baseline.

## next

- [howto/add-module.md](../howto/add-module.md) has the rules for a
  real module: position, error shapes, and what the ratchets check.
- [explanation/bootstrap.md](../explanation/bootstrap.md) says why
  building cosmic needs a cosmic.
- `cosmic --docs howto.test` covers `TEST_TMPDIR`, the test sandbox,
  and the `cosmic.check` assertions.
