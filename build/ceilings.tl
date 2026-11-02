--- The ceilings of the new checker: what of the checker's findings the tree still holds, per stage.
---
--- Every stage (`scoped`, `declared`, `untyped`, `checked`) is held by MARKERS: each finding it still makes is held by a comment
--- on the line it is reported at (`-- checked: map_field`, [`build.markers`]), so that a change that removes code moves or
--- deletes the markers with it and touches no shared file. [`Ceilings.marked`] judges a file against its markers: a finding
--- with no marker on its line is refused, by a compile of the module and by the check of the tree, and a marker whose finding
--- is gone is stale, which the check of the tree tells and `cosmic fix` removes. The markers only fall: [`build.ceilings_base`]
--- holds each file's count of each code to the file at the merge base with main. A code that no marker holds is closed
--- ([`Ceilings.closed`]): no marker holds it, so the tree keeps its rule with no exceptions.
---
--- [`build/ceilings.txt`] only says so: its one section, `[marked]`, lists exactly those four stages, and [`Ceilings.parse`]
--- refuses any other text. A row, or a section of rows (`[checked]`), is refused for every stage, since a count held in a
--- shared file is the way a finding got past the markers: a stage cannot be taken out of the list and given rows.
--- The examples a reader copies ([`build.example_checks`]) are held by markers in the example files, which are part of the
--- text shown, and the Teal under `ci/testdata` by none (every finding fails).
---
--- A count that a caller passes of its own (a table of [`Ceilings.Table`]'s `stages`) is still judged by [`Ceilings.over`], which
--- the tests of the checks use.
local Fs = require("cosmic.fs")
local Markers = require("build.markers")
local String = require("cosmic.string")

local record Ceilings
  --- The stages a ceiling may name, in the order of the file.
  enum Stage
    "scoped"
    "declared"
    "untyped"
    "checked"
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

  --- The ceilings `text` holds, or nil and what is wrong with it: it must list exactly the stages markers hold under
  --- `[marked]` (and no other section, nor a row of any stage, nor a line of no section).
  parse: function(text: string): Table?, string

  --- The codes that no file may be pinned for: each has no row left in any stage, so the tree keeps its rule with no
  --- exceptions. It is a list and not "every code that has no row", because a file that gives a row to such a code
  --- would be the row: only a list stays closed against the text it is asked to judge. The list is held to its
  --- meaning by [`build/ceilings_test.tl`]: a code of a stage with no row must be listed, so that the change that removes
  --- a code's last row closes it, and a listed code must be a code of some stage. A new code of a stage starts with no
  --- row, so it is listed with the change that adds it.
  closed: function(): {string}

  --- The ceilings of the tree at `root` ([`Ceilings.path`]).
  read: function(root: string): Table?, string

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

--- The stages that markers hold, in the order of the file.
local MARKABLE_LIST <const>: {Ceilings.Stage} = { "scoped", "declared", "untyped", "checked" }

local MARKABLE: mut {string: boolean} = {}
for _, stage in ipairs(MARKABLE_LIST) do
  MARKABLE[tostring(stage)] = true
end

function Ceilings.parse(text: string): Ceilings.Table?, string
  local marked: mut {string: boolean} = {}
  local out: Ceilings.Table = { stages = {}, none = nil, marked = marked }
  local listing = false
  local listed = false
  local number = 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    number = number + 1
    local at = Ceilings.path .. ":" .. tostring(number) .. ": "
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local name = line:match("^%[([a-z]+)%]$")
      if name == "marked" then
        if listed then
          return nil, at .. "[marked] is listed twice"
        end
        listing = true
        listed = true
      elseif name ~= nil then
        return nil, at .. "[" .. name .. "] is no section of this file: every stage is held by markers, and a row of counts " ..
          "would hold a finding no marker holds; fix the finding or mark its line"
      elseif listing and line:match("^[a-z ]+$") ~= nil then
        for word in line:gmatch("%S+") do
          if MARKABLE[word] ~= true then
            return nil, at .. "`" .. word .. "` is no stage that markers hold; [marked] lists " ..
              table.concat(MARKABLE_LIST, ", ")
          end
          marked[word] = true
        end
      elseif listing then
        return nil, at .. "[marked] lists stages by name, not `" .. line .. "`"
      else
        return nil, at .. "a line before [marked], or a row of counts: every stage is held by markers, so this file has no row"
      end
    end
  end
  for _, stage in ipairs(MARKABLE_LIST) do
    if marked[tostring(stage)] ~= true then
      return nil, Ceilings.path .. ": [marked] must list every stage that markers hold, " ..
        table.concat(MARKABLE_LIST, ", ") .. "; `" .. tostring(stage) .. "` is missing, and a stage not listed could be given rows"
    end
  end
  return out, ""
end

function Ceilings.read(root: string): Ceilings.Table?, string
  local text, why = Fs.read(root .. "/" .. Ceilings.path)
  if text == nil then
    return nil, why
  end
  return Ceilings.parse(text)
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
