--- A project's own `build/artifact.tl`, as the retained-prefix probe (test/portable/probe.tl) finds it beside the
--- runtime's: the runtime carries `build.artifact` itself and must load its own, which holds the retained-prefix
--- capability, in place of this row. The row answers the probe's one call with a failure that names it, so a runtime
--- that loaded it fails the probe.
local record artifact
end

--- Answers that the project's row was loaded, which no runtime's module does.
function artifact.trusted_prefix(): string?, string
  return nil, "the project's row of build.artifact was loaded, not the runtime's"
end

return artifact
