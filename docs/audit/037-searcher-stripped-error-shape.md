# 037 — in a stripped artifact the searcher turns every require miss into a `tl` error

severity: medium (every stripped artifact; wrong errors, broken searcher contract)
type: bug
area: `cosmic/searcher.tl`

## issue

`cosmic.searcher` is installed at boot by the generated embed wrapper in
**every** artifact anyone builds. the module itself loads dependency-free
by design — the docstring promises "runs that never touch a .tl file
never load the ~15k-line Teal compiler" — but the lazy
`require("cosmic.teal")` sits at the *top* of the searcher function,
**before** the module search. `cosmic.teal` requires `tl` at top level
(`cosmic/teal.tl:8`), and stripped artifacts do not carry `tl.lua`.

consequence: in a stripped artifact, *any* `require()` that reaches the
cosmic searcher — i.e. any module the default searchers cannot resolve —
throws `module 'tl' not found` from inside the searcher, instead of the
searcher returning a miss string. that breaks two things:

1. **error truthfulness.** `require("nosuchmod")` in a stripped artifact
   reports a missing Teal compiler, not a missing `nosuchmod`. a typo'd
   module name, a misspelled asset path, any ordinary miss — all
   masquerade as "this binary lacks tl".
2. **the `package.searchers` contract.** a searcher that cannot help is
   supposed to return a string so require can aggregate all searchers'
   messages; throwing aborts the aggregate. `pcall(require, "optional")`
   probes still return false, but with the misleading message.

## where

- `cosmic/searcher.tl:42-44` — `require("cosmic.teal")` before
  `teal.search_module(module_name)`.
- `cosmic/teal.tl:8` — the top-level `require("tl")` that throws.
- `cosmic/embed/floor.tl` — strips `tl.lua`; keeps `cosmic/searcher.lua`
  and the wrapper that installs it.

## failure scenario

a stripped artifact's code calls `require("config.schema")` with a typo
(`schma`). instead of lua's normal

```
module 'config.schma' not found: no field ... no file ...
```

the process dies with an error about `module 'tl' not found` and tl's
package.path candidates — pointing the user at the Teal compiler, which
was never the problem and is absent on purpose.

## suggested fix

wrap the teal acquisition in the searcher:

```
local ok, teal = pcall(require, "cosmic.teal")
if not ok then
  return "cosmic .tl searcher unavailable (no Teal compiler in this artifact)"
end
```

returning the miss string restores the searcher contract: a genuinely
missing module gets lua's normal aggregate (now including one honest line
about why `.tl` sources are unreachable), and an artifact that carries tl
behaves exactly as today. the loud-failure behavior for a module that
*is* found but fails to compile (`error(...)` at `searcher.tl:50`) is
deliberate and stays.

## test to add

the stripped-artifact lane: inside a stripped artifact, assert
`require("definitely.missing")` fails with a message naming
`definitely.missing` (and containing the searcher's unavailable line),
not `tl`.
