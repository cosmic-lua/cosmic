--- The directory of a project's generated files, and the name of
--- everything a build keeps there. It lies outside the project's sources,
--- under `$XDG_CACHE_HOME/cosmic/trees` (`$HOME/.cache/...` without it) or
--- the absolute base `COSMIC_BUILD_HOME` names, in a directory of its own
--- named by the SHA-256 of the project root's canonical path: worktrees
--- and projects keep apart even under one base, and a link to a root
--- names the root's own. Nothing falls back to the checkout's `o/`: a
--- base that cannot be named or trusted, or that would put the directory
--- inside the sources, is an error that names it.
---
--- Bootstrap and the running tool use the same resolver so a build, its
--- database and its lock always name the same directory: a consumer asks
--- [`resolve`] (or [`under`], given the directory a boot was handed)
--- rather than spell a path of its own, which `cosmic fix --check .`
--- holds the tree to ([`build.tree_checks`]' `build_directory`).
---
--- build/zig.tl and bin/cosmic run this file standalone on the bootstrap
--- release ([`main`]), so it uses nothing of the standard library that
--- release ([`ci/cosmic-driver.pin`]) lacks. build/zig.tl spells the
--- lock's names itself, which build/paths_test.tl holds to [`Layout`].

local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local cache_dir, dirname, mkdirs, put, within = Fs.cache_dir, Fs.dirname, Fs.mkdirs, Fs.put, Fs.within
local stat, mkdir, getuid, realpath = sys.stat, sys.mkdir, sys.getuid, sys.realpath
local hex_sha256 = Hash.hex_sha256
local ENOENT, EEXIST = sys.ENOENT, sys.EEXIST

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
    --- The rebuild lock ([`build.rebuild_lock`]), the one lock every
    --- build in the directory takes.
    lock: string
    --- Which run holds the lock, and what it is doing.
    holder: string
    --- Where the lock's holder sets the tool's database aside to read
    --- it ([`build.reboot`]).
    probe: string
    --- The record of the directory's last use: a file whose
    --- modification time [`prepare`] sets, which [`build.cache_lifetime`]
    --- prunes the directory by.
    used: string
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
    holder = directory .. "/rebuild.lock.pid",
    probe = directory .. "/rebuild.lock.probe",
    used = directory .. "/used",
    zig_global = directory .. "/zig-global",
    zig_cache = directory .. "/zig-cache",
  }
end
local under = paths.under

--- The raw core of `target` a boot of `layout` reads.
function paths.core(layout: paths.Layout, target: string): string
  return layout.cores .. "/" .. target .. "/cosmic-core"
end

--- The build directory of the project whose canonical root is `root`,
--- under the base `home`: the base and the SHA-256 of the root's path,
--- with nothing resolved or looked at. The sandbox names the directory a
--- worker has its tree's in by this ([`build.test_sandbox`]).
function paths.in_home(root: string, home: string): string
  local base = home:gsub("/+$", "")
  return base .. "/" .. hex_sha256(root)
end
local in_home = paths.in_home

--- `path` with its links resolved, or, where it does not exist yet, its
--- nearest existing ancestor's so resolved with the rest appended: a base
--- that is still to be made names the same directory from every working
--- directory and through every link to it.
local function named(path: string): string | nil, string
  local found, trouble = realpath(path)
  if found ~= nil then return found, "" end
  local _, stat_trouble, errno = stat(path)
  if errno ~= ENOENT then return nil, path .. ": " .. (stat_trouble or trouble) end
  local parent = dirname(path)
  if parent == path then return nil, path .. ": " .. trouble end
  local resolved, resolve_trouble = named(parent)
  if resolved == nil then return nil, resolve_trouble end
  local name = path:match("([^/]+)/*$") or ""
  if name == "." then return resolved, "" end
  if name == ".." then return dirname(resolved), "" end
  return (resolved == "/" and "" or resolved) .. "/" .. name, ""
end

--- Whether the directory at `path` is one to keep builds in: this user's
--- and writable by no one else, since a later run executes the tool kept
--- there. A missing one passes where `missing` allows it.
local function trusted(path: string, missing: boolean): boolean, string
  local st, trouble, errno = stat(path)
  if st == nil then
    if missing and errno == ENOENT then return true, "" end
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "dir" then return false, path .. ": not a directory" end
  if st.uid ~= getuid() then return false, path .. ": owned by another user" end
  if st.mode & 0x12 ~= 0 then return false, path .. ": writable by its group or others" end
  return true, ""
end

local record Location
  --- The project root, canonical.
  root: string
  --- The base the directory is in, canonical as far as it exists.
  home: string
  --- The build directory.
  output: string
  --- Whether the base is the user's cache, not COSMIC_BUILD_HOME's.
  cache: boolean
  --- Why there can be no build directory for the root at all -- no
  --- cache directory to put it in, or one inside the root itself --
  --- rather than a configuration to fix; "" where there is one.
  none: string
end

--- Where `root`'s build directory is, or nil and why: a location whose
--- `none` says why there is none where that is no configuration to fix.
--- [`cosmic.project`]'s `directory` names the same and refuses the same,
--- which build/paths_test.tl holds them to.
-- TODO: answer the location from cosmic.project's `directory`, its
-- `none` and all, and drop `named`, `trusted`'s check of a base and this
-- copy of the rules, once ci/cosmic-driver.pin names a release whose
-- cosmic.project returns a Location: bin/zig and bin/cosmic run this file
-- standalone on that release.
local function location(root: string, environment?: {string:string}): Location | nil, string
  if root == "" then return nil, "project root is empty" end
  local canonical, root_trouble = realpath(root)
  if canonical == nil then return nil, "project root " .. root .. ": " .. root_trouble end
  local root_stat, root_stat_trouble = stat(canonical)
  if root_stat == nil then return nil, canonical .. ": " .. root_stat_trouble end
  if root_stat.kind ~= "dir" then
    return nil, canonical .. ": the project root is not a directory"
  end
  local given: string
  if environment ~= nil then
    given = environment.COSMIC_BUILD_HOME or ""
  else
    given = Env.get_or("COSMIC_BUILD_HOME", "")
  end
  local home: string
  local cache = given == ""
  if cache then
    local selected, home_trouble = cache_dir("trees", { environment = environment, make = false })
    if selected == nil then
      return { root = canonical, home = "", output = "", cache = true, none = "no build directory for " ..
          canonical .. ": " .. home_trouble .. "; set COSMIC_BUILD_HOME to an absolute directory" }, ""
    end
    home = selected
  elseif given:sub(1, 1) ~= "/" then
    return nil, "COSMIC_BUILD_HOME=" .. given .. " is not an absolute path"
  else
    home = given
  end
  local where = cache and "build directory base " or "COSMIC_BUILD_HOME "
  local base, base_trouble = named(home)
  if base == nil then return nil, where .. base_trouble end
  local valid, trust_trouble = trusted(base, true)
  if not valid then return nil, where .. trust_trouble end
  local output = in_home(canonical, base)
  if within(output, canonical) then
    return { root = canonical, home = base, output = output, cache = cache,
      none = "the build directory " .. output .. " is inside the project root " .. canonical ..
        "; set COSMIC_BUILD_HOME to a directory outside it" }, ""
  end
  local output_valid, output_trouble = trusted(output, true)
  if not output_valid then return nil, "build directory " .. output_trouble end
  return { root = canonical, home = base, output = output, cache = cache, none = "" }, ""
end

--- `root`'s build directory, named without making it, or nil and why:
--- `root` is no directory, COSMIC_BUILD_HOME is set but not absolute,
--- the base or the directory is not this user's alone, there is no cache
--- directory to put it in, or it would be inside `root`.
function paths.directory(root: string, environment?: {string:string}): string | nil, string
  local selected, trouble = location(root, environment)
  if selected == nil then return nil, trouble end
  if selected.none ~= "" then return nil, selected.none end
  return selected.output, ""
end
local directory_of = paths.directory

--- `root`'s build directory for a lookup that may find none: nil with
--- no trouble where there can be no build directory for `root` (no
--- cache directory, or one that would be inside `root`, as for a
--- directory above the base), so the lookup answers as for a project
--- never built. Any other trouble is answered as [`directory`] answers it.
function paths.optional(root: string, environment?: {string:string}): string | nil, string
  local selected, trouble = location(root, environment)
  if selected == nil then return nil, trouble end
  if selected.none ~= "" then return nil, "" end
  return selected.output, ""
end

--- `root`'s build directory, made where it is missing -- the base too,
--- each new one 0700 -- and checked to be this user's alone. A directory
--- that fails the check is never repaired, only refused. It records the
--- use ([`Layout.used`]), which is what keeps the directory from
--- [`build.cache_lifetime`]'s pruning: it is written whole beside the
--- rest, and a failure to record it, in a directory a sandbox holds
--- read-only, is no failure to prepare.
function paths.prepare(root: string, environment?: {string:string}): string | nil, string
  local selected, trouble = location(root, environment)
  if selected == nil then return nil, trouble end
  if selected.none ~= "" then return nil, selected.none end
  if selected.cache then
    local made, made_trouble = cache_dir("trees", { environment = environment })
    if made == nil then return nil, "build directory base " .. made_trouble end
  else
    local made, made_trouble = mkdirs(dirname(selected.home))
    if not made then return nil, "COSMIC_BUILD_HOME " .. made_trouble end
    local created, create_trouble, errno = mkdir(selected.home, 0x1c0)
    if not created and errno ~= EEXIST then
      return nil, "COSMIC_BUILD_HOME " .. selected.home .. ": " .. create_trouble
    end
    local valid, home_trouble = trusted(selected.home, false)
    if not valid then return nil, "COSMIC_BUILD_HOME " .. home_trouble end
  end
  local out = selected.output
  local created, create_trouble, errno = mkdir(out, 0x1c0)
  if not created and errno ~= EEXIST then
    return nil, "build directory " .. out .. ": " .. create_trouble
  end
  local valid, out_trouble = trusted(out, false)
  if not valid then return nil, "build directory " .. out_trouble end
  local _, _ = Fs.write(under(out).used, "", 0x180)
  return out, ""
end
local prepare = paths.prepare

--- `root`'s build directory, raising the diagnostic where it cannot be named.
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

--- Prints `root`'s build directory for the bootstrap scripts, which run
--- this file standalone before the project's modules have been built:
--- `[--prepare] <project-root>`, `--prepare` making it first ([`prepare`]).
function paths.main(argv: {integer:string}): integer
  local making = argv[1] == "--prepare"
  local at = making and 2 or 1
  if argv[at] == nil or argv[at + 1] ~= nil then
    local _, _ = put(Fs.stderr, "usage: build/paths.tl [--prepare] <project-root>\n")
    return 2
  end
  local directory, trouble = (making and prepare or directory_of)(argv[at])
  if directory == nil then
    local _, _ = put(Fs.stderr, "build/paths.tl: " .. trouble .. "\n")
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
