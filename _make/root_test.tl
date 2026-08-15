#!/usr/bin/env cosmic
-- Tests for _make.root: what counts as a project root, and the
-- guard that refuses an ambiguous one.
--
-- The guard is the whole point of the ancestor scan -- discovery itself
-- never walks upward -- so both halves are asserted: it fires from
-- inside a project, and it stays quiet in an ordinary directory of
-- source files, which is what a false positive would look like.

local env = require("cosmic.env")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local root = require("_make.root")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Make a directory tree, returning its root.
local function tree(name: string, files: {string: string}): string
  local dir = fs.join(tmpdir, "root-" .. name)
  assert(fs.remove_all(dir))
  assert(fs.make_dirs(dir))
  for rel, content in pairs(files) do
    local path = fs.join(dir, rel)
    assert(fs.make_dirs(fs.dirname(path)))
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
  assert(env.unset("COSMIC_MAKE_ROOT"))
  local cwd = fs.cwd()
  assert(fs.set_cwd(fs.join(proj, "db")))
  local got, err = root.discover("check")
  assert(fs.set_cwd(cwd))
  if saved then
    assert(env.set("COSMIC_MAKE_ROOT", saved))
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
  assert(env.set("COSMIC_MAKE_ROOT", sub))
  local got, err = root.discover("check")
  assert(env.unset("COSMIC_MAKE_ROOT"))
  assert(got == sub, "expected " .. sub .. ", got " .. tostring(got) ..
    " (" .. tostring(err) .. ")")
end
test_override_suppresses_the_guard()

-- A named root that is not a directory fails by name, rather than
-- scanning something surprising.
local function test_override_must_exist()
  assert(env.set("COSMIC_MAKE_ROOT", fs.join(tmpdir, "root-no-such")))
  local got, err = root.discover("check")
  assert(env.unset("COSMIC_MAKE_ROOT"))
  assert(not got, "a missing root must fail")
  assert(err:find("not a directory", 1, true), "got: " .. tostring(err))
end
test_override_must_exist()

-- A build directory is a MIRROR of the project that produced it, so
-- every marker is on both sides and shape cannot tell them apart. The
-- two makefiles `--make` writes can: without this, a test whose scratch
-- directory lives under `o/` finds `o/` above it and every `--make` run
-- from there refuses with "ambiguous root".
local function test_a_build_directory_is_not_a_root()
  local dir = tree("build-output", {
      ["cosmic.mk"] = "# rules\n",
      ["project.mk"] = "# facts\n",
      ["main.lua"] = "return 0\n",
      ["cmd/tool/main.lua"] = "return 0\n",
    })
  assert(not root.is_root(dir),
    dir .. " has both makefiles: it is output, not a project")
end
test_a_build_directory_is_not_a_root()

-- Only both together. One of the two is an ordinary file a project may
-- well have -- this repo committed a `cosmic.mk` of its own for the
-- whole bridge -- and treating either alone as "output" would make a
-- real root undiscoverable.
local function test_one_makefile_alone_is_not_output()
  local rules = tree("rules-only", {
      ["cosmic.mk"] = "# rules\n",
      ["main.tl"] = "return 0\n",
    })
  assert(root.is_root(rules), "a project may commit a cosmic.mk")
  local facts = tree("facts-only", {
      ["project.mk"] = "# facts\n",
      ["main.tl"] = "return 0\n",
    })
  assert(root.is_root(facts), "a project may commit a project.mk")
end
test_one_makefile_alone_is_not_output()

-- And the consequence the fix exists for: the guard stays quiet for a
-- directory whose only ancestor-shaped thing is a build tree.
local function test_no_ambiguity_under_a_build_directory()
  local out = tree("under-output", {
      ["cosmic.mk"] = "# rules\n",
      ["project.mk"] = "# facts\n",
      ["cmd/tool/main.lua"] = "return 0\n",
    })
  local scratch = fs.join(out, "some_test.tl.test.tmp.d")
  assert(fs.make_dirs(scratch))
  assert(not root.ancestor_root(scratch),
    "a build directory must not be reported as the ancestor project")
end
test_no_ambiguity_under_a_build_directory()

-- Anything under `<root>/o/` is something a build PUT there — a staged
-- tree, a generator's output, a test's own scratch directory — so a
-- project inside it is deliberate rather than the accident the guard
-- exists to catch. Without this, every nested `--make` run from a
-- test's scratch directory would refuse with "ambiguous root", naming
-- the repo whose build put the directory there.
local function test_the_walk_stops_at_an_output_directory()
  local proj = tree("output-walk", {
      ["main.tl"] = "print('x')\n",
      ["o/some_test.tl.test.tmp.d/run/main.tl"] = "print('y')\n",
    })
  local inner = fs.join(proj, "o/some_test.tl.test.tmp.d/run")
  assert(not root.ancestor_root(inner),
    "a directory under the build output has no ambiguous ancestor")
  -- And the guard still fires for an ordinary subdirectory.
  assert(root.ancestor_root(fs.join(proj, "pkg")) == proj,
    "a source subdirectory is still inside its project")
end
test_the_walk_stops_at_an_output_directory()

-- A directory is not a project until it declares itself. Without this
-- refusal EVERY directory would be one: `--make build` in an empty one
-- would report PASS over nothing, and `--make test` would write `o/`
-- plus a 1.5 MB extracted engine into whatever directory you were
-- standing in. It is the twin of the ambiguous-root refusal above --
-- that one asks about ancestors, this one asks about the cwd.
local function test_a_bare_directory_is_not_a_project()
  local dir = tree("bare-dir", {["notes.tl"] = "return {}\n"})
  local saved = fs.cwd() as string -- cast: cwd exists in a test
  assert(fs.set_cwd(dir))
  local found, err = root.discover("build")
  assert(fs.set_cwd(saved))
  assert(not found, "a directory of Teal files is not a root")
  assert(err:find("not a project", 1, true), "got: " .. err)
  assert(err:find("main.tl", 1, true) and err:find(".cosmicignore", 1, true),
    "and names how to declare one, got: " .. err)
  assert(err:find("COSMIC_MAKE_ROOT", 1, true),
    "and names the way to mean it anyway, got: " .. err)
end
test_a_bare_directory_is_not_a_project()

-- A root make cannot NAME is refused up front. Prerequisites are
-- whitespace-separated with no escape that survives, and `o/project.mk`
-- assigns the cosmic path into one -- so a checkout under `My
-- Projects/` would produce "no rule to make target `/Users/me/My'",
-- which says nothing about the space being the problem.
local function test_a_root_with_whitespace_is_refused()
  local dir = tree("has space", {["main.tl"] = "print('x')\n"})
  -- Through the override, because that path skips the declaration
  -- guard: naming a root must not be a way around this one.
  assert(env.set(root.ROOT_ENV, dir, true))
  local found, err = root.discover("build")
  assert(env.unset(root.ROOT_ENV))
  assert(not found, "a root make cannot express is not a root")
  assert(err:find("whitespace", 1, true), "and says why, got: " .. err)
  assert(err:find(dir, 1, true), "naming the path, got: " .. err)
end
test_a_root_with_whitespace_is_refused()

-- Whitespace is not the only character that corrupts a recipe line or
-- the `COSMIC` variable assignment: `(`, `$`, `:`, `=`, `%`
-- all mean something to make. The same `validate.METACHARACTERS` list
-- a project PATH is refused for applies to the root itself.
local function test_a_root_with_a_metacharacter_is_refused()
  local dir = tree("has(paren)", {["main.tl"] = "print('x')\n"})
  assert(env.set(root.ROOT_ENV, dir, true))
  local found, err = root.discover("build")
  assert(env.unset(root.ROOT_ENV))
  assert(not found, "a root make cannot express is not a root")
  assert(err:find("make-significant", 1, true), "and says why, got: " .. err)
  assert(err:find(dir, 1, true), "naming the path, got: " .. err)
end
test_a_root_with_a_metacharacter_is_refused()

-- `resolve_self` is what makes argv[-1] usable as "the running cosmic
-- binary": a real file at (or under) the cwd wins as-is.
local function test_resolve_self_resolves_a_real_path()
  local dir = tree("self-real", {["cosmic"] = "print('x')\n"})
  local saved = fs.cwd() as string -- cast: cwd exists in a test
  assert(fs.set_cwd(dir))
  local self = root.resolve_self("cosmic")
  assert(fs.set_cwd(saved))
  assert(self == fs.absolute_path(fs.join(dir, "cosmic")), "got: " .. tostring(self))
end
test_resolve_self_resolves_a_real_path()

-- A bare, PATH-invoked argv0 that names nothing under the cwd falls
-- back to a real $PATH search instead of `fs.absolute_path`'s phantom
-- `<cwd>/name`: resolving to that phantom path would silently degrade
-- the tool stamps whenever a build runs from a directory that happens
-- not to contain the binary.
local function test_resolve_self_falls_back_to_path_search()
  local dir = tree("self-path", {})
  local saved = fs.cwd() as string -- cast: cwd exists in a test
  assert(fs.set_cwd(dir))
  local self = root.resolve_self("ls")
  assert(fs.set_cwd(saved))
  assert(self == proc.which("ls"), "got: " .. tostring(self))
  assert(self ~= fs.join(dir, "ls"), "must not be the cwd-relative phantom")
end
test_resolve_self_falls_back_to_path_search()

-- Neither the cwd nor $PATH has it: unresolvable stays unresolvable,
-- rather than a phantom path that later fails somewhere less clear.
local function test_resolve_self_returns_nil_when_unresolvable()
  local self = root.resolve_self("cosmic_xyz_does_not_exist_12345")
  assert(self == nil, "got: " .. tostring(self))
end
test_resolve_self_returns_nil_when_unresolvable()
