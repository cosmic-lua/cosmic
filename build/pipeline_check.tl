--- The pipeline ([`build.pipeline`]) held against the checks of the tree ([`build.tree_checks`]), for every module the working
--- database stages. A module the `declared` and `checked` checks refuse for a count over its ceiling is refused by
--- [`Driver.Build.held`] of the pipeline built over the `inputs` of the database, and a module they accept is held. The two
--- read one program ([`build.tree_program`]): the same sources, mended and spliced by the same steps. This is what tells a
--- difference in it, listing a module with the side that refuses it.
---
--- The pipeline refuses a module for more than a count: a translation that does not parse, a warning, a construct the
--- generator cannot write. No ceiling counts these, so a module refused so is listed with the code of the first line of its
--- refusal.

local CompileGrammar = require("build.compile_grammar")
local Pipeline = require("build.pipeline")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local logger = require("build.logger")
local TreeProgram = require("build.tree_program")
local tree = require("build.tree")
local check_memo = require("build.check_memo")
local Hash = require("cosmic.hash")

local record PipelineCheck
  --- A file of the tree to compare, as the checks of the tree lower it.
  record Row
    file: string
    module: string
    --- Whether the file is read as the fork's Teal (`tl`) or as a declaration file (`decl`).
    dialect: string
    --- What the pipeline's answer for the file is kept under in the memo: the file's source and everything it requires. The
    --- ceilings that hold it are added to it ([`PipelineCheck.keyed`]).
    mut key: string
    --- Whether the file is a source of the tree as it is written, and not one the build writes from another file: its ceilings
    --- are then the ones kept under its own name.
    plain: boolean
  end

  --- The key of a row's answer in the memo: `key` and the ceilings that hold the file. A module is held by the ceilings
  --- kept under its own name alone ([`Pipeline.pinned`]: `digests` holds, by file, a digest of them), so that a pin of another
  --- file does not change its answer; a file that is `plain` is keyed so, and any other by `whole`, a digest of every ceiling,
  --- since the name its ceilings are kept under is not its own.
  keyed: function(key: string, plain: boolean, file: string, digests: {string: string}, whole: string): string
  --- A digest of every ceiling of `digests` ([`PipelineCheck.keyed`]'s `whole`) and of whether the tree has none.
  whole: function(digests: {string: string}, none: boolean?): string

  --- The lines that tell where the pipeline and the tree's checks differ over the `count` files `row_at` answers by position.
  --- `declared` and `checked` are the lines the checks of the tree answer ([`tree_checks.declared`], [`tree_checks.checked`]).
  --- `memo` keeps the answer for a module under its key.
  --- A tree whose compared modules are not exactly the tree's own (every file but those of `ci/`, the declarations of the standard library apart) fails, since
  --- a comparison of a few agrees with everything. It says how many it compared.
  compare: function(
    root: string,
    build_db: Sqlite.Handle,
    memo: Sqlite.Handle?,
    count: integer,
    row_at: function(index: integer): Row,
    declared: {string},
    checked: {string}
  ): {string}
end

function PipelineCheck.keyed(key: string, plain: boolean, file: string, digests: {string: string}, whole: string): string
  local held = whole
  if plain then
    held = digests[file] or ""
  end
  return Hash.hex_sha256(key .. "\0" .. held)
end

function PipelineCheck.whole(digests: {string: string}, none: boolean?): string
  local files: mut {string} = {}
  for file in pairs(digests) do
    files[#files + 1] = file
  end
  table.sort(files, function(a: string, b: string): boolean return a < b end)
  local parts: mut {string} = { if none == true then "none" else "pinned" end }
  for _, file in ipairs(files) do
    parts[#parts + 1] = file .. "=" .. (digests[file] or "")
  end
  return Hash.hex_sha256(table.concat(parts, "\0"))
end

--- The file a line that refuses a count over its ceiling ([`build.ceilings.over`]) is about, if the line is one about declarations
--- or bodies.
local function over_file(line: string): string?
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
  local over: mut {string: boolean} = {}
  local other: mut {string: string} = {}
  local answers: mut {string: string} = {}
  local pipeline, built_why = Pipeline.build(build_db, options)
  if pipeline == nil then
    return { over = over, other = other, answers = answers }, { "the pipeline: " .. built_why }
  end
  local build = pipeline.build
  local index, ceilings = pipeline.index, pipeline.ceilings
  -- What the working database stages: the tree of `ci/` is none of its modules.
  local rows_of: mut {string: mut {PipelineCheck.Row}} = {}
  local names: mut {string} = {}
  for _, row in ipairs(rows) do
    if build:provides(row.module) then
      local held = rows_of[row.module]
      local list = held or {}
      if held == nil then
        rows_of[row.module] = list
        names[#names + 1] = row.module
      end
      list[#list + 1] = row
    else
      answers[row.key] = "-"
    end
  end
  --- The answer for each row of the module `module`, once it is lowered and checked.
  local function judge(module: string)
    local group = rows_of[module]
    if group == nil then
      return
    end
    local tl = false
    for _, row in ipairs(group) do
      tl = tl or row.dialect == "tl"
    end
    local result = build:result(module, tl)
    for _, row in ipairs(group) do
      if result ~= nil and row.file:match("%.md$") ~= nil then
        Pipeline.discounted(result)
      end
      local counted = false
      local code = ""
      if result ~= nil then
        for _, line in ipairs(build:held(result, ceilings)) do
          -- A scope error of a translated module is the translation's (a method moved above a name it reads): no ceiling of
          -- the tree's checks counts it, and the module is refused for it.
          local scoped = line:match("^%S+: %d+ errors? of (%S+) in its scopes, pinned %d+;")
          if scoped ~= nil then
            code = scoped
          else
            counted = counted or over_file(line) ~= nil
          end
        end
        if not counted and code == "" then
          local first = result.syntax[1]
          local warning = result.warnings[1]
          if row.dialect ~= "tl" then
            -- A declaration file is read and not written.
          elseif result.broken and first ~= nil then
            code = first.code
          elseif warning ~= nil then
            code = warning.code
          else
            local emitted = CompileGrammar.emit(build, result, nil, true, true)
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
      answers[row.key] = if counted then "O" elseif code == "" then "N" else "R " .. code end
    end
  end
  -- The modules in the order they require one another, each forgotten once it is answered: the syntax of the whole tree is
  -- not held at once.
  local out = TreeProgram.stream(build, index, names, true, judge)
  return { over = over, other = other, answers = answers }, out
end

function PipelineCheck.compare(
    root: string,
    build_db: Sqlite.Handle,
    memo: Sqlite.Handle?,
    count: integer,
    row_at: function(index: integer): PipelineCheck.Row,
    declared: {string},
    checked: {string}
): {string}
  local standing, standing_why = tree.standing(root)
  if standing == nil then
    return { "the pipeline's options: " .. standing_why }
  end
  local options, why = Pipeline.options(root, standing.own)
  if options == nil then
    return { "the pipeline's options: " .. why }
  end
  -- Only the counts of the checker are compared, which keep no type of a node.
  options.types = false
  local refused: mut {string: boolean} = {}
  for _, lines in ipairs({ declared, checked }) do
    for _, line in ipairs(lines) do
      local file = over_file(line)
      if file ~= nil then
        refused[file] = true
      end
    end
  end
  local digests = Pipeline.pinned(options.ceilings)
  local all = PipelineCheck.whole(digests, options.ceilings.none)
  local rows: mut {PipelineCheck.Row} = {}
  for index = 1, count do
    local row = row_at(index)
    row.key = PipelineCheck.keyed(row.key, row.plain, row.file, digests, all)
    rows[index] = row
  end
  if memo ~= nil then
    local _, _ = check_memo.prepare(memo, "pipeline")
  end
  local over: mut {string: boolean} = {}
  local other: mut {string: string} = {}
  local missed: mut {PipelineCheck.Row} = {}
  for _, row in ipairs(rows) do
    local kept: string? = nil
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
  local out: mut {string} = {}
  local compared = 0
  for _, row in ipairs(rows) do
    local by_pipeline = over[row.file]
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
      if code ~= nil then
        out[#out + 1] = row.file .. ": the pipeline refuses it for " .. code .. ", which no ceiling counts"
      end
    end
  end
  -- The working database stages every module of the tree but the tree of `ci/`.
  local expected = 0
  for _, row in ipairs(rows) do
    if row.file:find("^ci/") == nil then
      expected = expected + 1
    end
  end
  if compared ~= expected then
    out[#out + 1] = "the pipeline was compared on " .. String.counted(compared, "module") .. " where the tree has " ..
      tostring(expected) .. " outside ci/: the staging and the tree differ"
  end
  logger.log:say("fix: pipeline: compared " .. String.counted(compared, "module") .. " of the tree's " ..
      tostring(expected) .. " the working database stages")
  return out
end

return PipelineCheck
