--- The checker's rewrites ([`lang.rewrite`]) written into the Teal files `cosmic fix` is named, where the build refused
--- them: a number in `..` becomes `tostring(n)`, a `boolean?` condition `x == true`, as cosmic agent's run makes them in a
--- refused snippet, by the same path ([`Pipeline.edits`]). They are read from a pipeline built over the working database
--- the refused build staged ([`Pipeline.build`]), so a module is checked with the tree's modules it requires.
local type Driver = require("build.driver")
local Pipeline = require("build.pipeline")
local Rewrite = require("lang.rewrite")
local TreeProgram = require("build.tree_program")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")

--- The most rounds of rewrites a file is given, as a snippet is ([`Rewrite.rounds`]).
local ROUNDS <const> = 4

local record FixRewrites
  --- What a run made or would make: a line for each rewrite (`a.tl:3:18: concat_type: `n` -> `tostring(n)``), the files
  --- written, why one could not be read or written, and notes of why none was looked for: the build's own refusal,
  --- which the run has told already, says the rest.
  record Made
    told: {string}
    written: {string}
    failures: {string}
    notes: {string}
  end
end

--- Makes the rewrites of the files of `files` (paths under `root`, as the build names them) in the tree at `root`, its
--- standing `own`; where `checking`, it writes nothing and tells what it would make. A file written is laid out by `lay`
--- first, which answers nil where it refuses the text: the text is then written as the rewrites left it.
function FixRewrites.make(root: string, own: boolean, files: {string}, checking: boolean,
                          lay: function(text: string, file: string): string?): FixRewrites.Made
  local told: mut {string} = {}
  local written: mut {string} = {}
  local failures: mut {string} = {}
  local notes: mut {string} = {}
  local made: FixRewrites.Made = { told = told, written = written, failures = failures, notes = notes }
  if #files == 0 then return made end
  local wanted: mut {string: boolean} = {}
  for _, file in ipairs(files) do wanted[file] = true end
  local options, options_trouble = Pipeline.options(root, own)
  if options == nil then
    notes[#notes + 1] = "no rewrites: " .. options_trouble
    return made
  end
  local db, open_trouble = Sqlite.open(build_paths.resolve(root).working)
  if db == nil then
    local why = "no rewrites: " .. tostring(open_trouble)
    notes[#notes + 1] = why
    return made
  end
  local built, built_trouble = Pipeline.build(db, options)
  local _, _ = db:close()
  if built == nil then
    notes[#notes + 1] = "no rewrites: " .. built_trouble
    return made
  end
  local build = built.build
  -- What the build holds of `module` as `text`: lowered and checked as the build checks a module, its calls to splice
  -- resolved first ([`TreeProgram.splice`]). Nil where it cannot be checked so, the reason told in a note.
  local function checked(module: string, file: string, text: string, first: boolean): Driver.Outcome?
    if not first and build:replace(module, text) == nil then
      notes[#notes + 1] = "no rewrites of " .. file .. ": the build has no module " .. module
      return nil
    end
    local spliced, splice_trouble = TreeProgram.splice(build, module, file)
    if spliced == nil then
      notes[#notes + 1] = "no rewrites of " .. file .. ": " .. splice_trouble
    end
    build:lower({ module })
    return build:result(module, true)
  end
  for _, source in ipairs(built.index.sources) do
    local file = source.filename
    if wanted[file] == true and source.dialect == "tl" then
      local path = root .. "/" .. file
      local text, read_trouble = Fs.read(path)
      if text == nil then
        local why = tostring(read_trouble)
        failures[#failures + 1] = why
      elseif text ~= source.text then
        notes[#notes + 1] = "no rewrites of " .. file .. ": the build read another text of it"
      else
        -- In rounds, as cosmic agent's run makes them ([`Rewrite.rounds`]).
        local applied = Rewrite.rounds(text, function(now: string): {Rewrite.Edit}
          local result = checked(source.module, file, now, now == text)
          return if result ~= nil then Pipeline.edits(result) else {} end
        end, ROUNDS)
        for _, line in ipairs(Rewrite.told(file, applied.made)) do told[#told + 1] = line end
        if not checking and applied.text ~= text then
          local ok, write_trouble = Fs.write(path, lay(applied.text, file) or applied.text)
          if ok then
            written[#written + 1] = file
          else
            local why = tostring(write_trouble)
            failures[#failures + 1] = why
          end
        end
      end
    end
  end
  return made
end

return FixRewrites
