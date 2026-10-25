--- The example check with the new checker over the tree, alone: `bin/cosmic build/example_checks_main.tl`, run from the root of
--- the tree. It is the part of `COSMIC_GRAMMAR=new cosmic fix --check .` that reads what the tree's examples and guides
--- show ([`build.example_checks`]), without the other checks of the tree, so that the rehearsal of the switch can hold the
--- examples to their `[examples]` ceilings in minutes. It prints each finding and exits 1 for any, 2 where it could not run.

local ExampleChecks = require("build.example_checks")
local Fs = require("cosmic.fs")
local tree_checks = require("build.tree_checks")

return function(_argv: {string}): integer
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    print(root_trouble)
    return 2
  end
  local db, projection_trouble = tree_checks.projection(root)
  if db == nil then
    print(projection_trouble)
    return 2
  end
  local found = ExampleChecks.run(db, root)
  local _, _ = db:close()
  for _, line in ipairs(found) do
    print(line)
  end
  print(("examples: %d finding%s"):format(#found, if #found == 1 then "" else "s" end))
  return if #found == 0 then 0 else 1 end
end
