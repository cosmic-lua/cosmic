--- TRANSITIONAL teal compatibility (#1001; DELETE this module at the
--- pin advance): the pin boot-checks `_cli` against ITS embedded
--- cosmic.teal — path-taking `compile`/`check`, one-argument
--- format_issues — while the tree's record has compile_file/check_file
--- and format_issues opts (hints). These wrappers reach the members
--- through erasure with a runtime fallback to the pin's spelling, so
--- the dispatcher compiles and runs under both generations. Callers
--- always pass format_issues two arguments (nil opts when none).
local teal = require("cosmic.teal")

local record TealCompat
  compile_file: function(string, teal.CompileOptions): teal.CompileResult
  check_file: function(string, teal.CheckOptions): teal.CheckResult
  format_issues: function({teal.Issue}, any): string
end

local teal_any = teal as {string: any} -- cast: transitional dual-shape module

local M: TealCompat = {
  -- cast: transitional dual-shape call
  compile_file = (teal_any["compile_file"] or teal_any["compile"]) as
  function(string, teal.CompileOptions): teal.CompileResult,
  -- cast: transitional dual-shape call
  check_file = (teal_any["check_file"] or teal_any["check"]) as
  function(string, teal.CheckOptions): teal.CheckResult,
  -- cast: transitional dual-shape call
  format_issues = teal_any["format_issues"] as function({teal.Issue}, any): string,
}

return M
