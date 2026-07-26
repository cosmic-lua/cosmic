--- The artifact: a tree of `.tl`/`.lua` plus its `embed/` payload
--- becomes an executable at `o/bin/<name>`.
---
--- Every output under `o/` is produced by a unit — a directory that
--- declares it, a scope of inputs that is also its grant set, and an
--- output path derived from its position. A binary is one of those
--- units, which is why `scope_of` below is a plain function over the
--- model rather than a special case bolted onto the pack rule: a
--- `cmd/<name>/` directory generates `o/bin/<name>` from (root packages
--- + its own subtree) the same way a `*.gen.tl` directory generates
--- `o/<dir>/**` from its subtree.
---
--- Layout is derived, never enumerated. One rule:
---
---   package module, import path P  ->  /zip/P.lua
---   payload at embed/R             ->  /zip/R
---   entry                          ->  /zip/main.user.lua behind the wrapper
---
--- so "path relative to the root = import path" holds inside the
--- artifact too, because the zip root IS the module root.
---
--- This file is the STAGING half — everything that runs once per
--- binary. The generation phase, which runs once per project before
--- any binary stages, is `_make.generate`.

local embed = require("cosmic.embed")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local project = require("_make.project")
local types = require("_make.types")
local validate = require("_make.validate")

local type Binary = types.Binary
local type File = types.File
local type Project = types.Project

--- Kinds a binary carries. Its MODULES plus `embed/**`, and nothing
--- else -- shipping is a thing a project DOES, not the default a file
--- falls into.
---
--- `asset` is deliberately absent, and it used to be here. Every other
--- kind in the model is declared by position or marker (a test is
--- `*_test.*`, a pin is `*_pin.tl`, payload is `embed/**`, internal is
--- `_`), and "everything else ships at its relative path" was the one
--- row that inverted that: a repo is full of files that are ABOUT a
--- project rather than OF its artifact, and all of them shipped. It
--- cost cosmic's own artifact 1.5 MB of `docs/`, `mk/`, `Makefile` and
--- `_perf/`, and it is why "not shipped" and "not seen" were about to
--- become two separate knobs. With shipping opt-in there is nothing to
--- un-ship: `testdata/`'s exclusion and `.d.tl`'s never-embedded rule
--- stop being exceptions carved out of a default, and the artifact's
--- contents are greppable from the tree (`ls embed/` plus the module
--- set) the way its network and exec surfaces already are.
local ships: {string: boolean} = {
  module = true,
  entry = true,
  payload = true,
}

--- The payload directory's name, shared by the tree and `o/` halves.
local PAYLOAD_DIR < const > = "embed"

--- Where a payload file lands: at its path INSIDE its unit's `embed/`.
---
--- The one layout rule (path = import path = zip path) cannot say "this
--- lands at that", and some files must: a type checker looks for its
--- declarations at a fixed path, an engine reads its rules file, a
--- runtime finds its compiler beside the modules. `embed/` is where a
--- project says so, positionally, without the engine growing an opinion
--- about what belongs in an artifact.
---
--- Which `embed/` is the unit's own: `cmd/<name>/embed/tl.lua` ships as
--- `tl.lua` in that binary and is invisible to its siblings, because
--- `scope_of` already excludes another binary's `cmd/` subtree. Root
--- `embed/` is shared, like a root package. So one binary carries a
--- toolchain and the next one stays lean, with no rule but the one that
--- was already there.
--- @param rel string The payload file's path, relative to the root
--- @return string Its path inside the artifact
local function payload_stored(rel: string): string
  -- Drop the payload root's leading segments. `or 0` leaves a
  -- non-payload path unchanged, which classify never sends here anyway.
  local depth = project.payload_depth(project.segments(rel)) or 0
  return (rel:gsub("^" .. string.rep("[^/]+/", depth), ""))
end

--- One staged file: where it comes from, and where it lands in the zip.
local record Staged
  --- Source path, relative to the project root (or under `o/` for
  --- compiled output). Empty when `content` carries the bytes.
  source: string
  --- Path inside the artifact, relative to the zip root.
  stored: string
  --- Literal bytes, for an entry the build derives rather than copies.
  content: string
end

--- The default argv an APE reads at startup: run `/zip/main.lua`, then
--- pass everything else through.
---
--- Derived, not declared. The artifact's entry is always `/zip/main.lua`
--- — `stage_entry` puts it there — so what argv names is a fact about
--- this layout, not a project's choice. It has to be stated because a
--- base can be a bare `lua`, which has no `.args` of its own; embedding
--- onto a cosmic used to supply one by accident, and "the artifact boots
--- as the Lua interpreter" is what that accident looked like when it
--- stopped happening.
local ARGS_STORED < const > = ".args"
local ARGS_CONTENT < const > = "/zip/main.lua\n...\n"

--- Does this file belong to some `cmd/<name>/` directory?
--- @param path string Path relative to the root
--- @return string|nil The owning `cmd/<name>`, or nil
local function cmd_owner(path: string): string | nil
  local segs = project.segments(path)
  if #segs >= 2 and segs[1] == "cmd" then
    return "cmd/" .. segs[2]
  end
  return nil
end

--- The scope of one binary unit: the files it ships.
---
--- Root packages plus its own `cmd/<name>/**`, and nothing from a
--- sibling `cmd/`. That is the same set the validator already refuses
--- imports across, stated here as a file list instead of as an error —
--- the two must agree, which is why both derive from `cmd_owner`.
--- @param proj Project The scanned project
--- @param binary Binary The artifact being staged
--- @return {File} The files in scope, in path order
local function scope_of(proj: Project, binary: Binary): {File}
  local out: {File} = {}
  for _, f in ipairs(proj.files) do
    if ships[f.kind] then
      local owner = cmd_owner(f.path)
      -- A file under some cmd/ belongs to that binary alone; anything
      -- else is a root package and belongs to every binary.
      local mine = owner == nil or owner == binary.dir
      -- Another binary's root entry is not a module of this one.
      local other_entry = f.kind == "entry" and f.path ~= binary.entry
      if mine and not other_entry then
        out[#out + 1] = f
      end
    end
  end
  return out
end

--- Where a file lands inside the artifact.
---
--- The entry becomes `main.lua`; `cosmic.embed` moves it to
--- `main.user.lua` and puts its own searcher-installing wrapper in
--- front. Modules land at their import path, payload at its path
--- inside `embed/`, and a `cmd/<name>/` module keeps its full import
--- path — a binary's own `cmd` directory is still part of the module
--- tree it was written against.
--- @param f File The file being staged
--- @param binary Binary The artifact being staged
--- @return Staged|nil Its staging entry, or nil when it does not ship
local function stage_entry(f: File, binary: Binary): Staged | nil
  if f.path == binary.entry then
    return {source = fs.join(project.BUILD_DIR, (f.path:gsub("%.tl$", ".lua"))),
      stored = "main.lua"}
  end
  if f.kind == "payload" then
    return {source = f.path, stored = payload_stored(f.path)}
  end
  if not f.import then
    return nil
  end
  return {source = fs.join(project.BUILD_DIR, (f.path:gsub("%.tl$", ".lua"))),
    stored = f.import:gsub("%.", "/") .. ".lua"}
end

--- Payload a generator produced, under `o/`.
---
--- The tree half of `embed/` is committed files; this is the other
--- half, and it is why generated payload works at all: everything
--- generated lives in `o/`, so a `cmd/<name>/embed.gen.tl` writes into
--- `o/cmd/<name>/embed/**` and the artifact stages it exactly as if it
--- had been committed. Both halves land at the same place inside the
--- artifact, so a project can generate `tl.lua` and commit `notes.txt`
--- beside each other without knowing which is which.
--- @param root string Absolute project root
--- @param unit string The unit's directory, "" for the root
--- @param out {Staged} Plan to append to
local function generated_payload(root: string, unit: string, out: {Staged})
  -- The staged `source` stays relative, like every other entry, because
  -- the pack step runs from the root. The WALK has to be absolute: a
  -- plan can be computed from anywhere, and a relative path would
  -- resolve against the caller's directory instead of the project's.
  local rel = fs.join(project.BUILD_DIR, fs.join(unit, PAYLOAD_DIR))
  local dir = fs.join(root, rel)
  if not fs.isdir(dir) then
    return
  end
  fs.walk(dir, function(path: string, _name: string,
        st: fs_types.WalkStat): fs.WalkAction
      if st:is_file() then
        local inside = path:sub(#dir + 2)
        out[#out + 1] = {source = fs.join(rel, inside), stored = inside}
      end
      return nil
    end)
end

--- The name a unit's output directory gives the runtime its artifact is
--- built ON, as opposed to what it carries.
---
--- Two names in one directory, and the whole convention:
---
---   o/<unit>/embed/**   what the artifact carries
---   o/<unit>/base       what it carries it on
---
--- Without the second one, `build` has exactly one base available —
--- the cosmic that is running it — and that is wrong in the case this
--- build system most has to get right. Stripping a base removes its
--- zip entries but not their bytes, so a cosmic built on a cosmic
--- built on a cosmic grows by its own payload every generation: the
--- fixpoint would converge on nothing. A project that pins a runtime
--- can now say so, and its artifact is the same size whichever binary
--- built it.
local BASE_NAME < const > = "base"

--- The first stored-path collision in a sorted plan, if there is one.
---
--- Distinct kinds can map to one path inside the artifact: payload
--- `embed/pkg/db.lua` and module `pkg/db.tl` both store `pkg/db.lua`;
--- committed `embed/x` and generated `o/<unit>/embed/x` both store `x`.
--- `stage` writes every entry, so a collision resolved as last-writer-
--- wins, and the sort is not stable for equal keys -- which bytes ship
--- could vary run to run. That is a heisenbug at the artifact level,
--- and the honest answer is to refuse: if a deliberate override order
--- is ever wanted it should be written down, not inherited from
--- `table.sort`.
--- @param out {Staged} The sorted plan
--- @return string|nil The complaint, or nil when every path is distinct
local function collision(out: {Staged}): string | nil
  for i = 2, #out do
    if out[i].stored == out[i - 1].stored then
      local a = out[i - 1].source
      local b = out[i].source
      return "make: " .. out[i].stored .. ": staged by both " ..
      project.unit_label(a) .. " and " .. project.unit_label(b)
    end
  end
  return nil
end

--- The full staging plan for one binary.
--- @param proj Project The scanned project
--- @param binary Binary The artifact being staged
--- @return {Staged} Every file, source path paired with stored path
local function plan(proj: Project, binary: Binary): {Staged}
  local out: {Staged} = {}
  for _, f in ipairs(scope_of(proj, binary)) do
    local s = stage_entry(f, binary)
    if s then
      out[#out + 1] = s
    end
  end
  -- The root's payload reaches every binary; a cmd unit's is its own.
  generated_payload(proj.root, "", out)
  if binary.dir ~= "" then
    generated_payload(proj.root, binary.dir, out)
  end
  -- Last, and only if the project did not put one there itself: a
  -- payload `.args` is a deliberate override and outranks the default.
  local has_args = false
  for _, s in ipairs(out) do
    if s.stored == ARGS_STORED then
      has_args = true
    end
  end
  if not has_args then
    out[#out + 1] = {source = "", stored = ARGS_STORED, content = ARGS_CONTENT}
  end
  table.sort(out, function(a: Staged, b: Staged): boolean
      return a.stored < b.stored
    end)
  return out
end

--- Copy the plan into a staging directory under `o/`.
---
--- Staging to disk rather than handing `embed` a list of (content,
--- name) pairs keeps one code path: `embed.run` on a directory stores
--- everything relative to that directory's root, which is exactly the
--- artifact layout once the plan has named it.
--- @param proj Project The scanned project
--- @param binary Binary The artifact being staged
--- @return string|nil The staging directory, or nil on failure
--- @return string The error message
local function stage(proj: Project, binary: Binary): string | nil, string
  local dir = fs.join(project.BUILD_DIR, "stage", binary.name)
  -- Clear rather than merge: a file removed from the project must not
  -- survive in the artifact because it is still sitting in the stage.
  if fs.exists(dir) then
    local ok, rerr = fs.rmrf(dir)
    if not ok then
      return nil, "make: cannot clear " .. dir .. ": " .. (rerr or "unknown error")
    end
  end
  local entries = plan(proj, binary)
  local clash = collision(entries)
  if clash then
    return nil, clash
  end
  for _, s in ipairs(entries) do
    local content = s.content
    if not content then
      local body, err = fs.read(s.source)
      if not body then
        return nil, "make: cannot read " .. s.source .. ": " ..
        (err or "unknown error") .. " (run build first)"
      end
      content = body
    end
    local dst = fs.join(dir, s.stored)
    local mok, merr = fs.makedirs(fs.dirname(dst))
    if not mok then
      return nil, "make: cannot create " .. fs.dirname(dst) .. ": " ..
      (merr or "unknown error")
    end
    local wok, werr = fs.write(dst, content)
    if not wok then
      return nil, "make: cannot write " .. dst .. ": " ..
      (werr or "unknown error")
    end
  end
  return dir
end

--- The runtime this artifact is built on.
---
--- A unit that produced `o/<unit>/base` names its own — cosmic's own
--- generator copies the `lua` out of the pinned cosmos zip, so a
--- cosmic built by any cosmic is built on the runtime the project
--- pinned rather than on whichever binary happened to run the build.
--- Everything else falls back to the running cosmic, which is the
--- right answer for a project that pins nothing: their artifact is a
--- cosmic with their code in it.
--- @param proj Project The scanned project
--- @param binary Binary The artifact being built
--- @param cosmic string Absolute path to the running cosmic
--- @return string The base to embed onto
local function base_of(proj: Project, binary: Binary, cosmic: string): string
  local declared = fs.join(project.out_dir(binary.dir), BASE_NAME)
  if fs.isfile(fs.join(proj.root, declared)) then
    return declared
  end
  return cosmic
end

--- Build one artifact from an already-compiled tree.
--- @param proj Project The scanned project
--- @param binary Binary The artifact to build
--- @param cosmic string Absolute path to the running cosmic binary
--- @return string|nil The artifact path, or nil on failure
--- @return string The error message
local function build(proj: Project, binary: Binary, cosmic: string): string | nil, string
  local dir, serr = stage(proj, binary)
  if not dir then
    return nil, serr or "make: staging failed"
  end
  local out = fs.join(project.BUILD_DIR, "bin", binary.name)
  local mok, merr = fs.makedirs(fs.dirname(out))
  if not mok then
    return nil, "make: cannot create " .. fs.dirname(out) .. ": " ..
    (merr or "unknown error")
  end
  -- The other half of the provider exemption: the validator lets a
  -- project define `cosmic/**` when it defines the whole namespace, and
  -- this is what makes that true of the artifact too. Keeping the
  -- base's copy as well would ship two standard libraries, with the
  -- project's winning on package.path and the base's riding along.
  local result = embed.run({dir as string}, out, -- cast: scalar narrowing after the guard
    base_of(proj, binary, cosmic),
    {strip = true, provides = validate.claims(proj), mtime = embed.EPOCH})
  if not result.ok then
    return nil, "make: " .. binary.name .. ": " .. result.message
  end
  return out
end

local record ArtifactModule
  base_of: function(proj: Project, binary: Binary, cosmic: string): string
  scope_of: function(proj: Project, binary: Binary): {File}
  plan: function(proj: Project, binary: Binary): {Staged}
  stage: function(proj: Project, binary: Binary): string | nil, string
  build: function(proj: Project, binary: Binary, cosmic: string): string | nil, string
end

local M: ArtifactModule = {
  base_of = base_of,
  scope_of = scope_of,
  plan = plan,
  stage = stage,
  build = build,
}

return M
