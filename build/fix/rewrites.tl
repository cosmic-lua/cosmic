--- The checker's rewrites ([`lang.rewrite`]) written into the Teal files `cosmic fix` is named, where the build refused
--- them: a number in `..` becomes `tostring(n)`, a `boolean?` condition `x == true`, as cosmic agent's run makes them in a
--- refused snippet, by the same path ([`Pipeline.edits`]). They are read from a pipeline built over the working database
--- the refused build staged ([`Pipeline.build`]), so a module is checked with the tree's modules it requires.
local Pipeline = require("build.pipeline")
local Rewrite = require("lang.rewrite")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")

local record FixRewrites
  --- What a run made or would make: a line for each rewrite (`a.tl:3:18: concat_type: `n` -> `tostring(n)``), the files
  --- written, and why one could not be read or written.
  record Made
    told: {string}
    written: {string}
    failures: {string}
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
  local made: FixRewrites.Made = { told = told, written = written, failures = failures }
  if #files == 0 then return made end
  local wanted: mut {string: boolean} = {}
  for _, file in ipairs(files) do wanted[file] = true end
  local options, options_trouble = Pipeline.options(root, own)
  if options == nil then
    failures[#failures + 1] = "rewrites: " .. options_trouble
    return made
  end
  local db, open_trouble = Sqlite.open(build_paths.resolve(root).working)
  if db == nil then
    local why = "rewrites: " .. tostring(open_trouble)
    failures[#failures + 1] = why
    return made
  end
  local built, built_trouble = Pipeline.build(db, options)
  local _, _ = db:close()
  if built == nil then
    failures[#failures + 1] = "rewrites: " .. built_trouble
    return made
  end
  local build = built.build
  for _, source in ipairs(built.index.sources) do
    local file = source.filename
    if wanted[file] == true and source.dialect == "tl" then
      build:lower({ source.module })
      local result = build:result(source.module, true)
      local path = root .. "/" .. file
      local text, read_trouble = Fs.read(path)
      if text == nil then
        local why = tostring(read_trouble)
        failures[#failures + 1] = why
      elseif result ~= nil and text == source.text then
        local applied = Rewrite.apply(text, Pipeline.edits(result))
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
