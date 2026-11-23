--- The identity of the code that reads and checks a source ([`build.pipeline`] and every module of the tree it reaches),
--- which every compile is keyed by: an edit to the checker or to a reader compiles the tree again. A module of its own,
--- apart from the checker, so that a run whose every module a cache answers names the compile without loading the
--- checker's hundred modules.

local AnalysisSchema = require("build.analysis_schema")
local CodeWalk = require("build.code_walk")
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local Stamp = require("build.stamp")
local Store = require("cosmic.store")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): the sources of the checker's walk.
local _ = require("build.reads.pipeline")

local record code_identity
  --- The identity of the code over the modules `source` and `requires` answer for, as [`code_identity.coded`] hashes
  --- it: what [`build.stamps`] keeps as `stamp_coded`.
  code_of: function(source: function(name: string): string?, requires: function(name: string): {string}): string

  --- The tool string a compile is keyed by, given the one the harness chose ([`build.grammar_mode`]'s `tool`): that and the
  --- identity of the code that reads and checks a source, which is the source, as the running binary carries it,
  --- of every module of the tree (`lang.*`, `build.*`) that [`build.pipeline`] reaches, this module among them. A compile made with it is
  --- keyed by it, so that an edit to the checker or to a reader compiles the tree again; the compiler's identity
  --- ([`build.identity`]) holds none of it, so a default run is not read again for it. A parse is keyed by the part of it
  --- a parse runs, and no more ([`build.parse_derive`], [`build.importer`]'s `analyzer_identity`).
  coded: function(tool: string): string

  --- [`code_identity.coded`] over the code the working database `db` stages, parsed, in place of the code the running
  --- binary carries: the identity of a boot, which runs the tree's own code under a bootstrap release that carries
  --- another. nil and why where the tree is not parsed.
  coded_of: function(tool: string, db: Sqlite.Handle): string?, string
end

--- Where the identity of the code finds a module's source and what it requires.
local record Reader
  source: function(name: string): string?
  requires: function(name: string): {string}
end

--- The identity of the code that reads and checks ([`code_identity.coded`]), over the modules `reader` answers for: each module
--- of [`build.code_walk`]'s walk from this one by its name and its source. What the walk leaves out of this module's own
--- requires, and why, is [`CodeWalk.type_only`].
local function identity(reader: Reader): string
  local names, trouble = CodeWalk.reach(CodeWalk.pipeline, function(name: string): {string}?, string
    return reader.requires(name), ""
  end)
  assert(names, trouble)
  local parts: mut {string} = {}
  for _, name in ipairs(names) do
    local source = reader.source(name)
    if source ~= nil then
      parts[#parts + 1] = name .. "\n" .. source
    end
  end
  table.sort(parts)
  return Hash.hex_sha256(table.concat(parts, "\n\0\n"))
end

--- The code as the running binary carries it.
local carried_code: Reader = {
  source = function(name: string): string?
    local source, _ = Store.source(name)
    if source == nil then
      -- Held without its source is no module the identity may leave out.
      local withheld, trouble = Store.withheld(name)
      if withheld == nil then error(tostring(trouble), 0) end
      if withheld is string then error(withheld, 0) end
    end
    return source
  end,
  requires = function(name: string): {string}
    local required, _ = Store.requires(name)
    return required or {}
  end,
}

--- The code as the working database `db` stages it: a boot runs the tree's own, which the bootstrap release that runs it does
--- not carry. A declaration is no code, and the binary answers no source for one.
local function staged_code(db: Sqlite.Handle): Reader
  return {
    source = function(name: string): string?
      local rows, _ = Sqlite.text_rows(db, "SELECT source FROM inputs WHERE path = ?1 AND " .. AnalysisSchema.not_declaration("kind") .. " LIMIT 1", { { text = name } })
      if rows == nil then
        return nil
      end
      local row = rows[1]
      if row == nil then
        return nil
      end
      return row:text(1)
    end,
    requires = function(name: string): {string}
      local rows, _ = Sqlite.text_rows(db,
        "SELECT DISTINCT r.name FROM inputs i JOIN requires r ON r.source_hash = i.source_hash " ..
          "WHERE i.path = ?1 AND " .. AnalysisSchema.not_declaration("i.kind") .. " ORDER BY r.name", { { text = name } })
      local out: mut {string} = {}
      for _, row in ipairs(rows or {}) do
        out[#out + 1] = row:text(1)
      end
      return out
    end,
  }
end

--- The identity of the code the running binary carries, which nothing in this process changes: read once, rather than
--- hashing the sources of the checker's closure again for each compile of a process that compiles many trees.
local record Remembered
  mut code: string?
end

local carried_identity: Remembered = { code = nil }

function code_identity.code_of(source: function(name: string): string?, requires: function(name: string): {string}): string
  return identity({ source = source, requires = requires })
end

function code_identity.coded(tool: string): string
  local code = carried_identity.code
  if code == nil then
    code = Stamp.read("stamp_coded") or identity(carried_code)
    carried_identity.code = code
  end
  return Hash.hex_sha256(tool .. "\0" .. code)
end

function code_identity.coded_of(tool: string, db: Sqlite.Handle): string?, string
  -- The requires of a source are rows the parse of it made, so a tree not parsed yet has none: the identity would be the
  -- pipeline's own source alone, and an edit to the checker would read as none.
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT count(*) FROM inputs i JOIN requires r ON r.source_hash = i.source_hash WHERE i.path = 'build.pipeline'")
  if rows == nil then
    return nil, tostring(trouble)
  end
  local count = rows[1]
  if count == nil or count:text(1) == "0" then
    return nil, "build/pipeline.tl is not parsed yet, so the code that reads the tree cannot be named"
  end
  return Hash.hex_sha256(tool .. "\0" .. identity(staged_code(db))), ""
end

return code_identity
