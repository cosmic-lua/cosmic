# Why the checker works the way it does

why cosmic has two type layers, why a `| nil` annotation is only half
enforced, and why `--check types` never runs the file it checks. for a
reader who wants to understand the type system, not operate it.

## two layers

a cosmic program sees two families of modules. `cosmo.*` is the C
binding layer of Cosmopolitan Libc: `cosmo.unix`, `cosmo.path`,
`cosmo.lsqlite3` and the rest. `cosmic.*` is the typed Teal wrapper
layer with error handling and documentation.

the `cosmo.*` declarations are generated, not written. the binding
annotations live in one place, `tool/net/definitions.lua` in the
cosmopolitan fork, and a generator turns them into `.d.tl` records at
build time. the declarations therefore say exactly what the C code
says. the cost is that a fresh clone has no `cosmo.*` types until it
has fetched and built once.

the `cosmic.*` layer exists because a C binding's contract is thin. a
binding returns `nil, err, errno` in three slots, or throws on an
argument-shape error, or returns an integral value as `integer`. the
wrapper turns that into the two-slot shape every module shares: a
fallible value is `T | nil, string`, a fallible effect is
`boolean, string`, an infallible function returns a bare value.
`cosmic --docs explanation.errors` has the reasoning for the shape.
user code imports `cosmic.*`; `cosmo.*` is for the wrappers.

## a `| nil` annotation is half a contract

a `| nil` return says the call can fail. the reader expects the checker
to force a guard on every caller. it does not. the checker demands a
guard in exactly one position, an index. an unnarrowed `T | nil`
passes into a non-nil parameter, an arithmetic operator, a
concatenation, and an assignment to a declared non-nil type, and the
checker says nothing.

so a caller that never indexes the value can carry a nil a long way.
`local n: integer = size_of(path)` compiles, and `n` is declared
`integer` while it may hold nil. the annotation told the truth; the
checker only enforced it at the point where a nil would make Lua throw
on a table access.

the consequence is where a guard belongs. guard where the union is
produced, at the call that can fail, and give the rest of the function
a plain `T`. do not rely on the annotation to push a guard out of every
downstream use. `cosmic --docs reference.narrowing` lists the position
that demands a guard and the positions that admit the union.

## why the checker narrows more than upstream Teal

the checker cosmic ships is the pinned Teal compiler plus a set of
carried patch entries. the narrowing entries teach the checker the
guards Lua programmers write: truthiness, `assert`, `x and x.field`,
`== nil`, an exiting branch, `x or fallback`. each entry makes more
correct programs check and stops none.

a record field is the deliberate exception. `if o.sub then o.sub.x end`
is not narrowed because a field can change between the guard and the
use: another function may assign it, and the checker does not track
who holds a reference to `o`. a local cannot change under the guard
unless a closure assigns it, and the checker handles that case by
widening the local again. copying the field to a local is the honest
form of the guard.

## why `--check types` never runs the file

`--check types` reads the source as text, applies the same augmentation
the compiler applies, and hands the text to the checker. nothing in the
checked file executes. a `package.loaded["tl"]` or
`package.preload["tl"]` assignment written inside the checked file is
therefore inert. it does not swap the checker, and the run reports the
shipped checker's verdict at exit 0 with nothing logged.

```text
$ cat probe.tl
package.loaded["tl"] = dofile("/nonexistent/stock/tl.lua")

local record R
  x: integer
end
local function make(): R | nil
  return nil
end
local r = make()
if not r then
  return
end
print(r.x)

$ cosmic --check types probe.tl
Type check passed: probe.tl
```

the `dofile` names a path that does not exist. the line never ran, so
it never threw, and the guarded index passed on the shipped narrowing.

a modified `tl.lua` placed on `package.path` is ignored for a related
reason. the binary's `/zip` searcher outranks the file searcher, so
`require("tl")` resolves to the copy the binary embeds. both forms
give a confident answer to a question they never asked.

## the checker always answers for itself

a verdict from `--check types` is a verdict about the running binary's
own patched checker, never about upstream Teal. that is the design: the
checker a project builds with and the checker a project checks with
are the same bytes, so a source that passes the check compiles.

the flip side is the cold-build rule. a source that needs a narrowing
rule only the tree's checker has passes the converged gate and fails
under the pinned release. such a change stages behind a release and a
pin bump. `cosmic --docs explanation.build` says why the gate
converges.

measuring a different checker is a contributor task with its own
recipe: swap the module in the checking process before the first
check, and ask the loaded module which bytes answered. the contributor
docs carry it as `docs/dev/howto/swap-checker.md`.
