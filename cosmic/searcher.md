# searcher

 cosmic-owned runtime .tl package searcher, replacing
 tl.loader().

 Public, and the caller set is what settled it: the generated
 embed wrapper runs `require("cosmic.searcher").install()` before the
 entry of EVERY artifact anyone builds, which makes this the module
 with the widest reach in the tree. It sat under `_cli/` — marked
 internal — for as long as that was true. Same rule as the pure lint checks (now `_tool.lint`)
 in 3c: who requires a module decides whether it is internal, and a
 manifest can hold that contradiction where position cannot.

 Three guarantees tl's own loader did not make:

 1. Modules resolve through cosmic.teal's include dirs, so required
    .d.tl markers always resolve and `is` narrowing never silently
    degrades to a table test against a real userdata handle.
 2. One compile configuration: the same cosmic.teal env as
    --compile, instead of tl's own env defaults.
 3. Loud failures: a module that fails to compile fails the
    require() with the formatted issues. tl's loader ran tl.check
    and generated code without ever looking at the type errors.

 Compiled output is cached content-hashed, so a script's .tl require
 tree compiles once per content+build, not once per run — through
 `cosmic.teal.compile_cached`, which is the same call the script
 runner makes, so the two paths cannot drift. Compilation is lax —
 the same gradual-typing on-ramp as running a script directly;
 --check types remains the strict gate.

 install() appends the searcher at the END of package.searchers so
 the default Lua file searcher finds pre-compiled .lua modules
 first; without this, setting TL_PATH costs ~330ms per run
 recompiling cosmic's own modules. Everything here loads
 lazily on the first require() the default searchers cannot
 resolve, so runs that never touch a .tl file never load the
 ~15k-line Teal compiler.

 And in a STRIPPED artifact there is no compiler to load at all --
 the floor keeps `cosmic/**` (this module included) and drops
 `tl.lua`. Acquiring it is therefore fallible, and a failure is a
 MISS, not an error: see `acquire_teal`.

## Types

### TealSearch

 The two entry points this searcher needs from cosmic.teal.
 Named here because the compiler is acquired through pcall (see
 `acquire_teal`), which erases the module's own type.

```teal
local record TealSearch
  search_module: function(module_name: string): string | nil
  compile_cached: function(input_path: string, strict?: boolean): string | nil, string
end
```

### SearcherModule

```teal
local record SearcherModule
  install: function()
  install_argv_manifest: function(argv: {string}): boolean, string
  install_manifest: function(path: string): boolean, string
end
```

## Functions

### install

```teal
function install()
```

 Append the searcher to package.searchers. Idempotent (the embed
 wrapper installs it before the app entry, which may itself be the
 dispatcher that installs it too); no-op without package.searchers.

### install_manifest

```teal
function install_manifest(path: string): boolean, string
```

 Read a manifest and install the in-project searcher.
 The manifest is written by the engine into its own output directory
 and named on the child's command line. Two line kinds, so a reader
 never has to infer one from the other:
     root <absolute project root>
     build <build directory, relative to the root>
     mod <import.path> <built file>
 Inserted at index 2 — after `package.preload`, ahead of the default
 file searcher — because beating `/zip` is the entire point. A
 failure says why (#1001: the bare boolean was deliberately silent,
 and the caller could not tell "no manifest" from "unreadable
 manifest"); the CALLER decides whether that matters — a child with
 no manifest is an ordinary cosmic, which is what a hand-run script
 is.

**Parameters:**

- `path` (string) - Path to the manifest file

**Returns:**

- boolean - Whether a manifest was read and installed
- string? - Why not, when it was not

### install_argv_manifest

```teal
function install_argv_manifest(argv: {string}): boolean, string
```

 Find `--modules <manifest>` on an argv and install it.
 The scan STOPS at the first argument that is not a flag, which is
 where getopt stops parsing too: past that point a `--modules` is the
 SCRIPT's own, and acting on it would let `cosmic s.tl --modules x`
 redirect the dispatcher's requires. The engine always attaches its
 own ahead of everything, so the two never disagree about whose it is.
 Here rather than in the dispatcher because it is the channel's own
 rule, and the channel is this module's.
 argv with no --modules at all returns false with NO message — that
 is the ordinary case, not a failure)

**Parameters:**

- `argv` ({string}) - The process argv, 1-based

**Returns:**

- boolean - Whether a manifest was read and installed
- string? - Why not, when a named manifest could not be (an
