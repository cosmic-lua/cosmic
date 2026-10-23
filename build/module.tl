--- A staged module and the plan fields compilation fills in. Kept apart
--- from the compiler so position checks and test-input readers depend on
--- the shape without depending on code generation or contract checking.

local type analyzer = require("build.analyzer")
local type build_stub = require("build.stub")

local record module
  record Plan
    path: string
    file: string
    kind: string
    source: string
    source_hash: string
    requires: {string}
    --- The names the runner calls, bare: a `kind = "test"` module's own
    --- `local function test_*` names, or a `kind = "example"` module's
    --- `Example.<name>` names -- empty for any other kind. The two
    --- never mix in one module, since a file is only ever one kind.
    tests: {string}
    --- A test or example module's `policy` declaration ([`cosmic.test`]),
    --- or nil for none (see [`build.test_inputs`]).
    inputs: analyzer.Declared | nil
    has_top_level_return?: boolean
    --- True only for a module [`build.doctest`] produced from a
    --- `doc/guides/*.md` file rather than read off disk as `.tl`
    --- source: [`build.importer.compile`] widens its warning discount for
    --- exactly this module, and only this one, to cover the one
    --- `print`-shadowing warning that generated shape always carries --
    --- see [`build.compilation.generate`].
    generated?: boolean
    key?: string
    --- `key` less the compiler: the digest of the kinds and sources of
    --- the module's import graph alone, which a sandboxed test's key
    --- holds in `key`'s place ([`build.declared_key`]), since what the
    --- compiler made of that graph it holds by the bytes it made.
    graph_key?: string
    --- The compiled Lua of a module [`build.importer.compile`] made this
    --- run, or copied from another checkout's compile or from one made
    --- under another key for the same interfaces; none for a compile
    --- that stood in the cache, whose Lua it does not read back.
    lua?: string
    --- Its source's stub ([`build.stub`]), which cosmic's own build holds
    --- to the source's type, and whether it is declaration-only; none for
    --- a source with no top-level `return`, which has none.
    stub?: build_stub.Made
  end
end

return module
