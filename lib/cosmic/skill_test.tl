#!/usr/bin/env cosmic
-- test cosmic --skill

local path = require("cosmo.path")
local spawn = require("cosmic.child")
local unix = require("cosmo.unix")
local fs = require("cosmic.fs")
local cio = require("cosmic.io")

local cosmic = path.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

local function clean_env(): {string}
  local env: {string} = {}
  for _, entry in ipairs(unix.environ()) do
    if not entry:match("^LUA_PATH=") and not entry:match("^LUA_CPATH=") then
      env[#env + 1] = entry
    end
  end
  return env
end

local function test_skill_writes_file()
  local dir = fs.join(tmpdir, "skill-out")
  local ok, out = spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill should succeed, got: " .. tostring(out))
  local skill_path = fs.join(dir, "SKILL.md")
  assert(fs.isfile(skill_path), "SKILL.md should exist at " .. skill_path)
  local content, err = cio.slurp(skill_path)
  assert(content, "failed to read SKILL.md: " .. tostring(err))
  assert(content:match("^%-%-%-\n"), "should start with YAML frontmatter")
  assert(content:match("name: cosmic"), "frontmatter should have name")
  assert(content:match("description:"), "frontmatter should have description")
  assert(content:match("%-%-%-\n\n"), "frontmatter should close with ---")
end
test_skill_writes_file()

local function test_skill_content()
  local dir = fs.join(tmpdir, "skill-content")
  local ok, _ = spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill should succeed")
  local content = assert(cio.slurp(fs.join(dir, "SKILL.md")))
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
end
test_skill_content()

local function test_skill_creates_nested_dir()
  local dir = fs.join(tmpdir, "skill-nested", "a", "b")
  local ok, _ = spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill should create nested directories")
  assert(fs.isfile(fs.join(dir, "SKILL.md")), "SKILL.md should exist in nested dir")
end
test_skill_creates_nested_dir()

local function test_skill_prints_path()
  local dir = fs.join(tmpdir, "skill-path")
  local ok, out = spawn.spawn({cosmic, "--skill", dir}, {env = clean_env()}):read()
  assert(ok, "cosmic --skill should succeed")
  local s = out as string
  local expected = fs.join(dir, "SKILL.md")
  assert(s:find(expected, 1, true), "should print path to SKILL.md, got: " .. s)
end
test_skill_prints_path()
