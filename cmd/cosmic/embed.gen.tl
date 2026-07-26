--- The cosmic binary's payload — what this artifact carries besides
--- its own modules, and what it carries it on.
---
--- `cosmic --make build` runs `cmd/<name>/embed.gen.tl` with its
--- unit's output directory, then reads two names out of it: `embed/`
--- is staged at the artifact root, and `base` is the runtime the
--- artifact is built onto. So this file is cosmic's own answer to
--- "what is in a cosmic binary", written once, in the unit that ships
--- it:
---
---   .tl/**           cosmic's sources, so `--check-types` in a user's
---                    project can resolve `require("cosmic.fs")`
---   .types/**        the generated `cosmo.*` declarations, same reason
---   .docs/index.lua  the index `--docs` searches
---   tl.lua           the Teal compiler, from the pinned tarball
---   make             the graph engine, from the pinned cosmos zip
---   cosmic/_version.lua  the stamp `--version` prints
---
--- and beside them, `base`: the bare `lua` from the pinned cosmos zip.
--- Naming it is what makes the fixpoint converge. `build` will
--- otherwise embed onto the cosmic that is running it, and stripping a
--- base drops its zip entries without reclaiming their bytes — so a
--- cosmic built by a cosmic built by a cosmic grew by ~3.5 MB a
--- generation, measured, before this line existed.
---
--- `cosmic.mk` is deliberately absent: it is a committed file at
--- `embed/cosmic.mk`, which is the other half of the same convention.
--- A payload file that exists in the tree is committed; one that has
--- to be produced is generated. Both land at the same place, and
--- nothing downstream can tell which was which.
---
--- Scope, stated because it is wider than a `*.gen.tl` generation
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

--- The runtime the artifact is built onto, and the name `build` looks
--- for it under in this unit's output directory.
local BASE_FROM < const > = "o/3p/cosmos/lua"
local BASE_NAME < const > = "base"

--- The payload directory, inside the unit's output directory. `build`
--- stages everything under it at the artifact root.
local PAYLOAD_DIR < const > = "embed"

--- Where the `cosmo.*` type declarations live in the tree, and the
--- artifact directory `cosmic.teal` puts on the include path.
local TYPES_DIR < const > = "_types"
local TYPES_STORED < const > = ".types"

--- The cosmos pin the version stamp names, and the artifact path the
--- stamp lands at — inside the module root, since `--version` reaches
--- it with `require("cosmic._version")`.
local COSMOS_PIN < const > = "3p/cosmos/cosmos.pin.tl"
local VERSION_STORED < const > = "cosmic/_version.lua"

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

--- Every `.d.tl` under `_types/`, with its path inside that directory.
--- @param proj Project The scanned project
--- @return {{string, string}} Pairs of source path and stored path
local function declarations(proj: Project): {{string, string}}
  local out: {{string, string}} = {}
  local prefix = TYPES_DIR .. "/"
  for _, f in ipairs(project.of_kind(proj, {"types"})) do
    if f.path:sub(1, #prefix) == prefix then
      out[#out + 1] = {f.path, fs.join(TYPES_STORED, f.path:sub(#prefix + 1))}
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
  return out
end

--- Write the doc index.
--- @param proj Project The scanned project
--- @param dest string The payload directory
--- @return boolean, string Success, or false plus the reason
local function write_index(proj: Project, dest: string): boolean, string
  local body, err = index.generate(documented(proj))
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

--- Write the version stamp `--version` prints.
---
--- The cosmos half is READ from the pin, with the same literal reader
--- `--make fetch` uses — the build never executes the file that says
--- what it pinned. The cosmic half comes from `COSMIC_VERSION`,
--- because the only other source is `git describe`, and a build that
--- shells out to git is one that cannot run in the sandbox this build
--- system is for. Unset means "unknown", which is the truth for a
--- build nobody stamped.
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
      cosmic = env.get("COSMIC_VERSION", "unknown"),
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
  local dest = fs.join(out, PAYLOAD_DIR)
  -- Clear the payload — and only the payload: the compiled entry sits
  -- in this same output directory, and staging reads it next. A source
  -- that left the project must not survive in the artifact because its
  -- copy is still sitting in `o/`.
  if fs.exists(dest) then
    local rok, rerr = fs.rmrf(dest)
    if not rok then
      return dest .. ": " .. (rerr or "cannot clear")
    end
  end
  local mok, merr = fs.makedirs(dest)
  if not mok then
    return dest .. ": " .. (merr or "cannot create")
  end
  if not fs.isfile(BASE_FROM) then
    return BASE_FROM .. ": missing; run `cosmic --make fetch` first"
  end
  local bok, berr = put(BASE_FROM, BASE_NAME, out)
  if not bok then
    return berr
  end

  for _, path in ipairs(sources(p, binary)) do
    local ok, err = put(path, fs.join(".tl", path), dest)
    if not ok then
      return err
    end
  end
  for _, pair in ipairs(declarations(p)) do
    local ok, err = put(pair[1], pair[2], dest)
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
    io.stderr:write("embed.gen: usage: embed.gen.tl <outdir>\n")
    return 2
  end
  local err = generate(out)
  if err then
    io.stderr:write("embed.gen: " .. err .. "\n")
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

-- A generator is run, not imported; the guard keeps `--check-types`
-- and the compile step from executing it.
if arg and arg[0] and arg[0]:match("embed%.gen%.tl$") then
  os.exit(main(arg))
end

return M
