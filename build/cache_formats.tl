--- The shared caches' format names and creation statements, owned by the
--- build. Writers initialize only their current tables; maintenance reads
--- these definitions without opening a cache through a writer or migrating it.
--- No compiler, test coordinator, CLI or SQLite connection belongs here.

local record cache_formats
  --- Current compiled-module table.
  compiled: string
  --- Current parsed-source table.
  parsed: string
  --- Current declared-input verdict table.
  declared: string
  --- Current closure-store digest table.
  stores: string
  --- Compile/parse prefixes and current versions, for writer migration.
  compile_versions: {{string, integer}}
  --- Statements the compile cache initializes with.
  compiles: {string}
  --- Statements the verdict cache initializes with.
  verdicts: {string}
  --- The supported observation-keyed verdict table, retained by current writers.
  legacy_verdicts: string
end

local compiled <const> = "compiled_v2"
local parsed <const> = "parsed_v1"
local declared <const> = "declared_v1"
local stores <const> = "stores_v1"
cache_formats.compiled, cache_formats.parsed = compiled, parsed
cache_formats.declared, cache_formats.stores = declared, stores
cache_formats.compile_versions = { { "compiled_v", 2 }, { "parsed_v", 1 } }

cache_formats.compiles = {
  "CREATE TABLE IF NOT EXISTS " .. compiled .. [[ (key TEXT PRIMARY KEY,
                                                  lua BLOB NOT NULL,
                                                  bytecode BLOB NOT NULL,
                                                  refs BLOB NOT NULL,
                                                  digest TEXT NOT NULL,
                                                  size INTEGER NOT NULL,
                                                  used_ns INTEGER NOT NULL)]],
  "CREATE INDEX IF NOT EXISTS " .. compiled .. "_by_use ON " .. compiled .. " (used_ns)",
  -- `requires` apart from `rows`, and not deflated: [`build.importer`]'s
  -- fixed point reads it of every source, where it takes `rows` only
  -- of the analyzer it settles on.
  "CREATE TABLE IF NOT EXISTS " .. parsed .. [[ (analyzer TEXT NOT NULL,
                                                source_hash TEXT NOT NULL,
                                                mapped INTEGER NOT NULL,
                                                requires TEXT NOT NULL,
                                                rows BLOB NOT NULL,
                                                digest TEXT NOT NULL,
                                                size INTEGER NOT NULL,
                                                used_ns INTEGER NOT NULL,
                                                PRIMARY KEY (analyzer, source_hash, mapped))]],
  "CREATE INDEX IF NOT EXISTS " .. parsed .. "_by_use ON " .. parsed .. " (used_ns)",
  "CREATE INDEX IF NOT EXISTS " .. parsed .. "_by_source ON " .. parsed .. " (source_hash)",
}

cache_formats.verdicts = {
  "CREATE TABLE IF NOT EXISTS " .. declared .. [[ (key TEXT PRIMARY KEY,
                                                  test TEXT NOT NULL,
                                                  hits BLOB NOT NULL,
                                                  elapsed_ns INTEGER NOT NULL,
                                                  used_ns INTEGER NOT NULL,
                                                  origin TEXT NOT NULL,
                                                  parts TEXT NOT NULL DEFAULT '')]],
  "CREATE INDEX IF NOT EXISTS " .. declared .. "_by_use ON " .. declared .. " (used_ns)",
  "CREATE TABLE IF NOT EXISTS " .. stores .. [[ (address TEXT PRIMARY KEY,
                                                digest TEXT NOT NULL,
                                                used_ns INTEGER NOT NULL)]],
  "CREATE INDEX IF NOT EXISTS " .. stores .. "_by_use ON " .. stores .. " (used_ns)",
}

--- The observation format that preceded declared-input verdicts. Only this
--- version's historical shape is supported; a number in a name is no schema.
cache_formats.legacy_verdicts = [[CREATE TABLE verdicts_v4 (key TEXT PRIMARY KEY,
  test TEXT NOT NULL, module_key TEXT NOT NULL, reads BLOB NOT NULL,
  hits BLOB NOT NULL, elapsed_ns INTEGER NOT NULL, used_ns INTEGER NOT NULL,
  origin TEXT NOT NULL)]]

return cache_formats
