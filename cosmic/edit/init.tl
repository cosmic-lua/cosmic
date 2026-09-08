--- Revision-bound, atomic source edit plans. This module changes source
--- bytes only; parsing and formatting remain explicit caller choices.
local source_mod = require("cosmic.ast.source")
local template_scan = require("cosmic.edit.template_scan")

local type Snapshot = source_mod.Snapshot
local type Range = source_mod.Range

local enum Applicability
  "safe"
  "suggested"
  "unsafe"
end

local record Edit
  source: Snapshot
  revision: string
  range: Range
  replacement: string
end

local record Fix
  title: string
  applicability: Applicability
  edits: {Edit}
end

local record ApplyResult
  code: string
  changed: boolean
  applied_edits: integer
end

local record ValidationResult
  application: ApplyResult
  parse: source_mod.ParseResult
end

local function owns_range(snapshot: Snapshot, wanted: Range): boolean
  return snapshot.owned_ranges[wanted] or false
end

local function valid_bounds(snapshot: Snapshot, range: Range): boolean
  return range.start_byte >= 1
  and range.end_byte >= range.start_byte
  and range.end_byte <= #snapshot.source + 1
end

--- Bind a replacement to one exact snapshot-owned range.
--- @param snapshot Snapshot Immutable source revision
--- @param range Range An identity-owned range returned by source APIs
--- @param replacement string Literal replacement bytes
--- @return Edit|nil Revision-bound edit, or nil for a foreign/invalid range
--- @return string Error message on failure
local function replace(snapshot: Snapshot, range: Range,
    replacement: string): Edit | nil, string
  if not valid_bounds(snapshot, range) then
    return nil, "edit range is outside its source revision"
  end
  if not owns_range(snapshot, range) then
    return nil, "edit range is not owned by its source revision"
  end
  return {
    source = snapshot,
    revision = snapshot.id,
    range = range,
    replacement = replacement,
  }, nil
end

--- Group edits that must be accepted or refused together.
local function fix(title: string, applicability: Applicability, edits: {Edit}): Fix
  return {title = title, applicability = applicability, edits = edits}
end

local function compare_edits(a: Edit, b: Edit): boolean
  if a.range.start_byte ~= b.range.start_byte then
    return a.range.start_byte < b.range.start_byte
  end
  if a.range.end_byte ~= b.range.end_byte then
    return a.range.end_byte < b.range.end_byte
  end
  return a.replacement < b.replacement
end

local function same_edit(a: Edit, b: Edit): boolean
  return a.range.start_byte == b.range.start_byte
  and a.range.end_byte == b.range.end_byte
  and a.replacement == b.replacement
end

--- Apply disjoint fixes in one ascending source assembly. Validation,
--- conflict checks, and deduplication finish before any output is built.
--- @param snapshot Snapshot Revision all edits must name
--- @param fixes {Fix} Atomic fix groups to combine
--- @param current_source string Optional just-read contents for stale guard
--- @return ApplyResult|nil Raw candidate and truthful unique edit count
--- @return string Error message on refusal
local function apply(snapshot: Snapshot, fixes: {Fix},
    current_source?: string): ApplyResult | nil, string
  if current_source and current_source ~= snapshot.source then
    return nil, "source changed since this edit plan was created"
  end
  local ordered: {Edit} = {}
  for _, group in ipairs(fixes) do
    for _, edit in ipairs(group.edits) do
      if edit.source ~= snapshot or edit.revision ~= snapshot.id then
        return nil, "edit belongs to a different source revision"
      end
      if not valid_bounds(snapshot, edit.range) or not owns_range(snapshot, edit.range) then
        return nil, "edit has a foreign or invalid source range"
      end
      local existing = snapshot.source:sub(edit.range.start_byte,
        edit.range.end_byte - 1)
      if existing ~= edit.replacement then
        ordered[#ordered + 1] = edit
      end
    end
  end
  table.sort(ordered, compare_edits)

  local unique: {Edit} = {}
  for _, edit in ipairs(ordered) do
    local previous = unique[#unique]
    if previous and same_edit(previous, edit) then
      -- Exact duplicates across rules are one edit and one count.
    elseif previous and (edit.range.start_byte < previous.range.end_byte
      or edit.range.start_byte == previous.range.start_byte) then
      return nil, "edit ranges overlap or conflict"
    else
      unique[#unique + 1] = edit
    end
  end

  local pieces: {string} = {}
  local at = 1
  for _, edit in ipairs(unique) do
    pieces[#pieces + 1] = snapshot.source:sub(at, edit.range.start_byte - 1)
    pieces[#pieces + 1] = edit.replacement
    at = edit.range.end_byte
  end
  pieces[#pieces + 1] = snapshot.source:sub(at)
  local code = table.concat(pieces)
  return {code = code, changed = code ~= snapshot.source, applied_edits = #unique}, nil
end

--- Apply and parse a raw candidate without formatting it. Parse issues
--- remain structured in `ValidationResult.parse`.
local function validate(snapshot: Snapshot, fixes: {Fix},
    current_source?: string): ValidationResult | nil, string
  local result, err = apply(snapshot, fixes, current_source)
  if not result then return nil, err end
  return {
    application = result,
    parse = source_mod.inspect(result.code, snapshot.name, snapshot.lang),
  }, nil
end

local record EditModule
  type Applicability = Applicability
  type Edit = Edit
  type Fix = Fix
  type ApplyResult = ApplyResult
  type ValidationResult = ValidationResult
  replace: function(Snapshot, Range, string): Edit | nil, string
  fix: function(string, Applicability, {Edit}): Fix
  apply: function(Snapshot, {Fix}, current_source?: string): ApplyResult | nil, string
  validate: function(Snapshot, {Fix}, current_source?: string): ValidationResult | nil, string
  instantiate: function(string, {string: string}): string, {string: integer}
end

local M: EditModule = {
  replace = replace,
  fix = fix,
  apply = apply,
  validate = validate,
  instantiate = template_scan.instantiate,
}

return M
