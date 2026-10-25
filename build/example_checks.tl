--- The check that what `cosmic docs` shows as an example runs as shown.
--- An example runs in place, from its `_example.tl` file, where the file's
--- own `require` lines and the harness's variables are in scope; a reader
--- copies the rendered text alone. Here that text is wrapped as a
--- standalone chunk -- the `Example` table, the function, a call of it --
--- and compiled with the checker, so a missing `require` or a name only
--- the harness defines (`tmp`) is refused. Nothing is run: the function's
--- body already runs in place under `cosmic test`, and what differs when
--- it is copied is what a compile sees.
---
--- Each user guide's examples (`doc/guides`) are held the same way: a
--- block that opens an example must compile alone, unless it is only a
--- project's entry, which reads its `file=` companions through the
--- harness's `tmp` and is compiled with that one name in scope. That
--- exemption stays: the companions are the `file=` blocks the guide
--- shows, which the generated test writes into `tmp` before the entry
--- runs, so an entry that made its own directory would repeat each
--- file's text a second time, in code, beside the block that shows it;
--- doctest has no notion of a companion written into the current
--- directory instead.
---
--- An example is compiled by the new checker as a file alone ([`build.pipeline`]'s `checked_alone`): the standard library
--- is the declarations the tool carries. What the examples still write that the checker refuses is pinned per file and
--- code under `[examples]` in [`build/ceilings.txt`], so that it can only fall.
local Ceilings = require("build.ceilings")
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local doctest = require("build.doctest")
local symbols = require("build.symbols")
local type Pipeline = require("build.pipeline")

local record example_checks
end

--- What the new checker says of `source` as the chunk `name`, one line each: its place is a line of the text as shown.
local function problems(options: Pipeline.Options, name: string, source: string): {string}
  local made = require("build.pipeline").checked_alone(name, source, options)
  -- Each line is the checker's, `name:line:column: what is wrong (code): the fix`, the line a line of the text as shown.
  if made.code ~= nil then
    return {}
  end
  return made.lines
end

--- A stored example source ([`build.syntax_analyzer`]'s `ExampleEntry`.source: the
--- `require` lines it needs, the function) as a chunk that runs alone:
--- `local Example = {}` where the function begins, and a call of it.
--- Lines are kept, so a complaint's line is a line of the text shown,
--- less the one `local Example` takes at the function. The table is a record of that name, since a literal with no type to
--- make it from is refused.
local function chunk(name: string, source: string): string
  -- The function's `function` starts a line: a match inside a comment
  -- or a string of a call carried above it is not the boundary.
  local at = source:find("^function Example%.") or source:find("\nfunction Example%.")
  if at ~= nil and source:sub(at, at) == "\n" then
    at = at + 1
  end
  local head = at ~= nil and source:sub(1, at - 1) or ""
  local rest = at ~= nil and source:sub(at) or source
  return head .. "local record Example end " .. rest .. "\nExample." .. name .. "()\n"
end

--- The name a finding says is unknown (`` `X` is not declared (unknown_variable)``, or `` `X` is used before the record `X`
--- that is declared at 5:14 (unknown_variable)``), or nil.
local function unknown_name(finding: string): string?
  return finding:match("`([%w_]+)` is not declared %(unknown_[a-z]+%)") or
    finding:match("`([%w_]+)` is used before [^%(]*%(unknown_[a-z]+%)")
end

--- The names a top-level line of an example file declares as a helper
--- (`local function f`, `local record R`, `local type T = ...`,
--- `local a <const>, b = ...`), none for anything else, a `require`
--- included: that is an import, which the shown text carries by the
--- names its function uses.
local function declared_names(line: string): {string}
  local out: mut {string} = {}
  if line:match("^local%s") == nil or line:match("=%s*require%s*%(") ~= nil or
      line:match("^local%s+record%s+Example%f[^%w_]") ~= nil or
      line:match("^local%s+Example%f[^%w_]") ~= nil then
    return out
  end
  local named = line:match("^local%s+function%s+([%w_]+)")
  for _, keyword in ipairs({ "record", "type", "enum", "interface" }) do
    named = named or line:match("^local%s+" .. keyword .. "%s+([%w_]+)")
  end
  if named ~= nil then
    out[1] = named
    return out
  end
  local names = line:sub(7):match("^([^=:]*)")
  for name in (names:gsub("<[%w_]+>", "")):gmatch("[%w_]+") do
    out[#out + 1] = name
  end
  return out
end

--- What an example file (its text) says about `name`, a name a shown
--- example lacks: if a top-level helper declares it, it was too long
--- to carry; if `name` is `Example` and a helper
--- calls `Example.x`, the copy has no such table. Nil for any other.
local function helper_trouble(file: string, name: string): string?
  local helper = ""
  local sibling: string? = nil
  for line in file:gmatch("[^\n]+") do
    local declared = declared_names(line)
    if #declared > 0 then
      helper = declared[1]
      for _, each in ipairs(declared) do
        if each == name then
          return "uses helper " .. name .. ", too long to carry: inline it"
        end
      end
    elseif line:match("^%S") ~= nil and line:match("^end") == nil and
        line:match("^[})%]]") == nil then
      helper = ""
    end
    if helper ~= "" and name == "Example" and sibling == nil then
      sibling = line:match("Example%.([%w_]+)")
      if sibling ~= nil then
        return "helper " .. helper .. " calls Example." .. sibling ..
          ", which a copy does not carry"
      end
    end
  end
  return nil
end

--- Every public example's rendered source, compiled as it is copied.
--- A name the text lacks that its file declares as a helper is said to
--- be one too long to carry.
--- @param root the tree, whose example files are read for that
local function examples(db: Sqlite.Handle, options: Pipeline.Options, root: string): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, line, name, source FROM examples WHERE " ..
      symbols.public_only("module", true) .. " ORDER BY file, line")
  if rows == nil then
    return { "reading the examples: " .. trouble }
  end
  local out: mut {string} = {}
  for _, row in ipairs(rows) do
    local where = row:text(1) .. ":" .. row:text(2) .. ": example " .. row:text(3)
    local file, _ = Fs.read(root .. "/" .. row:text(1))
    file = file or ""
    local told: mut {string: boolean} = {}
    for _, line in ipairs(problems(options, where, chunk(row:text(3), row:text(4)))) do
      local name = unknown_name(line)
      local said = name ~= nil and helper_trouble(file, name) or nil
      if said == nil then
        out[#out + 1] = line
      elseif not told[said] then
        told[said] = true
        out[#out + 1] = where .. ": " .. said
      end
    end
  end
  return out
end

--- One guide's examples, each compiled alone (`file` is the guide's
--- path, named in a complaint). One with `file=` companions is a
--- project's entry, whose code reads them through `tmp`: it compiles
--- with `tmp` a string in scope, and a name it needs beyond that is
--- still refused.
local function guide(text: string, file: string, options: Pipeline.Options): {string}
  local entries, trouble = doctest.entries(text)
  if entries == nil then
    return { file .. ": " .. trouble }
  end
  local out: mut {string} = {}
  for _, entry in ipairs(entries) do
    local source = entry.source
    if entry.companions then
      source = 'local tmp: string = ""\nlocal _ = tmp\n' .. source
    end
    local where = file .. ":" .. entry.line .. ": example"
    for _, line in ipairs(problems(options, where, source .. "\n")) do
      out[#out + 1] = line
    end
  end
  return out
end

--- The code a finding names: `(code): fix` ends the words of its message.
local function code_of(line: string): string?
  return line:match("%(([%a][%w_]*)%): ")
end

--- Where a finding is told: the example file or guide and the code it names.
local record Told
  file: string
  code: string
  --- Whether the line counts a code's errors in an example ("2 errors of nil_not_allowed in its bodies; follow the fix above"),
  --- which counts for none.
  summary: boolean
end

--- The file and code a line is of, nil where it names no code (a helper too long to carry, a missing require of the text).
local function told(line: string): Told?
  local file = line:match("^([^:%s]+):%d+: example")
  if file == nil then
    return nil
  end
  local counted = line:match(": %d+ errors? of ([%a][%w_]*) in its %a+; follow the fix above$")
  if counted ~= nil then
    return { file = file, code = counted, summary = true }
  end
  local code = code_of(line)
  if code == nil then
    return nil
  end
  return { file = file, code = code, summary = false }
end

--- `lines`, the findings of the new checker over all of the examples, less what `pins` (the `examples` ceilings of the tree,
--- [`build.ceilings`]) allows: the findings of a code in an example file or a guide, all of them or none. A code over its pin
--- is told whole with the count and the pin; a pin above the count is told to fall.
local function held(lines: {string}, pins: {string: integer}): {string}
  local found: mut {string: integer} = {}
  for _, line in ipairs(lines) do
    local at = told(line)
    if at ~= nil and not at.summary then
      local key = at.file .. " " .. at.code
      found[key] = (found[key] or 0) + 1
    end
  end
  local out: mut {string} = {}
  local over: mut {string: boolean} = {}
  -- In the order the findings came, which is the order of the files.
  local keys: mut {string} = {}
  for _, line in ipairs(lines) do
    local at = told(line)
    if at == nil then
      out[#out + 1] = line
    else
      local key = at.file .. " " .. at.code
      if (found[key] or 0) > (pins[key] or 0) then
        out[#out + 1] = line
        if over[key] ~= true then
          over[key] = true
          keys[#keys + 1] = key
        end
      end
    end
  end
  for _, key in ipairs(keys) do
    out[#out + 1] = key .. ": " .. tostring(found[key]) .. " found, pinned " .. tostring(pins[key] or 0) ..
      "; follow the fix above rather than raise the pin in build/ceilings.txt's [examples]"
  end
  for _, line in ipairs(Ceilings.fallen(found, pins, "build/ceilings.txt's [examples]")) do
    out[#out + 1] = line
  end
  return out
end

--- The `examples` ceilings of the tree at `root`: none where it has no ceilings file, which a fixture's tree does not.
local function pins_of(root: string): {string: integer}?, string
  local there, _ = Fs.exists(root .. "/" .. Ceilings.path)
  if there ~= true then
    return {}, ""
  end
  local read, why = Ceilings.read(root)
  if read == nil then
    return nil, why
  end
  return Ceilings.of(read, "examples"), ""
end

--- Both of the above over the tree at `root`: the projection `db`'s
--- examples and each of `guides` (default [`symbols.guides`], read from
--- `doc/guides/<name>.md`). The findings are those over the tree's `[examples]` ceilings, and the ceilings above the
--- findings.
function example_checks.run(db: Sqlite.Handle, root: string, guides?: {string}): {string}
  local options, options_trouble = require("build.pipeline").alone()
  if options == nil then
    return { options_trouble }
  end
  local out = examples(db, options, root)
  for _, name in ipairs(guides or symbols.guides) do
    local file = "doc/guides/" .. name .. ".md"
    local text, read_trouble = Fs.read(root .. "/" .. file)
    if text == nil then
      out[#out + 1] = read_trouble
    else
      for _, line in ipairs(guide(text, file, options)) do
        out[#out + 1] = line
      end
    end
  end
  local pins, pins_trouble = pins_of(root)
  if pins == nil then
    out[#out + 1] = pins_trouble
    return out
  end
  return held(out, pins)
end

return example_checks
