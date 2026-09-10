#!/usr/bin/env cosmic
--- Tests for `--diff OLD`, with small archives for exact reports and the
--- running test binary for the real self-archive path.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local zip = require("cosmic.zip")
local cli_diff = require("_cli.diff")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"
local cosmic = fs.join(os.getenv("TEST_BIN"), "cosmic")
local capture_number = 0

local record Capture
  code: integer
  out: string
  err: string
end

local function archive(name: string, sources: {string: string}): string
  local path = fs.join(tmpdir, name)
  local writer = check.must(zip.open(path, {mode = "write"}))
  for source_path, contents in pairs(sources) do
    local ok, err = writer:add(".tl/" .. source_path, contents)
    assert(ok, err)
  end
  local ok, err = writer:close()
  assert(ok, err)
  return path
end

local function capture(action: function(): integer): Capture
  capture_number = capture_number + 1
  local out_path = fs.join(tmpdir, "diff-" .. capture_number .. ".out")
  local err_path = fs.join(tmpdir, "diff-" .. capture_number .. ".err")
  local real_out = io.output()
  local real_err = io.stderr
  io.output(assert(io.open(out_path, "w")))
  io.stderr = assert(io.open(err_path, "w"))
  local code = action()
  io.output():close()
  io.stderr:close()
  io.output(real_out)
  io.stderr = real_err
  return {
    code = code,
    out = check.must(fs.read(out_path)),
    err = check.must(fs.read(err_path)),
  }
end

local function mixed_archives(): string, string
  local old = archive("diff-mixed-old.zip", {
      ["cosmic/alpha.tl"] = [[
local record API
  removed: string
  changed: string
  stable: integer
end
]],
      ["cosmic/gone.tl"] = [[
local record Gone
  value: string
end
]],
    })
  local new = archive("diff-mixed-new.zip", {
      ["cosmic/alpha.tl"] = [[
local record API
  added: boolean
  changed: integer
  stable: integer
end
]],
    })
  return old, new
end

local function test_removed_retyped_added_and_module_removed_report()
  local old, new = mixed_archives()
  local got = capture(function(): integer
      return cli_diff.compare(old, new)
    end)
  check.equal(got.code, 1)
  check.equal(got.err, "")
  check.equal(got.out, [[cosmic.alpha:
  added API.added: boolean
  retyped API.changed: string -> integer
  removed API.removed: string

cosmic.gone:
  module-removed
  removed Gone.value: string

diff: 4 removed or retyped, 1 added
]])
end

local function test_added_only_report_exits_zero()
  local old = archive("diff-added-old.zip", {
      ["cosmic/alpha.tl"] = "local record API stable: integer end\n",
    })
  local new = archive("diff-added-new.zip", {
      ["cosmic/alpha.tl"] =
      "local record API added: boolean stable: integer end\n",
    })
  local got = capture(function(): integer
      return cli_diff.compare(old, new)
    end)
  check.equal(got.code, 0)
  check.equal(got.err, "")
  check.equal(got.out, [[cosmic.alpha:
  added API.added: boolean

diff: 0 removed or retyped, 1 added
]])
end

local function test_malformed_old_refuses_once()
  local old = fs.join(tmpdir, "diff-malformed.zip")
  assert(fs.write(old, "not a zip"))
  local _, new = mixed_archives()
  local got = capture(function(): integer
      return cli_diff.compare(old, new)
    end)
  check.equal(got.code, 2)
  check.equal(got.out, "")
  assert(got.err:find("cosmic-lua: --diff: " .. old, 1, true), got.err)
  assert(got.err:find("open failed", 1, true), got.err)
  check.equal(select(2, got.err:gsub("\n", "")), 1)
end

local function test_missing_old_has_usage_exit_two()
  local got = capture(function(): integer
      return cli_diff.run("")
    end)
  check.equal(got, {
      code = 2,
      out = "",
      err = "cosmic-lua: --diff: usage: --diff <binary>\n",
    })
end

local function test_literal_cli_missing_old_has_one_diagnostic_and_exit_two()
  local handle = check.must(child.start({cosmic, "--diff"}))
  local result = check.must(handle:wait())
  check.equal({
      code = result.code or 128,
      out = result.stdout or "",
      err = result.stderr or "",
    }, {
      code = 2,
      out = "",
      err = "cosmic-lua: --diff: usage: --diff <binary>\n",
    })
end

local function test_real_self_binary_has_no_deltas()
  local self_path, self_err = proc.interpreter()
  assert(self_path, self_err)
  local got = capture(function(): integer
      return cli_diff.run(self_path)
    end)
  check.equal(got, {
      code = 0,
      out = "diff: 0 removed or retyped, 0 added\n",
      err = "",
    })
end
