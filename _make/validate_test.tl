#!/usr/bin/env cosmic
-- Tests for _make.validate: every rule, and every message.
--
-- These messages are the first thing a fresh agent hits, so they are
-- asserted by content, not just by count: a rule that fires with a
-- message nobody can act on has not helped. Each test also asserts the
-- CLEAN case, because a validator that rejects valid projects is worse
-- than one that misses an invalid one.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local project = require("_make.project")
local types = require("_make.types")
local validate = require("_make.validate")

local type Issue = types.Issue
local type Project = types.Project

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree and scan it.
local function fixture(name: string, files: {string: string}): Project
  local root = fs.join(tmpdir, "validate-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  local proj = check.must(project.scan(root))
  return proj
end

--- The issues for a fixture, rendered as the user sees them.
local function issues_of(name: string, files: {string: string}): {Issue}, string
  local issues = validate.validate(fixture(name, files))
  return issues, validate.format_issues(issues)
end

--- Assert exactly one issue, whose rendered line contains each needle.
local function only(name: string, files: {string: string}, needles: {string})
  local issues, text = issues_of(name, files)
  assert(#issues == 1,
    name .. ": expected exactly 1 issue, got " .. #issues .. ":\n" .. text)
  for _, needle in ipairs(needles) do
    assert(text:find(needle, 1, true),
      name .. ": message must name " .. needle .. ", got:\n" .. text)
  end
end

--- Assert a fixture is clean.
local function clean(name: string, files: {string: string})
  local issues, text = issues_of(name, files)
  assert(#issues == 0, name .. ": expected no issues, got:\n" .. text)
end

-- Reserved import paths: a project file resolving to cosmic.*, cosmo.*,
-- tl.* or main.user would shadow the standard library inside its own
-- artifact.
local function test_reserved_import_path()
  only("reserved", {["cosmic/fs.tl"] = "return {}\n"},
    {"cosmic/fs.tl", "reserved import path 'cosmic.fs'"})
  only("reserved-exact", {["cosmo.tl"] = "return {}\n"},
    {"reserved import path 'cosmo'"})
  clean("reserved-ok", {["cosmicish/fs.tl"] = "return {}\n"})
end
test_reserved_import_path()

-- The provider exemption. `cosmo` and `main.user` are a native binding
-- and the wrapper's own slot, so nothing can claim them; `cosmic` and
-- `tl` are Lua trees a project may supply outright, which is how cosmic
-- builds itself and how anyone vendors Teal for runtime use.
local function test_provider_exemption()
  -- Claiming the root takes the whole namespace.
  clean("provides-cosmic", {
      ["cosmic/init.tl"] = "return {}\n",
      ["cosmic/fs.tl"] = "return {}\n",
      ["cosmic/net/init.tl"] = "return {}\n",
    })
  clean("provides-tl", {["tl.lua"] = "return {}\n", ["tl/parse.tl"] = "return {}\n"})
  -- Half a namespace is the hazard the rule was written for: one
  -- binary running two standard libraries, chosen per require().
  only("provides-partial", {["cosmic/fs.tl"] = "return {}\n"},
    {"reserved import path 'cosmic.fs'", "define cosmic/init.tl"})
  -- Unprovidable names are refused even when the root is defined,
  -- because defining it supplies nothing.
  local issues = issues_of("provides-cosmo", {
      ["cosmo/init.tl"] = "return {}\n",
      ["cosmo/unix.tl"] = "return {}\n",
    })
  assert(#issues == 2, "cosmo: expected both files refused, got " .. #issues)
  only("provides-main-user", {["main/user.tl"] = "return {}\n"},
    {"reserved import path 'main.user'", "no project file can provide"})
end
test_provider_exemption()

-- claims() is the fact the artifact half reads: a claimed namespace
-- drops the base's copy from the strip floor, so exactly one definition
-- ships. It must agree with what the validator let through.
local function test_claims()
  local claimed = validate.claims(fixture("claims", {
        ["cosmic/init.tl"] = "return {}\n",
        ["other/init.tl"] = "return {}\n",
      }))
  assert(claimed.cosmic, "cosmic/init.tl must claim 'cosmic'")
  assert(not claimed.tl, "nothing defines tl here")
  assert(not claimed.other, "only reserved namespaces are claimable")
  local none = validate.claims(fixture("claims-none", {
        ["cosmic/fs.tl"] = "return {}\n",
      }))
  assert(not none.cosmic, "a piece of the namespace claims nothing")
end
test_claims()

-- foo.tl beside foo.lua: two files claiming one import path. An error,
-- not a precedence rule -- a precedence rule is a coin flip nobody
-- remembers which way lands.
local function test_duplicate_import_path()
  only("duplicate", {
      ["pkg/a.tl"] = "return {}\n",
      ["pkg/a.lua"] = "return {}\n",
    }, {"duplicate import path 'pkg.a'", "pkg/a.lua"})
end
test_duplicate_import_path()

-- A .d.tl declaring types for a .lua implementation beside it is the
-- pattern .d.tl exists for, and must not read as a collision.
local function test_declaration_beside_lua_is_not_a_duplicate()
  clean("decl", {
      ["pkg/a.lua"] = "return {}\n",
      ["pkg/a.d.tl"] = "local record a end\nreturn a\n",
    })
end
test_declaration_beside_lua_is_not_a_duplicate()

-- cmd/foo cannot import cmd/bar: each cmd directory is private to the
-- binary it builds, which is what makes an artifact's contents
-- derivable from its entry.
local function test_cmd_cannot_import_another_cmd()
  only("cmd-cross", {
      ["cmd/servit/main.tl"] = "local o = require('cmd.fetchit.main')\nreturn o\n",
      ["cmd/fetchit/main.tl"] = "return {}\n",
    }, {"cmd/servit/main.tl", "imports 'cmd.fetchit.main'",
      "cmd/fetchit is private to its own binary"})
  clean("cmd-own", {
      ["cmd/servit/main.tl"] = "local r = require('cmd.servit.routes')\nreturn r\n",
      ["cmd/servit/routes.tl"] = "return {}\n",
    })
end
test_cmd_cannot_import_another_cmd()

-- A cmd/ directory with no entry compiles and ships nothing.
local function test_missing_entry()
  only("no-entry", {["cmd/nomain/lib.tl"] = "return {}\n"},
    {"cmd/nomain", "no entry", "cmd/nomain/main.tl"})
end
test_missing_entry()

-- Filenames: recipe lines are whitespace-split argv with no quoting
-- anywhere, so a space is a filename to refuse rather than an escaping
-- problem to solve.
local function test_filename_hygiene()
  only("space", {["my notes.tl"] = "return {}\n"},
    {"my notes.tl", "path contains whitespace"})
  only("metachar", {["weird&name.tl"] = "return {}\n"},
    {"weird&name.tl", "shell metacharacter: &"})
  only("dollar", {["a$b.tl"] = "return {}\n"},
    {"shell metacharacter: $"})
end
test_filename_hygiene()

-- Whitespace in a DIRECTORY is refused the same way: the whole path
-- reaches a recipe line, not just the basename.
local function test_directory_names_are_checked_too()
  only("space-dir", {["my dir/a.tl"] = "return {}\n"},
    {"my dir/a.tl", "path contains whitespace"})
end
test_directory_names_are_checked_too()

-- Assets are checked too: an asset is copied by a recipe like every
-- other file, so its path travels the same argv.
local function test_assets_are_name_checked()
  only("space-asset", {["my data.json"] = "{}\n"},
    {"my data.json", "path contains whitespace"})
end
test_assets_are_name_checked()

-- `_` marks internal: a directory whose name starts with _ is
-- importable only from within the directory containing it. Root _cli/
-- is project-wide internal; pkg/_priv/ is internal to pkg/.
local function test_internal_imports()
  only("internal", {
      ["pkg/_priv/x.tl"] = "return {}\n",
      ["other.tl"] = "local x = require('pkg._priv.x')\nreturn x\n",
    }, {"other.tl", "imports 'pkg._priv.x'", "internal to 'pkg/'"})
  clean("internal-ok", {
      ["pkg/_priv/x.tl"] = "return {}\n",
      ["pkg/user.tl"] = "local x = require('pkg._priv.x')\nreturn x\n",
    })
  clean("internal-root", {
      ["_cli/main.tl"] = "return {}\n",
      ["anywhere/deep/user.tl"] = "local m = require('_cli.main')\nreturn m\n",
    })
end
test_internal_imports()

-- Imports that leave the project -- the standard library, a pinned
-- dependency's own name -- are not this validator's business. Only
-- edges between project files are.
local function test_external_imports_are_ignored()
  clean("external", {
      ["a.tl"] = "local fs = require('cosmic.fs')\nreturn fs\n",
    })
end
test_external_imports_are_ignored()

-- All rules run: a project with three problems reports three, so a
-- fresh checkout is fixed in one pass instead of one error per run.
local function test_every_rule_runs()
  local issues, text = issues_of("many", {
      ["cosmic/fs.tl"] = "return {}\n",
      ["pkg/a.tl"] = "return {}\n",
      ["pkg/a.lua"] = "return {}\n",
      ["my notes.tl"] = "return {}\n",
      ["cmd/nomain/lib.tl"] = "return {}\n",
    })
  assert(#issues == 4, "expected 4 issues, got " .. #issues .. ":\n" .. text)
end
test_every_rule_runs()

-- Rendered form: `make: <path>: <message>`, one line per issue, so a
-- log line names the file first.
local function test_format_issues()
  local text = validate.format_issues({
      {path = "a.tl", message = "something"},
      {path = "b.tl", message = "else"},
    })
  assert(text == "make: a.tl: something\nmake: b.tl: else",
    "got: " .. text)
end
test_format_issues()

-- The import scan reads literal require() calls, in file order.
local function test_imports_of()
  local path = fs.join(tmpdir, "imports-of.tl")
  assert(fs.write(path, "local a = require('pkg.a')\n" ..
      'local b = require("pkg.b")\nlocal c = require "pkg.c"\nreturn {a, b, c}\n'))
  local got = validate.imports_of(path)
  assert(table.concat(got, ",") == "pkg.a,pkg.b,pkg.c",
    "got: " .. table.concat(got, ","))
end
test_imports_of()

-- Make's own significant characters are as dangerous as the shell's
-- here, because `o/project.mk` and the rules file ARE make input: a
-- `=` left of a rule colon parses as an assignment, a `:` splits a
-- prerequisite list, a `%` interacts with pattern-rule stems. All
-- silent-misbuild shapes, where the design's posture is refusal by
-- name.
local function test_make_significant_characters_are_refused()
  for _, bad in ipairs({"a=b.tl", "a:b.tl", "a%b.tl", "a,b.tl"}) do
    local _, text = issues_of("mkchars", {
        ["main.tl"] = "print('x')\n",
        [bad] = "return {}\n",
      })
    assert(text:find("metacharacter", 1, true),
      bad .. " should be refused, got: " .. text)
  end
end
test_make_significant_characters_are_refused()

-- A root init.tl compiles and then silently never ships: dropping the
-- trailing `init` leaves the project root with no name to be required
-- by, so `stage_entry` produces nothing for it.
local function test_root_init_is_refused()
  local _, text = issues_of("rootinit", {
      ["main.tl"] = "print('x')\n",
      ["init.tl"] = "return {}\n",
    })
  assert(text:find("no import path", 1, true), "got: " .. text)
  assert(text:find("main.tl", 1, true),
    "and points at the thing they probably meant, got: " .. text)
end
test_root_init_is_refused()

-- Two binaries with one name share o/bin/<name>: the second overwrites
-- the first, and which is second follows iteration order.
local function test_duplicate_binary_names_are_refused()
  local _, text = issues_of("dupbin", {
      ["main.tl"] = "print('root')\n",
      ["cmd/validate-dupbin/main.tl"] = "print('cmd')\n",
    })
  assert(text:find("already declared by", 1, true), "got: " .. text)
end
test_duplicate_binary_names_are_refused()

-- The import scan ERRORS on what it finds, so a false positive refuses
-- a project for code that never runs.
local function test_import_scan_ignores_comments_and_suffixes()
  local path = fs.join(tmpdir, "imports-noise.tl")
  assert(fs.write(path,
      "-- local x = require('cmd.other.main')\n" ..
      "local ok = myrequire('cmd.other.main')\n" ..
      "local real = require('pkg.a')\n" ..
      "return {ok, real}\n"))
  local got = validate.imports_of(path)
  assert(table.concat(got, ",") == "pkg.a",
    "only the real require counts, got: " .. table.concat(got, ","))
end
test_import_scan_ignores_comments_and_suffixes()

print("all validate tests passed")
