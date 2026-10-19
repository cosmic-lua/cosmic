--- The pipeline ([`build.pipeline`]) held against the checks of the tree ([`build.tree_checks`]), for every module the working
--- database stages. A module the `declared` and `checked` checks refuse for a count over its ceiling is refused by
--- [`Driver.Build.held`] of the pipeline built over the `inputs` of the database, and a module they accept is held. The two
--- read one program ([`build.tree_program`]): the same sources, mended and spliced by the same steps. This is what tells a
--- difference in it, listing a module with the side that refuses it.
---
--- The pipeline refuses a module for more than a count: a translation that does not parse, a warning, a construct the
--- generator cannot write. No ceiling counts these, so [`build.pipeline.residue`] names each such module with the code of the
--- first line of its refusal, and a module refused so and not named, named and not refused so, or named with another
--- code, is listed.

local CompileGrammar = require("build.compile_grammar")
local Pipeline = require("build.pipeline")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local logger = require("build.logger")
local TreeProgram = require("build.tree_program")
local check_memo = require("build.check_memo")

local record PipelineCheck
  --- A file of the tree to compare, as the checks of the tree lower it.
  record Row
    file: string
    module: string
    --- Whether the file is read as the fork's Teal (`tl`) or as a declaration file (`decl`).
    dialect: string
    --- What the pipeline's answer for the file is kept under in the memo: the file's source and everything it requires.
    key: string
  end

  --- The lines that tell where the pipeline and the tree's checks differ over the `count` files `row_at` answers by position.
  --- `declared` and `checked` are the lines the checks of the tree answer ([`tree_checks.declared`], [`tree_checks.checked`]).
  --- `memo` keeps the answer for a module under its key.
  --- A tree whose compared modules are not exactly the tree's own (every file but those of `ci/` and `checker/`, the declarations of the standard library apart) fails, since
  --- a comparison of a few agrees with everything. It says how many it compared.
  compare: function(
    root: string,
    build_db: Sqlite.Handle,
    memo: Sqlite.Handle | nil,
    count: integer,
    row_at: function(index: integer): Row,
    declared: {string},
    checked: {string}
  ): {string}
end

--- The file a line that refuses a count over its ceiling ([`build.ceilings.over`]) is about, if the line is one about declarations
--- or bodies.
local function over_file(line: string): string | nil
  return line:match("^(%S+): %d+ errors? of %S+ in its %a+, pinned %d+;")
end

--- What the pipeline answered: by file, whether it refuses it for a count over a ceiling (none for a module the database
--- does not stage), and the code of the first line of another refusal; by key, what a memo keeps: `O` for a count over a
--- ceiling, `R` and the code for another refusal, `N` for none, `-` for a module the database does not stage.
local record Answers
  over: {string: boolean}
  other: {string: string}
  answers: {string: string}
end

--- What the pipeline answers for the staged modules of `rows`, and the lines that say why it could not.
local function asked(build_db: Sqlite.Handle, options: Pipeline.Options, rows: {PipelineCheck.Row}): Answers, {string}
  local over: {string: boolean} = {}
  local other: {string: string} = {}
  local answers: {string: string} = {}
  local pipeline, built_why = Pipeline.build(build_db, options)
  if pipeline == nil then
    return { over = over, other = other, answers = answers }, { "the pipeline: " .. built_why }
  end
  local build = pipeline.build
  -- What the working database stages: the tree of `ci/` and the fork's `checker/` are none of its modules.
  local staged: {PipelineCheck.Row} = {}
  for _, row in ipairs(rows) do
    if build:parsed(row.module) ~= nil then
      staged[#staged + 1] = row
    else
      answers[row.key] = "-"
    end
  end
  local names: {string} = {}
  for _, row in ipairs(staged) do
    names[#names + 1] = row.module
  end
  local out = TreeProgram.splice_all(build, names)
  if #out > 0 then
    return { over = over, other = other, answers = answers }, out
  end
  build:lower(names)
  for _, row in ipairs(staged) do
    local result = build:result(row.module, row.dialect == "tl")
    local counted = false
    local code = ""
    if result ~= nil then
      for _, line in ipairs(build:held(result, pipeline.ceilings)) do
        counted = counted or over_file(line) ~= nil
      end
      if not counted then
        local first = result.syntax[1]
        local warning = result.warnings[1]
        if row.dialect ~= "tl" then
          -- A declaration file is read and not written.
        elseif result.broken and first ~= nil then
          code = first.code
        elseif warning ~= nil then
          code = warning.code
        else
          local emitted = CompileGrammar.emit(build, result)
          if emitted.code == nil then
            code = emitted.trouble:match("%(([%a_]+)%)") or "unwritten"
          end
        end
      end
    end
    over[row.file] = counted
    if code ~= "" then
      other[row.file] = code
    end
    answers[row.key] = counted and "O" or code == "" and "N" or "R " .. code
  end
  return { over = over, other = other, answers = answers }, out
end

function PipelineCheck.compare(
    root: string,
    build_db: Sqlite.Handle,
    memo: Sqlite.Handle | nil,
    count: integer,
    row_at: function(index: integer): PipelineCheck.Row,
    declared: {string},
    checked: {string}
): {string}
  local options, why = Pipeline.options(root)
  if options == nil then
    return { "the pipeline's options: " .. why }
  end
  local refused: {string: boolean} = {}
  for _, lines in ipairs({ declared, checked }) do
    for _, line in ipairs(lines) do
      local file = over_file(line)
      if file ~= nil then
        refused[file] = true
      end
    end
  end
  local rows: {PipelineCheck.Row} = {}
  for index = 1, count do
    rows[index] = row_at(index)
  end
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "pipeline")
  end
  local over: {string: boolean} = {}
  local other: {string: string} = {}
  local missed: {PipelineCheck.Row} = {}
  for _, row in ipairs(rows) do
    local kept: string | nil = nil
    if memo ~= nil then
      kept = check_memo.get(memo, "pipeline", row.key)
    end
    if kept ~= nil then
      if kept ~= "-" then
        over[row.file] = kept == "O"
      end
      if kept:sub(1, 2) == "R " then
        other[row.file] = kept:sub(3)
      end
    else
      missed[#missed + 1] = row
    end
  end
  if #missed > 0 then
    local made, trouble = asked(build_db, options, missed)
    if #trouble > 0 then
      return trouble
    end
    for file, counted in pairs(made.over) do
      over[file] = counted
    end
    for file, code in pairs(made.other) do
      other[file] = code
    end
    if memo ~= nil then
      for key, answer in pairs(made.answers) do
        check_memo.put(memo, "pipeline", key, answer)
      end
    end
  end
  if memo ~= nil then
    check_memo.finish(memo, "pipeline")
  end
  local out: {string} = {}
  local compared = 0
  for _, row in ipairs(rows) do
    local by_pipeline = over[row.file]
    local named = Pipeline.residue()[row.file]
    local code = other[row.file]
    -- Nothing is answered of a module the working database does not stage.
    if by_pipeline ~= nil then
      compared = compared + 1
      local by_tree = refused[row.file] == true
      if by_pipeline and not by_tree then
        out[#out + 1] = row.file .. ": the pipeline refuses it for a count over its ceiling, and the tree checks accept it: " ..
          "the two read different programs"
      elseif by_tree and not by_pipeline then
        out[#out + 1] = row.file .. ": the tree checks refuse it for a count over its ceiling, and the pipeline accepts it: " ..
          "the two read different programs"
      end
      if code ~= nil and named == nil then
        out[#out + 1] = row.file .. ": the pipeline refuses it for " .. code .. ", which no ceiling counts: name it in " ..
          "`Pipeline.residue` with that code"
      elseif code == nil and named ~= nil then
        out[#out + 1] = row.file .. ": `Pipeline.residue` names it for " .. named ..
          " and the pipeline no longer refuses it so: remove it from the list"
      elseif code ~= nil and code ~= named then
        out[#out + 1] = row.file .. ": the pipeline refuses it for " .. code .. " and `Pipeline.residue` names " ..
          tostring(named)
      end
    end
  end
  -- The working database stages every module of the tree but the trees of `ci/` and the fork's `checker/`, whose
  -- declarations of the standard library it stages.
  local expected = 0
  for _, row in ipairs(rows) do
    if row.file:find("^ci/") == nil and (row.file:find("^checker/") == nil or row.file == "checker/stdlib.d.tl") then
      expected = expected + 1
    end
  end
  if compared ~= expected then
    out[#out + 1] = "the pipeline was compared on " .. String.counted(compared, "module") .. " where the tree has " ..
      tostring(expected) .. " outside ci/ and the fork's checker/: the staging and the tree differ"
  end
  logger.log:say("fix: pipeline: compared " .. String.counted(compared, "module") .. " of the tree's " ..
      tostring(expected) .. " the working database stages")
  return out
end

return PipelineCheck
