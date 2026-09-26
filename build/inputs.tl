--- What a test module declares it reads beyond its default inputs, as
--- the build sees it: the `needs` call of `cosmic.test`, whose `Needs`
--- is the declaration's type, and which `cosmic test --audit` holds
--- each test's observed reads to (see `build.test_inputs`).
---
---     local Test = require("cosmic.test")
---     Test.needs {
---       reads = { "vendor/cacert/" },
---       env = { "PATH" },
---     }
---
--- A test's default inputs are its module's import closure, as source
--- files, every fuzz corpus (`testdata/fuzz/`) when that closure holds
--- `build.fuzz`, and a pinned environment; its module declares the
--- rest. The build reads the call from the source without running the
--- module (`build.analyzer`): a statement at the top level of a test or
--- example module, once, on the name a `local` binds
--- `require("cosmic.test")` to, handed one table literal whose every
--- value is written out -- a list of string literals, `true` or
--- `false`. An alias (`local needs = Test.needs`) is refused rather
--- than followed. A call the build cannot read so -- a field it does
--- not know, a value computed, a path that climbs, a second call, one
--- inside a function or in a module no test's -- fails the build,
--- naming its line; the `local _inputs = { ... }` this replaced is
--- refused with a pointer to `needs`. A module's declaration holds for
--- each of its tests.
---
--- When the module runs, the worker holds what the call was handed to
--- what the build read (`build.test_worker`), so a declaration the
--- build did not see, or saw otherwise, fails the module's load.
---
--- A doc guide, whose examples cannot `require` before the doc's first
--- block, declares its examples' in a line of its own outside any
--- fence, which renders as nothing: `<!-- needs: processes = true -->`
--- (doc/meta.md), which `build.doctest` turns into the call.

local type Test = require("cosmic.test")

local record inputs
  --- The declaration, as `cosmic.test` types it.
  type Needs = Test.Needs
end

return inputs
