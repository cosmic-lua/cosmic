--- Worked examples for `cosmic.tar`, shown by `cosmic docs` under the
--- symbol each one demonstrates and run by `cosmic test` like any
--- other test -- see doc/design.md's `examples` table.

local Stream = require("cosmic.stream")
local Tar = require("cosmic.tar")

local Example = {}

--- A tar made in memory and read back: `writer` over a
--- `Stream.collect`, then `reader` over what it collected.
function Example.writer()
  local out = Stream.collect()
  local w = Tar.writer(out, { deterministic = true })
  assert(w:add_dir("site"))
  assert(w:add_file("site/index.html", "<p>hello</p>"))
  assert(w:add_symlink("site/home.html", "index.html"))
  assert(w:close())
  local r = Tar.reader(Stream.from_string(out:result()))
  local kinds: {string} = {}
  while true do
    local entry, trouble = r:next()
    if entry == nil then
      assert(trouble == "", trouble)
      break
    end
    print(entry.path, entry.kind)
    kinds[#kinds + 1] = entry.kind
  end
  assert(r:close())
  assert(table.concat(kinds, " ") == "dir file symlink", table.concat(kinds, " "))
end

return Example
