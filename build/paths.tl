--- The physical directory of a project's generated files, and the name
--- of everything a build keeps there. Bootstrap and the running tool use
--- the same resolver so a build, its database and its lock always name
--- the same directory: a consumer asks [`resolve`] (or [`under`], given
--- the directory a boot was handed) rather than spell a path of its own,
--- which `cosmic fix --check .` holds the tree to ([`build.tree_checks`]'
--- `build_directory`).
---
--- build/zig.tl runs standalone on the bootstrap release and cannot
--- require this module: it asks [`main`] for the directory and spells the
--- lock's names itself, which build/paths_test.tl holds to [`Layout`].

local Fs = require("cosmic.fs")
local put = Fs.put

local record paths
  --- What a build keeps in its directory, each by its path where
  --- `directory` is.
  record Layout
    --- The build directory itself.
    directory: string
    --- The projection, `cosmic.db`: a pure function of the tree.
    projection: string
    --- The working database, `build.db` ([`build.work`]).
    working: string
    --- The projection less the tree's tests and examples, which the
    --- tool carries, `carried.db`.
    carried: string
    --- The database `cosmic fix --check .` renders the docs it checks into.
    docs_check: string
    --- The index of the uses by source module a test run extracts.
    uses: string
    --- The stores of the test modules' import closures.
    stores: string
    --- The executables a build writes, the tool among them.
    bin: string
    --- The tree's own tool, [`bin/cosmic`].
    tool: string
    --- The raw cores, a directory for each target ([`core`]).
    cores: string
    --- Where `bin/zig build sanitized` boots the checked core: a build
    --- directory of its own, as [`under`] names it.
    sanitized: string
    --- The rebuild lock ([`build.rebuild_lock`]).
    lock: string
    --- What a build in a directory no rebuild lock guards (build/dispatch.tl's
    --- private one) takes to write its projection.
    write_lock: string
    --- Which run holds the lock, and what it is doing.
    holder: string
    --- Where the lock's holder sets the tool's database aside to read
    --- it ([`build.reboot`]).
    probe: string
    --- zig's global cache where the user has no cache directory.
    zig_global: string
    --- zig's project cache where the user has no cache directory.
    zig_cache: string
  end
end

--- The layout of the build directory `directory`, named without
--- touching the filesystem. A boot handed its directory (build.zig's
--- install prefix, or the sanitized one beneath it) names it so.
function paths.under(directory: string): paths.Layout
  return {
    directory = directory,
    projection = directory .. "/cosmic.db",
    working = directory .. "/build.db",
    carried = directory .. "/carried.db",
    docs_check = directory .. "/docs-check.db",
    uses = directory .. "/uses-by-source.db",
    stores = directory .. "/stores",
    bin = directory .. "/bin",
    tool = directory .. "/bin/cosmic",
    cores = directory .. "/core",
    sanitized = directory .. "/sanitized",
    lock = directory .. "/rebuild.lock",
    write_lock = directory .. "/.write.lock",
    holder = directory .. "/rebuild.lock.pid",
    probe = directory .. "/rebuild.lock.probe",
    zig_global = directory .. "/zig-global",
    zig_cache = directory .. "/zig-cache",
  }
end
local under = paths.under

--- The raw core of `target` a boot of `layout` reads.
function paths.core(layout: paths.Layout, target: string): string
  return layout.cores .. "/" .. target .. "/cosmic-core"
end

--- The generated directory of `root`, without creating or checking it.
-- TODO: name a directory outside the tree, under
-- $XDG_CACHE_HOME/cosmic/trees/<project key> or the COSMIC_BUILD_HOME
-- `environment` names, in #2864's step 2.
function paths.directory(root: string, _environment?: {string:string}): string | nil, string
  if root == "" then return nil, "project root is empty" end
  return root .. "/o", ""
end

local directory_of = paths.directory

--- The generated directory, raising a diagnostic when it cannot be named.
function paths.required(root: string, environment?: {string:string}): string
  local directory, trouble = directory_of(root, environment)
  if directory == nil then error(trouble, 0) end
  return directory
end
local required = paths.required

--- The layout of `root`'s build directory, raising a diagnostic where it
--- cannot be named, as [`required`] does.
function paths.resolve(root: string, environment?: {string:string}): paths.Layout
  return under(required(root, environment))
end

--- Prints the directory for the bootstrap scripts, which run this file
--- standalone before the project's modules have been built.
function paths.main(argv: {integer:string}): integer
  if argv[1] == nil or argv[2] ~= nil then
    local _, _ = put(Fs.stderr, "usage: build/paths.tl <project-root>\n")
    return 2
  end
  local directory, trouble = directory_of(argv[1])
  if directory == nil then
    local _, _ = put(Fs.stderr, trouble .. "\n")
    return 1
  end
  local printed, print_trouble = put(Fs.stdout, directory .. "\n")
  if not printed then
    local _, _ = put(Fs.stderr, print_trouble .. "\n")
    return 1
  end
  return 0
end

return paths
