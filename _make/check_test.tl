#!/usr/bin/env cosmic
-- Tests for `cosmic --make check`, from both directions.
--
-- Most of them spawn the built binary against fixture trees with cwd
-- set to the fixture, because that is the whole contract: the root is
-- the current directory, the banner names it, and the verb type-checks
-- the project the model found there.
--
-- The last block runs the same dispatcher in process, against a named
-- root. That is the other half of the surface -- `--make` is a library
-- call with a CLI in front of it -- and it is what makes the verb's own
-- lines show up in coverage, since a spawned child's are attributed to
-- the binary's embedded copy and vanish.

local check = require("cosmic.check")
local cenv = require("cosmic.env")
local fs = require("cosmic.fs")
local mcheck = require("_make.check")
local mfetch = require("_make.fetch")
local mk = require("_make")
local spawn = require("cosmic.child")

local cosmic = fs.abspath(fs.join(os.getenv("TEST_BIN"), "cosmic"))
local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local record Run
  code: integer
  out: string
  err: string
end

--- Build a fixture tree, returning its absolute root.
local function fixture(name: string, files: {string: string}): string
  local root = fs.join(tmpdir, "check-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  -- A directory is not a project until it says so. Fixtures that
  -- declare a root themselves keep theirs; the rest get the marker
  -- that means "yes, this one" so the fixture tests what it is about.
  if not fs.isfile(fs.join(root, "main.tl"))
  and not fs.isfile(fs.join(root, "main.lua"))
  and not fs.isfile(fs.join(root, ".cosmicignore")) then
    assert(fs.write(fs.join(root, ".cosmicignore"), ""))
  end
  return root
end

--- Run `cosmic --make …` with cwd inside the given directory.
local function make(dir: string, ...: string): Run
  local argv: {string} = {cosmic, "--make"}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local h = check.must(spawn.spawn(argv, {cwd = dir}))
  local r = check.must(h:wait())
  return {code = r.code or 128, out = r.stdout or "", err = r.stderr or ""}
end

--- A project whose packages import each other, plus every kind of file
--- the model classifies but the checker must leave alone.
local function app(name: string): string
  return fixture(name, {
      ["main.tl"] = "local db = require('db')\nprint(db.name())\n",
      ["db/init.tl"] = "local u = require('_internal.util')\n" ..
      "local record Db\n  name: function(): string\nend\n" ..
      "local M: Db = {name = function(): string return u.tag() end}\nreturn M\n",
      ["db/query.tl"] = "local record Q\n  all: function(): {string}\nend\n" ..
      "local M: Q = {all = function(): {string} return {} end}\nreturn M\n",
      ["db/query_test.tl"] = "local q = require('db.query')\n" ..
      "assert(#q.all() == 0)\n",
      ["_internal/util.tl"] = "local record U\n  tag: function(): string\nend\n" ..
      "local M: U = {tag = function(): string return 'app' end}\nreturn M\n",
      ["db/testdata/broken.tl"] = "this is not teal at all ((\n",
      ["legacy.lua"] = "return { x = 1 }\n",
      ["schema.sql"] = "CREATE TABLE t(x);\n",
    })
end

-- The happy path, and with it three things at once: the banner names
-- the root, the verdict is machine-readable, and cross-package imports
-- resolve because the project root IS the module root.
local function test_clean_project_passes()
  local root = app("clean")
  local r = make(root, "check")
  assert(r.code == 0, "a clean project must pass, got " ..
    r.code .. ": " .. r.err .. r.out)
  assert(r.out:find("make: root=" .. root, 1, true),
    "every run names its root, got: " .. r.out)
  -- 5 .tl sources: main, db/init, db/query, db/query_test, _internal/util.
  -- Not legacy.lua (Lua is not type-checked), not schema.sql, and NOT
  -- db/testdata/broken.tl, which would fail to parse if it were.
  assert(r.out:find("check: PASS (5 files)", 1, true),
    "expected a PASS verdict over 5 files, got: " .. r.out)
end
test_clean_project_passes()

-- A type error fails the run, names the file and line, and the verdict
-- counts files rather than errors -- one broken file is one thing to go
-- fix.
local function test_type_error_fails()
  local root = fixture("typeerror", {
      ["a.tl"] = "local x: integer = 'not an integer'\nprint(x)\n",
      ["b.tl"] = "return {}\n",
    })
  local r = make(root, "check")
  assert(r.code == 1, "a type error must fail, got " .. r.code)
  assert(r.err:find("a.tl:1", 1, true),
    "the error must name file and line, got: " .. r.err)
  assert(r.out:find("check: FAIL (1 of 2 files)", 1, true),
    "expected a FAIL verdict, got: " .. r.out)
end
test_type_error_fails()

-- An import that resolves to nothing is a type error, which is what
-- makes the passing case above evidence that resolution works at all.
local function test_unresolvable_import_fails()
  local root = fixture("unresolved", {
      ["a.tl"] = "local m = require('db.nope')\nreturn m\n",
    })
  local r = make(root, "check")
  assert(r.code == 1, "an unresolvable import must fail, got " .. r.code)
end
test_unresolvable_import_fails()

-- Validation runs first and is fatal: a project whose filenames cannot
-- survive a recipe line has a problem the type checker cannot describe,
-- and reporting both at once buries it.
local function test_validation_precedes_type_checking()
  local root = fixture("validation", {
      ["my notes.tl"] = "return {}\n",
      ["broken.tl"] = "local x: integer = 'nope'\nreturn x\n",
    })
  local r = make(root, "check")
  assert(r.code == 1, "a validation error must fail, got " .. r.code)
  assert(r.err:find("path contains whitespace", 1, true),
    "expected the validator's message, got: " .. r.err)
  assert(r.out:find("check: FAIL (1 validation error)", 1, true),
    "the verdict must say it stopped at validation, got: " .. r.out)
  assert(not r.err:find("broken.tl", 1, true),
    "type checking must not have run, got: " .. r.err)
end
test_validation_precedes_type_checking()

-- Selection is by path, and a directory selects its subtree. It changes
-- which files are checked, never what the project is -- the model is
-- always scanned whole, so a partial run resolves imports the way a
-- full one does.
local function test_selection_by_path()
  local root = app("selection")
  local dir = make(root, "check", "db")
  assert(dir.code == 0, "selecting db/ should pass: " .. dir.err)
  assert(dir.out:find("check: PASS (3 files)", 1, true),
    "db/ holds 3 checkable files, got: " .. dir.out)

  local one = make(root, "check", "db/query.tl")
  assert(one.code == 0, "selecting one file should pass: " .. one.err)
  assert(one.out:find("check: PASS (1 file)", 1, true),
    "expected a single-file verdict, got: " .. one.out)

  local both = make(root, "check", "db/query.tl", "main.tl")
  assert(both.out:find("check: PASS (2 files)", 1, true),
    "several paths are accepted, got: " .. both.out)
end
test_selection_by_path()

-- A selection matching nothing is an error, not a silent zero-file
-- pass: "0 files checked, PASS" is how a typo becomes a green build.
local function test_empty_selection_fails()
  local root = app("badselection")
  local r = make(root, "check", "nope")
  assert(r.code == 1, "an empty selection must fail, got " .. r.code)
  assert(r.err:find("nothing to do under: nope", 1, true),
    "the message must name the path, got: " .. r.err)
end
test_empty_selection_fails()

-- An empty directory is a valid project with nothing to do. A fresh
-- project must not fail on a stage that had no material.
local function test_empty_project_passes()
  local root = fixture("emptyproject", {})
  local r = make(root, "check")
  assert(r.code == 0, "an empty project must pass, got " .. r.code .. ": " .. r.err)
  assert(r.out:find("check: PASS (0 files)", 1, true), "got: " .. r.out)
end
test_empty_project_passes()

-- Running from inside a project is refused rather than silently
-- checking a truncated file list.
local function test_ancestor_guard_end_to_end()
  local root = app("guard")
  local r = make(fs.join(root, "db"), "check")
  assert(r.code == 1, "running inside a project must be refused")
  assert(r.err:find("ambiguous root", 1, true), "got: " .. r.err)
  assert(r.err:find(root, 1, true), "the refusal must name the likely root")
end
test_ancestor_guard_end_to_end()

-- The verb vocabulary is closed and self-describing: an unknown verb
-- lists what exists, and a verb the design defines but this slice does
-- not ship says so instead of pretending never to have heard of it.
local function test_verb_vocabulary()
  local root = app("verbs")
  local unknown = make(root, "frobnicate")
  assert(unknown.code == 1, "an unknown verb must fail")
  assert(unknown.err:find("unknown verb 'frobnicate'", 1, true),
    "got: " .. unknown.err)
  assert(unknown.err:find("make: verbs: ", 1, true) and
    unknown.err:find("check", 1, true),
    "an unknown verb must list the verbs that exist, got: " .. unknown.err)

  -- `run` is implemented and takes a PATH. Bare, it must say what it
  -- wants rather than run the whole project or do nothing: a verb whose
  -- argument is the thing it acts on has no whole-project reading.
  local bare = make(root, "run")
  assert(bare.code == 1, "run with no target must fail")
  assert(bare.err:find("run needs a path", 1, true), "got: " .. bare.err)

  -- `enforce` carries the planned-verb contract now that `run` does not.
  local planned = make(root, "enforce")
  assert(planned.code == 1, "an unimplemented verb must fail")
  assert(planned.err:find("planned but not implemented yet", 1, true),
    "got: " .. planned.err)
end
test_verb_vocabulary()

-- Selection space had no bottom: every `-`-prefixed token fell through
-- into it and died as a path, so `--make fmt --fix` -- a spelling the
-- design's own verb table promises -- reported `nothing to do under:
-- --fix`. Reserving the namespace is the same durability move the
-- planned-verb rows make for verbs.
local function test_flags_are_a_namespace()
  local root = app("flags")
  local unknown = make(root, "check", "--nope")
  assert(unknown.code == 1, "an unknown flag must fail")
  assert(unknown.err:find("unknown flag '--nope' for check", 1, true),
    "got: " .. unknown.err)

  local misplaced = make(root, "check", "--baseline")
  assert(misplaced.code == 1, "a flag on the wrong verb must fail")
  assert(misplaced.err:find("belongs to `coverage`", 1, true),
    "got: " .. misplaced.err)

  -- A rewrite from a narrowed run is a floor built from partial data:
  -- every unselected file measures zero and its row craters.
  local narrowed = make(root, "coverage", "--baseline", "db")
  assert(narrowed.code == 1, "--baseline must refuse a selection")
  assert(narrowed.err:find("takes no paths", 1, true),
    "got: " .. narrowed.err)
end
test_flags_are_a_namespace()

-- `fmt --fix` rewrites rather than reports, in process: a `.fmt.got`
-- records a verdict ABOUT a file, and rewriting the file makes that
-- verdict about something that no longer exists.
local function test_fmt_fix_rewrites()
  local root = fixture("fmtfix", {
      ["main.tl"] = "print('x')\n",
      ["ugly.tl"] = "local  x =1\nprint(x)\n",
    })
  local r = make(root, "fmt", "--fix")
  assert(r.code == 0, "fmt --fix should succeed: " .. r.err)
  assert(r.out:find("rewrote ugly.tl", 1, true), "got: " .. r.out)
  local body = check.must(fs.read(fs.join(root, "ugly.tl")))
  assert(body == "local x = 1\nprint(x)\n", "got: " .. body)

  -- and says nothing about a file that was already formatted
  local again = make(root, "fmt", "--fix")
  assert(again.code == 0, "a second run should succeed: " .. again.err)
  assert(again.out:find("0 rewritten", 1, true), "got: " .. again.out)
end
test_fmt_fix_rewrites()

-- `help` is a verb you asked for, so it succeeds on stdout. Without
-- the verb, the text reaches the reader only as the unknown-verb
-- error's incidental output -- the right text, on stderr, under exit 1
-- -- while docs/build.md tells people to run it. It also answers
-- outside a project root, which is where "what are the verbs" gets
-- asked.
local function test_help_is_a_verb()
  local root = app("help")
  local h = make(root, "help")
  assert(h.code == 0, "help must succeed, got " .. h.code .. ": " .. h.err)
  assert(h.out:find("make: verbs:", 1, true), "got: " .. h.out)
  assert(h.out:find("help", 1, true), "help must name itself: " .. h.out)
  assert(h.out:find("ci", 1, true), "got: " .. h.out)
  assert(h.out:find("make: planned:", 1, true), "got: " .. h.out)

  local bare = fixture("help-no-project", {})
  local outside = make(bare, "help")
  assert(outside.code == 0,
    "help must answer outside a project root, got " .. outside.code ..
    ": " .. outside.err)
  assert(outside.out:find("make: verbs:", 1, true), "got: " .. outside.out)
end
test_help_is_a_verb()

-- `--make` with no verb is a usage error, not a default action:
-- silently doing something with no verb is worse than saying so.
local function test_bare_make_is_a_usage_error()
  local root = app("bare")
  local h = check.must(spawn.spawn({cosmic, "--make"}, {cwd = root}))
  local r = check.must(h:wait())
  assert(r.code ~= 0, "bare --make must not exit 0")
  assert((r.stderr or ""):find("--make requires", 1, true),
    "got: " .. tostring(r.stderr))
end
test_bare_make_is_a_usage_error()

-- COSMIC_MAKE_ROOT names a root for callers that cannot chdir, and the
-- banner reports the root that was actually used.
local function test_root_override()
  local root = app("override")
  local elsewhere = fixture("override-elsewhere", {})
  local h = check.must(spawn.spawn({cosmic, "--make", "check"}, {
        cwd = elsewhere,
        env = {"PATH=" .. (os.getenv("PATH") or ""),
          "COSMIC_MAKE_ROOT=" .. root},
      }))
  local r = check.must(h:wait())
  assert(r.code == 0, "the named root should check cleanly, got " ..
    tostring(r.code) .. ": " .. tostring(r.stderr))
  assert((r.stdout or ""):find("make: root=" .. root, 1, true),
    "the banner must name the root actually used, got: " .. tostring(r.stdout))
end
test_root_override()

-- In process, against a named root. `mk.run` chdirs into the root it
-- resolved, so the caller's cwd is saved and restored around every
-- call: a verb that leaves the process somewhere else is a verb no
-- caller can use twice.
local function in_process(root: string, ...: string): integer
  local cwd = check.must(fs.getcwd())
  cenv.set("COSMIC_MAKE_ROOT", root)
  local argv: {string} = {}
  for _, a in ipairs({...}) do
    argv[#argv + 1] = a
  end
  local code = mk.run(argv)
  cenv.unset("COSMIC_MAKE_ROOT")
  assert(fs.chdir(cwd))
  return code
end

local function test_in_process_dispatch()
  local root = app("inproc")
  assert(in_process(root, "check") == 0, "a clean project must pass in process")
  assert(in_process(root, "check", "db") == 0, "selection works in process")
  assert(in_process(root, "check", "nope") == 1, "a bad selection fails")
  assert(in_process(root, "run") == 1, "a planned verb fails")
  assert(in_process(root, "frobnicate") == 1, "an unknown verb fails")
  assert(in_process(root) == 1, "no verb at all fails")

  local broken = fixture("inproc-invalid", {["my notes.tl"] = "return {}\n"})
  assert(in_process(broken, "check") == 1, "a validation error fails")

  local typed = fixture("inproc-typed", {
      ["a.tl"] = "local x: integer = 'nope'\nreturn x\n",
    })
  assert(in_process(typed, "check") == 1, "a type error fails")
end
test_in_process_dispatch()

-- The vocabulary is data, and the usage text is built from it: a verb
-- added to one list without the other would print a menu that lies.
local function test_usage_lists_the_vocabulary()
  local text = mk.usage()
  for _, verb in ipairs(mk.IMPLEMENTED) do
    assert(text:find(verb, 1, true), "usage must name " .. verb)
  end
  for _, verb in ipairs(mk.PLANNED) do
    assert(text:find(verb, 1, true), "usage must name " .. verb)
  end
end
test_usage_lists_the_vocabulary()

-- `check.run` and `fetch.run` are module functions, and each refuses a
-- selection naming nothing on its own. The `--make` pre-flight now
-- refuses first, so these branches are unreachable from the CLI -- but
-- a module function may not assume its caller pre-flighted, so the
-- guard stays and is tested where it is still reachable: here.
local function test_the_verbs_refuse_a_bad_selection_on_their_own()
  local root = fixture("ownrefusal", {
      ["main.tl"] = "print('hi')\n",
      ["db/init.tl"] = "return {}\n",
    })
  local proj = check.must(mk.scan(root))
  assert(mcheck.run(proj, {"nope"}) == 1,
    "check.run must refuse a path that names nothing")
  assert(mfetch.run(proj, {"nope"}) == 1,
    "fetch.run must refuse a path that names nothing")
end
test_the_verbs_refuse_a_bad_selection_on_their_own()

print("all make check tests passed")
