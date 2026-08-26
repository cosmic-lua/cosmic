--- The in-process test runner: a test runs because it was defined.
--- `main` takes the ordered cases a test file's toolchain-generated tail
--- hands it, runs each under `pcall` so one failure never hides the
--- rest, prints the failures and a counts line, and RETURNS the exit
--- code its caller turns into the process's status. It never exits and
--- never throws: only `cosmic.check` may do either.
---
--- Two spellings below are `_tool.records`' output grammar --- the
--- failure row `✗ <name>` and the counts line `<N> checks: <P> passed`
--- --- reproduced rather than imported, because `cosmic/**` is the strip
--- floor and may not require the internal tree. `_tool/records_test.tl`
--- asserts the two agree, the way it already does for
--- `cosmic.check`'s EXIT_SKIP.
local env = require("cosmic.env")

--- The exit grammar every runner grades by: 0 all passed, 2 nothing
--- ran, anything else failed.
local EXIT_OK < const > = 0
local EXIT_FAIL < const > = 1
local EXIT_SKIP < const > = 2

--- The environment variable a runner passes a name filter through.
local FILTER_VAR < const > = "COSMIC_TEST_FILTER"

--- One test to run: the name it reports under and the function itself.
--- A test fails by throwing, which is the whole failure vocabulary
--- (`assert`, `cosmic.check`); a test that returns has passed.
local record Case
  name: string
  fn: function()
end

--- Options for `main`.
local record Options
  --- A plain SUBSTRING matched against a case name --- the contract the
  --- benchmark and example runners already honour, not a Lua pattern.
  --- When absent, COSMIC_TEST_FILTER is read instead.
  filter: string
end

--- The filter in force: the option when it carries one, else the
--- environment. An empty string is no filter, not a filter matching
--- everything, so an exported-but-unset variable behaves like an unset
--- one.
--- @param opts Options|nil What the caller passed
--- @return string|nil The substring to match, nil for no filter
local function filter_of(opts: Options | nil): string | nil
  local from_opts = opts and opts.filter
  if from_opts ~= nil and from_opts ~= "" then
    return from_opts
  end
  local from_env = env.get(FILTER_VAR)
  if from_env ~= nil and from_env ~= "" then
    return from_env
  end
  return nil
end

--- The cases a filter selects, in the order given. Source order is run
--- order: the list is never sorted and never shuffled.
--- @param cases {Case} Every case the file defined
--- @param filter string|nil The substring, nil to select all
--- @return {Case} The selected cases
local function select_cases(cases: {Case}, filter: string | nil): {Case}
  if filter == nil then
    return cases
  end
  local selected: {Case} = {}
  for _, case in ipairs(cases) do
    -- A filter is a substring, so `find` is told so explicitly.
    if case.name:find(filter, 1, true) then
      selected[#selected + 1] = case
    end
  end
  return selected
end

--- `text` with every line indented four spaces, so a traceback reads as
--- detail belonging to the failure row above it.
--- @param text string The block to indent
--- @return string The indented block, newline-terminated
local function indent(text: string): string
  local out: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = "    " .. line
  end
  return table.concat(out, "\n") .. "\n"
end

--- The counts line: `<N> checks: <P> passed[, <F> failed]`.
--- `_tool.records`' `counts` with a skipped count of zero --- there is
--- no per-test skip, because `check.needs` and `check.reap` invalidate
--- the whole file by exiting the process.
--- @param passed integer How many cases passed
--- @param failed integer How many threw
--- @return string The line, without its newline
local function counts(passed: integer, failed: integer): string
  local out = (passed + failed) .. " checks: " .. passed .. " passed"
  if failed > 0 then
    out = out .. ", " .. failed .. " failed"
  end
  return out
end

--- Run an ordered list of test cases and report on them.
---
--- Every selected case runs, in the order given, whatever the ones
--- before it did: a throw is recorded against its case's name and the
--- run continues. Output goes to stdout through `io.write` only --- no
--- `print` --- so a caller can capture all of it by swapping that one
--- function.
--- @param cases {Case} The cases, in source order
--- @param opts Options? A name filter; COSMIC_TEST_FILTER when absent
--- @return integer 0 when every selected case passed, 2 when none ran,
--- 1 otherwise
local function main(cases: {Case}, opts?: Options): integer
  local filter = filter_of(opts)
  local selected = select_cases(cases, filter)

  if #selected == 0 then
    if filter ~= nil and #cases > 0 then
      io.write("no tests matching '" .. filter .. "' (found "
        .. #cases .. " total)\n")
    end
    io.write(counts(0, 0) .. "\n")
    return EXIT_SKIP
  end

  -- The message handler runs on the failing stack, so the traceback it
  -- builds still names the throwing line; it is kept here rather than
  -- read back from `xpcall`, whose second return a zero-return function
  -- type does not carry.
  local failure = ""
  local function record_failure(e: any): string
    failure = debug.traceback(tostring(e), 2)
    return failure
  end

  local passed = 0
  local failed = 0
  for _, case in ipairs(selected) do
    failure = ""
    if xpcall(case.fn, record_failure) then
      passed = passed + 1
    else
      failed = failed + 1
      io.write("✗ " .. case.name .. "\n")
      io.write(indent(failure))
    end
  end

  io.write(counts(passed, failed) .. "\n")
  return failed > 0 and EXIT_FAIL or EXIT_OK
end

local record TestModule
  type Case = Case
  type Options = Options

  main: function(cases: {Case}, opts?: Options): integer
end

local M: TestModule = {
  main = main,
}

return M
