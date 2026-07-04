#!/usr/bin/env cosmic
-- test cosmic env var fallbacks: COSMIC_EMBED, COSMIC_OUTPUT, COSMIC_EXTRACT

local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local cenv = require("cosmic.env")
local spawn = require("cosmic.child")
local zip = require("cosmic.zip")

local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local tmpdir = os.getenv("TEST_TMPDIR")

-- Local declaration of Reader interface for type casting
local record Reader
  list: function(self: Reader): {string}
  read: function(self: Reader, name: string): string | nil, string | nil
  stat: function(self: Reader, name: string): Stat | nil
  close: function(self: Reader)
end

-- Stat record for file metadata
local record Stat
  mode: number
end

local function write_temp(name: string, content: string): string
  local filepath = fs.join(tmpdir, name)
  local dir = fs.dirname(filepath)
  if dir ~= tmpdir then
    fs.makedirs(dir)
  end
  cio.barf(filepath, content)
  return filepath
end

-- Test embed via COSMIC_EMBED and COSMIC_OUTPUT env vars
local function test_embed_via_env()
  local input = write_temp("env-hello.txt", "env hello world")
  local output = fs.join(tmpdir, "cosmic-env-embed")

  -- Build env: inherit parent + add COSMIC_EMBED, COSMIC_OUTPUT
  local parent_env = cenv.list()
  local env: {string} = {}
  for _, e in ipairs(parent_env) do
    env[#env + 1] = e
  end
  env[#env + 1] = "COSMIC_EMBED=" .. input
  env[#env + 1] = "COSMIC_OUTPUT=" .. output

  -- Invoke without --embed or --output flags
  local ok, out = spawn.spawn({cosmic}, {env = env}):read()
  assert(ok, "cosmic with COSMIC_EMBED env should succeed: " .. (out or ""))

  -- Verify output exists and content is embedded
  local stat = fs.stat(output)
  assert(stat, "output file should exist")

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  local expected_name = input:gsub("^/+", "")
  local content = reader:read(expected_name)
  assert(content == "env hello world", "embedded content should match via env var")
  reader:close()
end
test_embed_via_env()

-- Test extract via COSMIC_EXTRACT env var
local function test_extract_via_env()
  local extractdir = fs.join(tmpdir, "env-extracted")

  -- Build env: inherit parent + add COSMIC_EXTRACT
  local parent_env = cenv.list()
  local env: {string} = {}
  for _, e in ipairs(parent_env) do
    env[#env + 1] = e
  end
  env[#env + 1] = "COSMIC_EXTRACT=" .. extractdir

  -- Invoke without --extract flag
  local ok, out = spawn.spawn({cosmic}, {env = env}):read()
  assert(ok, "cosmic with COSMIC_EXTRACT env should succeed: " .. (out or ""))

  -- main.lua should be extracted
  assert(fs.isfile(fs.join(extractdir, "main.lua")), "main.lua should be extracted via env var")
end
test_extract_via_env()

-- Test that CLI args take priority over env vars
local function test_cli_priority_over_env()
  local env_input = write_temp("env-priority.txt", "from env")
  local cli_input = write_temp("cli-priority.txt", "from cli")
  local output = fs.join(tmpdir, "cosmic-priority")

  -- Build env: inherit parent + COSMIC_EMBED pointing to env_input
  local parent_env = cenv.list()
  local env: {string} = {}
  for _, e in ipairs(parent_env) do
    env[#env + 1] = e
  end
  env[#env + 1] = "COSMIC_EMBED=" .. env_input
  env[#env + 1] = "COSMIC_OUTPUT=" .. output

  -- Pass --embed via CLI (should override env)
  local ok, out = spawn.spawn({cosmic, "--embed", cli_input, "--output", output}, {env = env}):read()
  assert(ok, "cosmic --embed with env override should succeed: " .. (out or ""))

  local data = cio.slurp(output)
  local reader_maybe = zip.from(data)
  assert(reader_maybe, "failed to open zip from data")
  local reader = reader_maybe as Reader

  -- CLI file should be present
  local cli_name = cli_input:gsub("^/+", "")
  local cli_content = reader:read(cli_name)
  assert(cli_content == "from cli", "CLI-specified file should be embedded, not env var file")

  -- Env file should NOT be present (CLI took priority)
  local env_name = env_input:gsub("^/+", "")
  local env_content = reader:read(env_name)
  assert(env_content == nil, "env var file should not be embedded when CLI arg is present")

  reader:close()
end
test_cli_priority_over_env()

print("All embed env tests passed!")
