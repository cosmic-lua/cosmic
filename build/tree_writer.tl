--- Writes the whole tree translated into the new checker's grammar ([`lang.translate`]) to a directory: every `.tl`
--- and `.d.tl` file given, and each guide of `doc/guides` with the Teal of its examples translated in place. It is
--- the step the switch (doc/plans/strict-teal.md, "the switch") makes once, with nothing in the tree reading it yet.
---
---     bin/cosmic build/tree_writer_main.tl write <dir> [--again] [--raw] [--root <tree>] [path...]
---
--- writes the files below `<dir>` at the paths they have in the tree. With no path it takes the files git tracks.
---
--- A module is written as the pipeline reads it: its translation and then the steps of [`TreeProgram.read`] (the `where`
--- clauses of the files that cannot be read in the new grammar blanked, the tests of their records written as the tests of
--- their tags, the lines the new checker reads otherwise replaced), so that the tree committed in the new grammar is the text
--- the build already checks, with the pins and the Lua unchanged. `raw` (`--raw`) writes the translation alone.
--- The checker's fork (`checker/`) and the fork-only fixtures (`testdata/rehearsal/fork_only/`) are *kept*: neither is
--- read nor written, since they stay in the fork's Teal by design.
---
--- A file whose text still has errors ([`lang.translate`]'s `errors`: a form the translator does not handle)
--- is *refused*: it is not written, and the report says why. A file the allow-list names ([`TreeWriter.allowance`], and
--- the files [`build/ceilings.txt`] still pins under `[translated]`, up to their pins) is *allowed*: it is written as
--- translated, errors and all, for a hand edit that the switch makes. Every other file is *clean*.
---
--- A guide's examples are read the way the example check reads them ([`build.example_checks`]): an example is its
--- opening block and the `continue` blocks after it, translated as one chunk so that a name declared in one is seen by
--- the next; a `file=` block is a file of its own. A block that is skipped (`skip=`) is translated where it can be and
--- left as written where it cannot, and is counted in [`TreeWriter.Guide.left`]; a shebang block and a `lua` block are
--- left. Prose is never touched.
---
--- With `again` each file written is translated a second time, and one whose text moves is *unstable*: the
--- translator's result must be its own fixed point, or committing it and translating it again on read would differ.
local Ceilings = require("build.ceilings")
local Child = require("cosmic.child")
local Clock = require("cosmic.clock")
local Fs = require("cosmic.fs")
local Doctest = require("build.doctest")
local Proc = require("cosmic.proc")
local String = require("cosmic.string")
local LangProof = require("build.lang_proof")
local Translate = require("lang.translate")
local TreeProgram = require("build.tree_program")

local record TreeWriter
  --- What the allow-list lets through.
  record Allowance
    --- Paths of files written although their translation has errors: a path, or a directory and `/*`.
    paths: {string}
    --- `[translated]` of [`build/ceilings.txt`]: `<file> <code>` to how many errors of the code the file may keep.
    pins: {string: integer}
  end

  --- One file as translated.
  record File
    path: string
    --- The errors its translation still has, one per line, each with its place.
    errors: {string}
    --- How many of them there are of each code.
    codes: {string: integer}
    --- Whether the translation changed the text.
    changed: boolean
  end

  --- What a run did.
  record Report
    --- How many files were read, and how many of them the translation changed.
    files: integer
    changed: integer
    --- The files written without an error left, by path.
    clean: {string}
    --- The files written with the errors the allow-list lets stand.
    allowed: {File}
    --- The files not written.
    refused: {File}
    --- How many files were neither read nor written, being fork-only by design (`kept`).
    kept: integer
    --- The files whose second translation changed the text (only where `again` was asked).
    unstable: {string}
    --- Methods the translation moved into a class that read or give something else, one per line.
    hazards: {string}
    --- How many times each row of [`lang.translate`] rewrote.
    counts: {string: integer}
    --- Blocks of skipped examples left as written because they do not translate.
    left: integer
    --- The nanoseconds the run took, reading and writing included.
    nanoseconds: integer
  end

  --- What translates a module, `name` ending `.d.tl` for a declaration file: [`lang.translate`]'s `translate`.
  type Translator = function(source: string, name: string): Translate.Result

  record Options
    allowance: Allowance
    --- Translate every file written once more, to find the ones that move.
    again: boolean
    --- What translates, where not [`lang.translate`]: a test plants one that drifts or loses a comment to see the writer
    --- report it.
    translator: Translator?
    --- Write the translation alone, without the steps the pipeline takes after it ([`TreeProgram.read`]).
    raw: boolean?
  end

  --- What [`TreeWriter.guide`] answers.
  record Guide
    --- The guide with the Teal of its examples translated.
    text: string
    --- The errors a translation still has, one per line, each naming the example it is in.
    errors: {string}
    codes: {string: integer}
    counts: {string: integer}
    hazards: {string}
    --- Blocks of skipped examples that do not translate and stay as written.
    left: integer
  end

  --- The allow-list of the tree at `root`: the files the owner decided to let keep errors (the tour, a guide's example of a
  --- generic method) and the `[translated]` ceilings.
  allowance: function(root: string): Allowance?, string

  --- Whether the allow-list lets `path` keep errors of these `codes` (a count for each).
  permits: function(allowance: Allowance, path: string, codes: {string: integer}): boolean

  --- Of `paths`, the ones this writes, sorted: the `.tl` and `.d.tl` files and the guides of `doc/guides`, apart from
  --- `vendor/`.
  selected: function(paths: {string}): {string}

  --- The files of the tree at `root` this writes: the `.tl` and `.d.tl` files git tracks (a walk of the tree where
  --- `root` is no checkout), [`TreeWriter.selected`].
  tracked: function(root: string): {string}?, string

  --- `text`, a guide called `name`, with the Teal of its examples translated. A guide whose fences do not parse is
  --- answered as it is with the reason as its one error.
  guide: function(text: string, name: string, translator?: Translator): Guide

  --- Translates the files `paths` of the tree at `root` and writes them below `out`.
  write: function(root: string, paths: {string}, out: string, options: Options): Report?, string

  --- The lines that say what `report` found.
  summary: function(report: Report): {string}

  --- The command line of [`build/tree_writer_main.tl`].
  main: function(argv: {string}): integer
end

--- The files whose text may keep errors, by the owner's decision: the tour (which teaches forms the new grammar cuts) and a
--- guide's example of a generic method.
local ALLOWED <const>: {string} = {
  "cosmic/removed_example.tl", "doc/guides/project.md",
}

--- The directories that stay in the fork's Teal: the fork's checker (its copy of the standard library's declarations goes
--- with it) and the fixtures that exist for the fork.
local KEPT <const>: {string} = { "checker/", "testdata/rehearsal/fork_only/" }

local function kept(path: string): boolean
  for _, directory in ipairs(KEPT) do
    if path:sub(1, #directory) == directory then
      return true
    end
  end
  return false
end

function TreeWriter.allowance(root: string): TreeWriter.Allowance?, string
  local ceilings, why = Ceilings.read(root)
  if ceilings == nil then
    return nil, why
  end
  return { paths = ALLOWED, pins = Ceilings.of(ceilings, "translated") }, ""
end

function TreeWriter.permits(allowance: TreeWriter.Allowance, path: string, codes: {string: integer}): boolean
  for _, allowed in ipairs(allowance.paths) do
    if allowed == path or (allowed:sub(-2) == "/*" and path:sub(1, #allowed - 1) == allowed:sub(1, -2)) then
      return true
    end
  end
  for code, count in pairs(codes) do
    if count > (allowance.pins[path .. " " .. code] or 0) then
      return false
    end
  end
  return true
end

--- The lines of `text` as [`String.lines`] gives them: joined by `"\n"` they are `text` again.
local function lines_of(text: string): {string}
  local out: mut {string} = {}
  for line in String.lines(text) do
    out[#out + 1] = line
  end
  return out
end

--- Text the blocks of one example are joined with to be translated together. A comment is never rewritten, so the
--- translation keeps it where it stood and the blocks come apart again.
local BOUNDARY <const> = "-- tree_writer: end of block"

--- The blocks of a guide that are translated together: an example, or one block that stands alone.
local record Group
  blocks: mut {Doctest.Block}
  --- A skipped block, left as written where it does not translate.
  skipped: boolean
end

--- The path a `file=` block names.
local function file_of(block: Doctest.Block): string
  return block.modifiers.file or ""
end

--- The groups of the Teal blocks of `blocks`, as the example check forms its examples ([`build.doctest.generate`]).
local function groups_of(blocks: {Doctest.Block}): {Group}
  local out: mut {Group} = {}
  local current: Group? = nil
  for _, block in ipairs(blocks) do
    if block.lang == "text" or block.lang == "output" then
      current = nil
    elseif block.lang == "teal" or block.lang == "lua" then
      local shebang = block.modifiers.file == nil and block.content:sub(1, 2) == "#!"
      if block.modifiers.skip ~= nil or shebang then
        current = nil
        if block.lang == "teal" and not shebang and (block.modifiers.file == nil or file_of(block):match("%.tl$") ~= nil) then
          out[#out + 1] = { blocks = { block }, skipped = true }
        end
      elseif block.modifiers.file ~= nil then
        -- A file of the example's project: the example stays open around it. Only a `.tl` file is Teal; a template, a
        -- stylesheet and a word list are not.
        if block.lang == "teal" and file_of(block):match("%.tl$") ~= nil then
          out[#out + 1] = { blocks = { block }, skipped = false }
        end
      elseif block.modifiers.continue then
        if current ~= nil then
          current.blocks[#current.blocks + 1] = block
        end
      elseif block.lang == "lua" then
        -- The example a `lua` block opens is never translated, and nor is a `continue` of it.
        current = nil
      else
        current = { blocks = { block }, skipped = false }
        out[#out + 1] = current
      end
    end
  end
  return out
end

--- How many lines a block's content takes in the guide.
local function height(content: string): integer
  if content == "" then
    return 0
  end
  local _, breaks = content:gsub("\n", "")
  return breaks + 1
end

--- Adds `from` to `into`, row by row.
local function add_counts(into: mut {string: integer}, from: {string: integer})
  for row, n in pairs(from) do
    into[row] = (into[row] or 0) + n
  end
end

function TreeWriter.guide(text: string, name: string, translator?: TreeWriter.Translator): TreeWriter.Guide
  local translate: TreeWriter.Translator = translator or Translate.translate
  local made: TreeWriter.Guide = { text = text, errors = {}, codes = {}, counts = {}, hazards = {}, left = 0 }
  local blocks, trouble = Doctest.blocks(text)
  if blocks == nil then
    made.errors[1] = name .. ": " .. trouble
    made.codes["fences"] = 1
    return made
  end
  -- The new content of each block that changes, by the line of its first content line.
  local replaced: mut {integer: {string}} = {}
  local taken: mut {integer: integer} = {}
  for _, group in ipairs(groups_of(blocks)) do
    local first = assert(group.blocks[1])
    local contents: mut {string} = {}
    for i, block in ipairs(group.blocks) do
      contents[i] = block.content
    end
    local called = first.modifiers.file or name .. ".tl"
    -- The chunk ends in a newline, as a file does: a class closes with an `end` on a line of its own.
    local result = translate(table.concat(contents, "\n" .. BOUNDARY .. "\n") .. "\n", called)
    local pieces = String.split(result.text, "\n" .. BOUNDARY .. "\n")
    local last = pieces[#pieces]
    if last ~= nil and last:sub(-1) == "\n" then
      pieces[#pieces] = last:sub(1, -2)
    end
    local whole = #pieces == #group.blocks
    if group.skipped and (#result.errors > 0 or not whole) then
      made.left = made.left + 1
    elseif not whole then
      made.errors[#made.errors + 1] = name .. ":" .. tostring(first.line) .. ": the translation of the example lost a block boundary"
      made.codes["boundary"] = (made.codes["boundary"] or 0) + 1
    else
      for _, e in ipairs(result.errors) do
        made.errors[#made.errors + 1] = name .. ":" .. tostring(first.line) .. ": example, line " .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg ..
          " (" .. e.code .. ")"
        made.codes[e.code] = (made.codes[e.code] or 0) + 1
      end
      add_counts(made.counts, result.counts)
      for _, h in ipairs(result.hazards) do
        made.hazards[#made.hazards + 1] = name .. ":" .. tostring(first.line) .. ": " .. h.class .. ":" .. h.method .. " (" .. h.kind .. ") " .. h.name
      end
      for i, block in ipairs(group.blocks) do
        local piece = pieces[i]
        if piece ~= nil and piece ~= block.content then
          replaced[block.line + 1] = lines_of(piece)
          taken[block.line + 1] = height(block.content)
        end
      end
    end
  end
  local lines = lines_of(text)
  local out: mut {string} = {}
  local at = 1
  while at <= #lines do
    local new = replaced[at]
    if new ~= nil then
      for _, line in ipairs(new) do
        out[#out + 1] = line
      end
      at = at + (taken[at] or 0)
    else
      out[#out + 1] = lines[at] or ""
      at = at + 1
    end
  end
  made.text = table.concat(out, "\n")
  return made
end

function TreeWriter.selected(paths: {string}): {string}
  local out: mut {string} = {}
  for _, path in ipairs(paths) do
    if path:sub(1, 7) ~= "vendor/" and (path:match("%.tl$") ~= nil or path:match("^doc/guides/[^/]+%.md$") ~= nil) then
      out[#out + 1] = path
    end
  end
  table.sort(out, function(a: string, b: string): boolean
    return a < b
  end)
  return out
end

function TreeWriter.tracked(root: string): {string}?, string
  local git, _ = Proc.find("git")
  local listed: {string} = {}
  local from_git = false
  local checkout, _ = Fs.exists(root .. "/.git")
  if git ~= nil and checkout == true then
    local result, _ = Child.run({ git, "-C", root, "ls-files", "-z" }, { stdout = "capture", stderr = "capture" })
    if result ~= nil and result.ok then
      listed = String.split(result.stdout or "", "\0")
      from_git = true
    end
  end
  if not from_git then
    local walked, trouble = Fs.walk(root, function(relative: string, name: string, kind: Fs.Kind): boolean
      return kind == "dir" and (name:sub(1, 1) == "." or relative == "vendor" or relative == "o" or relative == "ci/o")
    end)
    if walked == nil then
      return nil, trouble
    end
    listed = walked
  end
  return TreeWriter.selected(listed), ""
end

--- What translating one file gave.
local record Done
  text: string
  errors: {string}
  codes: {string: integer}
  counts: {string: integer}
  hazards: {string}
  left: integer
end

--- The files of the tree already written in the new grammar ([`lang/prelude.d.tl`], [`lang/stdlib.d.tl`]): they are written as
--- they are, since the translator reads the fork's Teal.
local NEW_GRAMMAR <const>: {string: boolean} = {
  ["lang/prelude.d.tl"] = true,
  ["lang/stdlib.d.tl"] = true,
}

--- `text`, the file `path`, translated: a guide through [`TreeWriter.guide`], a file already in the new grammar as it is, any
--- other file as a module, with the steps of [`TreeProgram.read`] where `tags` are given.
local function translated(path: string, text: string, translator: TreeWriter.Translator?,
                          tags: {string: LangProof.Tags}?): Done
  if NEW_GRAMMAR[path] == true then
    return { text = text, errors = {}, codes = {}, counts = {}, hazards = {}, left = 0 }
  end
  if path:sub(-3) == ".md" then
    local g = TreeWriter.guide(text, path, translator)
    return { text = g.text, errors = g.errors, codes = g.codes, counts = g.counts, hazards = g.hazards, left = g.left }
  end
  local translate: TreeWriter.Translator = translator or Translate.translate
  local result: Translate.Result
  local final: string
  if tags ~= nil then
    local read = TreeProgram.read(path, text, tags, translator)
    result, final = read.translation, read.text
  else
    result = translate(text, path)
    final = result.text
  end
  local errors: mut {string} = {}
  local codes: mut {string: integer} = {}
  for _, e in ipairs(result.errors) do
    errors[#errors + 1] = path .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. e.code .. ")"
    codes[e.code] = (codes[e.code] or 0) + 1
  end
  local hazards: mut {string} = {}
  for _, h in ipairs(result.hazards) do
    hazards[#hazards + 1] = path .. ":" .. tostring(h.y) .. ": " .. h.class .. ":" .. h.method .. " (" .. h.kind .. ") " .. h.name
  end
  return { text = final, errors = errors, codes = codes, counts = result.counts, hazards = hazards, left = 0 }
end

function TreeWriter.write(root: string, paths: {string}, out: string, options: TreeWriter.Options): TreeWriter.Report?, string
  local started = Clock.monotonic_ns()
  local held = 0
  for _, path in ipairs(paths) do
    if kept(path) then
      held = held + 1
    end
  end
  local report: TreeWriter.Report = {
    files = 0, changed = 0, clean = {}, allowed = {}, refused = {}, kept = held, unstable = {}, hazards = {}, counts = {},
    left = 0, nanoseconds = 0,
  }
  -- The steps after the translation read the two modules that hold the `where` clauses, as the tree has them.
  local tags: {string: LangProof.Tags}? = nil
  if options.raw ~= true then
    local ast, _ = Fs.read(root .. "/lang/ast.tl")
    local types, _ = Fs.read(root .. "/lang/types.tl")
    if ast ~= nil and types ~= nil then
      tags = TreeProgram.tags_of({ { "lang/ast.tl", ast }, { "lang/types.tl", types } })
    else
      tags = {}
    end
  end
  for _, path in ipairs(paths) do
    if not kept(path) then
      local source, why = Fs.read(root .. "/" .. path)
      if source == nil then
        return nil, why
      end
      local done = translated(path, source, options.translator, tags)
      report.files = report.files + 1
      local changed = done.text ~= source
      if changed then
        report.changed = report.changed + 1
      end
      add_counts(report.counts, done.counts)
      report.left = report.left + done.left
      for _, line in ipairs(done.hazards) do
        report.hazards[#report.hazards + 1] = line
      end
      local file: TreeWriter.File = { path = path, errors = done.errors, codes = done.codes, changed = changed }
      local written = true
      if #done.errors == 0 then
        report.clean[#report.clean + 1] = path
      elseif TreeWriter.permits(options.allowance, path, done.codes) then
        report.allowed[#report.allowed + 1] = file
      else
        report.refused[#report.refused + 1] = file
        written = false
      end
      if written then
        local target = out .. "/" .. path
        local made, trouble = Fs.mkdirs(Fs.dirname(target))
        if not made then
          return nil, trouble
        end
        local wrote, write_trouble = Fs.write(target, done.text)
        if not wrote then
          return nil, write_trouble
        end
        -- Translated alone: the steps are done, and translating what they made must move nothing.
        if options.again and translated(path, done.text, options.translator, nil).text ~= done.text then
          report.unstable[#report.unstable + 1] = path
        end
      end
    end
  end
  report.nanoseconds = Clock.monotonic_ns() - started
  return report, ""
end

function TreeWriter.summary(report: TreeWriter.Report): {string}
  local out: mut {string} = {}
  local written = #report.clean + #report.allowed
  out[#out + 1] = "read " .. String.counted(report.files, "file") .. ", " .. tostring(report.changed) ..
    " changed by the translation"
  out[#out + 1] = "written " .. tostring(written) .. " (" .. tostring(#report.clean) .. " clean, " ..
    tostring(#report.allowed) .. " allowed with errors), refused " .. tostring(#report.refused) .. ", kept in the fork's Teal " ..
    tostring(report.kept)
  for _, file in ipairs(report.allowed) do
    out[#out + 1] = "  allowed " .. file.path .. ": " .. tostring(#file.errors) .. " left"
  end
  for _, file in ipairs(report.refused) do
    out[#out + 1] = "  REFUSED " .. file.path .. ": " .. tostring(#file.errors) .. " left"
    for i, line in ipairs(file.errors) do
      if i > 3 then
        break
      end
      out[#out + 1] = "    " .. line
    end
  end
  for _, path in ipairs(report.unstable) do
    out[#out + 1] = "  UNSTABLE " .. path .. ": translating the output changes it"
  end
  local kinds: mut {string: integer} = {}
  for _, line in ipairs(report.hazards) do
    local kind = line:match(".*%((%a+)%) ") or "other"
    kinds[kind] = (kinds[kind] or 0) + 1
  end
  local hazard_parts: mut {string} = {}
  for kind, n in pairs(kinds) do
    hazard_parts[#hazard_parts + 1] = kind .. " " .. tostring(n)
  end
  table.sort(hazard_parts, function(a: string, b: string): boolean
    return a < b
  end)
  out[#out + 1] = "hazards " .. tostring(#report.hazards) .. " (" .. table.concat(hazard_parts, ", ") ..
    "), skipped blocks left as written " .. tostring(report.left)
  local rows: mut {string} = {}
  for row in pairs(report.counts) do
    rows[#rows + 1] = row
  end
  table.sort(rows, function(a: string, b: string): boolean
    return a < b
  end)
  local parts: mut {string} = {}
  for _, row in ipairs(rows) do
    parts[#parts + 1] = row .. " " .. tostring(report.counts[row] or 0)
  end
  out[#out + 1] = "rewrites: " .. table.concat(parts, ", ")
  out[#out + 1] = string.format("%.1f seconds", report.nanoseconds / 1e9)
  return out
end

function TreeWriter.main(argv: {string}): integer
  local usage = "usage: bin/cosmic build/tree_writer_main.tl write <dir> [--again] [--raw] [--root <tree>] [path...]"
  if argv[1] ~= "write" or argv[2] == nil then
    print(usage)
    return 2
  end
  local out = assert(argv[2])
  local root = "."
  local again = false
  local raw = false
  local paths: mut {string} = {}
  local index = 3
  while argv[index] ~= nil do
    local word = assert(argv[index])
    if word == "--again" then
      again = true
      index = index + 1
    elseif word == "--raw" then
      raw = true
      index = index + 1
    elseif word == "--root" then
      local given = argv[index + 1]
      if given == nil then
        print(usage)
        return 2
      end
      root = given
      index = index + 2
    else
      paths[#paths + 1] = word
      index = index + 1
    end
  end
  local allowance, why = TreeWriter.allowance(root)
  if allowance == nil then
    print("reading the ceilings: " .. why)
    return 1
  end
  if #paths == 0 then
    local listed, trouble = TreeWriter.tracked(root)
    if listed == nil then
      print("listing the tree: " .. trouble)
      return 1
    end
    paths = listed
  end
  local report, trouble = TreeWriter.write(root, paths, out, { allowance = allowance, again = again, translator = nil, raw = raw })
  if report == nil then
    print("writing: " .. trouble)
    return 1
  end
  for _, line in ipairs(TreeWriter.summary(report)) do
    print(line)
  end
  return if (#report.refused == 0 and #report.unstable == 0) then 0 else 1 end
end

return TreeWriter
