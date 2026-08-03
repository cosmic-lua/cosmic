--- Flush line-coverage data before rights drop: a dump attempted after
--- a pledge/unveil policy lands would violate it and kill the process.
---
--- Shared by cosmic.pledge and cosmic.unveil, which must not require
--- each other (cosmic.sandbox composes both over the same policy) —
--- hence its own internal home here rather than living in either one.
--- Reaches coverage via `package.loaded` rather than
--- `require("cosmic.coverage")` so pledge/unveil stay leaf modules
--- that never force-load coverage instrumentation a caller isn't
--- using.
--- @param keep boolean? Skip the seal — the caller granted the
--- coverage directory itself, so sealing here would throw away
--- everything recorded under this policy
local function seal_coverage(keep?: boolean)
  if keep then
    return
  end
  local cov = package.loaded["cosmic.coverage"]
  if cov ~= nil then
    local seal = (cov as {string: any})["seal"] as function() -- cast: from any
    seal()
  end
end

return {
  seal_coverage = seal_coverage,
}
