-- The module store, as the core provides it. `require` reads a database
-- and nothing else; these are the ways in that `require` does not cover.

local type sqlite = require("cosmic.internal.sqlite")

local record store
  -- The running core, as trusted_core hands it over.
  record Core
    bytes: string
    target_id: integer
    configuration_id: integer
    digest: string
  end

  -- Opens a projected module database and searches it ahead of every other.
  attach: function(path: string): boolean, string

  -- One module's compiled bytes, for a caller that must load the chunk
  -- in an environment of its own.
  bytecode: function(path: string): string | nil, string

  -- One entry of the meta table, which is where the build records what
  -- it decided. Nil when no database holds that key.
  meta: function(key: string): string | nil

  -- One module's Teal source, or a declaration's, from the binary's own
  -- database and no other: what a checker building another tree needs
  -- to type a `require` of this one's modules.
  source: function(path: string): string | nil, string

  -- Every database `require` searches, in search order, each as a
  -- borrowed `cosmic.sqlite` handle that reads only and never closes
  -- the connection under it.
  databases: function(): {sqlite.Handle}

  -- Private retained-artifact capability. Only trusted build.artifact receives
  -- this raw table; cosmic.store deliberately exposes no wrapper for it.
  trusted_prefix: function(): string | nil, string

  -- Private: the running core's exact bytes, checked against its manifest,
  -- which a host program is made from.
  trusted_core: function(): Core | nil, string
end

return store
