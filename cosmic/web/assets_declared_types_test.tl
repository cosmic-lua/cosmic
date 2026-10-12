--- The declarations of cosmic.web.assets tell the truth about nil: an
--- asset with no gzip variant holds none. A checked run
--- (`cosmic test --check-types`) says whether a value crossed a typed
--- boundary as a kind its type does not admit; in any other run the
--- tests skip.

local Assets = require("cosmic.web.assets")
local TypeWatch = require("build.type_watch")

local function test_an_asset_with_no_gzip_variant_is_as_declared()
  local found = TypeWatch.during(function()
    local css = ("a { color: red }\n"):rep(200)
    assert(assert(Assets.memory({ ["a.css"] = "a{}" }):get("a.css")).gzip == nil)
    assert(assert(Assets.memory({ ["a.css"] = css }, { gzip = true }):get("a.css")).gzip ~= nil)
  end)
  assert(#found == 0, #found .. " violations:\n" .. table.concat(found, "\n"))
end
