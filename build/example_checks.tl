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
local Hash = require("cosmic.hash")
local Sqlite = require("cosmic.sqlite")
local check_memo = require("build.check_memo")
local Markers = require("build.markers")
local build_schema = require("build.schema")
local type Build = build_schema.Build
local String = require("cosmic.string")
local doctest = require("build.doctest")
local symbols = require("cosmic.internal.symbols")
local type Pipeline = require("build.pipeline")
-- Declares what text this module reads ([`build.code_walk`]'s `markers`): the docs, examples, uses or links of the database it is handed.
local _ = require("build.reads.all")

local record example_checks
  --- What a run keeps of each example's findings, so that an example whose key stands is not compiled again: the memo
  --- ([`build.check_memo`], kind `example`) and the salt of its keys ([`example_checks.salt`]).
  record Kept
    memo: Sqlite.Handle
    salt: string
  end
end

--- The memo's kind.
local KIND <const> = "example"

--- What an example's findings depend on beyond its own text and its file's: the code that compiles it, by the import
--- closure of this module in the projection `db` ([`check_memo.closure_salt`]), and what the standard library declares,
--- by the working database `work` of the tree: each standard-library file's shape ([`build.shape_key`], kept in
--- `shapes`, which a body's edit leaves as it was), each declaration's text, and each header a declaration is made
--- from. Nil and why where either database cannot say.
function example_checks.salt(db: Build, work: Sqlite.Handle): string?, string
  local code, code_trouble = check_memo.closure_salt(db, { "build.example_checks" }, "example 1")
  if code == nil then return nil, code_trouble end
  local rows, trouble = work:rows(
    "SELECT DISTINCT i.file, coalesce(s.digest, i.source_hash) FROM inputs i " ..
      "LEFT JOIN shapes s ON s.source_hash = i.source_hash " ..
      "WHERE i.file GLOB 'cosmic/*' OR i.file GLOB 'lang/*.d.tl' OR i.file GLOB 'core/*.h' ORDER BY 1, 2")
  if rows == nil then return nil, "reading the inputs: " .. tostring(trouble) end
  local parts: mut {string} = { code }
  for _, row in ipairs(rows) do parts[#parts + 1] = row:text(1) .. "=" .. row:text(2) end
  return Hash.hex_sha256(table.concat(parts, "\0")), ""
end

--- The findings kept under `key`, or nil.
local function recalled(kept: example_checks.Kept?, key: string): {string}?
  if kept == nil then return nil end
  local text = check_memo.get(kept.memo, KIND, key)
  if text == nil then return nil end
  local lines: mut {string} = {}
  for _, row in ipairs(check_memo.decode(text)) do
    if row[1] == "L" then lines[#lines + 1] = row[2] or "" end
  end
  return lines
end

--- Keeps `lines` under `key`.
local function keep(kept: example_checks.Kept?, key: string, lines: {string})
  if kept == nil then return end
  local rows: mut {{string}} = { { "E" } }
  for _, line in ipairs(lines) do rows[#rows + 1] = { "L", line } end
  check_memo.put(kept.memo, KIND, key, check_memo.encode(rows))
end

--- A finding of the new checker: its lines, one each, whose place is a line of the text as shown, and the stage of each
--- finding ([`Pipeline.Alone`]'s `stages`, from the checker's own lists).
local record Said
  lines: {string}
  stages: {string: string}
end

--- What the new checker says of each of `items`, `{ name, source }`, as that chunk alone: all in one build, so what they
--- read of the standard library is checked once.
local function problems(options: Pipeline.Options, items: {{string}}): {Said}
  local out: mut {Said} = {}
  for i, made in ipairs(require("build.pipeline").checked_alone_each(items, options)) do
    -- Each line is the checker's, `name:line:column: what is wrong (code): the fix`, the line a line of the text as shown.
    out[i] = if made.code ~= nil then { lines = {}, stages = {} } else { lines = made.lines, stages = made.stages } end
  end
  return out
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
-- TODO: drop this reader of the checker's prose, and the one of [`found_at`], once [`Pipeline.checked_alone`] returns the spots of
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
local function examples(db: Build, options: function(): Pipeline.Options?, string, root: string,
                        kept?: example_checks.Kept): mut {string}
  local rows, trouble = db:rows(
    "SELECT file, line, name, source FROM examples WHERE " ..
      symbols.public_only("module", true) .. " ORDER BY file, line")
  if rows == nil then
    return { "reading the examples: " .. tostring(trouble) }
  end
  -- Each example's findings, by its place in `rows`: those its key holds, and the rest compiled in one build.
  local found: mut {integer: {string}} = {}
  local items: mut {{string}} = {}
  local missed: mut {integer} = {}
  local keys: mut {integer: string} = {}
  local files: mut {integer: string} = {}
  for i, row in ipairs(rows) do
    local where = row:text(1) .. ":" .. tostring(row:integer(2)) .. ": example " .. row:text(3)
    local text = chunk(row:text(3), row:text(4))
    local file, _ = Fs.read(root .. "/" .. row:text(1))
    files[i] = file or ""
    local key = check_memo.key(if kept ~= nil then kept.salt else "" end, "example",
      where .. "\0" .. text .. "\0" .. (file or ""))
    keys[i] = key
    local lines = recalled(kept, key)
    if lines ~= nil then
      found[i] = lines
    else
      items[#items + 1] = { where, text }
      missed[#missed + 1] = i
    end
  end
  if #items > 0 then
    local made, made_trouble = options()
    if made == nil then return { made_trouble } end
    local said = problems(made, items)
    for at, i in ipairs(missed) do
      local where, text = assert(assert(items[at])[1]), assert(assert(items[at])[2])
      local file = assert(files[i])
      local told: mut {string: boolean} = {}
      local said_lines: mut {string} = {}
      local lines, stages = assert(said[at]).lines, assert(said[at]).stages
      for _, line in ipairs(lines) do
        local name = unknown_name(line)
        local helper = if name ~= nil then helper_trouble(file, name) else nil end
        if helper == nil then
          said_lines[#said_lines + 1] = line
        elseif told[helper] ~= true then
          told[helper] = true
          said_lines[#said_lines + 1] = where .. ": " .. helper
        end
      end
      local out = held(where, text, said_lines, stages, true)
      found[i] = out
      keep(kept, assert(keys[i]), out)
    end
  end
  local out: mut {string} = {}
  for i = 1, #rows do
    for _, line in ipairs(assert(found[i])) do out[#out + 1] = line end
  end
  return out
end

--- One guide's examples, each compiled alone (`file` is the guide's
--- path, named in a complaint). One with `file=` companions is a
--- project's entry, whose code reads them through `tmp`: it compiles
--- with `tmp` a string in scope, and a name it needs beyond that is
--- still refused.
local function guided(text: string, file: string, options: Pipeline.Options): {string}
  local entries, trouble = doctest.entries(text)
  if entries == nil then
    return { file .. ": " .. trouble }
  end
  local out: mut {string} = {}
  local items: mut {{string}} = {}
  for _, entry in ipairs(entries) do
    local source = entry.source
    if entry.companions then
      source = 'local tmp: string = ""\nlocal _ = tmp\n' .. source
    end
    items[#items + 1] = { file .. ":" .. tostring(entry.line) .. ": example", source .. "\n" }
  end
  for i, said in ipairs(problems(options, items)) do
    local item = assert(items[i])
    for _, line in ipairs(held(assert(item[1]), assert(item[2]), said.lines, said.stages, false)) do
      out[#out + 1] = line
    end
  end
  return out
end

--- [`guided`], or what `kept` holds of the guide.
local function guide(text: string, file: string, options: function(): Pipeline.Options?, string,
                     kept?: example_checks.Kept): {string}
  local key = check_memo.key(if kept ~= nil then kept.salt else "" end, "guide", file .. "\0" .. text)
  local recall = recalled(kept, key)
  if recall ~= nil then return recall end
  local made, made_trouble = options()
  if made == nil then return { made_trouble } end
  local lines = guided(text, file, made)
  keep(kept, key, lines)
  return lines
end

--- Both of the above over the tree at `root`: the projection `db`'s
--- examples and each of `guides` (default the user guides, each Markdown
--- file directly under `doc/guides/`, read from `doc/guides/<name>.md`). A
--- guide under `doc/guides/internal/` is not held to it: its examples
--- require the tree's own modules, which the reader these are shown to,
--- one with the binary alone, does not have. The tree compiles and runs
--- them as its tests. The findings are those the markers of an example do not hold, and the markers that hold
--- none.
--- @param kept where given, the memo of each example's and guide's findings: one whose key it holds is not compiled
function example_checks.run(db: Build, root: string, guides?: {string}, kept?: example_checks.Kept): {string}
  -- The standard library's declarations are read once, and only for an example no key holds.
  local made: Pipeline.Options? = nil
  local made_trouble = ""
  local tried = false
  local function options(): Pipeline.Options?, string
    if not tried then
      tried = true
      made, made_trouble = require("build.pipeline").alone()
    end
    if made ~= nil then return made, "" end
    return nil, made_trouble
  end
  local out = examples(db, options, root, kept)
  if tried and made == nil then return out end
  local named = guides
  if named == nil then
    -- A tree with no guides has no such directory.
    local listed, _ = Fs.list(root .. "/doc/guides")
    local found: mut {string} = {}
    for _, entry in ipairs(listed or {}) do
      local name = entry:match("^(.+)%.md$")
      if name ~= nil then found[#found + 1] = name end
    end
    table.sort(found)
    named = found
  end
  for _, name in ipairs(named) do
    local file = "doc/guides/" .. name .. ".md"
    local text, read_trouble = Fs.read(root .. "/" .. file)
    if text == nil then
      local said = tostring(read_trouble)
      out[#out + 1] = said
    else
      for _, line in ipairs(guide(text, file, options, kept)) do
        out[#out + 1] = line
      end
    end
  end
  return out
end

return example_checks
