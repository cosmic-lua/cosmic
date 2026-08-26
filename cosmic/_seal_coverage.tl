--- Flush line-coverage data before rights drop: a dump attempted after
--- a pledge/unveil policy lands would violate it and kill the process.
---
--- Shared by cosmic.pledge, cosmic.unveil, and cosmic.landlock, which
--- must not require each other (cosmic.sandbox composes them over the
--- same policy) — hence its own internal home here rather than living
--- in any one of them.
--- Reaches coverage via `package.loaded` rather than
--- `require("cosmic.coverage")` so pledge/unveil stay leaf modules
--- that never force-load coverage instrumentation a caller isn't
--- using.
--- The keep decision lives in cosmic.coverage: build tooling that KNOWS
--- its policy grants the coverage directory calls
--- coverage.keep_on_restrict() before applying, and this consults that
--- mark — security policy records carry no coverage flag of their own.
--- The two entry points seal_coverage() needs from cosmic.coverage,
--- declared here because the module is reached through package.loaded:
--- requiring it would force-load instrumentation a caller is not using.
local record CoverageModule
  is_kept_on_restrict: function(): boolean
  seal: function()
end

local function seal_coverage()
  local cov = package.loaded["cosmic.coverage"]
  if cov == nil or not (cov is CoverageModule) then
    return
  end
  local kept = cov.is_kept_on_restrict
  if kept ~= nil and kept() then
    return
  end
  cov.seal()
end

return {
  seal_coverage = seal_coverage,
}
