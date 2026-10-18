--- The rows of one parse that the syntax tree alone gives, written where [`build.derivation`] writes the rest of a
--- parse's rows: what the source requires, where it declares a global, and its stub.
---
-- TODO: write the other rows of a parse (`parsed`, `tests`, `test_inputs`, `catalog`, `docs`, `refs`, `bound`, `links`,
-- `examples`) from the tree here too, and have [`build.derivation`]'s `parse_fresh` call this module, once
-- [`build.analyzer`] and [`build.link_text`] are rewritten to the new tree (doc/plans/strict-teal.md, "the switch"); the
-- rows above wait on them.
local Ast = require("lang.ast")
local Globals = require("build.syntax_globals")
local Node = require("build.syntax_node")
local Sqlite = require("cosmic.sqlite")
local Stub = require("build.syntax_stub")
local bind = require("build.bind")

local record Derivation
  --- What the tree gives of a source.
  record Rows
    requires: {string}
    globals: {Globals.Place}
    --- The stub of a source that returns a value, nil for one that returns nothing (a test, as a rule): it is no module
    --- a checker reads in place of anything.
    stub: Stub.Made | nil
  end

  --- The rows of `chunk`, read off its tree.
  rows_of: function(chunk: Ast.Chunk): Rows

  --- Writes the `requires`, `globals` and `stubs` rows of the source `source_hash`, the tree of which is `chunk`, as
  --- [`build.derivation`] writes them. `file` names the source in a failure.
  insert: function(db: Sqlite.Handle, source_hash: string, file: string, chunk: Ast.Chunk): boolean, string
end

local text = bind.text

function Derivation.rows_of(chunk: Ast.Chunk): Derivation.Rows
  local returns = false
  for _, stat in ipairs(chunk.body.stats) do
    if stat is Ast.Return then
      returns = true
    end
  end
  local stub: Stub.Made | nil = nil
  if returns then
    stub = Stub.made(chunk)
  end
  return { requires = Node.requires(chunk), globals = Globals.found(chunk), stub = stub }
end

function Derivation.insert(db: Sqlite.Handle, source_hash: string, file: string, chunk: Ast.Chunk): boolean, string
  local rows = Derivation.rows_of(chunk)
  for ordinal, name in ipairs(rows.requires) do
    local ok, why = Sqlite.run(db, "INSERT INTO requires (source_hash, ordinal, name) VALUES (?1, ?2, ?3)",
      { text(source_hash), { integer = ordinal }, text(name) })
    if not ok then
      return false, file .. ": " .. why
    end
  end
  for ordinal, place in ipairs(rows.globals) do
    local ok, why = Sqlite.run(db, "INSERT INTO globals (source_hash, ordinal, line, column) VALUES (?1, ?2, ?3, ?4)",
      { text(source_hash), { integer = ordinal }, { integer = place.line }, { integer = place.column } })
    if not ok then
      return false, file .. ": " .. why
    end
  end
  local stub = rows.stub
  if stub ~= nil then
    local ok, why = Sqlite.run(db, "INSERT INTO stubs (source_hash, text, pruned) VALUES (?1, ?2, ?3)",
      { text(source_hash), text(stub.text), { integer = stub.pruned and 1 or 0 } })
    if not ok then
      return false, file .. ": " .. why
    end
  end
  return true, ""
end

return Derivation
