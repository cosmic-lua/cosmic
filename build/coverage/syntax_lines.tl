--- Which lines of a module's own source could ever be hit ([`build.syntax_executable`]), as coverage reads them: from
--- the `executable` table a parse fills, or worked out here where a source has no row there.
local Executable = require("build.syntax_executable")
local Sqlite = require("cosmic.sqlite")
local bind = require("build.bind")

local record Lines
  --- [`build.syntax_executable.of_source`]'s answer for `source`, a file named `name`.
  executable: function(source: string, name: string): {integer: boolean}?, string

  --- [`Lines.executable`]'s answer for `source`, read from the `executable` table of `db` (one of
  --- [`build.analysis_schema`]'s, which a parse fills) when it has a row for `source_hash`, else computed and stored.
  --- A parse failure is returned as [`Lines.executable`] returns it and nothing is written: only a parse is a function
  --- of the hash.
  executable_cached: function(db: Sqlite.Handle, source_hash: string, source: string,
                              name: string): {integer: boolean}?, string
end

local text = bind.text

function Lines.executable(source: string, name: string): {integer: boolean}?, string
  return Executable.of_source(source, name)
end

function Lines.executable_cached(db: Sqlite.Handle, source_hash: string, source: string,
                                 name: string): {integer: boolean}?, string
  local key = source_hash
  local cached, select_trouble = db:text_rows(
    "SELECT lines FROM executable WHERE source_hash = ?1", { text(key) })
  if cached == nil then
    return nil, tostring(select_trouble)
  end
  if #cached > 0 then
    local out: mut {integer: boolean} = {}
    for piece in cached[1]:text(1):gmatch("%d+") do
      local line = math.tointeger(tonumber(piece))
      if line ~= nil then out[line] = true end
    end
    return out, ""
  end
  local executable, trouble = Lines.executable(source, name)
  if executable == nil then
    return nil, trouble
  end
  local inserted, insert_trouble = db:run(
    "INSERT OR IGNORE INTO executable (source_hash, lines) VALUES (?1, ?2)",
    { text(key), text(Executable.joined(executable)) })
  if not inserted then
    return nil, tostring(insert_trouble)
  end
  return executable, ""
end

return Lines
