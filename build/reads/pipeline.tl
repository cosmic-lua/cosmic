--- A module that requires this one declares that it reads the sources of the modules the checker's identity hashes ([`build.code_walk`]'s walk from [`build.pipeline`]).
---
--- A test's pure store ([`build.closure_store`]) keeps the text its closure's modules declare they read, found by which of
--- these modules the closure holds: the declaration is an import, so the key follows the importers with no run of them.
--- [`build.tree_checks`]'s `text_readers` holds a module that reads text to one of these. The vocabulary is
--- [`build.code_walk`]'s `markers`.
---
--- @public
local record reads
  reads: string
end

local declared: reads = { reads = "pipeline" }

return declared
