--- Building a tree into its own `o/cosmic.db` and attaching it, the
--- step `cosmic <file.tl>` and `cosmic test` both take before running
--- anything.
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local importer = require("build.importer")
local payload = require("build.payload")
local teal = require("build.teal")
local writer = require("build.writer")
local type compiler = require("build.compiler")

local record project
end

--- Builds the tree at `root` into `root/o/cosmic.db` and attaches it,
--- so `require` reaches the tree's modules.
---
--- Refuses a stale tool first: when the tree is cosmic's own and this
--- binary's `build/**` and `core/**` no longer match what it was
--- booted from, compiling would use a checker or patch set the tree no
--- longer agrees with.
--- @param root the tree, absolute
--- @return importer.Result | nil what the importer compiled
--- @return compiler | nil the compiler it compiled with
--- @return string error message when the build failed
--- @return integer the exit code for that failure: 3 for a stale tool
function project.build(root: string): importer.Result | nil, compiler | nil, string, integer
  local running = Store.meta("boot_hash") or ""
  if importer.is_own_tree(root) then
    local current, hash_trouble = importer.boot_hash(root)
    if current == nil then
      return nil, nil, hash_trouble, 1
    end
    if current ~= running then
      return nil, nil, "the tool is stale; run bin/zig build boot", 3
    end
  end

  local built, load_trouble = teal.load()
  if built == nil then
    return nil, nil, load_trouble, 1
  end
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    return nil, nil, env_trouble, 1
  end

  local made, mkdir_trouble = Fs.mkdirs(root .. "/o")
  if not made then
    return nil, nil, mkdir_trouble, 1
  end

  -- Re-importing over cosmic's own database must not erase what `boot`
  -- put there: the three core images and the vendored compiler row.
  local database = root .. "/o/cosmic.db"
  local images, teal_source, carry_trouble = payload.carried(database)
  if carry_trouble ~= "" then
    return nil, nil, carry_trouble, 1
  end

  -- A project's rows are keyed by the tool's own hash, so a new cosmic
  -- recompiles them.
  local result, compile_trouble = importer.compile(root, built, env, running)
  if result == nil then
    return nil, nil, compile_trouble, 1
  end
  local written, write_trouble =
    writer.write_result(database, result, images, teal_source)
  if not written then
    return nil, nil, write_trouble, 1
  end

  local attached, attach_trouble = Store.attach(database)
  if not attached then
    return nil, nil, attach_trouble, 1
  end
  return result, built, "", 0
end

return project
