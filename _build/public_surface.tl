--- The public module surface, enumerated from the committed tree.
---
--- A module is public because of where it sits: `cosmic/<name>.tl` or
--- `cosmic/<name>/init.tl`, for a `<name>` that does not start with
--- `_`. Position is the whole manifest, which means the surface can
--- grow by adding one file and nobody has to agree to it.
---
--- `cosmic/surface_test.tl` asks a different question of the same
--- surface: it enumerates the modules EMBEDDED in the running binary
--- and asserts each one loads and is documented. That is a statement
--- about the artifact; this is a statement about the tree, and a name
--- can be added here long before anyone notices it shipped.
--- `cosmic/doc/public_test.tl` asserts the third leg: the `--docs`
--- listing agrees with the same rule. `_build.size` is the one caller
--- outside the tests that asks this module the tree-side question, for
--- its report's public-module count.
---
--- The rule for what counts as public is not restated here — the names
--- go through `cosmic.doc`'s `public_of`, and the rule itself lives in
--- `cosmic/doc/visibility.tl`, where a second copy of it would be the
--- drift this module exists to prevent.

-- The position rule, asked rather than copied. `cosmic.doc` re-exports
-- it: the rule itself lives in a shard no file outside cosmic/ may
-- require.
local doc = require("cosmic.doc")
local fs = require("cosmic.fs")

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
--- the honest answer for a tree that is not this one; the caller
--- reading the result sees it as a surface that lost every name.
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

local record PublicSurfaceModule
  modules: function(root: string): {string}
end

local M: PublicSurfaceModule = {
  modules = modules,
}

return M
