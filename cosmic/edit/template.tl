--- Typed expression and type replacement templates over source snapshots.
local edit = require("cosmic.edit")
local scan = require("cosmic.edit.template_scan")
local source_mod = require("cosmic.ast.source")
local walk = require("cosmic.ast.walk")

local type Edit = edit.Edit
local type Node = source_mod.Node
local type Range = source_mod.Range
local type Snapshot = source_mod.Snapshot
local type TypeSyntax = source_mod.TypeSyntax

local expression_kinds: {string: boolean} = {
  op = true, literal_table = true, ["function"] = true, paren = true,
  variable = true, ["nil"] = true, string = true, boolean = true,
  integer = true, number = true, ["..."] = true,
}

local function slice(snapshot: Snapshot, range: Range): string
  return snapshot.source:sub(range.start_byte, range.end_byte - 1)
end

local function grouped_expression(snapshot: Snapshot, node: Node,
    range: Range): string
  local text = slice(snapshot, range)
  if node.kind == "op" then
    local op = node.op
    if op and op.op ~= "@funcall" and op.op ~= "@method" and op.op ~= "@index" then
      return "(" .. text .. ")"
    end
  end
  return text
end

local function is_effectful(node: Node): boolean
  local effectful = false
  walk.walk(node, function(child: Node)
      if child.kind == "op" then
        local op = child.op
        if op and (op.op == "@funcall" or op.op == "@method") then
          effectful = true
        end
      end
    end)
  return effectful
end

local function offset(snapshot: Snapshot, line: integer, column: integer): integer
  local start = snapshot.line_starts[line]
  if not start then return #snapshot.source + 1 end
  return math.min(start + math.max(column, 1) - 1, #snapshot.source + 1)
end

local function contains(range: Range, byte: integer): boolean
  return byte >= range.start_byte and byte < range.end_byte
end

local function preserves_comments(snapshot: Snapshot, target: Range,
    kept: {Range}): boolean
  for _, token in ipairs(snapshot.tokens) do
    if token.comments then
      for _, comment in ipairs(token.comments) do
        local byte = offset(snapshot, comment.y, comment.x)
        if contains(target, byte) then
          local preserved = false
          for _, range in ipairs(kept) do
            if contains(range, byte) then preserved = true break end
          end
          if not preserved then return false end
        end
      end
    end
  end
  return true
end

local function valid_expression(text: string, snapshot: Snapshot): boolean, string
  local _, err = source_mod.parse(
    "local __cosmic_template = (" .. text .. ")\n",
    snapshot.name .. ".expression-template", snapshot.lang)
  if err then return false, "invalid expression template: " .. err end
  return true, nil
end

--- Build an expression edit. Every capture must belong to the same
--- snapshot. Effectful captures must occur exactly once, and comments
--- in the replaced region must remain inside a reused capture.
local function replace_expression(snapshot: Snapshot, target: Node,
    template: string, captures: {string: Node}): Edit | nil, string
  if not expression_kinds[target.kind] then
    return nil, "replacement target is not an expression"
  end
  local target_range, target_err = source_mod.range(snapshot, target)
  if not target_range then return nil, target_err end

  local values: {string: string} = {}
  local ranges: {string: Range} = {}
  for name, capture in pairs(captures) do
    local range, range_err = source_mod.range(snapshot, capture)
    if not range then return nil, "foreign expression capture: " .. range_err end
    ranges[name] = range
    values[name] = grouped_expression(snapshot, capture, range)
  end
  local replacement, uses = scan.instantiate(template, values)
  local kept: {Range} = {}
  for name, capture in pairs(captures) do
    local count = uses[name] or 0
    if is_effectful(capture) and count ~= 1 then
      return nil, "effectful expression capture must be used exactly once"
    end
    if count > 0 then kept[#kept + 1] = ranges[name] end
  end
  if not preserves_comments(snapshot, target_range, kept) then
    return nil, "expression replacement would drop comments"
  end
  local valid, valid_err = valid_expression(replacement, snapshot)
  if not valid then return nil, valid_err end
  return edit.replace(snapshot, target_range, replacement)
end

local function valid_type(text: string, snapshot: Snapshot): boolean, string
  if snapshot.lang ~= "tl" then return false, "type templates require Teal source" end
  local _, err = source_mod.parse(
    "local __cosmic_template: " .. text .. " = nil\n",
    snapshot.name .. ".type-template", "tl")
  if err then return false, "invalid type template: " .. err end
  return true, nil
end

local function owns_type(snapshot: Snapshot, wanted: TypeSyntax): boolean
  for _, typ in ipairs(snapshot.types) do
    if typ == wanted then return true end
  end
  return false
end

--- Build a type-syntax edit. Type captures are distinct from expression
--- nodes and union captures are grouped before insertion.
local function replace_type(snapshot: Snapshot, target: TypeSyntax,
    template: string, captures: {string: TypeSyntax}): Edit | nil, string
  if not owns_type(snapshot, target) then
    return nil, "replacement target is foreign type syntax"
  end
  local values: {string: string} = {}
  local ranges: {string: Range} = {}
  for name, capture in pairs(captures) do
    if not owns_type(snapshot, capture) then
      return nil, "foreign type capture"
    end
    local text = slice(snapshot, capture.range)
    values[name] = text:find("|", 1, true) and "(" .. text .. ")" or text
    ranges[name] = capture.range
  end
  local replacement, uses = scan.instantiate(template, values)
  local kept: {Range} = {}
  for name, range in pairs(ranges) do
    if (uses[name] or 0) > 0 then kept[#kept + 1] = range end
  end
  if not preserves_comments(snapshot, target.range, kept) then
    return nil, "type replacement would drop comments"
  end
  local valid, valid_err = valid_type(replacement, snapshot)
  if not valid then return nil, valid_err end
  return edit.replace(snapshot, target.range, replacement)
end

local record TemplateModule
  replace_expression: function(Snapshot, Node, string,
  {string: Node}): Edit | nil, string
  replace_type: function(Snapshot, TypeSyntax, string,
  {string: TypeSyntax}): Edit | nil, string
end

local M: TemplateModule = {
  replace_expression = replace_expression,
  replace_type = replace_type,
}

return M
