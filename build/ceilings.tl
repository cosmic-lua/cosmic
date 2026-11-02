--- The ceilings of the new checker: how many errors of each code each file of the tree may still have, per stage.
---
--- A stage is held in one of two ways. A stage listed under `[marked]` in [`build/ceilings.txt`] is held by MARKERS: each
--- finding it still makes is held by a comment on the line it is reported at (`-- checked: map_field`, [`build.markers`]), so
--- that a change that removes code moves or deletes the markers with it and touches no shared file. [`Ceilings.marked`] judges
--- a file against its markers: a finding with no marker on its line is refused, by a compile of the module and by the check of
--- the tree, and a marker whose finding is gone is stale, which the check of the tree tells and `cosmic fix` removes. The
--- markers only fall: [`build.ceilings_base`] holds each file's count of each code to the file at the merge base with main. The
--- stage `examples` and the stages not listed are held by counts, as the rest of this comment says.
---
--- A COUNT is data in [`build/ceilings.txt`] and not Teal compiled into the tool.
---
--- A ceiling only falls, and two things enforce it. A file that goes over its ceiling is refused, by a compile of a module
--- and by the check of the tree ([`Ceilings.over`]); a missing row is a ceiling of 0. And a code that has no row left in any
--- stage is closed ([`Ceilings.closed`]): [`Ceilings.parse`] refuses a line keyed by it. A rewrite removes the places a
--- ceiling counts and lowers the number; nothing raises it. The markers are held falling by [`build.ceilings_base`].
---
--- The file is text, a section per stage (`[checked]`) and a line per ceiling: a file, a code and a count, or for the stage
--- `untyped` a file and a count. A line that begins with `#` is a comment, and a comment before the lines it explains
--- says what brings them to zero. Each ceiling line stands alone between blank lines ([`Ceilings.crowded`]), so two pull
--- requests that move neighbouring pins merge. The stages are the checks of [`build.tree_checks`], and `scoped`, `declared` and
--- `checked` are also the stages of a compile ([`build.driver`]), whose [`Ceilings.over`] a compile calls for a module: the
--- tree's check of a file and the build's refuse the same count, with the same words.
--- The examples a reader copies ([`build.example_checks`]) have no section: their findings are held by markers in the
--- example files, which are part of the text shown, and a guide's block holds none.
---
--- `testdata` is the check of the Teal under `ci/testdata` ([`build.tree_checks`]'s `ci_testdata`):
--- a key is a file and a code of any stage, and a count is the findings of that code in the file.
---
--- A ceiling is read at the start of a run, from the file or from a database the file filled; a caller that has neither
--- passes a table of its own.
local Check = require("lang.check")
local Declarations = require("lang.declarations")
local Fs = require("cosmic.fs")
local Markers = require("build.markers")
local Scopes = require("lang.scopes")
local String = require("cosmic.string")

local record Ceilings
  --- The stages a ceiling may name, in the order of the file.
  enum Stage
    "scoped"
    "declared"
    "untyped"
    "checked"
    "testdata"
  end

  --- An error of a file, as a check lists it.
  record Finding
    code: string
    y: integer
    x: integer
    msg: string
    fix: string
  end

  --- The ceilings of each stage, by stage: a key (`<file> <code>`, or `<file>` for `untyped`) to its count.
  record Table
    stages: mut {string: {string: integer}}
    --- Whether the tree has no ceilings to be held to and none to raise: a project's. An error over a ceiling of 0 is then
    --- listed without the pin that is not there.
    none: boolean?
    --- The stages whose findings are held by markers at the lines they occur on ([`Ceilings.marked`]) and not by
    --- counts: those the file lists under `[marked]`. A stage listed has no rows. Nil where no stage is.
    marked?: {string: boolean}
  end

  --- The path of the data file below the root of the tree.
  mut path: string

  --- The ceilings `text` holds, or nil and what is wrong with it: a line of no section or of the wrong shape, a stage no
  --- check has, a count that is not a positive integer, a key that two lines give, and a key that can never be met: one
  --- of a stage that counts by code whose code is none of that stage's, or whose shape is not the stage's, and a line
  --- keyed by a closed code ([`Ceilings.closed`], or `closed` where a caller gives its own list: a test of a checker that
  --- finds an error of a code the tree has closed holds it to a pin of its own).
  parse: function(text: string, closed?: {string}): Table?, string

  --- The codes that no file may be pinned for: each has no row left in any stage, so the tree keeps its rule with no
  --- exceptions. It is a list and not "every code that has no row", because a file that gives a row to such a code
  --- would be the row: only a list stays closed against the text it is asked to judge. The list is held to its
  --- meaning by [`build/ceilings_test.tl`]: a code of a stage with no row must be listed, so that the change that removes
  --- a code's last row closes it, and a listed code must be a code of some stage. A new code of a stage starts with no
  --- row, so it is listed with the change that adds it.
  closed: function(): {string}

  --- The ceilings of the tree at `root` ([`Ceilings.path`]).
  read: function(root: string): Table?, string

  --- The ceiling lines of `text` that a line follows directly, one line of message each with its place, or "" where there
  --- are none. A ceiling stands alone between blank lines (a comment may sit directly above the one it explains, and a
  --- `[stage]` line above its first): git merges two changes only where an unchanged line lies between them, so a
  --- ceiling that has a neighbour conflicts with every change to that neighbour, and most pull requests move some pin.
  crowded: function(text: string): string

  --- The keys of `ceilings` that name a file `root` lacks, one line each: a ceiling that no run can meet, since the check of
  --- the tree finds no error in a file that is not there.
  dead: function(root: string, ceilings: Table): {string}

  --- The ceilings of `stage` in `ceilings`: empty for a stage the table has none of.
  of: function(ceilings: Table, stage: Stage): {string: integer}

  --- The pseudo code of a call the checker gave no function ([`build.syntax_contracts`]'s `untyped`), the one finding of the
  --- stage `untyped`: a marker (`-- untyped: call`) names it as it names a code of the checker.
  mut untyped_code: string
  --- The words of that finding: what it is and what to do.
  mut untyped_message: string
  mut untyped_fix: string

  --- The stages that markers can hold: those whose findings have a line.
  markable: function(): {Stage}

  --- Whether `ceilings` holds the findings of `stage` by markers.
  by_marks: function(ceilings: Table, stage: Stage): boolean

  --- A place where a finding and a marker disagree, for the check that tells it and the fix that mends it.
  type Spot = Markers.Spot

  --- The places a run found that the markers of the tree disagree with its findings: `unmarked` where findings have no
  --- marker (which the author writes) and `stale` where a marker holds more than the line has (what
  --- `cosmic fix` removes). Each is of one file and one code.
  record Sink
    unmarked: mut {Spot}
    stale: mut {Spot}
    --- Whether the caller mends the stale markers itself, so that the check does not tell them as findings.
    mend?: boolean
  end

  --- How a check of the tree is run over the markers: `sink` collects what disagrees ([`Ceilings.Sink`]).
  record Marking
    sink?: Sink
  end

  --- What [`Ceilings.marked`] found of one file.
  record Judged
    --- The refusals, listed: each finding that has no marker, with its place, message and fix, then a line that says how many
    --- there are at the line and what the marker holds; and a marker of a closed code.
    lines: {string}
    --- The findings no marker holds, by line and code.
    unmarked: {Spot}
    --- The markers that hold what the line lacks, by line and code.
    stale: {Spot}
  end

  --- The errors of the file `file` whose text is `text`, held by its markers of `stage`: the errors of a code on a line that
  --- the markers of that line do not hold, listed. `codes` are the codes of the stage, and a marker of another code or
  --- another stage is none of its business. `what` says where the errors are (`bodies`). With `unpinned` the lines do not point to the marker.
  marked: function(stage: Stage, file: string, text: string, errors: {Finding}, codes: {string}, what: string,
                   unpinned?: boolean): Judged

  --- What [`Ceilings.over`] found.
  record Held
    --- The errors over their ceilings, listed.
    lines: {string}
    --- The count of the errors of each code the file has, by key, for the check that a ceiling is not above what the file
    --- has.
    found: {string: integer}
  end

  --- The errors of the file `file` over its ceilings in `pinned`, listed: each error of a code over its ceiling with its
  --- place, message and fix, then a line that says how many there are and what the ceiling is (`pinned N`). `what` says
  --- where they are (`bodies`). With `unpinned` (a tree without ceilings, [`Table.none`]) that line says the count alone.
  over: function(file: string, errors: {Finding}, codes: {string}, pinned: {string: integer}, what: string,
                 unpinned?: boolean): Held

  --- The ceilings of `pinned` that are above the counts in `found` (by key), one line each, with where to lower it.
  fallen: function(found: {string: integer}, pinned: {string: integer}, where: string): {string}
end

Ceilings.path = "build/ceilings.txt"

local CLOSED_CODES <const>: {string} = {
  "alias_cycle",
  "arity",
  "array_hole",
  "array_part_map",
  "assign_repeated",
  "bound_not_interface",
  "bound_not_met",
  "bound_unmet",
  "class_scope",
  "concat_type",
  "const_assigned",
  "declaration_value",
  "enum_member",
  "env_reserved",
  "format_malformed",
  "generic_op",
  "gsub_key",
  "infer_conflict",
  "invariant_mut",
  "iterator_extra",
  "iterator_variables",
  "listing_too_large",
  "lists_overlap",
  "literal_ambiguous",
  "literal_repeated",
  "literal_spread",
  "local_untyped",
  "match_missing",
  "match_pattern",
  "match_redundant",
  "metamethod_signature",
  "metamethod_unknown",
  "narrowing_dropped",
  "narrows_unproved",
  "not_a_type",
  "not_a_value",
  "not_callable",
  "not_indexable",
  "operand_type",
  "optional_generic",
  "optional_metamethod",
  "outer_type_parameter",
  "pack_malformed",
  "param_untyped",
  "paren_is",
  "pattern_malformed",
  "primitive_type_name",
  "record_as_map",
  "record_index",
  "repeated_field",
  "repeated_value",
  "require_unknown",
  "return_arity",
  "return_unexpected",
  "shadows",
  "static_before_definition",
  "store_refused",
  "super_cycle",
  "super_not_interface",
  "type_arguments",
  "type_name",
  "type_too_deep",
  "unknown_parameter",
  "unknown_type",
  "unknown_variable",
  "unused_type_parameter",
  "value_count",
  "vararg_outside",
}

local CLOSED: mut {string: boolean} = {}
for _, code in ipairs(CLOSED_CODES) do
  CLOSED[code] = true
end

function Ceilings.closed(): {string}
  return CLOSED_CODES
end

--- The codes of the errors each stage that counts by code counts.
local function codes_of(stage: string): {string}?
  if stage == "scoped" then
    return Scopes.codes
  elseif stage == "declared" then
    return Declarations.codes
  elseif stage == "checked" then
    return Check.codes
  end
  return nil
end

--- Why `key`, a ceiling of `stage`, can never be met, or "" where it can.
local function unmeetable(stage: string, key: string): string
  if stage == "testdata" then
    -- A finding of a file of ci/testdata is of any stage's code, so the shape is all that can be held.
    if key:match("^%S+ %S+$") == nil then
      return "a ceiling of [" .. stage .. "] is a file and a code, not `" .. key .. "`"
    end
    return ""
  end
  local codes = codes_of(stage)
  if codes == nil then
    if key:find("%s") ~= nil then
      return "a ceiling of [" .. stage .. "] is one word, not `" .. key .. "`"
    end
    return ""
  end
  local file, code = key:match("^(%S+) (%S+)$")
  if file == nil or code == nil then
    return "a ceiling of [" .. stage .. "] is a file and a code, not `" .. key .. "`"
  end
  for _, known in ipairs(codes) do
    if known == code then
      return ""
    end
  end
  return "`" .. code .. "` is no code of [" .. stage .. "]"
end

--- The closed code ([`Ceilings.closed`]) `key`, a ceiling of `stage`, is keyed by, or "" where it is keyed by none: a stage
--- that counts by file alone has no code to close.
local function closed_code(shut: {string: boolean}, stage: string, key: string): string
  if stage == "untyped" then
    return ""
  end
  local code = key:match("^%S+ (%S+)$")
  if code ~= nil and shut[code] == true then
    return code
  end
  return ""
end

local STAGES <const>: {string: boolean} = {
  scoped = true, declared = true, untyped = true, checked = true, testdata = true,
}

--- The stages that markers hold, in the order of the file.
local MARKABLE_LIST <const>: {Ceilings.Stage} = { "scoped", "declared", "untyped", "checked" }

local MARKABLE: mut {string: boolean} = {}
for _, stage in ipairs(MARKABLE_LIST) do
  MARKABLE[tostring(stage)] = true
end

function Ceilings.parse(text: string, closed?: {string}): Ceilings.Table?, string
  local shut = CLOSED
  if closed ~= nil then
    local own: mut {string: boolean} = {}
    for _, code in ipairs(closed) do
      own[code] = true
    end
    shut = own
  end
  local marked: mut {string: boolean} = {}
  local out: Ceilings.Table = { stages = {}, none = nil, marked = marked }
  local held: mut {string: integer}? = nil
  local stage = ""
  local number = 0
  local listing = false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name = line:match("^%[([a-z]+)%]$")
      if name == "marked" then
        listing = true
        held = nil
        stage = "marked"
      elseif listing and name == nil and line:match("^[a-z ]+$") ~= nil then
        local at = Ceilings.path .. ":" .. tostring(number) .. ": "
        for word in line:gmatch("%S+") do
          if MARKABLE[word] ~= true then
            return nil, at .. "`" .. word .. "` is no stage that markers hold; [marked] lists " .. table.concat(MARKABLE_LIST, ", ")
          end
          marked[word] = true
        end
      elseif name ~= nil then
        listing = false
        if STAGES[name] ~= true then
          return nil, Ceilings.path .. ":" .. tostring(number) .. ": no stage " .. name .. " in a check of the tree"
        end
        stage = name
        local opened: mut {string: integer} = {}
        for key, count in pairs(out.stages[name] or {}) do opened[key] = count end
        out.stages[name] = opened
        held = opened
      elseif listing then
        return nil, Ceilings.path .. ":" .. tostring(number) .. ": [marked] lists stages by name, not `" .. line .. "`"
      else
        local key, count = line:match("^(%S.-)%s+(%d+)$")
        local n: integer? = nil
        if count ~= nil then
          n = math.tointeger(tonumber(count))
        end
        local at = Ceilings.path .. ":" .. tostring(number) .. ": "
        if held == nil then
          return nil, at .. "a ceiling before any [stage] line"
        elseif key == nil or n == nil or n < 1 then
          return nil, at .. "expected `<file> <code> <count>` with a count of 1 or more, not `" .. line .. "`"
        elseif held[key] ~= nil then
          return nil, at .. "`" .. key .. "` has a ceiling twice in [" .. stage .. "]"
        end
        local why = unmeetable(stage, key)
        if why ~= "" then
          return nil, at .. why
        end
        local code = closed_code(shut, stage, key)
        if code ~= "" then
          return nil, at .. code .. " is closed: the tree keeps this rule with no exceptions; fix the code instead"
        end
        held[key] = n
      end
    end
  end
  for word in pairs(marked) do
    if next(out.stages[word] or {}) ~= nil then
      return nil, Ceilings.path .. ": [" .. word .. "] is held by markers, so it has no rows; the markers are its ceilings"
    end
  end
  return out, ""
end

function Ceilings.crowded(text: string): string
  local out = ""
  local number = 0
  -- The line before the one being read where it is a ceiling, else "".
  local before = ""
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    if before ~= "" and line ~= "" then
      out = out .. Ceilings.path .. ":" .. tostring(number - 1) .. ": `" .. before ..
        "` is followed directly by another line: a ceiling stands alone between blank lines, " ..
        "so that a change to its neighbour merges with a change to it\n"
    end
    if line ~= "" and line:sub(1, 1) ~= "#" and line:match("^%[[a-z]+%]$") == nil then
      before = line
    else
      before = ""
    end
  end
  return out
end

function Ceilings.read(root: string): Ceilings.Table?, string
  local text, why = Fs.read(root .. "/" .. Ceilings.path)
  if text == nil then
    return nil, why
  end
  return Ceilings.parse(text)
end

function Ceilings.dead(root: string, ceilings: Ceilings.Table): {string}
  local out: mut {string} = {}
  for stage, held in pairs(ceilings.stages) do
    for key in pairs(held) do
      local file = assert(key:match("^(%S+)"), "a key names its file")
      local there, _ = Fs.exists(root .. "/" .. file)
      if there ~= true then
        out[#out + 1] = key .. ": pinned in [" .. stage .. "], and the tree has no file " .. file
      end
    end
  end
  table.sort(out)
  return out
end

function Ceilings.of(ceilings: Ceilings.Table, stage: Ceilings.Stage): {string: integer}
  return ceilings.stages[tostring(stage)] or {}
end

Ceilings.untyped_code = "call"
Ceilings.untyped_message = "a call the checker gave no function, which no rule of the discipline judged"
Ceilings.untyped_fix = "type what it calls through"

function Ceilings.markable(): {Ceilings.Stage}
  return MARKABLE_LIST
end

function Ceilings.by_marks(ceilings: Ceilings.Table, stage: Ceilings.Stage): boolean
  local marked = ceilings.marked
  return marked ~= nil and marked[tostring(stage)] == true
end

function Ceilings.marked(stage: Ceilings.Stage, file: string, text: string, errors: {Ceilings.Finding}, codes: {string},
                         what: string, unpinned?: boolean): Ceilings.Judged
  local out: mut {string} = {}
  local unmarked: mut {Markers.Spot} = {}
  local stale: mut {Markers.Spot} = {}
  local wanted: mut {string: boolean} = {}
  for _, code in ipairs(codes) do
    wanted[code] = true
  end
  -- What the markers hold, by line and code: those of this stage's codes alone.
  local held: mut {integer: mut {string: integer}} = {}
  local marks = Markers.read(text, file).marks
  for _, mark in ipairs(marks) do
    for _, segment in ipairs(mark.segments) do
      if segment.stage == tostring(stage) then
        for code, n in pairs(segment.counts) do
          if wanted[code] == true then
            local on = held[mark.line] or {}
            held[mark.line] = on
            on[code] = (on[code] or 0) + n
          end
        end
      end
    end
  end
  -- The findings, by line and code, in the order of the lines.
  local found: mut {integer: mut {string: mut {Ceilings.Finding}}} = {}
  local lines: mut {integer} = {}
  for _, e in ipairs(errors) do
    if wanted[e.code] == true then
      local on = found[e.y] or {}
      if found[e.y] == nil then
        found[e.y] = on
        lines[#lines + 1] = e.y
      end
      local list = on[e.code] or {}
      on[e.code] = list
      list[#list + 1] = e
    end
  end
  table.sort(lines)
  for _, line in ipairs(lines) do
    local on = assert(found[line])
    for _, code in ipairs(codes) do
      local list = on[code]
      if list ~= nil then
        local marked_n = (held[line] or {})[code] or 0
        -- A closed code has no exceptions: a marker for it holds nothing.
        local allowed = marked_n
        if CLOSED[code] == true then
          allowed = 0
        end
        if #list > allowed then
          for _, e in ipairs(list) do
            out[#out + 1] = file .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. code .. "): " .. e.fix
          end
          local tail = "; follow the fix above"
          if unpinned ~= true then
            tail = ", marked " .. tostring(allowed) .. tail .. " rather than add a marker"
          end
          out[#out + 1] = file .. ": " .. String.counted(#list, "error") .. " of " .. code .. " in its " .. what ..
            " on line " .. tostring(line) .. tail
          unmarked[#unmarked + 1] = { file = file, line = line, stage = tostring(stage), code = code, count = #list - allowed }
        end
      end
    end
  end
  -- The markers that hold more than the line has, in the order of the lines.
  local marked_lines: mut {integer} = {}
  for line in pairs(held) do
    marked_lines[#marked_lines + 1] = line
  end
  table.sort(marked_lines)
  for _, line in ipairs(marked_lines) do
    local on = assert(held[line])
    for _, code in ipairs(codes) do
      local n = on[code]
      if n ~= nil then
        local has = #(((found[line] or {})[code]) or {})
        if n > has then
          stale[#stale + 1] = { file = file, line = line, stage = tostring(stage), code = code, count = n - has }
        elseif CLOSED[code] == true then
          out[#out + 1] = file .. ":" .. tostring(line) .. ": " .. code .. " is closed: the tree keeps this rule with no " ..
            "exceptions; a marker holds none of it, so fix the code"
        end
      end
    end
  end
  return { lines = out, unmarked = unmarked, stale = stale }
end

function Ceilings.over(file: string, errors: {Ceilings.Finding}, codes: {string}, pinned: {string: integer},
                       what: string, unpinned?: boolean): Ceilings.Held
  local out: mut {string} = {}
  local found: mut {string: integer} = {}
  local by_code: mut {string: mut {Ceilings.Finding}} = {}
  for _, e in ipairs(errors) do
    local held = by_code[e.code] or {}
    held[#held + 1] = e
    by_code[e.code] = held
  end
  for _, code in ipairs(codes) do
    local list = by_code[code]
    if list ~= nil then
      local key = file .. " " .. code
      found[key] = #list
      local limit = pinned[key] or 0
      if #list > limit then
        for _, e in ipairs(list) do
          out[#out + 1] = file .. ":" .. tostring(e.y) .. ":" .. tostring(e.x) .. ": " .. e.msg .. " (" .. code .. "): " ..
            e.fix
        end
        local tail = "; follow the fix above"
        if unpinned ~= true then
          tail = ", pinned " .. tostring(limit) .. tail .. " rather than raise the pin"
        end
        out[#out + 1] = file .. ": " .. String.counted(#list, "error") .. " of " .. code .. " in its " .. what .. tail
      end
    end
  end
  return { lines = out, found = found }
end

function Ceilings.fallen(found: {string: integer}, pinned: {string: integer}, where: string): {string}
  local out: mut {string} = {}
  local keys: mut {string} = {}
  for key in pairs(pinned) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local count = found[key] or 0
    local limit = pinned[key]
    if limit ~= nil and count < limit then
      out[#out + 1] = key .. ": pinned " .. tostring(limit) .. " but " .. tostring(count) .. " found; lower the pin in " ..
        where
    end
  end
  return out
end

return Ceilings
