--- Decides, for each interpolation of an `html` template, where its
--- value lands (text, a quoted attribute value, a quoted URL), by walking
--- the tree in the order the output is written and feeding the literal
--- text it passes to [`markup`]'s tokenizer. Private to
--- [`cosmic.template`].
---
--- A slot's place must not depend on which branch ran. The arms of an
--- `if` or `with` (counting the arm that is missing when there is no
--- `else`) must leave the markup in the same place, and the body of a
--- `range` where it found it, since the next slot, or the next time round
--- the loop, is judged from there: `{{if .a}}<b class="{{else}}<i class="{{end}}`
--- is refused at the `{{if}}` rather than guessed at.

local markup = require("cosmic.template.markup")
local types = require("cosmic.template.types")

--- `name:line:col: reason`.
local function refuse(name: string, line: integer, col: integer, reason: string): string
  return name .. ":" .. line .. ":" .. col .. ": " .. reason
end

local walk: function(name: string, body: {types.Node}, from: markup.Place): markup.Place | nil, string

--- The place after the block `node`, whose arms start at `from`.
local function block(name: string, node: types.Node, from: markup.Place): markup.Place | nil, string
  local ends: {markup.Place} = {}
  local closed = false
  for _, arm in ipairs(node.branches) do
    local after, why = walk(name, arm.body, from)
    if after == nil then
      return nil, why
    end
    ends[#ends + 1] = after
    closed = closed or arm.pipeline == nil
  end
  if node.kind == "range" or not closed then
    ends[#ends + 1] = from
  end
  for _, place in ipairs(ends) do
    if markup.same(place, ends[1]) then
      markup.join(ends[1], place)
    else
      local what = node.kind == "range" and "the body of this {{range}} ends where it did not begin" or
        "the arms of this {{" .. node.kind .. "}} end in different places in the HTML"
      return nil, refuse(name, node.line, node.col, what ..
          " (a tag, attribute or comment is left open in one way and not another)")
    end
  end
  return ends[1], ""
end

walk = function(name: string, body: {types.Node}, from: markup.Place): markup.Place | nil, string
  local at = markup.copy(from)
  for _, node in ipairs(body) do
    if node.kind == "text" then
      markup.feed(at, node.text)
      if at.colon then
        return nil, refuse(name, node.line, node.col,
          "text after a URL slot, before its first / ? or #, holds a ':' and could complete a scheme")
      elseif at.late ~= "" then
        return nil, refuse(name, at.meta_line, at.meta_col, at.late)
      end
    elseif node.kind == "interp" then
      local slot, why = markup.slot(at)
      if slot == nil then
        return nil, refuse(name, node.line, node.col, why)
      end
      node.ctx = slot
      markup.wrote(at, slot, node.line, node.col)
    else
      local after, why = block(name, node, at)
      if after == nil then
        return nil, why
      end
      at = after
    end
  end
  return at, ""
end

local record Context
end

--- Sets `ctx` on every interpolation of `template`, or refuses the first
--- slot that has no escaping.
--- @param template types.Template The tree, changed in place
--- @param name string The template's name, for messages
--- @return boolean True when every slot has a place
--- @return string The reason, as `name:line:col: ...`, on a refusal
function Context.annotate(template: types.Template, name: string): boolean, string
  if template.mode == "text" then
    return true, ""
  end
  local after, why = walk(name, template.body, markup.start())
  if after == nil then
    return false, why
  end
  return true, ""
end

return Context
