--- The parse of the staged tree: reads each source no parse has seen and writes its rows.
---
--- THIS MODULE IS A ROOT OF THE ANALYZER'S IDENTITY ([`build.code_walk`]'s `analyzer_roots`), which keys every stored
--- parse: a parse stands while the source of every module reached from here stands. So everything that decides the rows
--- of a parse, or whether a source has any, is here or is required from here: which files of `inputs` are sources and
--- under what names ([`ParseDerive.entries`], [`ParseDerive.index`]), the lexer and the parser ([`build.source_parse`]),
--- the readers of the syntax tree and the statements that write their rows ([`build.syntax_derivation`]), the line a
--- syntax error is told by ([`ParseDerive.line`]) and the repair of one. [`build.importer`] chooses when to run it and
--- takes no part in what it writes.
---
--- Nothing here requires the checker ([`lang.check`]) or a module that does, a type import included, so an edit to the
--- checker parses nothing again. [`build.pipeline`], [`build.tree_program`] and [`build.error_render`] answer the pieces
--- they share with a compile from here.
local Ast = require("lang.ast")
local Declarations = require("lang.declarations")
local SourceParse = require("build.source_parse")
local Sqlite = require("cosmic.sqlite")
local SyntaxDerivation = require("build.syntax_derivation")
local type Derivation = require("build.derivation")

local record ParseDerive
  --- Whether the tree was refused for what it holds (a declaration beside its source), rather than for a trouble reading it.
  record Refusal
    mut refused: boolean
  end

  --- Whether the programs of a tree leave out the file `file`: those of a `testdata/` directory, which are fixtures of a test.
  skipped: function(file: string): boolean

  --- The sources of `entries`: pairs of a path below the root and its text, or with the module and the name the
  --- findings are told under as well for a source the build writes from another file ([`SourceParse.index`]), all in the new
  --- grammar, less the programs of a `testdata/` directory. `kinds` says of a file what the working database says
  --- of its input; a `test` has its functions called from outside.
  index: function(entries: {{string}}, kinds: {string: string}): SourceParse.Index

  --- What `inputs` stages for the new checker: the files and their text (the tree's own, and what is written from it) as
  --- [`ParseDerive.index`] takes them, and the kind of each by its file.
  record Staged
    entries: {{string}}
    kinds: {string: string}
  end

  --- What `inputs` of `db` stages. nil and why where a row cannot be read or the tree is refused
  --- ([`SourceParse.declared`]), which sets `refusal.refused` when given. `own` says the tree is cosmic's own.
  entries: function(db: Sqlite.Handle, own: boolean, refusal?: Refusal): Staged?, string

  --- The line for `problem` of the file `file`, its fix included: `file:line:column: message (code): fix`.
  line: function(file: string, problem: SourceParse.Problem): string

  --- Reads the sources `fresh` ([`build.derivation`]'s `fresh`) as written, and writes the rows of each ([`build.syntax_derivation`])
  --- into `db` beside the others, counting each in `tally` and listing it in `made`. A source that does not parse is listed
  --- in `broken` when given and stops the derive otherwise, told by [`ParseDerive.line`].
  derive: function(db: Sqlite.Handle, own: boolean, fresh: {Derivation.Fresh}, tally: Derivation.Parses,
    made: mut {Derivation.Source}, broken?: mut {Derivation.Broken}, refusal?: Refusal): boolean, string
end

function ParseDerive.skipped(file: string): boolean
  return file:find("^testdata/") ~= nil or file:find("/testdata/", 1, true) ~= nil
end

local skipped = ParseDerive.skipped

function ParseDerive.index(entries: {{string}}, kinds: {string: string}): SourceParse.Index
  return SourceParse.index(entries, skipped, function(file: string, _text: string): SourceParse.Extra
    return { tests = kinds[file] == "test" }
  end)
end

--- The complaints of [`SourceParse.declared`] for `entries` less the programs of a `testdata/` directory: "" for none. `own`
--- says the tree is cosmic's own.
local function declared(entries: {{string}}, own: boolean): string
  return SourceParse.declared(entries, skipped, own)
end

function ParseDerive.entries(db: Sqlite.Handle, own: boolean, refusal?: ParseDerive.Refusal): ParseDerive.Staged?, string
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, path, kind, origin, source FROM inputs WHERE kind <> 'vendor' ORDER BY file")
  if rows == nil then
    return nil, trouble
  end
  local entries: mut {{string}} = {}
  local kinds: mut {string: string} = {}
  for _, row in ipairs(rows) do
    local file, path, kind, origin, source = row:text(1), row:text(2), row:text(3), row:text(4), row:text(5)
    if origin == "syscalls" then
      -- The declaration is the file of the module, named for the header it is written from.
      local named = (path:gsub("%.", "/")) .. ".d.tl"
      entries[#entries + 1] = { named, source, path, file }
      kinds[named] = kind
    elseif origin == "tree" then
      entries[#entries + 1] = { file, source }
      kinds[file] = kind
    else
      entries[#entries + 1] = { file, source, path }
      kinds[file] = kind
    end
  end
  local refused = declared(entries, own)
  if refused ~= "" then
    if refusal ~= nil then refusal.refused = true end
    return nil, refused
  end
  return { entries = entries, kinds = kinds }, ""
end

function ParseDerive.line(file: string, problem: SourceParse.Problem): string
  return file .. ":" .. tostring(problem.y) .. ":" .. tostring(problem.x) .. ": " .. problem.msg .. " (" .. problem.code .. "): " ..
    problem.fix
end

--- Puts the collector back in the mode `previous` names: the answer it gave when it was switched to the generational one.
local function restore_collector(previous: string)
  if previous == "incremental" then
    collectgarbage("incremental")
  end
end

--- The text of `source`, which `read` parsed with errors, with the fix of each error written in ([`Derivation.Broken`]'s
--- `repaired`): nil unless every error is a `global` in a program and the text with `local` for each parses.
--
-- TODO: repair the other errors of the parser whose fix is one spelling for another of the same statement (`T | nil` for
-- `T?`, a `;`, a trailing comma), once each is shown to leave the tree whole and to have a fix that moves no token: the
-- parser says which construct it skipped ([`lang.parser`]'s `Error` nodes), and not which error left none.
local function repaired_of(source: SourceParse.Source, read: SourceParse.Parsed): string?
  local text = read.text
  local parts: mut {string} = {}
  local from = 1
  for _, p in ipairs(read.syntax) do
    if p.code ~= "global_in_program" or text:sub(p.offset, p.offset + 5) ~= "global" or p.offset < from then
      return nil
    end
    parts[#parts + 1] = text:sub(from, p.offset - 1)
    parts[#parts + 1] = "local "
    from = p.offset + 6
  end
  parts[#parts + 1] = text:sub(from)
  local repaired = table.concat(parts)
  local again = SourceParse.source(source.module, source.filename, repaired, source.dialect)
  if #SourceParse.parse(again).syntax > 0 then
    return nil
  end
  return repaired
end

function ParseDerive.derive(db: Sqlite.Handle, own: boolean, fresh: {Derivation.Fresh}, tally: Derivation.Parses,
                            made: mut {Derivation.Source}, broken?: mut {Derivation.Broken}, refusal?: ParseDerive.Refusal): boolean, string
  local staged, trouble = ParseDerive.entries(db, own, refusal)
  if staged == nil then
    return false, trouble
  end
  local index = ParseDerive.index(staged.entries, staged.kinds)
  -- A source is found by the name of its file in the database, which for a declaration written from a header is the header's.
  local by_file: mut {string: SourceParse.Source} = {}
  for _, source in ipairs(index.sources) do
    local named = source.filename
    if source.pinned ~= "" then
      named = source.pinned
    end
    by_file[named] = source
  end
  -- Each source is read once and its rows kept: the garbage of one is freed as the next is read, and not when the heap has
  -- doubled. The collector goes back to the mode it was in.
  local previous = collectgarbage("generational")
  for _, one in ipairs(fresh) do
    -- A file the program leaves out (a fixture of a test) is read as written, as a module of its own.
    local source = by_file[one.file]
    if source == nil then
      local dialect: Ast.Dialect = "tl"
      if one.file:match("%.d%.tl$") ~= nil then
        dialect = "decl"
      end
      source = SourceParse.source(Declarations.module_of(one.file), one.file, one.source, dialect)
    end
    local read = SourceParse.parse(source)
    local first = read.syntax[1]
    if first ~= nil then
      -- TODO: tell every error of the parser, as the check of a lone file does ([`build.pipeline`]'s `checked_alone`), once the
      -- readers that take the first line of this message for the whole of it take several (`left_out` in
      -- build/importer.tl, and the line `cosmic fix` says once for a file its own parse refused): a file with two syntax
      -- errors takes two runs.
      local message = ParseDerive.line(one.file, first)
      local repaired = repaired_of(source, read)
      if repaired ~= nil then
        local lines: mut {string} = {}
        for _, p in ipairs(read.syntax) do
          lines[#lines + 1] = ParseDerive.line(one.file, p)
        end
        message = table.concat(lines, "\n")
      end
      if broken == nil then
        restore_collector(previous)
        return false, message
      end
      broken[#broken + 1] = { source_hash = one.source_hash, file = one.file, message = message, repaired = repaired }
    else
      local put, why = SyntaxDerivation.insert(db, one.source_hash, one.file, read.text, read.chunk, one.mapped)
      if not put then
        restore_collector(previous)
        return false, why
      end
      tally.parsed = tally.parsed + 1
      made[#made + 1] = { source_hash = one.source_hash, mapped = one.mapped }
    end
  end
  restore_collector(previous)
  return true, ""
end

return ParseDerive
