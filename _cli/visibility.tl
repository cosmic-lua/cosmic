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
---
--- The per-require check above sees one file at a time, so a directory
--- of shards with no public parent at all never trips it: nothing
--- outside ever requires the shard directly, because there is no
--- `cosmic.<name>` to require instead. `check_shard_dir_init` closes
--- that gap by looking at the directory a shard lives in rather than
--- its requires — a `cosmic/<name>/` holding a non-test `.tl` file and
--- no `init.tl` is a library nobody outside `cosmic/` can name.
local fs = require("cosmic.fs")
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

--- Report a top-level `cosmic/<name>/` directory that holds a shard
--- with no `init.tl` beside it — nothing outside `cosmic/` can require
--- ANY name in it, so the module is unreachable by construction.
--- @param file string The file being linted
--- @return {Diagnostic} One finding if file is such a shard, else none
local function check_shard_dir_init(file: string): {Diagnostic}
  local dir, name = file:match("^(cosmic/[%w_]+)/([%w_]+%.tl)$")
  if not dir or name == "init.tl" or name:match("_test%.tl$") then
    return {}
  end
  if fs.is_file(dir .. "/init.tl") then
    return {}
  end
  return {{
      file = file,
      line = 1,
      col = 1,
      rule = "visibility",
      message = dir .. "/: shards with no public parent — add " .. dir ..
      "/init.tl re-exporting what outside callers need",
    }}
end

local record VisibilityModule
  check_shard_require: function(file: string, lines: {string}): {Diagnostic}
  check_shard_dir_init: function(file: string): {Diagnostic}
end

local M: VisibilityModule = {
  check_shard_require = check_shard_require,
  check_shard_dir_init = check_shard_dir_init,
}

return M
