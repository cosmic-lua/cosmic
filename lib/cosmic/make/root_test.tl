#!/usr/bin/env cosmic
-- Tests for cosmic.make.root: what counts as a project root, and the
-- guard that refuses an ambiguous one.
--
-- The guard is the whole point of the ancestor scan -- discovery itself
-- never walks upward -- so both halves are asserted: it fires from
-- inside a project, and it stays quiet in an ordinary directory of
-- source files, which is what a false positive would look like.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local root = require("cosmic.make.root")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Make a directory tree, returning its root.
local function tree(name: string, files: {string: string}): string
  local dir = fs.join(tmpdir, "root-" .. name)
  fs.rmrf(dir)
  assert(fs.makedirs(dir))
  for rel, content in pairs(files) do
    local path = fs.join(dir, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  return dir
end

-- What declares a root: a deliberate marker, never a stray source file.
-- If a directory of .tl files counted, the guard would fire on every
-- ordinary package and the escape hatch would become the normal path.
local function test_root_markers()
  assert(root.is_root(tree("marker-main", {["main.tl"] = "print('x')\n"})),
    "main.tl declares a root")
  assert(root.is_root(tree("marker-lua", {["main.lua"] = "print('x')\n"})),
    "main.lua declares a root")
  assert(root.is_root(tree("marker-cmd", {["cmd/a/main.tl"] = "print('x')\n"})),
    "a cmd/<name>/main.tl declares a root")
  assert(root.is_root(tree("marker-ignore", {[".cosmicignore"] = "o\n"})),
    ".cosmicignore declares a root")
  assert(not root.is_root(tree("no-marker", {["pkg/a.tl"] = "return {}\n"})),
    "a directory of sources is a package, not a root")
  assert(not root.is_root(tree("cmd-no-entry", {["cmd/a/lib.tl"] = "return {}\n"})),
    "a cmd/ without an entry declares nothing")
end
test_root_markers()

-- The ancestor scan finds the nearest project above a directory, and
-- returns nothing when there is none.
local function test_ancestor_root()
  local proj = tree("ancestor", {
      ["main.tl"] = "print('x')\n",
      ["db/query.tl"] = "return {}\n",
    })
  local found = root.ancestor_root(fs.join(proj, "db"))
  assert(found == proj, "expected " .. proj .. ", got " .. tostring(found))
  local none = root.ancestor_root(tree("orphan", {["a.tl"] = "return {}\n"}))
  assert(none == nil, "no project above an orphan tree, got " .. tostring(none))
end
test_ancestor_root()

-- The refusal names the likely root AND the exact command, because the
-- user is one `cd` away from the right answer and a bare "ambiguous"
-- makes them guess which direction.
local function test_refusal_names_the_command()
  local proj = tree("refuse", {
      ["main.tl"] = "print('x')\n",
      ["db/query.tl"] = "return {}\n",
    })
  local saved = env.get("COSMIC_MAKE_ROOT")
  env.unset("COSMIC_MAKE_ROOT")
  local cwd = fs.getcwd()
  assert(fs.chdir(fs.join(proj, "db")))
  local got, err = root.discover("check")
  assert(fs.chdir(cwd as string)) -- cast: scalar narrowing through the guard
  if saved then
    env.set("COSMIC_MAKE_ROOT", saved)
  end
  assert(not got, "running inside a project must be refused")
  assert(err:find("ambiguous root", 1, true), "got: " .. tostring(err))
  assert(err:find(proj, 1, true), "the refusal must name the likely root")
  assert(err:find("cosmic --make check", 1, true),
    "the refusal must name the command to run")
  assert(err:find("COSMIC_MAKE_ROOT=", 1, true),
    "the refusal must name the override for the other reading")
end
test_refusal_names_the_command()

-- COSMIC_MAKE_ROOT is the explicit answer, so it suppresses the guard:
-- the guard exists to catch a root the user did not think about, and
-- naming one is thinking about it.
local function test_override_suppresses_the_guard()
  local proj = tree("override", {
      ["main.tl"] = "print('x')\n",
      ["db/query.tl"] = "return {}\n",
    })
  local sub = fs.join(proj, "db")
  env.set("COSMIC_MAKE_ROOT", sub)
  local got, err = root.discover("check")
  env.unset("COSMIC_MAKE_ROOT")
  assert(got == sub, "expected " .. sub .. ", got " .. tostring(got) ..
    " (" .. tostring(err) .. ")")
end
test_override_suppresses_the_guard()

-- A named root that is not a directory fails by name, rather than
-- scanning something surprising.
local function test_override_must_exist()
  env.set("COSMIC_MAKE_ROOT", fs.join(tmpdir, "root-no-such"))
  local got, err = root.discover("check")
  env.unset("COSMIC_MAKE_ROOT")
  assert(not got, "a missing root must fail")
  assert(err:find("not a directory", 1, true), "got: " .. tostring(err))
end
test_override_must_exist()

print("all root tests passed")
