--- The build a read-only verb makes so it answers from the tree as it
--- stands: `docs` and `uses` read `o/cosmic.db`, which only a build
--- writes, so without this an edit is invisible to them until a
--- `cosmic test` or `cosmic fix` builds. It is the build `cosmic test`
--- makes (stage, compile, write the projection), and no more.

local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Time = require("cosmic.time")
local clock = require("build.clock")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")

local record rebuild
end

--- Whether `entries` (a directory's names) hold a Teal source.
local function holds_teal(entries: {string}): boolean
  for _, name in ipairs(entries) do
    if String.ends_with(name, ".tl") then
      return true
    end
  end
  return false
end

--- Whether the directory `root` is a project to build: cosmic's own
--- tree, one with a build already (`o/cosmic.db`), or one that holds
--- Teal at its top, in a directory of its own, or under `cmd/`. The
--- directory of no project at all (an empty one, the home directory)
--- is none, so a lookup there builds nothing and writes no `o/`.
local function is_project(root: string): boolean | nil, string
  local own, own_trouble = tree.is_own(root)
  if own == nil then return nil, own_trouble end
  if own then return true, "" end
  local built, built_trouble = Fs.exists(root .. "/o/cosmic.db")
  if built == nil then return nil, built_trouble end
  if built then return true, "" end
  local top, top_trouble = Fs.list(root)
  if top == nil then return nil, top_trouble end
  if holds_teal(top) then return true, "" end
  for _, name in ipairs(top) do
    if name == "cmd" then return true, "" end
    if name:sub(1, 1) ~= "." and name ~= "o" then
      local inside, _ = Fs.list(root .. "/" .. name)
      if inside ~= nil and holds_teal(inside) then return true, "" end
    end
  end
  return false, ""
end

--- Builds the project at `root` as `cosmic test` does, leaving
--- `o/cosmic.db` as the tree stands. It does nothing, answering true,
--- where `root` is no project (`is_project`). Answers false and
--- why when the build fails, which the caller may say and go on from
--- the last build.
local function project(root: string): boolean, string
  local found, found_trouble = is_project(root)
  if found == nil then return false, found_trouble end
  if not found then return true, "" end
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then return false, own_trouble end
  local started = Time.monotonic_ns()
  local handle, open_trouble = work.open(root)
  if handle == nil then return false, open_trouble end
  local staged, stage_trouble = work.stage(handle, own_tree)
  if staged == nil then
    local _, _ = work.close(handle)
    return false, stage_trouble
  end
  local result, compile_trouble = importer.compile(handle, teal.lazy(),
    Store.meta("compiler") or "", false, shared_compiles.for_build())
  if result == nil then
    local _, _ = work.record(handle, clock.elapsed_ms(started), staged, 0, 0, "FAIL")
    local _, _ = work.close(handle)
    return false, compile_trouble
  end
  local written, write_trouble = writer.write_result(handle, root .. "/o/cosmic.db", result)
  local _, _ = work.record(handle, clock.elapsed_ms(started), staged, result.compiled,
    result.cached, written and "PASS" or "FAIL")
  local _, _ = work.close(handle)
  if not written then return false, write_trouble end
  return true, ""
end

--- Builds the project in the working directory, as `project` does.
function rebuild.here(): boolean, string
  local root, trouble = Fs.absolute(".")
  if root == nil then return false, trouble end
  return project(root)
end

return rebuild
