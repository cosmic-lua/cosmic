--- Worked examples for [`cosmic.web.assets`], shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any other
--- test -- see doc/design.md's `examples` table.

local Assets = require("cosmic.web.assets")
local Fs = require("cosmic.fs")

local Example = {}

--- A program built from a project with a `static/` directory carries its
--- files; one that was not, as this example is, holds none, and a lookup
--- is a miss with a reason rather than a raise.
function Example.embedded()
  local source = Assets.embedded()
  assert(#source:paths() == 0 and source:dynamic() == false)
  local asset, why = source:get("css/app.css")
  assert(asset == nil)
  assert(why:find("no such asset", 1, true))
  print(why)
end

--- Memory serves what a program generates; each file has the hash, entity
--- tag and type a server sends it by, and the subresource-integrity value
--- a page's `integrity` attribute takes.
function Example.memory()
  local source = Assets.memory({ ["app.js"] = "console.log(1)" })
  local asset = assert(source:get("app.js"))
  print(asset.type, asset.etag)
  assert(asset.type == "text/javascript; charset=utf-8")
  assert(asset:integrity():sub(1, 7) == "sha384-")
end

--- A directory source reads a file as it is on disk, again after an edit,
--- which is what development wants; a path out of the root, a hidden file
--- and a link that leaves the directory are misses.
function Example.directory()
  local root = assert(Fs.mkdtemp("cosmic-assets-example-"))
  assert(Fs.write(root .. "/app.css", "one"))
  assert(Fs.write(root .. "/.env", "SECRET"))
  local source = Assets.directory(root)
  assert(assert(source:get("app.css")).data == "one")
  assert(Fs.write(root .. "/app.css", "two!"))
  assert(assert(source:get("app.css")).data == "two!")
  assert(source:get("../app.css") == nil)
  assert(#source:paths() == 1)
  assert(Fs.remove_tree(root))
end

return Example
