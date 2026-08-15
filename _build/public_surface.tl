#!/usr/bin/env cosmic
--- The public module surface, enumerated from the committed tree.
---
--- A module is public because of where it sits: `cosmic/<name>.tl` or
--- `cosmic/<name>/init.tl`, for a `<name>` that does not start with
--- `_`. Position is the whole manifest, which means the surface can
--- grow by adding one file and nobody has to agree to it. This module
--- counts what the tree carries so `_build/public_surface_test.tl` can
--- hold it against the committed set in
--- `_build/public_surface_baseline.tl`. Rewrite that set whenever the
--- surface moves deliberately:
---
---     bin/cosmic --make run _build/public_surface.tl --baseline
---
--- `cosmic/surface_test.tl` asks a different question of the same
--- surface: it enumerates the modules EMBEDDED in the running binary
--- and asserts each one loads and is documented. That is a statement
--- about the artifact; this is a statement about the tree, and a name
--- can be added here long before anyone notices it shipped. Neither
--- test replaces the other.
---
--- The rule for what counts as public is not restated here — the names
--- go through `cosmic.doc`'s `public_of`, and the rule itself lives in
--- `cosmic/doc/visibility.tl`, where a second copy of it would be the
--- drift this gate exists to prevent.
---
--- The baseline is written by the renderer below rather than by
--- `cosmic.literal.format`, because a baseline is read as a diff: one
--- name per line, sorted, so a review sees the names that changed and
--- nothing else. The grammar `cosmic.literal` reads admits keyed
--- entries only, so the set is spelled `["<name>"] = true` — the names
--- are the keys, and `cosmic.literal` reads the file back.

-- The position rule, asked rather than copied. `cosmic.doc` re-exports
-- it: the rule itself lives in a shard no file outside cosmic/ may
-- require.
local doc = require("cosmic.doc")
local fs = require("cosmic.fs")
local literal = require("cosmic.literal")
local proc = require("cosmic.proc")

--- The committed set: where this module writes it and the test reads
--- it, relative to the project root.
local BASELINE < const > = "_build/public_surface_baseline.tl"

--- The public module names in a tree, sorted.
---
--- Each `cosmic/<name>.tl` yields `cosmic.<name>` and each
--- `cosmic/<name>/` holding an `init.tl` yields `cosmic.<name>`; tests
--- and examples are not modules and are skipped by name. A top-level
--- `init.tl` is the package initializer, so it yields bare `cosmic`
--- rather than `cosmic.init` — the visibility rule already knows that
--- name is not one anybody requires, and drops it along with every
--- underscore name.
---
--- A `root` with no `cosmic/` under it has no public surface, which is
--- the honest answer for a tree that is not this one; the gate reading
--- the result sees it as a surface that lost every name.
--- @param root string The project root to enumerate under
--- @return {string} The public module names, sorted
local function modules(root: string): {string}
  local dir = fs.join(root, "cosmic")
  local handle = fs.open_dir(dir)
  if not handle then
    return {}
  end
  local found: {string} = {}
  local reading = true
  while reading do
    local name = handle:read()
    if name then
      local stem = name:match("^(.+)%.tl$")
      if stem then
        if not stem:match("_test$") and not stem:match("_example$") then
          found[#found + 1] = stem == "init" and "cosmic" or "cosmic." .. stem
        end
      elseif name ~= "." and name ~= ".."
      and fs.is_file(fs.join(dir, name, "init.tl")) then
        found[#found + 1] = "cosmic." .. name
      end
    else
      reading = false
    end
  end
  handle:close()
  return doc.public_of(found)
end

--- The committed set, read as data and sorted.
--- @param path string|nil The baseline file (default the committed one)
--- @return {string}|nil The public module names
--- @return string The error when the file cannot be read or parsed
local function baseline(path?: string): {string} | nil, string
  local data, err = literal.parse_file(path or BASELINE)
  if not data then
    return nil, err
  end
  local out: {string} = {}
  for name in pairs(data) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

--- The baseline file's source: one name per line, sorted.
--- @param names {string} The public module names, in any order
--- @return string The file's bytes, newline-terminated
local function render(names: {string}): string
  local sorted: {string} = {}
  for _, name in ipairs(names) do
    sorted[#sorted + 1] = name
  end
  table.sort(sorted)
  local out: {string} = {"return {"}
  for _, name in ipairs(sorted) do
    out[#out + 1] = string.format("  [%q] = true,", name)
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

--- Rewrite the baseline from a fresh enumeration of the tree.
--- @param ... string Command-line arguments
--- @return integer The exit status
local function main(...: string): integer
  local args = {...}
  if args[1] ~= "--baseline" then
    io.stderr:write(
      "usage: cosmic --make run _build/public_surface.tl --baseline\n")
    return 1
  end
  local names = modules(".")
  local ok, err = fs.write(BASELINE, render(names))
  if not ok then
    io.stderr:write("public_surface: " .. err .. "\n")
    return 1
  end
  print(string.format("public_surface: wrote %s — %d public modules",
      BASELINE, #names))
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

local record PublicSurfaceModule
  --- The committed set's path, relative to the project root.
  BASELINE: string
  modules: function(root: string): {string}
  baseline: function(path?: string): {string} | nil, string
  render: function(names: {string}): string
  main: function(...: string): integer
end

local M: PublicSurfaceModule = {
  BASELINE = BASELINE,
  modules = modules,
  baseline = baseline,
  render = render,
  main = main,
}

return M
