--- Decides, for each interpolation of an `html` template, where its
--- value lands (text, a quoted attribute value, a quoted URL), by walking
--- the tree in the order the output is written and feeding the literal
--- text it passes to [`markup`]'s tokenizer. Private to
--- [`cosmic.template`].
---
--- A slot's place must not depend on which branch ran. The arms of an
--- `if` or `with` (counting the arm that is missing when there is no
--- `else`) must leave the markup in the same place; the body of a
--- `range` must leave it where it found it (walked a second time, from the
--- join of the two, as the loop runs again), and a range's `else`, which
--- runs in place of the first time round, where the body does. The next
--- slot, or the next time round the loop, is judged from there:
--- `{{if .a}}<b class="{{else}}<i class="{{end}}` is refused at the `{{if}}`
--- rather than guessed at.

local markup = require("cosmic.template.markup")
local types = require("cosmic.template.types")

--- `name:line:col: reason`.
local function refuse(name: string, line: integer, col: integer, reason: string): string
  return name .. ":" .. line .. ":" .. col .. ": " .. reason
end

--- The place a walk last gave each interpolation it reached.
local type Marks = {types.Node: types.Slot}

--- What a walk of a block from one place found: the place after it, or the
--- refusal, and the place it last gave each interpolation inside it.
local record Outcome
  after: markup.Place
  why: string
  marks: Marks
end

--- What the walks of one template share: its name, and each block's
--- outcome from each place it was walked from, by [`Markup.key`].
local record Walk
  name: string
  seen: {types.Node: {string: Outcome}}
end

--- How two places that `same` found different differ, for a message.
local function difference(a: markup.Place, b: markup.Place): string
  local raw = markup.differ(a, b)
  return raw ~= "" and " (" .. raw .. ")" or " (a tag, attribute or comment is left open in one way and not another)"
end

local walk: function(w: Walk, body: {types.Node}, from: markup.Place, marks: Marks): markup.Place | nil, string

--- The place after the `range` `node`, which begins at `from`.
local function range_after(w: Walk, node: types.Node, from: markup.Place, marks: Marks): markup.Place | nil, string
  local body = node.branches[1].body
  local loop, why = walk(w, body, from, marks)
  if loop == nil then
    return nil, why
  end
  local function differs(place: markup.Place): string
    return refuse(w.name, node.line, node.col, "the body of this {{range}} ends where it did not begin" ..
        difference(place, from))
  end
  if not markup.same(loop, from) then
    return nil, differs(loop)
  end
  -- The body runs again from where it ended: a URL value it began is no
  -- longer fresh, and text it ended after a URL slot is still watched.
  -- The second walk, from the two joined, finds what a third would.
  markup.join(loop, from)
  local again, again_why = walk(w, body, loop, marks)
  if again == nil then
    return nil, again_why
  end
  if not markup.same(again, from) then
    return nil, differs(again)
  end
  markup.join(loop, again)
  local other = node.branches[2]
  if other ~= nil then
    -- The else arm runs once, in place of the first time round.
    local alternative, other_why = walk(w, other.body, from, marks)
    if alternative == nil then
      return nil, other_why
    end
    if not markup.same(alternative, from) then
      return nil, refuse(w.name, node.line, node.col, "the arms of this {{range}} end in different places in the HTML" ..
          difference(alternative, from))
    end
    markup.join(loop, alternative)
  end
  return loop, ""
end

--- The place after the `if` or `with` `node`, whose arms start at `from`.
local function arms_after(w: Walk, node: types.Node, from: markup.Place, marks: Marks): markup.Place | nil, string
  local ends: {markup.Place} = {}
  local closed = false
  for _, arm in ipairs(node.branches) do
    local after, why = walk(w, arm.body, from, marks)
    if after == nil then
      return nil, why
    end
    ends[#ends + 1] = after
    closed = closed or arm.pipeline == nil
  end
  if not closed then
    ends[#ends + 1] = from
  end
  for _, place in ipairs(ends) do
    if not markup.same(place, ends[1]) then
      return nil, refuse(w.name, node.line, node.col, "the arms of this {{" .. node.kind ..
          "}} end in different places in the HTML" .. difference(place, ends[1]))
    end
    markup.join(ends[1], place)
  end
  return ends[1], ""
end

--- The place after the block `node`, which begins at `from`. A block is
--- walked once from each place: a range walks its body twice, so walking
--- again from a place already seen would take time exponential in how deep
--- ranges nest. A walk not taken again still sets the places it set on
--- its interpolations, as taking it again would.
local function block(w: Walk, node: types.Node, from: markup.Place, marks: Marks): markup.Place | nil, string
  local outcomes = w.seen[node]
  if outcomes == nil then
    outcomes = {}
    w.seen[node] = outcomes
  end
  local at = markup.key(from)
  local outcome = outcomes[at]
  if outcome == nil then
    local own: Marks = {}
    local after, why: markup.Place, string
    if node.kind == "range" then
      after, why = range_after(w, node, from, own)
    else
      after, why = arms_after(w, node, from, own)
    end
    outcome = { after = after, why = why, marks = own }
    outcomes[at] = outcome
  end
  for interp, ctx in pairs(outcome.marks) do
    interp.ctx = ctx
    marks[interp] = ctx
  end
  if outcome.after == nil then
    return nil, outcome.why
  end
  return markup.copy(outcome.after), ""
end

walk = function(w: Walk, body: {types.Node}, from: markup.Place, marks: Marks): markup.Place | nil, string
  local name = w.name
  local at = markup.copy(from)
  for _, node in ipairs(body) do
    if node.kind == "text" then
      markup.feed(at, node.text)
      if at.colon then
        return nil, refuse(name, node.line, node.col,
          "text after a URL slot, before its first / ? or #, holds a ':' and could complete a scheme")
      elseif at.rooted then
        return nil, refuse(name, node.line, node.col,
          "text after a URL slot begins with '/' or '\\': the value and that text could make a protocol-relative URL (//host)")
      elseif at.late ~= "" then
        return nil, refuse(name, at.late_line, at.late_col, at.late)
      end
    elseif node.kind == "interp" then
      local slot, why = markup.slot(at)
      if slot == nil then
        return nil, refuse(name, node.line, node.col, why)
      end
      node.ctx = slot
      marks[node] = slot
      markup.wrote(at, slot, node.line, node.col)
    else
      local after, why = block(w, node, at, marks)
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
--- @param end_line integer The line the template's source ends on
--- @param end_col integer The column just after its last byte
--- @return boolean True when every slot has a place
--- @return string The reason, as `name:line:col: ...`, on a refusal
function Context.annotate(template: types.Template, name: string, end_line: integer, end_col: integer): boolean, string
  if template.mode == "text" then
    return true, ""
  end
  local after, why = walk({ name = name, seen = {} }, template.body, markup.start(), {})
  if after == nil then
    return false, why
  end
  local open = markup.ending(after)
  if open ~= "" then
    return false, refuse(name, end_line, end_col,
      "the template ends " .. open .. ": it would put what follows it in another template into that place")
  end
  return true, ""
end

return Context
