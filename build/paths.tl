--- Each project's generated files live in a private directory outside
--- its sources. Bootstrap and the running tool share this resolver so
--- the database, executables and rebuild lock always name one place.

local Codec = require("cosmic.codec")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local cache_dir, dirname, mkdirs, put, within = Fs.cache_dir, Fs.dirname, Fs.mkdirs, Fs.put, Fs.within
local stat, mkdir, getuid, realpath = sys.stat, sys.mkdir, sys.getuid, sys.realpath
local environ = Env.all
local sha256, hex = Hash.sha256, Codec.hex
local ENOENT, EEXIST = sys.ENOENT, sys.EEXIST

local record paths
end

local function absolute(path: string): string | nil, string
  local found, trouble = realpath(path)
  if found == nil then return nil, path .. ": " .. trouble end
  return found, ""
end

--- A project's directory under an already chosen build home. `root`
--- is canonical; this pure mapping also names the sandbox's virtual tree.
function paths.in_home(root: string, home: string): string
  return (home:gsub("/+$", "")) .. "/" .. hex(sha256(root))
end
local in_home = paths.in_home

local record Location
  root: string
  home: string
  output: string
  cache: boolean
  environment: {string:string}
end

--- Existing generated directories must belong to this user and be
--- unwritable by others: later runs execute programs kept there.
local function trusted(path: string, missing: boolean,
                       cache_parent?: boolean): boolean, string
  local st, trouble, errno = stat(path)
  if st == nil then
    if missing and errno == ENOENT then return true, "" end
    return false, path .. ": " .. trouble
  end
  if st.kind ~= "dir" then return false, path .. ": not a directory" end
  if st.uid ~= getuid() and not (cache_parent and st.uid == 0) then
    return false, path .. ": owned by another user"
  end
  if not cache_parent and st.mode & 0x12 ~= 0 then
    return false, path .. ": writable by its group or others"
  end
  return true, ""
end

--- Resolve a missing name from its nearest existing ancestor, so a
--- relative cache home or a symlink never makes the chosen output depend
--- on the working directory of a later command.
local function named(path: string): string | nil, string
  local found, trouble = absolute(path)
  if found ~= nil then return found, "" end
  local st, stat_trouble, errno = stat(path)
  if st ~= nil then return nil, trouble end
  if errno ~= ENOENT then return nil, path .. ": " .. stat_trouble end
  local parent = dirname(path)
  if parent == path then return nil, trouble end
  local resolved, resolve_trouble = named(parent)
  if resolved == nil then return nil, resolve_trouble end
  local name = path:match("([^/]+)/*$") or ""
  if name == "." then return resolved, "" end
  if name == ".." then return dirname(resolved), "" end
  return (resolved == "/" and "" or resolved) .. "/" .. name, ""
end

local function location(root: string, environment?: {string:string},
                        optional_default?: boolean): Location | nil, string
  if root == "" then return nil, "project root is empty" end
  if root:find("\0", 1, true) ~= nil then return nil, "project root contains a NUL byte" end
  local canonical, root_trouble = absolute(root)
  if canonical == nil then return nil, "project root: " .. root_trouble end
  local root_stat, root_stat_trouble = stat(canonical)
  if root_stat == nil then return nil, canonical .. ": " .. root_stat_trouble end
  if root_stat.kind ~= "dir" then return nil, canonical .. ": project root is not a directory" end
  local variables = environment or environ()
  local home = variables.COSMIC_BUILD_HOME
  local cache = home == nil or home == ""
  if cache then
    local selected, home_trouble = cache_dir("trees", { environment = variables, make = false })
    if selected == nil then
      if optional_default then return nil, "" end
      return nil, "build directory: " .. home_trouble
    end
    home = selected
    if home:find("\0", 1, true) ~= nil then return nil, "build directory contains a NUL byte" end
    local parent = dirname(dirname(home))
    local valid, parent_trouble = trusted(parent, true, true)
    if not valid then return nil, parent_trouble end
    local cosmic_valid, cosmic_trouble = trusted(dirname(home), true)
    if not cosmic_valid then return nil, cosmic_trouble end
  elseif home:sub(1, 1) ~= "/" or home:find("\0", 1, true) ~= nil then
    return nil, "COSMIC_BUILD_HOME must name an absolute directory"
  end
  if home:find("\0", 1, true) ~= nil then
    return nil, "build directory contains a NUL byte"
  end
  local valid, home_trouble = trusted(home, true)
  if not valid then return nil, home_trouble end
  local resolved, resolve_trouble = named(home)
  if resolved == nil then return nil, resolve_trouble end
  local output, output_trouble = named(in_home(canonical, resolved))
  if output == nil then return nil, output_trouble end
  local output_valid, output_trust_trouble = trusted(output, true)
  if not output_valid then return nil, output_trust_trouble end
  if within(output, canonical) then
    if cache and optional_default then return nil, "" end
    return nil, "build directory must be outside the project root: " .. output
  end
  return { root = canonical, home = resolved, output = output,
    cache = cache, environment = variables }, ""
end

--- Names the directory without creating it. COSMIC_BUILD_HOME selects
--- an absolute base; otherwise it is the user's `cosmic/trees` cache.
--- The selected output must be outside the project's source tree.
--- The full SHA-256 of the canonical project root separates worktrees
--- and projects while making aliases of one root share their output.
function paths.directory(root: string, environment?: {string:string}): string | nil, string
  local selected, trouble = location(root, environment)
  if selected == nil then return nil, trouble end
  return selected.output, ""
end
local directory_of = paths.directory

--- Names a project directory for an optional lookup. Without a cache
--- home outside the sources there can be no project output, so nil with
--- no error leaves a lookup free to answer from the executable's own
--- database. Explicit build-home configuration and directory trust are
--- validated just as by `directory`.
function paths.optional(root: string, environment?: {string:string}): string | nil, string
  local selected, trouble = location(root, environment, true)
  if selected == nil then return nil, trouble end
  return selected.output, ""
end

--- Names and creates the directory, vouching for every generated
--- directory it reuses. New build homes and project directories are 0700;
--- existing directories keep their permissions and are never repaired.
function paths.prepare(root: string, environment?: {string:string}): string | nil, string
  local selected, trouble = location(root, environment)
  if selected == nil then return nil, trouble end
  if selected.cache then
    local prepared, prepare_trouble = cache_dir("trees", { environment = selected.environment })
    if prepared == nil then return nil, prepare_trouble end
  else
    local made, make_trouble = mkdirs(dirname(selected.home))
    if not made then return nil, make_trouble end
    local created, create_trouble, errno = mkdir(selected.home, 0x1c0)
    if not created and errno ~= EEXIST then return nil, selected.home .. ": " .. create_trouble end
  end
  local valid, home_trouble = trusted(selected.home, false)
  if not valid then return nil, home_trouble end
  local out = in_home(selected.root, selected.home)
  local made, make_trouble, errno = mkdir(out, 0x1c0)
  if not made and errno ~= EEXIST then return nil, out .. ": " .. make_trouble end
  local trusted_out, out_trouble = trusted(out, false)
  if not trusted_out then return nil, out_trouble end
  return named(out)
end
local prepare = paths.prepare

--- The generated directory, raising a clean diagnostic if it cannot be named.
function paths.required(root: string, environment?: {string:string}): string
  local directory, trouble = directory_of(root, environment)
  if directory == nil then error(trouble, 0) end
  return directory
end

--- Prints the directory for bootstrap; `--prepare` creates and vouches
--- for it before a bootstrap takes its lock or writes any output.
function paths.main(argv: {integer:string}): integer
  local creating = argv[1] == "--prepare"
  local slot = creating and 2 or 1
  if argv[slot] == nil or argv[slot + 1] ~= nil then
    local _, _ = put(Fs.stderr, "usage: build/paths.tl [--prepare] <project-root>\n")
    return 2
  end
  local directory, trouble = (creating and prepare or directory_of)(argv[slot])
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
