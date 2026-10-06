--- A staged module and the plan fields compilation fills in. Kept apart
--- from the compiler so position checks and test-input readers depend on
--- the shape without depending on code generation or contract checking.

local type analyzer = require("build.analyzer")

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
    has_top_level_return: boolean
    --- True only for a module [`build.doctest`] produced from a
    --- `doc/guides/*.md` file rather than read off disk as `.tl`
    --- source: [`build.importer.compile`] widens its warning discount for
    --- exactly this module, and only this one, to cover the one
    --- `print`-shadowing warning that generated shape always carries --
    --- see [`build.compilation.generate`].
    generated: boolean
    key: string
    --- `key` less the compiler: the digest of the kinds and sources of
    --- the module's import graph alone, which a sandboxed test's key
    --- holds in `key`'s place ([`build.declared_key`]), since what the
    --- compiler made of that graph it holds by the bytes it made.
    graph_key: string
    --- The compiled Lua, once [`build.importer.compile`] has it: made
    --- this run or read back from the cache under the same key.
    lua: string
  end
end

return module
