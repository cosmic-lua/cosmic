--- The artifact: a tree of `.tl`/`.lua` plus assets becomes an
--- executable at `o/bin/<name>`.
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
---   asset at relative path R       ->  /zip/R
---   entry                          ->  /zip/main.user.lua behind the wrapper
---
--- so "path relative to the root = import path" holds inside the
--- artifact too, because the zip root IS the module root.

local embed = require("cosmic.embed")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local project = require("_make.project")
local types = require("_make.types")
local validate = require("_make.validate")

local type Binary = types.Binary
local type File = types.File
local type Project = types.Project

--- Kinds that travel into an artifact. Everything absent is absent on
--- purpose: `testdata` exists solely to stay out (that is its only
--- job), `.d.tl` is type-only, a pin is data for `fetch`, and a
--- generator is run rather than shipped — its *output* is an asset by
--- the time staging sees it.
local ships: {string: boolean} = {
  module = true,
  entry = true,
  asset = true,
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
  --- compiled output).
  source: string
  --- Path inside the artifact, relative to the zip root.
  stored: string
end

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
--- front. Modules land at their import path, assets at their relative
--- path, and a `cmd/<name>/` module keeps its full import path — a
--- binary's own `cmd` directory is still part of the module tree it was
--- written against.
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
  if f.kind == "asset" then
    return {source = f.path, stored = f.path}
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
  for _, s in ipairs(plan(proj, binary)) do
    local content, err = fs.read(s.source)
    if not content then
      return nil, "make: cannot read " .. s.source .. ": " ..
      (err or "unknown error") .. " (run build first)"
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

--- Build one artifact from an already-compiled tree.
--- @param proj Project The scanned project
--- @param binary Binary The artifact to build
--- @param cosmic string Absolute path to the cosmic binary (the base)
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
  local result = embed.run({dir as string}, out, cosmic, -- cast: scalar narrowing after the guard
    {strip = true, provides = validate.claims(proj), mtime = embed.EPOCH})
  if not result.ok then
    return nil, "make: " .. binary.name .. ": " .. result.message
  end
  return out
end

local record ArtifactModule
  scope_of: function(proj: Project, binary: Binary): {File}
  plan: function(proj: Project, binary: Binary): {Staged}
  stage: function(proj: Project, binary: Binary): string | nil, string
  build: function(proj: Project, binary: Binary, cosmic: string): string | nil, string
end

local M: ArtifactModule = {
  scope_of = scope_of,
  plan = plan,
  stage = stage,
  build = build,
}

return M
