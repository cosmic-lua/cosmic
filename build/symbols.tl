--- What names an exact query as a symbol -- one rule, shared by
--- `cosmic docs`'s own matching (`build.docs`) and the compiler's own
--- hint for a name it could not resolve (`build.importer`), so a
--- compile-time pointer can never name a row `cosmic docs <word>`
--- itself would disagree with. `build.docs` cannot hold this rule on
--- its own: it already requires `build.importer` (for
--- `is_own_tree`), so `build.importer` requiring it back would be a
--- cycle. This module requires neither.

local Sqlite = require("cosmic.sqlite")

local record symbols
end

--- Whether a module is the public standard library's own: what a
--- public source answers for.
function symbols.is_public_module(module: string): boolean
  return module:sub(1, 7) == "cosmic." and module:sub(1, 16) ~= "cosmic.internal." and
    module:sub(-5) ~= "_test"
end

--- The rows a public source answers with, as a condition on the
--- module `column` names; `1` when the source is not public.
function symbols.public_only(column: string, public: boolean): string
  if not public then
    return "1"
  end
  return "(" .. column .. " LIKE 'cosmic.%' AND " .. column ..
    " NOT LIKE 'cosmic.internal.%' AND substr(" .. column .. ", -5) <> '_test')"
end

--- The condition under which `alias` (a row of `docs`) names `?1`
--- exactly: a symbol as declared (`Fs.read`), a symbol's last name
--- alone (`read`, matching every `X.read` and `X:read`), or a
--- module's own row (`cosmic.fs`).
function symbols.named_where(alias: string): string
  return "(" .. alias .. ".symbol = ?1 OR " .. alias .. ".source_symbol = ?1 OR " ..
    "substr(" .. alias .. ".symbol, -length(?1) - 1) = '.' || ?1 OR " ..
    "substr(" .. alias .. ".symbol, -length(?1) - 1) = ':' || ?1 OR " ..
    "(" .. alias .. ".symbol = '' AND " .. alias .. ".module = ?1))"
end

--- Every symbol `query` names exactly, across `databases` (searched in
--- order, a project's own working database ahead of the binary's),
--- named the way `symbol` itself already reads -- `Removed.io`,
--- already qualified by its own record -- or the bare module name for
--- a module's own row (`symbol` is `""` there). This is what a name a
--- compile could not resolve might have meant, so a database this
--- database view does not carry `docs` in, or a query that fails
--- outright, answers as no match rather than a trouble: a hint is
--- never a reason to fail the compile it is explaining.
function symbols.named(databases: {Sqlite.Handle}, public: {boolean},
                       query: string): {string}
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for index, db in ipairs(databases) do
    local rows = Sqlite.text_rows(db,
      "SELECT DISTINCT module, symbol FROM docs d WHERE " ..
      symbols.named_where("d") .. " AND " ..
      symbols.public_only("d.module", public[index] == true) ..
      " ORDER BY module, symbol",
      { { text = query } })
    if rows ~= nil then
      for _, row in ipairs(rows) do
        local name = row[2] ~= "" and row[2] or row[1]
        if not seen[name] then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    end
  end
  return out
end

return symbols
