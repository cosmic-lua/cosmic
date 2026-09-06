--- Whether a test file spawns the tree's own built `cosmic` -- behavior
--- no import edge can name, so `_make/graph.tl`'s `project_mk` uses this
--- to add `o/bin/cosmic` to a test's `deps_<stem>` BY POSITION.

local fs = require("cosmic.fs")

--- Whether a test drives `--make` itself, or a binary it produces, by
--- spawning cosmic. Position decides it first: `_make/**` and `_cli/**`
--- are this project's own tooling. Everywhere else, content decides it:
--- a readable file naming the literal token `TEST_BIN` -- what the
--- runner sets for the built binary (`_make/stage.tl`) -- spawns it too,
--- whatever tree it lives in. The graph is built after `open_project`
--- chdirs to the root (`_make/init.tl`), so a relative read here lands
--- on the right file; a path that cannot be read falls back to position
--- alone.
--- @param path string Source file path, relative to the root
--- @return boolean
local function exercises_the_engine(path: string): boolean
  if path:match("^_make/") ~= nil or path:match("^_cli/") ~= nil then
    return true
  end
  local text = fs.read(path)
  if not text then
    return false
  end
  return text:find("TEST_BIN", 1, true) ~= nil
end

local record EngineModule
  exercises_the_engine: function(path: string): boolean
end

local M: EngineModule = {
  exercises_the_engine = exercises_the_engine,
}

return M
