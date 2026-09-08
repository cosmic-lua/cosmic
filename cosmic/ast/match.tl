--- Structural pattern matching over real Teal syntax trees.
--- `$NAME` captures one subtree; trailing `$$$NAME` captures a list.
--- Repeated captures compare complete syntax, excluding parser metadata.
---
--- The implementation lives in a new module shared with owned Pattern
--- values. This facade preserves the shipped API while new callers use
--- the engine's exact typed API under both the pinned and built checkers.
local engine = require("cosmic.ast._match_engine")
return engine
