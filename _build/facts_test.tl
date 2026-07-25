#!/usr/bin/env cosmic
-- Tests for the 3e bridge's facts generator.
--
-- The compile rule takes `srcdeps_<stem>` as prerequisites, so what this
-- file writes IS the build's dependency graph. Two properties matter and
-- both are asserted here: the closure is transitive (a module three
-- imports away still rebuilds its importer), and the write is
-- conditional (make re-execs itself whenever an included makefile is
-- remade, so an unconditional write would restart every build forever).

local check = require("cosmic.check")
local facts = require("_build.facts")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

--- Build a fixture tree, run the generator inside it, return the facts.
local function generate(name: string, files: {string: string}): string, string
  local root = fs.join(tmpdir, "facts-" .. name)
  fs.rmrf(root)
  assert(fs.makedirs(root))
  for rel, content in pairs(files) do
    local path = fs.join(root, rel)
    assert(fs.makedirs(fs.dirname(path)))
    assert(fs.write(path, content))
  end
  local cwd = check.must(fs.getcwd())
  local out = fs.join(root, "project.mk")
  assert(fs.chdir(root))
  local code = facts.main(out)
  assert(fs.chdir(cwd))
  assert(code == 0, name .. ": generator exited " .. code)
  return check.must(fs.read(out)), out
end

--- The value of one variable in the generated file.
local function var_of(content: string, name: string): string
  local line = content:match("\n" .. name .. " := ([^\n]*)")
  or content:match("^" .. name .. " := ([^\n]*)")
  return line or "<missing>"
end

-- A closure is transitive: main imports mid, mid imports leaf, so
-- editing leaf must rebuild main. This is the property the compile rule
-- rides on -- a strict compile type-checks against what it imports.
local function test_closure_is_transitive()
  local content = generate("chain", {
      ["main.tl"] = "local m = require('mid')\nreturn m\n",
      ["mid.tl"] = "local l = require('leaf')\nreturn l\n",
      ["leaf.tl"] = "return {}\n",
    })
  local main_deps = var_of(content, "srcdeps_main")
  assert(main_deps:find("mid.tl", 1, true),
    "main must depend on what it imports, got: " .. main_deps)
  assert(main_deps:find("leaf.tl", 1, true),
    "…and on what THAT imports, got: " .. main_deps)
  assert(var_of(content, "srcdeps_leaf") == "",
    "a leaf imports nothing, got: " .. var_of(content, "srcdeps_leaf"))
end
test_closure_is_transitive()

-- An unrelated module is NOT a prerequisite. Without this the closures
-- would be indistinguishable from "everything depends on everything",
-- which is what the rule had before and is why nothing rebuilt.
local function test_closure_excludes_unrelated()
  local content = generate("unrelated", {
      ["main.tl"] = "local m = require('used')\nreturn m\n",
      ["used.tl"] = "return {}\n",
      ["other.tl"] = "return {}\n",
    })
  local main_deps = var_of(content, "srcdeps_main")
  assert(main_deps:find("used.tl", 1, true), "imports are prerequisites")
  assert(not main_deps:find("other.tl", 1, true),
    "a module nobody imports is not a prerequisite, got: " .. main_deps)
end
test_closure_excludes_unrelated()

-- Write-if-changed, and it is load-bearing rather than tidy: make
-- re-execs when an included makefile is remade, so a generator that
-- always writes turns every build into two.
local function test_write_is_conditional()
  local files: {string: string} = {
    ["main.tl"] = "local m = require('mid')\nreturn m\n",
    ["mid.tl"] = "return {}\n",
  }
  local _, out = generate("stable", files)
  local first = (check.must(fs.stat(out)) as fs_types.Stat):mtim() -- cast: mixed-representation Stat

  local root = fs.dirname(out)
  local cwd = check.must(fs.getcwd())
  assert(fs.chdir(root))
  assert(facts.main(out) == 0, "second run should succeed")
  assert(fs.chdir(cwd))

  local second = (check.must(fs.stat(out)) as fs_types.Stat):mtim() -- cast: mixed-representation Stat
  assert(first == second,
    "an unchanged tree must not rewrite the facts (make would re-exec)")
end
test_write_is_conditional()

print("all facts tests passed")
