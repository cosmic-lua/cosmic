--- The module store, as the core provides it. `require` reads a database
--- and nothing else; these are the ways in that `require` does not cover.

local type sqlite = require("cosmic.internal.sqlite")

local record store
  --- The running core, as trusted_core hands it over.
  record Core
    --- The core's exact bytes, as the artifact holds them.
    bytes: string
    --- The target the artifact's manifest names it by.
    target_id: integer
    --- The configuration the artifact's manifest names it by.
    configuration_id: integer
    --- Its SHA-256 digest, as 32 raw bytes, which its bytes match.
    digest: string
  end

  --- Opens a projected module database and searches it ahead of every other.
  attach: function(path: string): boolean, string

  --- One module's compiled bytes, for a caller that must load the chunk
  --- in an environment of its own.
  bytecode: function(path: string): string | nil, string

  --- One entry of the meta table, which is where the build records what
  --- it decided. Nil when no database holds that key.
  meta: function(key: string): string | nil

  --- One module's Teal source, or a declaration's, from the binary's own
  --- database and no other: what a checker building another tree needs
  --- to type a `require` of this one's modules.
  source: function(path: string): string | nil, string

  --- Every database `require` searches, in search order, each as a
  --- borrowed `cosmic.sqlite` handle that reads only and never closes
  --- the connection under it.
  databases: function(): {sqlite.Handle}

  --- Calls the function searching only the binary's own database, then
  --- puts every other back, whether it returned or raised.
  alone: function(function())

  --- The names the binary's own `imports` table records a module
  --- requiring, sorted: none for a name it holds no row of. Nil and why
  --- when a hold holds the name, or the query failed.
  requires: function(name: string): {string} | nil, string

  --- One time zone's TZif file, by IANA name, from the binary's own
  --- database: nil and why when it carries no such zone or the query
  --- failed.
  zoneinfo: function(name: string): string | nil, string

  --- Every time zone name the binary's own database carries, as a set,
  --- or nil and why when the query failed.
  zone_names: function(): {string:boolean} | nil, string

  --- Private: puts up a hold, for the rest of the process, on the names
  --- the set holds as keys, saying why of a module with the first text
  --- and why of `databases` with the second; raises when one is up
  --- already. While it is up, the searcher, `bytecode`, `source` and
  --- `requires` answer none of those names, and `databases` raises.
  hold: function(names: {string:boolean}, why: string, why_databases: string)

  --- Private retained-artifact capability. Only trusted build.artifact receives
  --- this raw table; cosmic.store deliberately exposes no wrapper for it.
  trusted_prefix: function(): string | nil, string

  --- Private: the running core's exact bytes, checked against its manifest,
  --- which a host program is made from.
  trusted_core: function(): Core | nil, string
end

return store
