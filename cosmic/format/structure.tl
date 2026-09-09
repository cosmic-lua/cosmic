--- Project parsed syntax ranges onto formatter tokens.
---
--- Teal type syntax is not an expression Node. cosmic.ast.source owns
--- those occurrences and their roles; this module turns their byte ranges
--- into the small token flags the established emitter needs.

local source = require("cosmic.ast.source")
local ftypes = require("cosmic.format.types")

local type Item = ftypes.Item
local type Range = source.Range
local type Snapshot = source.Snapshot

local record Span
  start_byte: integer
  end_byte: integer
end

local function merged_spans(values: {any}, type_ranges?: boolean): {Span}
  local spans: {Span} = {}
  for _, value in ipairs(values) do
    local fields = value as {string: any} -- cast: all indexed syntax records own .range
    local include = true
    if type_ranges then
      local raw = fields["value"] as {string: any} -- cast: TypeSyntax value contract
      local typename = raw["typename"]
      -- Teal represents a record/interface declaration itself as its outer
      -- type value. Its range spans the declaration body, including the
      -- real block-opening keyword and `end`; nested field records below
      -- carry the exact ranges that formatter rules need.
      include = typename ~= "record" and typename ~= "interface" and typename ~= "enum"
    end
    if include then
      local range = fields["range"] as Range -- cast: source index contract
      spans[#spans + 1] = {
        start_byte = range.start_byte,
        end_byte = range.end_byte,
      }
    end
  end
  table.sort(spans, function(a: Span, b: Span): boolean
    if a.start_byte ~= b.start_byte then return a.start_byte < b.start_byte end
    return a.end_byte < b.end_byte
  end)

  local merged: {Span} = {}
  for _, span in ipairs(spans) do
    local last = merged[#merged]
    if last and span.start_byte <= last.end_byte then
      if span.end_byte > last.end_byte then last.end_byte = span.end_byte end
    else
      merged[#merged + 1] = span
    end
  end
  return merged
end

local function is_inside(spans: {Span}, at: integer, cursor: integer): boolean, integer
  while spans[cursor] and at >= spans[cursor].end_byte do
    cursor = cursor + 1
  end
  local span = spans[cursor]
  return span ~= nil and at >= span.start_byte and at < span.end_byte, cursor
end

--- Attach syntax classifications to every item in one source-order pass.
--- @param snapshot Snapshot that owns the items
--- @param items Token/comment items built from snapshot.tokens
local function annotate(snapshot: Snapshot, items: {Item})
  local types = merged_spans(snapshot.types as {any}, true) -- cast: TypeSyntax records
  local attributes = merged_spans(snapshot.attributes as {any}) -- cast: same ranged record contract
  local generics = merged_spans(snapshot.generics as {any}) -- cast: same ranged record contract
  local ti, ai, gi = 1, 1, 1

  for _, item in ipairs(items) do
    local line_start = snapshot.line_starts[item.y]
    local at = line_start and line_start + item.x - 1 or #snapshot.source + 1
    local fields = item as {string: any} -- cast: private formatter metadata on Item
    fields["_start_byte"] = at
    fields["_syntax_classified"] = true
    if item.kind ~= "comment" then
      fields["_type_syntax"], ti = is_inside(types, at, ti)
      fields["_attribute_syntax"], ai = is_inside(attributes, at, ai)
      fields["_generic_syntax"], gi = is_inside(generics, at, gi)
    else
      fields["_type_syntax"] = false
      fields["_attribute_syntax"] = false
      fields["_generic_syntax"] = false
    end
  end

  -- A generic parameter list binds tightly at its outside edges and after
  -- its opening `<`; commas retain the established `T, U` house style.
  for i, item in ipairs(items) do
    local prev = items[i - 1]
    local fields = item as {string: any} -- cast: metadata initialized above
    local prev_generic = false
    if prev then
      local prev_fields = prev as {string: any} -- cast: same Item metadata
      prev_generic = prev_fields["_generic_syntax"] == true
    end
    if fields["_generic_syntax"] and (item.tk == "<" or item.tk == ">"
        or item.tk == ">>"
        or (prev and prev_generic and prev.tk == "<")) then
      fields["_tight_before"] = true
    elseif item.tk == "(" and prev and prev_generic
        and (prev.tk == ">" or prev.tk == ">>") then
      fields["_tight_before"] = true
    end
  end
end

local record StructureModule
  annotate: function(snapshot: Snapshot, items: {Item})
end

local M: StructureModule = {
  annotate = annotate,
}

return M
