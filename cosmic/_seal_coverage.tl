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
--- The keep decision moved to cosmic.coverage (#989): build tooling
--- that KNOWS its policy grants the coverage directory calls
--- coverage.keep_on_restrict() before applying, and this consults that
--- mark — the security policy records no longer carry a coverage flag.
local function seal_coverage()
  local cov = package.loaded["cosmic.coverage"]
  if cov == nil then
    return
  end
  local c = cov as {string: any} -- cast: from any
  local kept = c["is_kept_on_restrict"] as function(): boolean -- cast: from any
  if kept ~= nil and kept() then
    return
  end
  local seal = c["seal"] as function() -- cast: from any
  seal()
end

return {
  seal_coverage = seal_coverage,
}
