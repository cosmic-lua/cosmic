--- What a root is to the running tool: whether it is cosmic's own source
--- tree. A tool is built from one root, by a boot or a rebuild, and
--- carries that root's canonical path ([`built_from`], in its `meta`); a
--- root is cosmic's own when that path is its own. Nothing a root holds
--- can say so, and no layout does: a directory that looks like cosmic's
--- is a project to any tool not built from it.

local build_paths = require("build.paths")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local Store = require("cosmic.store")
local sys = require("cosmic.sys")

local record tree
  --- What a root is to the running tool, decided by [`tree.standing`] where a
  --- command starts. [`work.stage`] keeps it on the handle for the compile and the
  --- writer, and [`positions.check`] takes it whole: whether the tree may define
  --- `cosmic.*` is a part of what it says.
  record Standing
    --- Whether the root is cosmic's own tree.
    own: boolean
  end
end

--- The canonical path of `root`, which a tool built from it records as
--- its [`built_from`] ([`build.identity.record_fingerprint`]). Nil and why
--- where the root cannot be resolved.
function tree.built_from(root: string): string?, string
  local canonical, trouble = sys.realpath(root)
  if canonical == nil then return nil, root .. ": " .. trouble end
  return canonical, ""
end

--- Whether the running binary is in the build directory of `root`
--- ([`build.paths`]), as the tool and the checked suite's sanitized one
--- are: a tool a boot or a rebuild of `root` wrote. Only such a tool
--- rebuilds itself when stale. A rebuild writes the tree's tool over the
--- path it was started as, so any other cosmic run here (a release, the
--- bootstrap cache's, one on PATH) would be overwritten.
--- The path is judged where it names: its directory is resolved but not
--- its name. A file renamed or removed while it runs is still judged by
--- where it was, and a link into the build directory from elsewhere is
--- elsewhere, since a rebuild would replace the link, not the tool. A root
--- with no build directory yet holds no tool, and a directory this process
--- cannot resolve is in none it can see. `executable` is the path this
--- process was started as, by default.
-- TODO: refuse a host-built tool whose file was removed while it runs:
-- with no started-as path, Proc.executable falls back to /proc/self/exe,
-- which then reads ".../cosmic (deleted)", and a rebuild would write a
-- file of that name. Once Proc.executable says the file is gone, answer
-- nil for it here.
function tree.own_tool(root: string, executable?: string): boolean?, string
  local running = executable
  if running == nil then
    local found, trouble = Proc.executable()
    if found == nil then
      return nil, trouble
    end
    running = found
  end
  -- A sandboxed worker, say, cannot see the directory of the tool it was started from.
  local directory, _ = Fs.absolute(Fs.dirname(running))
  if directory == nil then
    return false, ""
  end
  local named, named_trouble = build_paths.optional(root)
  if named == nil then
    if named_trouble ~= "" then return nil, named_trouble end
    return false, ""
  end
  local outputs, _ = Fs.absolute(named)
  if outputs == nil then
    return false, ""
  end
  return Fs.within(directory .. "/" .. Fs.basename(running), outputs), ""
end

--- [`tree.standing`] once `here`, the canonical path of `root`, and `built`, what the tool records, are known.
local function decided(root: string, here: string, built: string?, executable?: string): tree.Standing?, string
  local core, core_trouble = Fs.is_dir(root .. "/core")
  if core == nil then return nil, core_trouble end
  if built == here and core then return { own = true }, "" end
  local inside, inside_trouble = tree.own_tool(root, executable)
  if inside == nil then return nil, inside_trouble end
  if not inside then return { own = false }, "" end
  if built == here then
    return nil, here .. ": this tool was built from this path, which has no core/ now; " ..
      "restore the checkout or run bin/zig build boot in another"
  end
  if built == nil then
    return nil, here .. ": this tool is in the build directory of this checkout but records no checkout it " ..
      "was built from; run bin/zig build boot"
  end
  return nil, here .. ": this tool was built from " .. built .. "; run bin/zig build boot"
end

--- What `root` is to the running tool: its [`tree.Standing`], or nil and
--- why where the root cannot be read or the tool cannot be held to it:
--- a tool in the build directory of `root` that records another root, or
--- none, is cosmic's own tool of a tree it was not built from, and no
--- command goes on as if the tree were a project. So is such a tool built
--- from this root where the root has no `core/`. A tool outside the
--- build directory is a project's tool, a release among them: it is built
--- from no checkout.
---
--- `carried` is the [`built_from`] the tool carries, by default the running
--- binary's ([`cosmic.store.meta`]), and "" for a tool that records none.
--- A test passes the root of its fixture. `executable` is
--- [`tree.own_tool`]'s.
--- @param carried the tool's [`built_from`], "" for none, or nil to read the binary's
--- @param executable the path the tool was started as, or nil for this process's
function tree.standing(root: string, carried?: string, executable?: string): tree.Standing?, string
  local here, trouble = tree.built_from(root)
  if here == nil then return nil, trouble end
  local built = carried
  if built == nil then built = Store.meta("built_from") end
  if built == "" then built = nil end
  return decided(root, here, built, executable)
end

--- What `root` is to the tool a boot of it is writing, which will record
--- `root` as its [`built_from`]: the tool running the boot is the one it
--- replaces, so the row it carries says nothing. Nil and why where the root
--- cannot be read or holds no `core/`.
function tree.booted(root: string): tree.Standing?, string
  local here, trouble = tree.built_from(root)
  if here == nil then return nil, trouble end
  local standing, why = decided(root, here, here)
  if standing == nil then return nil, why end
  if not standing.own then return nil, here .. ": a boot needs the checkout's core/" end
  return standing, ""
end

return tree
