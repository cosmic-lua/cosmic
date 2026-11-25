--- The modules of a tree on disk that a chunk of `cosmic -e` or a snippet of cosmic agent may require, as a file at the
--- tree's root requires them: `require("summarize")` reads `summarize.tl` (or `summarize/init.tl`) under the root, and
--- the checker checks it with the chunk ([`Pipeline.Options.nearby`]). A `cosmic.*` name, and any module the binary
--- carries (in cosmic's own checkout, `build.*` and `lang.*` too), is the binary's, never a tree's.
---
---     local found: {string: Pipeline.Nearby} = {}
---     local provide = Nearby.provider({ "." }, found)
---     print(provide("cosmic.fs") == nil) -- true

local type Driver = require("build.driver")
local Fs = require("cosmic.fs")
local Store = require("cosmic.store")
local type Pipeline = require("build.pipeline")

local record Nearby
end

--- The file of module `name` in the first of `roots` that has one, and its text: `<name>.tl` or `<name>/init.tl`
--- under the root, the name's dots as slashes, its path the root's and the file's joined (`./util.tl`). nil for a
--- `cosmic.*` name, a module the binary carries, and a name with no file.
function Nearby.find(roots: {string}, name: string): Pipeline.Nearby?
  if name == "cosmic" or name:sub(1, 7) == "cosmic." or name:find("^[%w_]+[%w_.]*$") == nil then
    return nil
  end
  local carried, _ = Store.source(name)
  if carried ~= nil then
    return nil
  end
  local stem = name:gsub("%.", "/")
  for _, root in ipairs(roots) do
    for _, candidate in ipairs({ stem .. ".tl", stem .. "/init.tl" }) do
      local file = if root == "." then candidate else root .. "/" .. candidate end
      local text, _ = Fs.read(file)
      if text ~= nil then
        return { file = file, text = text }
      end
    end
  end
  return nil
end

--- A provider of the modules of the trees at `roots`, each a checked source named for its file, which records each it
--- gives in `found`.
function Nearby.provider(roots: {string}, found: mut {string: Pipeline.Nearby}): Driver.Provider
  return function(name: string): Driver.Source?
    local near = Nearby.find(roots, name)
    if near == nil then
      return nil
    end
    found[name] = near
    return require("build.driver").source(name, near.file, near.text, "tl")
  end
end

--- Whether a module of `found` has another file or text in `roots` now, or none: a checker that read them must read
--- them again.
function Nearby.moved(roots: {string}, found: {string: Pipeline.Nearby}): boolean
  for name, near in pairs(found) do
    local now = Nearby.find(roots, name)
    if now == nil or now.file ~= near.file or now.text ~= near.text then
      return true
    end
  end
  return false
end

--- Whether `text` calls `require` with a literal name, as `require("m")` or `require "m"`, of a module the trees at
--- `roots` have a file of. It reads the text, not its syntax, so that a chunk that requires none is told so without
--- loading the checker: a match in a comment or a string only sends the chunk to the slower path that checks it.
function Nearby.required(roots: {string}, text: string): boolean
  for name in text:gmatch("%f[%w_.]require%s*%(?%s*[\"']([%w_.]+)[\"']") do
    if Nearby.find(roots, name) ~= nil then
      return true
    end
  end
  return false
end

return Nearby
