--- What of the checker's findings the tree still holds, and how: by MARKERS, in every stage (`scoped`, `declared`, `untyped`,
--- `checked`). Each finding a stage still makes is held by a comment on the line it is reported at (`-- checked: map_field`,
--- [`build.markers`]), so that a change that removes code moves or deletes the markers with it and touches no shared file.
--- [`Ceilings.marked`] judges a file against its markers: a finding with no marker on its line is refused, by a compile of the
--- module and by the check of the tree, and a marker whose finding is gone is stale, which the check of the tree tells and
--- `cosmic fix` removes. The markers only fall: [`build.ceilings_base`] holds each file's count of each code to the file at the
--- merge base with main. A code that no marker holds is closed ([`Ceilings.closed`]): no marker holds it, so the tree keeps its
--- rule with no exceptions.
---
--- There is no file of counts: the stages are these four ([`Ceilings.Stage`]) and nothing configures them, so a stage cannot
--- be taken out of the list and given rows. A project outside cosmic's tree is held to no marker: every finding refuses.
local Markers = require("build.markers")
local String = require("cosmic.string")

local record Ceilings
  --- The stages whose findings the markers hold, in the order a comment writes them.
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

  --- The codes that no marker may hold: each has no marker left in any stage, so the tree keeps its rule with no exceptions.
  --- It is a list and not "every code that has no marker", because a marker for such a code would be the marker: only a list
  --- stays closed against the text it is asked to judge. The list is held to its meaning by [`build/ceilings_test.tl`] and
  --- the check of the tree ([`tree_checks.closure`]): a code of a stage with no marker must be listed, so that the change that
  --- removes a code's last marker closes it, and a listed code must be a code of some stage. A new code of a stage starts with
  --- no marker, so it is listed with the change that adds it.
  closed: function(): {string}

  --- The pseudo code of a call the checker gave no function ([`build.syntax_contracts`]'s `untyped`), the one finding of the
  --- stage `untyped`: a marker (`-- untyped: call`) names it as it names a code of the checker.
  mut untyped_code: string
  --- The words of that finding: what it is and what to do.
  mut untyped_message: string
  mut untyped_fix: string

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
  --- another stage is none of its business. `what` says where the errors are (`bodies`). With `markerless` (a project's, which
  --- no marker holds) the lines do not point to a marker.
  marked: function(stage: Stage, file: string, text: string, errors: {Finding}, codes: {string}, what: string,
                   markerless?: boolean): Judged
end

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

Ceilings.untyped_code = "call"
Ceilings.untyped_message = "a call the checker gave no function, which no rule of the discipline judged"
Ceilings.untyped_fix = "type what it calls through"

function Ceilings.marked(stage: Ceilings.Stage, file: string, text: string, errors: {Ceilings.Finding}, codes: {string},
                         what: string, markerless?: boolean): Ceilings.Judged
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
          if markerless ~= true then
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

return Ceilings
