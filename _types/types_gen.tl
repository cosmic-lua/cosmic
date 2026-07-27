--- Generate the `cosmo.*` and `tl` type declarations into `o/_types/types_gen/`.
---
--- A generation unit: `--make` hands it its output directory and runs it
--- before the graph, because what it writes is an INPUT — the checker,
--- the compiler, the formatter and the linter all resolve `cosmo.*`
--- through these files.
---
--- They are not committed, which is the point. A generated file in the
--- tree needs a drift test to prove it still matches its generator, a
--- regeneration command to rewrite it, and a reviewer to notice when a
--- diff is output rather than intent. Generating them where every other
--- output goes retires all three: there is nothing to drift from, the
--- build produces them, and a `cosmo.*` change shows up as the pin bump
--- that caused it.
---
--- Cost, stated: a fresh clone cannot resolve `cosmo.*` until it has
--- fetched and built once, and an editor needs `o/_types/types_gen` on its
--- include path.

local cosmic = require("cosmic")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local gentl = require("_types.gentl")
local gentype = require("_types.gentype")

--- Where a generated module's declarations land, inside `dest`.
---
--- `cosmo` is the top-level record and its submodules sit under it, so
--- the layout mirrors the import path exactly as everywhere else:
--- `cosmo` -> `cosmo.d.tl`, `unix` -> `cosmo/unix.d.tl`.
--- @param dest string The unit's output directory
--- @param module string The module name
--- @return string The output path
local function output_of(dest: string, module: string): string
  if module == "cosmo" then
    return fs.join(dest, "cosmo.d.tl")
  end
  return fs.join(dest, "cosmo", module .. ".d.tl")
end

--- Write one file, creating its directory.
--- @param path string Where to write
--- @param body string What to write
--- @return string|nil The error message, nil on success
local function put(path: string, body: string): string | nil
  if not fs.makedirs(fs.dirname(path)) then
    return "cannot create " .. fs.dirname(path)
  end
  local ok, err = fs.write(path, body)
  if not ok then
    return "cannot write " .. path .. ": " .. (err or "unknown error")
  end
  return nil
end

--- Generate every `cosmo.*` declaration from the pinned definitions.
--- @param dest string The unit's output directory
--- @return string|nil The error message, nil on success
local function cosmo_types(dest: string): string | nil
  for _, module in ipairs(gentype.MODULES) do
    local result = gentype.run(module)
    if not result.success then
      return module .. ": " .. (result.error or "generation failed")
    end
    local werr = put(output_of(dest, module), result.output)
    if werr then
      return werr
    end
  end
  return nil
end

--- Generate the `tl` shim from the pinned Teal source.
--- @param dest string The unit's output directory
--- @return string|nil The error message, nil on success
local function tl_types(dest: string): string | nil
  -- Where `--make fetch` unpacks the tl tarball: beside its pin.
  local source, rerr = fs.read(fs.join("o", "3p", "tl", "tl.tl"))
  if not source then
    return "tl.tl: " .. (rerr or "cannot read") .. " (run `--make fetch`)"
  end
  local out, gerr = gentl.generate(source)
  if not out then
    return "tl.d.tl: " .. (gerr or "generation failed")
  end
  return put(fs.join(dest, "tl.d.tl"), out)
end

--- Generate every declaration into `dest`.
---
--- Exported as well as run, for the ONE caller that cannot wait for the
--- graph: `cmd/cosmic/embed_gen.tl` ships this output as the artifact's
--- `.types/`, and a payload generator is run by whatever `--make` is
--- driving the build -- including a PINNED cosmic older than source
--- generation, which would stage an artifact with no types at all. A
--- payload generator answering for its own payload is the model's rule,
--- not an exception to it; this is that rule reaching the one payload
--- that is also a build input.
--- @param dest string The output directory
--- @return string|nil The error message, nil on success
local function generate(dest: string): string | nil
  local cerr = cosmo_types(dest)
  if cerr then
    return cerr
  end
  return tl_types(dest)
end

-- The `is_main` question is asked HERE, in this chunk, because that is
-- the only place it answers about this file (see cosmic.main).
if proc.is_main() then
  cosmic.main(function(args: {string}): number, string
      local dest = args[1]
      if not dest or dest == "" then
        return 1, "types_gen: usage: types_gen <output-dir>"
      end
      local err = generate(dest)
      if err then
        return 1, "types_gen: " .. err
      end
      return 0
    end)
end

local record TypesGenModule
  generate: function(dest: string): string | nil
end

local M: TypesGenModule = {
  generate = generate,
}

return M
