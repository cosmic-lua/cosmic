--- Proves the sibling-privacy rule `build.positions` enforces on every
--- directory in the tree, not only cosmic's own: a directory with its
--- own `init.tl` is private, and only a file inside it may require a
--- sibling that sits beside that entry.
---
--- The fixture is written to a temp directory at run time rather than
--- checked into the tree: a version of it that violates the rule would
--- fail this tree's own build the moment it existed on disk, since the
--- whole tree compiles together in one pass. This file itself has to
--- sit at the tree's root, the same as hello.tl, because `cosmic
--- <file>` takes the file's own directory as the project root; run it
--- with `cosmic visibility_test.tl`.

local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local importer = require("build.importer")
local teal = require("build.teal")

local function say(line: string)
  Fs.put(Fs.stdout, line .. "\n")
end

local entry_source = "local record entry\nend\nreturn entry\n"
local sibling_source = "local record sibling\nend\nreturn sibling\n"
local user_source = "local sibling = require(\"case.sibling\")\nreturn sibling\n"

--- Writes a directory-shaped module, `case/`, with its own `init.tl`
--- and a sibling beside it, plus one file that requires the sibling --
--- inside `case/` when `outside` is false, beside it otherwise.
local function write_fixture(root: string, outside: boolean): boolean, string
  local made, trouble = Fs.mkdirs(root .. "/case")
  if not made then
    return false, trouble
  end
  local ok: boolean
  ok, trouble = Fs.write(root .. "/case/init.tl", entry_source)
  if not ok then
    return false, trouble
  end
  ok, trouble = Fs.write(root .. "/case/sibling.tl", sibling_source)
  if not ok then
    return false, trouble
  end
  local user_path = outside and (root .. "/outsider.tl") or
    (root .. "/case/insider.tl")
  ok, trouble = Fs.write(user_path, user_source)
  if not ok then
    return false, trouble
  end
  return true, ""
end

--- Builds the fixture at `root` and says whether the tree compiled.
local function try_build(root: string): boolean, string
  local built, load_trouble = teal.load()
  if built == nil then
    return false, load_trouble
  end
  local env, env_trouble = teal.environment_for(built, root)
  if env == nil then
    return false, env_trouble
  end
  local result, trouble = importer.compile(root, built, env, "visibility-test")
  if result == nil then
    return false, trouble
  end
  return true, ""
end

local function run(_argv: {integer:string}): integer
  local base = "/tmp/cosmic-visibility-" .. tostring(Proc.pid())

  local inside_root = base .. "/inside"
  local wrote_inside, inside_write_trouble = write_fixture(inside_root, false)
  if not wrote_inside then
    say("visibility: FAIL (could not write the inside fixture: " ..
      inside_write_trouble .. ")")
    return 1
  end
  local inside_ok, inside_trouble = try_build(inside_root)
  if not inside_ok then
    say("visibility: FAIL (a sibling required from within its own " ..
      "directory should build, but: " .. inside_trouble .. ")")
    return 1
  end

  local outside_root = base .. "/outside"
  local wrote_outside, outside_write_trouble = write_fixture(outside_root, true)
  if not wrote_outside then
    say("visibility: FAIL (could not write the outside fixture: " ..
      outside_write_trouble .. ")")
    return 1
  end
  local outside_ok, outside_trouble = try_build(outside_root)
  if outside_ok then
    say("visibility: FAIL (a sibling required from outside its own " ..
      "directory should have been refused)")
    return 1
  end
  if outside_trouble:find("case.sibling", 1, true) == nil or
     outside_trouble:find("case/", 1, true) == nil then
    say("visibility: FAIL (the refusal should name the path and the " ..
      "private directory it belongs to: " .. outside_trouble .. ")")
    return 1
  end

  say("visibility: PASS (case.sibling reachable from within case/, " ..
    "refused from outside it: " .. outside_trouble .. ")")
  return 0
end

return run
