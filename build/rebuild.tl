--- The build a read-only verb makes so it answers from the tree as it
--- stands: `docs` and `uses` read `o/cosmic.db`, which only a build
--- writes, so without this an edit is invisible to them until a
--- `cosmic test` or `cosmic fix` builds. It is the build `cosmic test`
--- makes (stage, compile, write the projection), and no more.

local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local String = require("cosmic.string")
local Clock = require("cosmic.clock")

local clock = require("build.clock")
local importer = require("build.importer")
local shared_compiles = require("build.shared_compiles")
local teal = require("build.teal")
local tree = require("build.tree")
local work = require("build.work")
local writer = require("build.writer")
local log = require("build.verdict").log

local record rebuild
end

--- Whether the directory `root` is one to build: cosmic's own tree, or
--- one a build has written `o/cosmic.db` under. Anything else is left
--- alone, whatever it holds: a lookup never starts a tree of its own in
--- a directory that has a stray `.tl`, nor below the home directory.
local function is_project(root: string): boolean | nil, string
  local own, own_trouble = tree.is_own(root)
  if own == nil then return nil, own_trouble end
  if own then return true, "" end
  return Fs.exists(root .. "/o/cosmic.db")
end

--- Whether `root` looks like a project that has not been built: Teal at
--- its top, or a `cmd/`.
local function looks_unbuilt(root: string): boolean
  local top, _ = Fs.list(root)
  if top == nil then return false end
  for _, name in ipairs(top) do
    if name == "cmd" or String.ends_with(name, ".tl") then return true end
  end
  return false
end

--- Builds the project at `root` as `cosmic test` does, leaving
--- `o/cosmic.db` as the tree stands. It does nothing, answering true,
--- where `root` is not one to build ([`is_project`]) and `start` is not
--- set, saying so on stderr when it looks like a project no build has
--- been made of. Answers false and why when the build fails, which the
--- caller may say and go on from the last build.
local function project(root: string, verb: string, start: boolean): boolean, string
  local found, found_trouble = is_project(root)
  if found == nil then return false, found_trouble end
  if not found and not start then
    if looks_unbuilt(root) then
      log:complain(verb .. ": this directory has not been built; `cosmic build` or `cosmic test` " ..
          "first to include its modules")
    end
    return true, ""
  end
  local own_tree, own_trouble = tree.is_own(root)
  if own_tree == nil then return false, own_trouble end
  local started = Clock.monotonic_ns()
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

--- Builds the project in the working directory, as `project` does, for
--- the verb `verb`, which names itself in what it says. With `start`, it
--- builds one no build has been made of yet too: `cosmic fix`, which
--- stages and compiles the directory to check it whatever it holds
--- ([`build.fix.spill`]), so that what its links name is the tree as it
--- stands rather than whatever an earlier `cosmic test` left.
function rebuild.here(verb: string, start?: boolean): boolean, string
  local root, trouble = Fs.absolute(".")
  if root == nil then return false, trouble end
  return project(root, verb, start == true)
end

return rebuild
