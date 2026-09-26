--- What a test module declares it reads beyond its default inputs: the
--- type of its top-level `_inputs`, which `cosmic test --audit` holds
--- each test's observed reads to (see `build.test_inputs`).
---
--- A test's default inputs are its module's import closure, as source
--- files, the corpora of the fuzz properties it names
--- (`testdata/fuzz/<property>/`), and a pinned environment; its module
--- declares the rest, as a plain literal at its top level, which the
--- build reads without running the module -- named with a leading `_`,
--- the checker's mark of a value left unused on purpose, since the
--- module never reads it, so that any tool compiles it, whatever it
--- knows of declarations:
---
---     local type Declared = require("build.inputs").Declared
---     local _inputs: Declared = {
---       reads = { "vendor/cacert/" },
---       env = { "PATH" },
---     }
---
--- Every field is optional, and every value a literal: a list of string
--- literals, or `true` or `false`. A declaration the build cannot read
--- so -- a field it does not know, a value computed, a path that climbs
--- -- fails the build, naming its line (`build.analyzer`). A module's
--- declaration holds for each of its tests. A doc guide declares its
--- examples' in a line of its own outside any fence, which renders as
--- nothing: `<!-- inputs: processes = true -->` (doc/meta.md).
local record inputs
  record Declared
    --- Paths of the tree, relative to its root, each a file or a
    --- directory and everything beneath it: what the tests read beyond
    --- their import closure.
    reads: {string}
    --- Absolute paths outside the tree, each a file or a directory and
    --- everything beneath it: the host's own files the tests read.
    host: {string}
    --- Environment variables the tests read beyond the pinned ones;
    --- `"*"` is the whole environment, which a process started without
    --- an `env` of its own inherits.
    env: {string}
    --- Whether the tests make requests over the network: `true` for any
    --- host, or the hosts they reach.
    network: boolean | {string}
    --- Whether the tests start processes no sandbox holds
    --- (`observations.confine` holds one), or hand one what no
    --- observation accounts for: a descriptor, a path of /proc, a
    --- declaration of what it reads that did not hold.
    processes: boolean
    --- Whether the tests read the tool itself, `o/bin/cosmic`, or the
    --- program running them.
    tool: boolean
    -- TODO: give each test a store derived from its import closure, and
    -- take `store` for the whole one, once the sandboxed worker (a
    -- later phase of declared inputs) binds one at o/cosmic.db: today a
    -- test reads all of it, declared or not.
    --- Whether the tests open the tree's projection, `o/cosmic.db`,
    --- themselves rather than through `require` and `cosmic.store`.
    store: boolean
  end
end

return inputs
