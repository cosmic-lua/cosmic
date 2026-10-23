--- Why a tool is stale against the tree: the modules of the tree the
--- running binary does not carry as the tree has them, as the line that
--- says the tool is rebuilding names them.

local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local plural = require("build.plural")
local work = require("build.work")

local record stale_reason
end

--- What follows "the tool is stale; rebuilding it from the tree": how
--- many modules of the tree in `handle`, open and staged, the running
--- binary does not carry as the tree has them (one it lacks too), and
--- the first three, as " (2 modules moved: build.a, build.b)". "" where
--- none is found (what moved was not a module) or the tree cannot be
--- read.
function stale_reason.of(handle: work.Handle): string
  local rows, _ = Sqlite.text_rows(handle.db,
    "SELECT path, source_hash FROM inputs WHERE (origin = 'tree' " ..
      "AND kind IN ('module', 'main')) OR origin = 'vendor' ORDER BY path")
  if rows == nil then
    return ""
  end
  local count = 0
  local shown = ""
  for _, row in ipairs(rows) do
    local source, _ = Store.source(row:text(1))
    if source == nil or Hash.hex_sha256(source) ~= row:text(2) then
      count = count + 1
      if count == 1 then
        shown = row:text(1)
      elseif count <= 3 then
        shown = shown .. ", " .. row:text(1)
      end
    end
  end
  if count == 0 then
    return ""
  end
  local more = ""
  if count > 3 then more = " and " .. tostring(count - 3) .. " more" end
  return " (" .. plural.count(count, "module") .. " moved: " .. shown .. more .. ")"
end

return stale_reason
