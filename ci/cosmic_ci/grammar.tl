--- The environment for a child that is the pinned release itself, the driver or a copy of it, started on
--- a file of ci/.

local Maps = require("cosmic_ci.maps")

local record Grammar
end

--- A copy of `base` with COSMIC_GRAMMAR=new. The pinned release reads ci/ in the new grammar only where
--- the variable says so, as the CI driver's wrapper and bin/cosmic-bootstrap set it for the release they
--- run. A child started by the release's own path, or a copy of it, is not started through the
--- wrapper and does not get the variable from its parent: a test worker's environment does not carry it, so
--- the child would read ci/ as Teal and stop at a syntax error.
function Grammar.driver(base: {string:string}): {string:string}
  return Maps.with(base, { COSMIC_GRAMMAR = "new" })
end

return Grammar
