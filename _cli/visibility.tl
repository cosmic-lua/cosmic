--- The visibility rule, enforced: a module is public API exactly when
--- it is `cosmic.<name>` with no `_` (position is the manifest — see
--- AGENTS.md and cosmic/doc/visibility.tl). Anything deeper —
--- `cosmic.fs.types`, `cosmic.coverage.baseline` — is an internal
--- shard of its parent, and a file OUTSIDE cosmic/ may not require it:
--- the shard's exports are implementation, and every outside require
--- freezes one more accident of decomposition into API. What an
--- outside caller needs, the public parent re-exports (fs's Stat/Dir
--- types, coverage's gate).
---
--- Files inside cosmic/ are exempt (a shard exists to be required by
--- its siblings), and so are `*_gen.tl` generators: a generator runs
--- under the CURRENT binary before the tree rebuilds, so it may only
--- use the surface that binary already embeds — holding it to today's
--- tree would break the bootstrap.
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Report each require of a cosmic-internal shard from outside cosmic/.
--- @param file string Path, for the diagnostic and the exemptions
--- @param lines {string} The file's lines
--- @return {Diagnostic} One per shard require
local function check_shard_require(file: string, lines: {string}): {Diagnostic}
  if file:match("^cosmic/") or file:match("_gen%.tl$") then
    return {}
  end
  local diagnostics: {Diagnostic} = {}
  for i, line in ipairs(lines) do
    local col, _, mod = line:find("require%s*%(%s*[\"'](cosmic%.[%w_%.]-)[\"']")
    -- TRANSITIONAL (#992): the runners moved to `_tool/` still parse
    -- function blocks with `cosmic.doc.scan`, which is shared with
    -- doc's extraction half. The doc split (part 2) moves that half —
    -- scan included — into `_tool/`, and this exemption dies with it.
    if col and mod == "cosmic.doc.scan" and file:match("^_tool/") then
      col = nil
    end
    if col and (mod:find(".", 8, true) or mod:find("._", 7, true)) then
      diagnostics[#diagnostics + 1] = {
        file = file,
        line = i,
        col = col,
        rule = "visibility",
        message = string.format(
          "%s:%d: require(\"%s\") reaches a cosmic-internal shard from"
          .. " outside cosmic/; use the public parent module (which"
          .. " re-exports what outside callers need)", file, i, mod),
      }
    end
  end
  return diagnostics
end

local record VisibilityModule
  check_shard_require: function(file: string, lines: {string}): {Diagnostic}
end

local M: VisibilityModule = {
  check_shard_require = check_shard_require,
}

return M
