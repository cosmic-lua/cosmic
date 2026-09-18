-- The module store, as the core provides it. `require` reads a database
-- and nothing else; these are the ways in that `require` does not cover.

local record store
  -- Opens a database and searches it ahead of every other, which is what
  -- a project's own build database needs.
  attach: function(path: string): boolean, string

  -- One module's compiled bytes, for a caller that must load the chunk
  -- in an environment of its own.
  bytecode: function(path: string): string | nil, string

  -- One entry of the meta table, which is where the build records what
  -- it decided. Nil when no database holds that key.
  meta: function(key: string): string | nil
end

return store
