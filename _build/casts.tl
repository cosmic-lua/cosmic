#!/usr/bin/env cosmic
--- The trees this repo counts `as` casts under.
---
--- `_build/casts_test.tl` classifies every cast the committed tree
--- carries into one of the named kinds in `_build/casts_kinds.tl`, by
--- walking exactly these trees with `cosmic.ast` -- the same scope
--- `_build/size.tl` reports line counts over, so a tree tracked for
--- size is a tree tracked for casts too.

local record CastsModule
  --- The trees this count covers: every tree of committed Teal source.
  TREES: {string}
end

local M: CastsModule = {
  TREES = {
    "_build", "_cli", "_docs", "_eval",
    "_fuzz", "_make", "_perf", "_tool",
    "_types", "cmd", "cosmic",
  },
}

return M
