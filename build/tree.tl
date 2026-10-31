--- What a root is to the running tool: whether it is cosmic's own source
--- tree. A tool is built from one root, by a boot or a rebuild, and
--- carries a hash of that root's path (`built_from`, in its `meta`); a
--- root is cosmic's own when that hash is its own. Nothing a root
--- holds can say so, and no layout does: a directory that looks like
--- cosmic's is a project to any tool not built from it.

local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")

local record tree
  --- What a root is to the running tool, decided once per command by
  --- [`tree.standing`] and passed on.
  record Standing
    --- Whether the root is cosmic's own tree.
    own: boolean
  end
end

--- What a tool built from `root` carries as its `built_from`: the SHA-256
--- of the root's canonical path, which also names the root's build
--- directory ([`build.paths`]). A boot or rebuild of `root` records it
--- ([`build.identity.record_fingerprint`]). Nil and why where the root
--- cannot be resolved.
function tree.built_from(root: string): string?, string
  local canonical, trouble = sys.realpath(root)
  if canonical == nil then return nil, root .. ": " .. trouble end
  return Hash.hex_sha256(canonical), ""
end

--- What to do about a tool that is not built from the root it runs on,
--- whose `built_from` is `carried` (nil for a tool that records none).
function tree.advice(carried: string?): string
  if carried == nil then
    return "this tool was not built from a checkout (a release, or a tool older than the record); " ..
      "run bin/cosmic, which runs the tool built from this checkout"
  end
  return "this tool was built from a checkout at another path; run bin/zig build boot here"
end

--- What `root` is to the running tool: its [`tree.Standing`]. Nil and why
--- where the root cannot be read, or where the tool says it was built
--- from this root and the root has no `core/`, which no checkout of
--- cosmic lacks.
---
--- `carried` is the `built_from` the tool carries, by default the running
--- binary's ([`cosmic.store.meta`]). A boot or a rebuild passes the
--- row it is about to write, since the tool it runs is the one it
--- replaces; a test passes the row of its fixture's root.
--- @param carried the tool's `built_from`, or nil to read the binary's
function tree.standing(root: string, carried?: string): tree.Standing?, string
  local here, trouble = tree.built_from(root)
  if here == nil then return nil, trouble end
  local built = carried or Store.meta("built_from")
  if built ~= here then
    return { own = false }, ""
  end
  local core, core_trouble = Fs.is_dir(root .. "/core")
  if core == nil then return nil, core_trouble end
  if not core then
    return nil, root .. ": the tool was built from this path, but it holds no core/ any more; " ..
      "restore the checkout or run bin/zig build boot in another"
  end
  return { own = true }, ""
end

return tree
