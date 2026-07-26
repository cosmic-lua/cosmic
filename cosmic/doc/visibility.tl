--- Which modules are the published API — answered from the name alone.
---
--- This replaces `cosmic.public`, a hand-maintained list of every
--- top-level module split into public and internal. The list was the
--- last hand-maintained description of the tree in this repo, and it
--- had the drift problem every such description has: a new module was
--- public or internal depending on whether someone remembered to say
--- so, and a deleted one left an entry behind. A ratchet test existed
--- solely to catch both.
---
--- Position decides instead (`--make`'s `_` rule, phase 3c): a
--- directory or file whose name starts with `_` is internal to its
--- container, so `_cli/` and `_cli/require_hints.tl` are not the
--- API and say so in their own names. Nothing to keep in sync, and a
--- module's visibility is visible in `ls`.

--- Is this module name part of the published API?
---
--- Public is exactly `cosmic.<name>` for one segment that does not
--- start with `_`. Everything else is internal, and each for its own
--- reason: a deeper path is a shard of a directory module
--- (`cosmic.fs.walk` — the entry point is `cosmic.fs`), an underscore
--- segment is marked internal by position (`_cli.args`,
--- `_perf.harness`), and bare `cosmic` is the package initializer
--- rather than a module anyone requires by name.
--- @param name string A dotted module name
--- @return boolean True when the module is public API
local function is_public(name: string): boolean
  local leaf = name:match("^cosmic%.([%w_]+)$")
  if not leaf then
    return false
  end
  return leaf:sub(1, 1) ~= "_"
end

--- The public module names in a set of module names, sorted.
--- @param names {string} Dotted module names in any order
--- @return {string} The public ones, sorted
local function public_of(names: {string}): {string}
  local out: {string} = {}
  for _, name in ipairs(names) do
    if is_public(name) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local record VisibilityModule
  is_public: function(name: string): boolean
  public_of: function(names: {string}): {string}
end

local M: VisibilityModule = {
  is_public = is_public,
  public_of = public_of,
}

return M
