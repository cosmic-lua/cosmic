#!/usr/bin/env cosmic
--- Representative literal-entrypoint contracts for cosmic's CLI.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local support = require("_cli.test_support")

local tmpdir = check.must(os.getenv("TEST_TMPDIR"))
local root = check.must(fs.cwd())
local cwd = fs.join(tmpdir, "cli-contract")
assert(fs.make_dirs(cwd))
local forbidden = fs.join(cwd, "losing-action.txt")

local function test_literal_entrypoint_contracts()
  local cases: {support.Case} = {
    {
      argv = {"--diff"},
      exit_code = 2,
      stdout = "",
      stderr = "cosmic-lua: --diff: usage: --diff <binary>\n",
    },
    {
      argv = {"-e", "io.write(assert(require('cosmic.fs').cwd()))"},
      cwd = cwd,
      exit_code = 0,
      stdout = root,
      stderr = "",
    },
    {
      argv = {"--welcome", "-e", "assert(io.open('losing-action.txt', 'w'))"},
      cwd = cwd,
      exit_code = 0,
      stdout = [[
Welcome to cosmic-lua!

Quick start:
  cosmic --docs [query]    search documentation (non-interactive)
  cosmic --help            show all options
  cosmic -i                start REPL (help() available interactively)

Run 'cosmic --welcome' to see this again.
]],
      stderr = "",
      absent_paths = {forbidden},
    },
  }
  for _, c in ipairs(cases) do
    support.assert_case(c)
  end
end

local function test_dangling_symlink_is_a_forbidden_side_effect()
  local dangling = fs.join(cwd, "dangling")
  local code = string.format(
    "local ok, err = require('cosmic.fs').symlink('missing', %q); " ..
    "assert(ok, err)", dangling)
  local ok, err = pcall(function()
      support.assert_case({
          argv = {"-e", code},
          exit_code = 0,
          stdout = "",
          stderr = "",
          absent_paths = {dangling},
        })
    end)
  assert(fs.remove(dangling))
  assert(not ok, "the helper must reject a forbidden dangling symlink")
  assert(tostring(err):find("forbidden side effect created: " .. dangling,
      1, true), tostring(err))
end
