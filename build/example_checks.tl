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
--- is the declarations the tool carries. What the examples still write that the checker refuses is held by markers, as in
--- the rest of the tree ([`build.markers`]): `-- checked: <code>` at the end of the line, which is part of the text shown, so a
--- marker in an example file is the marker its chunk is judged by. A finding with no marker on its line is refused, and so
--- is a marker whose finding is gone. A guide's block holds no marker (a reader copies the block), so any finding in one
--- is refused.
local Fs = require("cosmic.fs")
local Markers = require("build.markers")
local Sqlite = require("cosmic.sqlite")
local String = require("cosmic.string")
local doctest = require("build.doctest")
local symbols = require("build.symbols")
local type Pipeline = require("build.pipeline")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): the docs, examples, uses or links of the database it is handed.
local _ = require("build.reads.all")

local record example_checks
end

--- What the new checker says of `source` as the chunk `name`, one line each: its place is a line of the text as shown, and the
--- stage of each finding ([`Pipeline.Alone`]'s `stages`, from the checker's own lists).
local function problems(options: Pipeline.Options, name: string, source: string): {string}, {string: string}
  local made = require("build.pipeline").checked_alone(name, source, options)
  -- Each line is the checker's, `name:line:column: what is wrong (code): the fix`, the line a line of the text as shown.
  if made.code ~= nil then
    return {}, {}
  end
  return made.lines, made.stages
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
  local head = if at ~= nil then source:sub(1, at - 1) else "" end
  local rest = if at ~= nil then source:sub(at) else source end
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
  local names = assert(line:sub(7):match("^([^=:]*)"), "the pattern matches an empty head at worst")
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

--- The code a finding names: `(code): fix` ends the words of its message.
local function code_of(line: string): string?
  return line:match("%(([%a][%w_]*)%): ")
end

--- Where a finding is: its line of the chunk and its code.
local record Place
  y: integer
  x: integer
  code: string
end

--- Where a finding of the checker is (`name:5:9: message (code): fix`), nil for any other
--- line: a helper too long to carry, a count of a code's errors ("2 errors of x in its bodies on line 3; follow the fix above"), which
--- the judging below says again by the markers.
local function found_at(line: string): Place?
  local y = math.tointeger(tonumber(line:match(":(%d+):%d+: ")))
  local x = math.tointeger(tonumber(line:match(":%d+:(%d+): ")))
  local code = code_of(line)
  if y == nil or x == nil or code == nil then
    return nil
  end
  return { y = y, x = x, code = code }
end

--- Whether `line` is the checker's own count of a code's errors in an example.
-- TODO: drop this reader of the checker's prose, and the one of [`found_at`], once [`Pipeline.checked_alone`] answers the spots of
-- [`build.ceilings.marked`] beside its lines: they match the words of a finding and of a count line, and a changed wording makes them
-- tell a finding twice, which fails closed.
local function is_count(line: string): boolean
  return line:match(": %d+ errors? of [%a][%w_]* in its %a+ on line %d+; follow the fix above$") ~= nil
end

--- The stage of the finding at `place`, from what the checker told ([`Pipeline.Alone`]'s `stages`): "" where it has none (a
--- warning, a finding two stages report at one place), which no marker holds.
local function stage_of(stages: {string: string}, place: Place): string
  return stages[tostring(place.y) .. ":" .. tostring(place.x) .. ":" .. place.code] or ""
end

--- `lines`, the findings of the checker over `text` (the chunk `where` names), less what the markers of `text` hold: the
--- findings of a code of a stage on a line that the markers of that stage do not hold, each told with a count, and each
--- marker that holds more of a code than its line has. `marks` is false for a guide's block, which carries none.
local function held(where: string, text: string, lines: {string}, stages: {string: string}, marks: boolean): {string}
  local out: mut {string} = {}
  -- The findings and the markers by line and `<stage> <code>`.
  local found: mut {integer: mut {string: integer}} = {}
  local order: mut {string} = {}
  for _, line in ipairs(lines) do
    local place = found_at(line)
    if place ~= nil then
      local key = stage_of(stages, place) .. " " .. place.code
      local on = found[place.y] or {}
      found[place.y] = on
      if on[key] == nil then
        order[#order + 1] = tostring(place.y) .. " " .. key
      end
      on[key] = (on[key] or 0) + 1
    end
  end
  local marked: mut {integer: mut {string: integer}} = {}
  local marked_lines: mut {integer} = {}
  if marks then
    for _, mark in ipairs(Markers.read(text, where).marks) do
      for _, segment in ipairs(mark.segments) do
        for code, n in pairs(segment.counts) do
          local on = marked[mark.line] or {}
          if marked[mark.line] == nil then
            marked[mark.line] = on
            marked_lines[#marked_lines + 1] = mark.line
          end
          local key = segment.stage .. " " .. code
          on[key] = (on[key] or 0) + n
        end
      end
    end
  end
  local function allowed(y: integer, key: string): integer
    return (marked[y] or {})[key] or 0
  end
  local told: mut {string: boolean} = {}
  for _, line in ipairs(lines) do
    local place = found_at(line)
    if place == nil then
      if not is_count(line) then
        out[#out + 1] = line
      end
    else
      local key = stage_of(stages, place) .. " " .. place.code
      if (assert(found[place.y])[key] or 0) > allowed(place.y, key) then
        out[#out + 1] = line
      end
    end
  end
  for _, entry in ipairs(order) do
    local y = assert(math.tointeger(tonumber(entry:match("^(%d+)"))))
    local key = assert(entry:match("^%d+ (.*)$"))
    local code = assert(key:match("^%S* (%S+)$"))
    local n, has = assert(assert(found[y])[key]), allowed(y, key)
    if n > has and told[entry] ~= true then
      told[entry] = true
      local how = if marks then ", marked " .. tostring(has) .. " rather than add a marker" else "" end
      out[#out + 1] = where .. ": " .. String.counted(n, "error") .. " of " .. code .. " on line " .. tostring(y) ..
        " of the text shown" .. how .. "; follow the fix above"
    end
  end
  table.sort(marked_lines)
  for _, y in ipairs(marked_lines) do
    local keys: mut {string} = {}
    for key in pairs(assert(marked[y])) do
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      local n = assert(assert(marked[y])[key])
      local has = (found[y] or {})[key] or 0
      local code = assert(key:match("^%S* (%S+)$"))
      if n > has then
        out[#out + 1] = where .. ": line " .. tostring(y) .. " of the text shown: its marker holds " ..
          String.counted(n - has, "finding") .. " of " .. code .. " that the line no longer has; remove the marker"
      end
    end
  end
  return out
end

--- Every public example's rendered source, compiled as it is copied.
--- A name the text lacks that its file declares as a helper is said to
--- be one too long to carry.
--- @param root the tree, whose example files are read for that
local function examples(db: Sqlite.Handle, options: Pipeline.Options, root: string): mut {string}
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
    local text = chunk(row:text(3), row:text(4))
    local said_lines: mut {string} = {}
    local lines, stages = problems(options, where, text)
    for _, line in ipairs(lines) do
      local name = unknown_name(line)
      local said = if name ~= nil then helper_trouble(file, name) else nil end
      if said == nil then
        said_lines[#said_lines + 1] = line
      elseif told[said] ~= true then
        told[said] = true
        said_lines[#said_lines + 1] = where .. ": " .. said
      end
    end
    for _, line in ipairs(held(where, text, said_lines, stages, true)) do
      out[#out + 1] = line
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
    local where = file .. ":" .. tostring(entry.line) .. ": example"
    local lines, stages = problems(options, where, source .. "\n")
    for _, line in ipairs(held(where, source .. "\n", lines, stages, false)) do
      out[#out + 1] = line
    end
  end
  return out
end

--- Both of the above over the tree at `root`: the projection `db`'s
--- examples and each of `guides` (default [`symbols.guides`], read from
--- `doc/guides/<name>.md`). The findings are those the markers of an example do not hold, and the markers that hold
--- none.
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
  return out
end

return example_checks
