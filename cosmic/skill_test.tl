#!/usr/bin/env cosmic
-- test cosmic --skill

local check = require("cosmic.check")
local spawn = require("cosmic.child")
local fs = require("cosmic.fs")
local cenv = require("cosmic.env")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- drop LUA_PATH so the test exercises the bundled libraries, not the repo
local function clean_env(): {string}
  return cenv.list({drop = {"LUA_PATH", "LUA_CPATH"}})
end

local function test_skill_writes_file()
  local dir = fs.join(tmpdir, "skill-out")
  local __r1 = check.must(check.must(spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()})):wait())
  local ok, out = __r1.ok, __r1.stdout
  assert(ok, "cosmic --skill should succeed, got: " .. tostring(out))
  local skill_path = fs.join(dir, "SKILL.md")
  assert(fs.isfile(skill_path), "SKILL.md should exist at " .. skill_path)
  local c = check.must(fs.read(skill_path))
  assert(c:match("^%-%-%-\n"), "should start with YAML frontmatter")
  assert(c:match("name: cosmic"), "frontmatter should have name")
  assert(c:match("description:"), "frontmatter should have description")
  assert(c:match("%-%-%-\n\n"), "frontmatter should close with ---")
end
test_skill_writes_file()

local function test_skill_content()
  local dir = fs.join(tmpdir, "skill-content")
  local __r2 = check.must(check.must(spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()})):wait())
  local ok, _ = __r2.ok, __r2.stdout
  assert(ok, "cosmic --skill should succeed")
  local content = check.must(fs.read(fs.join(dir, "SKILL.md")))
  assert(content:find("curl", 1, true),
    "should contain curl download command")
  assert(content:find("releases/latest/download/cosmic%-lua"),
    "should contain releases URL")
  assert(content:find("%-%-welcome"),
    "should mention --welcome")
  assert(content:find("%-%-help"),
    "should mention --help")
  assert(content:find("%-%-docs"),
    "should mention --docs")
  assert(content:find("script%.tl"),
    "should show how to run a script")
  -- description should mention key capabilities for agent discovery
  assert(content:find("HTTP"), "description should mention HTTP")
  assert(content:find("JSON"), "description should mention JSON")
  assert(content:find("SQLite"), "description should mention SQLite")
  assert(content:find("filesystem"), "description should mention filesystem")
  assert(content:find("child process"), "description should mention child processes")
  -- commands should use ./cosmic, not ./cosmic-lua
  assert(content:find("./cosmic --", 1, true),
    "commands should use ./cosmic")
  assert(not content:find("./cosmic-lua", 1, true),
    "commands should not use ./cosmic-lua")
end
test_skill_content()

local function test_skill_creates_nested_dir()
  local dir = fs.join(tmpdir, "skill-nested", "a", "b")
  local __r3 = check.must(check.must(spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()})):wait())
  local ok, _ = __r3.ok, __r3.stdout
  assert(ok, "cosmic --skill should create nested directories")
  assert(fs.isfile(fs.join(dir, "SKILL.md")), "SKILL.md should exist in nested dir")
end
test_skill_creates_nested_dir()

local function test_skill_prints_path()
  local dir = fs.join(tmpdir, "skill-path")
  local __r4 = check.must(check.must(spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()})):wait())
  local ok, out = __r4.ok, __r4.stdout
  assert(ok, "cosmic --skill should succeed")
  local s = out
  local expected = fs.join(dir, "SKILL.md")
  assert(s:find(expected, 1, true), "should print path to SKILL.md, got: " .. s)
end
test_skill_prints_path()
