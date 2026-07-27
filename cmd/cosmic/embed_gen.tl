--- The cosmic binary's payload — what this artifact carries besides
--- its own modules, and what it carries it on.
---
--- `cosmic --make build` runs `cmd/<name>/embed_gen.tl` with its
--- unit's output directory, then reads two names out of it: `embed/`
--- is staged at the artifact root, and `base` is the runtime the
--- artifact is built onto. So this file is cosmic's own answer to
--- "what is in a cosmic binary", written once, in the unit that ships
--- it:
---
---   .tl/**           cosmic's sources, so `--check types` in a user's
---                    project can resolve `require("cosmic.fs")`
---   .types/**        the generated `cosmo.*` declarations, same reason
---   .docs/index.lua  the index `--docs` searches
---   tl.lua           the Teal compiler, from the pinned tarball
---   make             the graph engine, from the pinned cosmos zip
---   cosmic/_version.lua  the stamp `--version` prints
---   sys/**           the static `--help` text
---   skills/cosmic/** the guides `--docs` reads
---
--- and beside them, `base`: the bare `lua` from the pinned cosmos zip.
--- Naming it is what makes the fixpoint converge. Without it `build`
--- embeds onto the cosmic that is running it, and stripping a base
--- drops its zip entries without reclaiming their bytes — so a cosmic
--- built by a cosmic built by a cosmic grows by ~3.5 MB a generation,
--- measured.
---
--- `cosmic.mk` is deliberately absent: it is a committed file at
--- `embed/cosmic.mk`, which is the other half of the same convention.
--- A payload file that exists in the tree is committed; one that has
--- to be produced is generated. Both land at the same place, and
--- nothing downstream can tell which was which.
---
--- Scope, stated because it is wider than a `*_gen.tl` generation
--- unit's subtree: a BINARY's payload generator reads the binary's own
--- scope — `.tl/**` is literally that set — plus the pinned bytes
--- `--make fetch` left under `o/`. It writes only into the directory
--- it is handed. The two halves of that sentence are why this is a
--- payload generator and not a generation unit: its inputs are the
--- artifact's inputs, which is the one scope a generator cannot be
--- narrower than.

local artifact = require("_make.artifact")
local codec = require("cosmic.codec")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local index = require("cosmic.doc.index")
local literal = require("cosmic.literal")
local project = require("_make.project")
local types = require("_make.types")
local types_gen = require("_types.types_gen")

local type Binary = types.Binary
local type Project = types.Project

--- The unit this generator belongs to. It is a constant rather than
--- derived from `arg[0]`: the file's position already says it, and a
--- generator that guesses its own unit can be wrong in a way that is
--- silent.
local UNIT < const > = "cmd/cosmic"

--- Pinned bytes this binary embeds, artifact path -> where `--make
--- fetch` unpacked them. Both are named by their pin's position plus
--- the archive's own layout, so a pin that moves breaks here loudly.
local PINNED: {{string, string}} = {
  {"tl.lua", "o/3p/tl/tl.lua"},
  {"make", "o/3p/cosmos/make"},
}

--- Committed files this binary ships that are not modules, as
--- directory prefixes: everything under each, at the same path.
---
--- Enumerated here because shipping is opt-in. Taking them as implicit
--- assets instead -- "everything else, embedded at its relative path"
--- -- also ships `docs/`, `_perf/` and `_make/testdata/`, which is
--- megabytes of artifact nobody asked for. What a binary carries is a
--- thing its unit SAYS, and this is cosmic saying it. Both are read
--- from `/zip` at run time: `_cli.help` reads `sys/help.md`, and
--- `--docs` reads the guides under `skills/cosmic`.
local TREES: {string} = {
  "sys",
  "skills/cosmic",
}

--- Copy one file into the payload.
--- @param from string Source path, relative to the project root
--- @param to string Destination path, relative to the payload root
--- @param dest string The payload directory
--- @return boolean, string Success, or false plus the reason
local function put(from: string, to: string, dest: string): boolean, string
  local body, rerr = fs.read(from)
  if not body then
    return false, from .. ": " .. (rerr or "cannot read")
  end
  local out = fs.join(dest, to)
  local mok, merr = fs.makedirs(fs.dirname(out))
  if not mok then
    return false, fs.dirname(out) .. ": " .. (merr or "cannot create")
  end
  local wok, werr = fs.write(out, body)
  if not wok then
    return false, out .. ": " .. (werr or "cannot write")
  end
  return true
end

--- Copy a committed directory into the payload, at the same paths.
---
--- Sorted, because the payload is compared byte for byte between
--- generations and a directory walk has no order of its own.
--- @param dir string Directory path, relative to the project root
--- @param dest string The payload directory
--- @return boolean, string Success, or false plus the reason
local function put_tree(dir: string, dest: string): boolean, string
  local found, lerr = fs.collect(dir, "*")
  if not found then
    return false, dir .. ": " .. (lerr or "cannot list")
  end
  local paths = found as {string} -- cast: nil ruled out by the guard above
  table.sort(paths)
  for _, from in ipairs(paths) do
    local ok, err = put(from, from, dest)
    if not ok then
      return false, err
    end
  end
  return true
end

--- The runtimes the artifact is built onto, and the names `build` looks
--- for them under in this unit's output directory. `base` is the
--- artifact; a `base-<variant>` beside it gets the same payload on that
--- runtime, as `o/bin/cosmic-<variant>`. A release is both: `cosmic` and
--- `cosmic-debug` are one payload on the pinned `lua` and `lua-debug`.
local BASES: {{string, string}} = {
  {"base", "o/3p/cosmos/lua"},
  {"base-debug", "o/3p/cosmos/lua-debug"},
}

--- The payload directory, inside the unit's output directory. `build`
--- stages everything under it at the artifact root.
local PAYLOAD_DIR < const > = "embed"

--- Where the `cosmo.*` and `tl` declarations are GENERATED --
--- `_types/types_gen.tl` owns this directory, and the graph runs it
--- before anything reads it -- and the artifact directory
--- `cosmic.teal` puts on the include path.
local TYPES_DIR < const > = "o/_types/types_gen"
local TYPES_STORED < const > = ".types"

--- The cosmos pin the version stamp names, and the artifact path the
--- stamp lands at — inside the module root, since `--version` reaches
--- it with `require("cosmic._version")`.
local COSMOS_PIN < const > = "3p/cosmos/cosmos_pin.tl"
local VERSION_STORED < const > = "cosmic/_version.lua"

--- Where a release records the version it is building, read with the
--- same literal reader as every pin. A root dotfile, and an ASSET --
--- part of the project, not of its artifacts, so it does not ship.
---
--- `COSMIC_VERSION` alone made the version the one build input not
--- enumerable from the tree: two builds of the same commit differed by
--- ambient environment, and the reproducibility claim silently
--- acquired a precondition no committed file recorded. Nothing in the
--- graph could see an env change either, which is the exact staleness
--- shape `write_if_changed` and the facts closures exist to prevent.
--- A committed file is an ordinary input; the environment variable
--- stays as a documented OVERRIDE for a build nobody tagged.
local VERSION_PIN < const > = ".version"

--- The binary this generator belongs to.
--- @param proj Project The scanned project
--- @return Binary|nil The matching binary, or nil when there is none
local function unit_binary(proj: Project): Binary | nil
  for _, b in ipairs(proj.binaries) do
    if b.dir == UNIT then
      return b
    end
  end
  return nil
end

--- The `.tl` sources this binary is made of.
---
--- `artifact.scope_of` is the same function staging uses, which is the
--- point: the sources shipped for type checking and the modules
--- shipped to run are two views of one list, so they cannot drift into
--- a binary whose checker sees a module its runtime does not have.
--- @param proj Project The scanned project
--- @param binary Binary The binary being built
--- @return {string} Source paths, relative to the root
local function sources(proj: Project, binary: Binary): {string}
  local out: {string} = {}
  for _, f in ipairs(artifact.scope_of(proj, binary)) do
    if f.path:sub(-3) == ".tl" and (f.kind == "module" or f.kind == "entry") then
      out[#out + 1] = f.path
    end
  end
  return out
end

--- Every generated declaration, in path order.
---
--- Read from the FILESYSTEM rather than from the model, because the
--- model prunes `o/` -- generated files are not project files, which is
--- the rule that lets the tree describe itself without describing its
--- own output. Walking a directory only works because a generation unit
--- owns its output directory exclusively; if build bookkeeping shared
--- it, this would ship it.
--- @return {string} Paths under TYPES_DIR, sorted
local function generated_types(): {string}
  local found = fs.collect(TYPES_DIR, "*")
  if not found then
    return {}
  end
  local paths = found as {string} -- cast: nil ruled out by the guard
  table.sort(paths)
  return paths
end

--- Every generated `.d.tl`, with its path inside the artifact.
--- @return {{string, string}} Pairs of source path and stored path
local function declarations(): {{string, string}}
  local out: {{string, string}} = {}
  local prefix = TYPES_DIR .. "/"
  for _, path in ipairs(generated_types()) do
    if path:sub(-5) == ".d.tl" and path:sub(1, #prefix) == prefix then
      out[#out + 1] = {path, fs.join(TYPES_STORED, path:sub(#prefix + 1))}
    end
  end
  return out
end

--- The files the doc index is built from: every module, entry and
--- example in the project, plus the `cosmo.*` declarations. The index
--- describes what a user can look up, which is wider than what this
--- binary imports — `--docs` answers for the whole distribution.
--- @param proj Project The scanned project
--- @return {string} Source paths, in path order
local function documented(proj: Project): {string}
  local out: {string} = {}
  for _, f in ipairs(project.of_kind(proj,
      {"module", "entry", "example", "types"})) do
    if f.path:sub(-3) == ".tl" then
      out[#out + 1] = f.path
    end
  end
  for _, pair in ipairs(declarations()) do
    out[#out + 1] = pair[1]
  end
  return out
end

--- What each generated declaration documents: the binding it declares,
--- not the `o/` path the build wrote it to.
--- @return {string: string} Source path -> import path
local function declared_names(): {string: string}
  local out: {string: string} = {}
  local prefix = TYPES_DIR .. "/"
  for _, pair in ipairs(declarations()) do
    local rel = pair[1]:sub(#prefix + 1):gsub("%.d%.tl$", ""):gsub("/", ".")
    out[pair[1]] = rel
  end
  return out
end

--- Write the doc index.
--- @param proj Project The scanned project
--- @param dest string The payload directory
--- @return boolean, string Success, or false plus the reason
local function write_index(proj: Project, dest: string): boolean, string
  -- The `cosmic.doc.index` that resolves here is the RUNNING cosmic's,
  -- not this tree's: a build produced by the pin sees the pin's
  -- signature, the way `cosmo.Slurp` above is chosen to survive both.
  -- The names argument is newer than some pins, and an older one
  -- ignores it and falls back to naming by path — which is why the
  -- release, and the gate, build twice.
  -- cast: the running artifact's signature may predate the names argument
  local generate_index = index.generate as
  function(files: {string}, names: {string: string}): string | nil, string
  local body, err = generate_index(documented(proj), declared_names())
  if not body then
    return false, "doc index: " .. (err or "unknown error")
  end
  local out = fs.join(dest, ".docs/index.lua")
  local mok, merr = fs.makedirs(fs.dirname(out))
  if not mok then
    return false, fs.dirname(out) .. ": " .. (merr or "cannot create")
  end
  -- cast: scalar narrowing after the guard
  local wok, werr = fs.write(out, body as string)
  if not wok then
    return false, out .. ": " .. (werr or "cannot write")
  end
  return true
end

--- The version this build stamps: the tree's, else the environment's,
--- else unknown.
--- @return string The version string
local function declared_version(): string
  if fs.isfile(VERSION_PIN) then
    local declared, derr = literal.of_file(VERSION_PIN, "version")
    if not declared then
      io.stderr:write("embed_gen: " .. VERSION_PIN .. ": " ..
        (derr or "cannot read") .. "; falling back to the environment\n")
    else
      -- cast: the literal reader returns a plain table
      local named = (declared as {string: any}).cosmic
      if named is string then
        return named
      end
    end
  end
  return env.get("COSMIC_VERSION", "unknown")
end

--- Write the version stamp `--version` prints.
---
--- Both halves are READ, with the same literal reader `--make fetch`
--- uses — the build never executes a file that says what it pinned.
--- The cosmos half comes from its pin. The cosmic half comes from a
--- root `.version` when the tree carries one, else `COSMIC_VERSION`,
--- else "unknown", which is the truth for a build nobody stamped -- and
--- what every build of this tree stamps, because this tree commits no
--- `.version`: a release names itself by the commit it is tagging, and
--- that is not a fact a file in that commit can hold.
---
--- Committed file first, environment second: a bare `--make build` of
--- a clean tree is then bit-reproducible with no environment
--- coordination at all, and the override is still there for a build
--- that wants to stamp without committing. `git describe` is not a
--- third option — a build that shells out to git is one that cannot
--- run in the sandbox this build system is for.
--- @param dest string The payload directory
--- @return boolean, string Success, or false plus the reason
local function write_version(dest: string): boolean, string
  local pin, perr = literal.of_file(COSMOS_PIN, "pin")
  if not pin then
    return false, COSMOS_PIN .. ": " .. (perr or "cannot read")
  end
  -- cast: the literal reader returns a plain table
  local cosmos = (pin as {string: any}).version
  -- `return`, because this one is `require`d: the doc index next door
  -- is `load`ed by a reader that supplies the keyword itself, and a
  -- module cannot be.
  local stamp = "return " .. codec.encode_lua({
      cosmic = declared_version(),
      cosmos = cosmos is string and cosmos or "unknown",
    }) .. "\n"
  local out = fs.join(dest, VERSION_STORED)
  local mok, merr = fs.makedirs(fs.dirname(out))
  if not mok then
    return false, fs.dirname(out) .. ": " .. (merr or "cannot create")
  end
  local wok, werr = fs.write(out, stamp)
  if not wok then
    return false, out .. ": " .. (werr or "cannot write")
  end
  return true
end

--- Produce this unit's generated output.
--- @param out string The unit's output directory
--- @return string The error message, or nil on success
local function generate(out: string): string
  local proj, serr = project.scan(".")
  if not proj then
    return serr or "cannot scan the project"
  end
  -- cast: record union after the guard
  local p = proj as Project
  local binary = unit_binary(p)
  if not (binary is Binary) then
    return "no binary at " .. UNIT .. "; this generator has nothing to fill"
  end
  -- Bootstrap, before anything reads the declarations: a `--make` older
  -- than source generation never ran the generation unit, and the graph
  -- is what normally fills this directory. Shipping an artifact with no
  -- `.types/` is a silent degradation rather than a failure -- and the
  -- doc index reads them too, so this has to happen first. A payload
  -- generator answering for its own payload is the model's rule, not an
  -- exception to it.
  if #declarations() == 0 then
    local gerr = types_gen.generate(TYPES_DIR)
    if gerr then
      return "types: " .. gerr
    end
  end
  -- The directory handed over is this generator's own —
  -- `o/cmd/cosmic/embed_gen` — cleared and created by the engine
  -- before the call, so a name this generator stops writing stops
  -- shipping without anything here to remember it. That used to be
  -- this file's job, and it could only ever be this file's job while
  -- the directory was the unit's output, shared with the compiled
  -- entry the build puts there.
  local dest = fs.join(out, PAYLOAD_DIR)
  local mok, merr = fs.makedirs(dest)
  if not mok then
    return dest .. ": " .. (merr or "cannot create")
  end
  for _, pair in ipairs(BASES) do
    if not fs.isfile(pair[2]) then
      return pair[2] .. ": missing; run `cosmic --make fetch` first"
    end
    local bok, berr = put(pair[2], pair[1], out)
    if not bok then
      return berr
    end
  end

  for _, path in ipairs(sources(p, binary)) do
    local ok, err = put(path, fs.join(".tl", path), dest)
    if not ok then
      return err
    end
  end
  for _, pair in ipairs(declarations()) do
    local ok, err = put(pair[1], pair[2], dest)
    if not ok then
      return err
    end
  end
  for _, dir in ipairs(TREES) do
    local ok, err = put_tree(dir, dest)
    if not ok then
      return err
    end
  end
  for _, pair in ipairs(PINNED) do
    if not fs.isfile(pair[2]) then
      return pair[2] .. ": missing; run `cosmic --make fetch` first"
    end
    local ok, err = put(pair[2], pair[1], dest)
    if not ok then
      return err
    end
  end
  local vok, verr = write_version(dest)
  if not vok then
    return verr
  end
  local iok, ierr = write_index(p, dest)
  if not iok then
    return ierr
  end
  return nil
end

--- @param args {string} The unit's output directory, as argv
--- @return integer Exit code
local function main(args: {string}): integer
  local out = args[1]
  if not out or out == "" then
    io.stderr:write("embed_gen: usage: embed_gen.tl <outdir>\n")
    return 2
  end
  local err = generate(out)
  if err then
    io.stderr:write("embed_gen: " .. err .. "\n")
    return 1
  end
  return 0
end

local record EmbedGenModule
  generate: function(out: string): string
  main: function(args: {string}): integer
end

local M: EmbedGenModule = {
  generate = generate,
  main = main,
}

-- A generator is run, not imported; the guard keeps `--check types`
-- and the compile step from executing it.
if arg and arg[0] and arg[0]:match("embed_gen%.tl$") then
  os.exit(main(arg))
end

return M
