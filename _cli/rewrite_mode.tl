--- Per-invocation rewrite mode kept outside `_cli.parse.Options`.
---
--- `_cli.parse` resets this module for every invocation. That preserves the
--- pinned Options record at the make startup boundary while still giving main
--- the bare preview switch.
local record RewriteMode
  preview: boolean
  error: string
end

local mode: RewriteMode = {
  preview = false,
}

return mode
