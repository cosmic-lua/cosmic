# Measure a different checker

how to run a type check against a checker other than the one the
binary ships, and prove which bytes answered. for a contributor working
on a carried tl patch entry.

`cosmic --check types` always answers from the running binary's own
patched checker, and it never runs the file it checks. a
`package.loaded["tl"]` line inside the checked file is inert, and a
`tl.lua` on `package.path` loses to the `/zip` searcher.
[explanation/types](../../explanation/types.md) says why. a probe
therefore swaps the checker inside the checking process, before the
first check.

## 1. name the entries to reverse

1. open the patch set in `3p/tl/tl_patch/`. each file returns named
   entries; the narrowing entries are in `narrow.tl`.

2. note the entry names the probe measures without, for example
   `narrow-truthiness`.

3. confirm the unpack directory is patched. `_make.patch`'s `reverse`
   refuses when an entry's `replace` text is not present exactly once
   in `o/3p/tl/tl.lua`, and its message says to run `--make fetch`.

## 2. write the probe

1. save `package.loaded["tl"]` when the process outlives the probe.
   `reverse` does not restore it.

2. call `reverse` with the pin, the unpack directory, the entries, the
   file, and the module name. it reverses the entries into a copy in
   a fresh temporary directory (under `TEST_TMPDIR` when set) and
   installs the copy in `package.loaded["tl"]`. `require` reads that
   table before any searcher, so `cosmic.teal.check` answers from the
   copy.

3. check a source string with `cosmic.teal.check` and compare the
   messages against the shipped verdict.

4. put the saved module back.

```teal
local patch = require("_make.patch")
local teal = require("cosmic.teal")

local src = [==[
local record R
  x: integer
end
local function f(r: R | nil): integer
  if not r then
    return 0
  end
  return r.x
end
return f
]==]

local shipped = teal.check(src, {chunk_name = "probe.tl"})
print("shipped errors:", #shipped.errors)

local saved = package.loaded["tl"]
local raw, err = patch.reverse({
    pin = "3p/tl/tl_pin.tl",
    dir = "o/3p/tl",
    entries = {"narrow-truthiness"},
    file = "tl.lua",
    module_name = "tl",
  })
if raw == nil then
  print("reverse failed: " .. tostring(err))
  return
end
local reversed = teal.check(src, {chunk_name = "probe.tl"})
package.loaded["tl"] = saved
for _, issue in ipairs(reversed.errors) do
  print("reversed:", issue.message)
end
```

the gated form of this probe is `_make/patch_test.tl`, in
`test_reverse_flips_the_checker_on_the_real_pin` and
`test_reverse_flips_the_metatable_value_type`. copy those; do not
re-derive them.

## 3. prove which bytes answered

ask the loaded module for the source of one of its functions:

```text
debug.getinfo(require("tl").process_string, "S").source
--> @/zip/tl.lua                       the shipped copy
--> @/tmp/patch-reverse-XXXXXX/tl.lua  a reversed copy
```

print that line before and after `reverse` in the probe. a probe that
prints `@/zip/tl.lua` after the swap measured the shipped checker.

## 4. run the probe under `--make run`

run the probe against the tree, from the repo root:

```bash
bin/cosmic --make run probe.tl
```

`--make run` builds first and resolves `require("_make.patch")` to the
tree's `_make/patch.tl`. a bare `cosmic probe.tl` resolves the same
require to `@/zip/_make/patch.lua`, the binary's embedded copy, even
from the repo root, because the `/zip` searcher outranks the file
searcher. the embedded copy may not carry the change under test.

## 5. read the result

1. compare the shipped and reversed error lists. an entry that narrows
   shows as zero errors shipped and at least one `cannot index key`
   reversed.

2. when both lists agree, the entry did not decide this source. pick a
   source the entry's `note` describes, or check that the entry name
   is the one the source exercises.

the census of nil-flow sites the narrowing entries were measured
against is [explanation/nil-flow](../explanation/nil-flow.md); the
cast census is [explanation/casts](../explanation/casts.md).
