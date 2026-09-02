# Add a public module

steps to add a `cosmic.<name>` module to the standard library, for a
contributor who has built the tree once.
[tutorial/first-contribution.md](../tutorial/first-contribution.md)
walks the same path with every file shown.

## 1. choose the position

position is the whole manifest. no list of modules exists to edit.

| file | module | visibility |
|---|---|---|
| `cosmic/<name>.tl` | `cosmic.<name>` | public |
| `cosmic/<name>/init.tl` | `cosmic.<name>` | public; a directory module |
| `cosmic/<name>/<part>.tl` | `cosmic.<name>.<part>` | a shard; only files under `cosmic/` may require it |
| `cosmic/_<name>.tl` | `cosmic._<name>` | internal to `cosmic/` |
| `cosmic/<name>/_<part>.tl` | `cosmic.<name>._<part>` | internal to `cosmic/<name>/` |

1. put a module that fits in one file at `cosmic/<name>.tl`.
2. put a module that needs several files at `cosmic/<name>/init.tl`,
   with its shards beside it. split before 500 lines. the lint gate
   refuses a longer file.
3. name the module in `snake_case`, spelled out.
   `cosmic --docs reference.conventions` has the naming rules.

`is_public` in `cosmic/doc/visibility.tl` is the rule that decides
visibility: public is exactly `cosmic.<name>` for one segment that does
not start with `_`. two consequences bind a module under `cosmic/`:
nothing outside `cosmic/` may require a shard or an internal module,
and nothing under `cosmic/` may require a module outside `cosmic/`,
because `cosmic/**` is the floor a stripped artifact boots with.

## 2. write the header

1. start the file with a `---` doc comment. its first line is the
   description; `cosmic --docs` lists it beside the module name.
2. write the description as one noun phrase with a full stop, and the
   rest of the header as the paragraph a reader needs before the
   signatures.

```teal
--- Widgets: named things with a size.
--- The smallest module with the shape every `cosmic.*` module has.
--- A widget is a value; this module never touches the filesystem.

local record MyModule
  record Widget
    name: string
    size: integer
  end
  new: function(name: string, size: integer): Widget
end

local function new(name: string, size: integer): MyModule.Widget
  return {name = name, size = size}
end

local M: MyModule = {
  new = new,
}

return M
```

## 3. declare the records and the functions

1. declare a record for each value the module trades in. nest a record
   the caller names inside the interface record, so `mymod.Widget` is
   a type the caller can write.
2. doc-comment every record, field and function with `---`. a function
   comment is one sentence, then one `@param` per parameter and one
   `@return` per return slot.
3. use `cosmo.*` only to implement a wrapper. a library internal is the
   one place `require("cosmo")` belongs.
4. give a deliberately unused value a name that starts with `_`. the
   checker treats a warning as an error.

## 4. pick the error shape

1. choose one shape for the module and use it throughout.

   | the function | returns |
   |---|---|
   | produces a value and can fail | `T \| nil, string` |
   | performs an effect and can fail | `boolean, string` |
   | fails with structure the caller branches on | `T \| nil, <Module>.Error`, its own error record in slot 2 |
   | cannot fail (encoding, escaping, formatting) | the bare value |

2. keep a fallible return to two slots. the `fallible-returns` lint
   refuses a third. extra facts ride on the value's record.
3. never throw from library code. never discard an error.

`cosmic --docs reference.errors` has the complete table, `cosmic
--examples errors` runs each shape, and `cosmic --docs
explanation.errors` says why.

```teal
--- Widget parsing.
--- Parse "name:size" text into a widget.

local record ParseModule
  record Widget
    name: string
    size: integer
  end
  parse: function(text: string): Widget | nil, string
end

--- Parse "name:size" into a widget.
--- @param text string The input
--- @return Widget|nil The widget, nil when the text is malformed
--- @return string The error message
local function parse(text: string): ParseModule.Widget | nil, string
  local name, digits = text:match("^(%w+):(%d+)$")
  if not name then
    return nil, "expected name:size, got " .. text
  end
  return {name = name, size = math.tointeger(tonumber(digits))}
end

local M: ParseModule = {
  parse = parse,
}

return M
```

## 5. return the interface record

1. declare one record that names exactly the public surface: each
   function's type, and each record a caller names.
2. build one table typed as that record and return it. a function the
   record does not name is private, whatever its `local` says.

## 6. write the test and the example beside it

1. create `cosmic/<name>_test.tl` in runner mode: top-level `test_*`
   functions, never called. `cosmic --docs howto.test` has the rules,
   `TEST_TMPDIR` and the sandbox.
2. create `cosmic/<name>_example.tl` with `Example_*` functions, each
   ending in an `-- Output:` block. `cosmic --docs howto.examples` has
   the shape.
3. write tests and examples against `cosmic.*`, never `cosmo.*`.

## 7. move the two floors

1. rewrite the public surface set. `_build/public_surface_test.tl`
   holds the tree against `_build/public_surface_baseline.tl` in both
   directions, so a new name fails until the set carries it:

   ```bash
   o/bin/cosmic --make run _build/public_surface.tl --baseline
   ```

2. rewrite the coverage floor. a file with no row in `.cosmic-coverage`
   fails the coverage stage with `not in baseline`:

   ```bash
   o/bin/cosmic --make coverage --baseline
   ```

3. commit both files with the module.

## 8. run the gate and read the page

1. run the gate under the binary the tree builds:

   ```bash
   bin/cosmic --make build && o/bin/cosmic --make ci
   ```

2. read the rendered reference:

   ```bash
   o/bin/cosmic --docs <name>
   ```

   the header and every `---` comment appear there.
   `cosmic/surface_test.tl` asserts that each public module embedded in
   the binary loads and is documented.
