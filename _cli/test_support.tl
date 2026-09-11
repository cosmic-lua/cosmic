--- Test-only assertions for the observable cosmic CLI contract.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")

local record Case
  argv: {string}
  cwd: string
  exit_code: integer
  stdout: string
  stderr: string
  absent_paths: {string}
end

local function invocation(argv: {string}): string
  local rendered: {string} = {"bin/cosmic"}
  for _, value in ipairs(argv) do
    rendered[#rendered + 1] = string.format("%q", value)
  end
  return table.concat(rendered, " ")
end

local function assert_same(label: string, want: string, got: string,
    invoked: string)
  assert(got == want, invoked .. ": " .. label .. " differs\n" ..
    "expected: " .. string.format("%q", want) .. "\n" ..
    "actual:   " .. string.format("%q", got))
end

--- Run one literal CLI case and assert its first observable mismatch.
--- @param c Case Arguments, expected process result, and forbidden paths
local function assert_case(c: Case)
  local launcher = fs.absolute_path("bin/cosmic")
  local argv: {string} = {launcher}
  for _, value in ipairs(c.argv) do
    argv[#argv + 1] = value
  end
  local invoked = invocation(c.argv)
  local opts: child.Options = nil
  if c.cwd then
    opts = {cwd = c.cwd}
  end
  local result, run_err = child.run(argv, opts)
  local got = check.must(result,
    invoked .. ": could not run: " .. (run_err or "unknown error"))
  assert(got.code == c.exit_code,
    invoked .. ": exit code differs: expected " .. tostring(c.exit_code) ..
    ", actual " .. tostring(got.code or "signal"))
  assert_same("stdout", c.stdout, got.stdout, invoked)
  assert_same("stderr", c.stderr, got.stderr, invoked)
  for _, path in ipairs(c.absent_paths or {}) do
    assert(not (fs.is_present(path) or fs.is_link(path)),
      invoked .. ": forbidden side effect created: " .. path)
  end
end

local record TestSupport
  type Case = Case
  assert_case: function(Case)
end

local M: TestSupport = {
  assert_case = assert_case,
}

return M
