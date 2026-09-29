--- What names an exact query as a symbol, and what is a use of it: one
--- rule, shared by `cosmic docs` and `cosmic uses` (`build.docs`) and by
--- the compiler's hint for a name it could not resolve
--- (`build.importer`), so a hint never names a row `cosmic docs <word>`
--- would disagree with. It is a module of its own because
--- `build.importer` requires it for the hint, and `build.docs` requiring
--- `build.importer` back for this rule would be a cycle. This module
--- requires neither.

local Sqlite = require("cosmic.sqlite")

local record symbols
  guides: {string}
  internal_guides: {string:string}
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

--- The user guides (`doc/guides/<name>.md`) a binary carries: the ones
--- a reader of `cosmic docs` is meant to find. A guide about how the
--- runtime is built is left to the tree (`internal_guides`). Every
--- guide is in one list or the other: `build.tree_checks` refuses a
--- guide in neither, so a new one is never left out by mistake.
symbols.guides = { "command-line", "project", "quickstart" }

--- The guides a binary does not carry, each with its reason.
symbols.internal_guides = {
  ["portable-runtime"] = "how the release artifact is built, for those working on cosmic",
}

--- Whether a module is a user guide a public source answers for: the
--- module a guide compiles as (`doc.guides.quickstart`).
function symbols.is_public_guide(module: string): boolean
  for _, name in ipairs(symbols.guides) do
    if module == "doc.guides." .. name then
      return true
    end
  end
  return false
end

--- The condition under which the SQL `column` names a user guide's
--- module (one of the user guides above).
function symbols.guide_module(column: string): string
  local names: {string} = {}
  for _, name in ipairs(symbols.guides) do
    names[#names + 1] = "'doc.guides." .. name .. "'"
  end
  return column .. " IN (" .. table.concat(names, ", ") .. ")"
end

--- `public_only`, and the user guides too: what a public source's
--- docs rows may hold. Only a guide's own row is carried (its prose),
--- not the helpers its generated test module declares, so this is a
--- condition on `docs` rows alone.
function symbols.public_docs(column: string, public: boolean): string
  if not public then
    return "1"
  end
  return "(" .. symbols.public_only(column, true) .. " OR " ..
    symbols.guide_module(column) .. ")"
end

--- The condition under which the SQL `name` ends in `.` or `:` and then
--- the SQL `last`: `last` is `name`'s last name, or its last few.
local function ends_in(name: string, last: string): string
  return "(substr(" .. name .. ", -length(" .. last .. ") - 1) = '.' || " .. last ..
    " OR substr(" .. name .. ", -length(" .. last .. ") - 1) = ':' || " .. last .. ")"
end

--- `?1` with a method's `:` spelled `.`, as a member path is kept:
--- `Box:grow` names the member `Box.grow`.
local DOTTED <const> = "replace(?1, ':', '.')"

--- The condition under which `alias` (a row of `docs`) names `?1`
--- exactly: a symbol as declared (`Fs.read`), a symbol's last name
--- alone (`read`, matching every `X.read` and `X:read`), a member path
--- or its last few names, called or not (`Box:grow`, `Box.grow`), or a
--- module's own row (`cosmic.fs`).
function symbols.named_where(alias: string): string
  return "(" .. alias .. ".symbol = ?1 OR " .. alias .. ".source_symbol = ?1 OR " ..
    ends_in(alias .. ".symbol", "?1") .. " OR " ..
    alias .. ".symbol = " .. DOTTED .. " OR " ..
    ends_in(alias .. ".symbol", DOTTED) .. " OR " ..
    "(" .. alias .. ".symbol = '' AND " .. alias .. ".module = ?1))"
end

--- The condition under which `alias` (a row of `uses`) is a use of what
--- `?1` names, the same way `named_where` finds its declaration. A use
--- is recorded under its canonical path, without the module's own
--- record (`exists`, `Writer.add_file`), so besides that path and
--- its last name alone, `?1` may spell it from the module's record
--- down (`Fs.exists`, `Zip.Writer.add_file`): one name more, and
--- only one, so `Stream.Writer.write` is not a use of every `write`.
--- A use is recorded with `.` throughout (`Box.grow`), so `?1`'s `:`
--- is read as one (`Thing.Box:grow`, `Box:grow`), as `cosmic docs`
--- prints a method's name.
-- TODO: the one name past the path is not checked against the module's
-- own record, which no table keeps, so `Writer.write` is also a use of
-- every bare `write` (`Fs.write`'s among them). Keep each module's
-- record name (`Fs`, `Stream`) where `build.analyzer` canonicalizes a
-- symbol, and match that name here rather than any single name.
function symbols.used_where(alias: string): string
  local symbol = alias .. ".symbol"
  local record = "substr(" .. DOTTED .. ", 1, length(?1) - length(" .. symbol .. ") - 1)"
  return "(" .. symbol .. " = " .. DOTTED .. " OR " .. ends_in(symbol, DOTTED) .. " OR " ..
    "(" .. ends_in(DOTTED, symbol) .. " AND instr(" .. record .. ", '.') = 0))"
end

--- Every symbol `query` names exactly, across `databases` (searched in
--- order, the tree's own last projection ahead of the binary's), each
--- as the `symbol` column reads, already qualified by its record
--- (`Removed.io`), or as the bare module name for a module's own row
--- (`symbol` is `""` there). It is what a name the compiler could not
--- resolve might have meant. A database with no `docs` table, or a
--- query that fails, answers as no match rather than a trouble: a hint
--- is never a reason to fail the compile it explains.
function symbols.named(databases: {Sqlite.Handle}, public: {boolean},
                       query: string): {string}
  local seen: {string: boolean} = {}
  local out: {string} = {}
  for index, db in ipairs(databases) do
    -- A query that fails is no match: a hint never fails the compile.
    local rows, _ = Sqlite.text_rows(db,
      "SELECT DISTINCT module, symbol FROM docs d WHERE " ..
      symbols.named_where("d") .. " AND " ..
      symbols.public_docs("d.module", public[index] == true) ..
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

--- Whether a worked-example name, comment, or checked source answers a
--- query in any of `databases`. Compiler diagnostics ask before printing
--- a docs command, so an old or incomplete binary never advertises
--- documentation it cannot answer. A query that fails is false: a hint
--- cannot replace the compiler's own diagnostic.
function symbols.has_example_query(databases: {Sqlite.Handle}, public: {boolean},
                                   name: string): boolean
  local owners: {string: integer} = {}
  for index, db in ipairs(databases) do
    -- A query that fails is no owner, and so no example.
    local modules, _ = Sqlite.text_rows(db, "SELECT path FROM modules")
    if modules ~= nil then
      for _, row in ipairs(modules) do
        if owners[row[1]] == nil then owners[row[1]] = index end
      end
    end
  end
  local words: {string} = {}
  for word in name:gmatch("[%w_]+") do words[#words + 1] = word end
  local phrase = '"' .. table.concat(words, " ") .. '"'
  for index, db in ipairs(databases) do
    for _, lookup in ipairs({
      { "SELECT e.module FROM examples e WHERE e.name = ?1 AND " ..
          symbols.public_only("e.module", public[index] == true), name },
      { "SELECT e.module FROM examples_fts JOIN examples e " ..
          "ON e.id = examples_fts.rowid WHERE examples_fts MATCH ?1 AND " ..
          symbols.public_only("e.module", public[index] == true), phrase },
    }) do
      -- A query that fails is no match.
      local rows, _ = Sqlite.text_rows(db, lookup[1], { { text = lookup[2] } })
      if rows ~= nil then
        for _, row in ipairs(rows) do
          if owners[row[1]] == index then return true end
        end
      end
    end
  end
  return false
end

return symbols
