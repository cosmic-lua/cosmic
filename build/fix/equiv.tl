--- Whether two parses mean the same thing.
---
--- A renderer checked only against a golden string, or against itself
--- run twice, would be shown consistent, not right: `local x <const> = 5`
--- re-emitted as `local x < const > = 5` is stable, idempotent and
--- wrong. So `cosmic fix` reparses what it wrote and compares the two
--- trees here, field by field, ignoring only what a rewrite may move.
---
--- Ignored: a node's position (`y`, `x`, `yend`, `xend`), the filename
--- stamped on it, the type identifier tl hands out from a counter, and
--- the comments the parser attached to statements. Comments are
--- compared separately, off the token stream, where each appears
--- exactly once. Everything else is compared, including the fields a
--- type object carries, so a record body that lost a field or a
--- `<const>` that became something else is a difference.
---
--- `if_parent` is skipped rather than followed: an "if_block" node
--- points back at its enclosing "if" statement, a cycle. That statement
--- is compared anyway, from the top.
---
--- The walk keeps a set of pairs, one before-side table with the
--- after-side table it is compared against, not a set of before-side
--- tables. A cycle still terminates, since coming back around brings
--- the same pair, but a table reached by two different routes is
--- compared once against each thing the other tree holds there. tl's
--- parser output is not a tree: `local record Node is {Node}` in
--- `build/ast/node.tl` yields the same type object as the record's
--- element type and as its interface list's. Keyed on the before side
--- alone, what the after tree held at the end of the second route would
--- go unchecked, and a renderer that changed it would pass.

local ast = require("build.ast")
local type compiler = require("build.compiler")

local type Node = ast.Node

--- Fields that say where something was, not what it is.
local positional: {string:boolean} = {
  ["y"] = true,
  ["x"] = true,
  ["yend"] = true,
  ["xend"] = true,
  ["f"] = true,
  ["typeid"] = true,
  ["comments"] = true,
  ["if_parent"] = true,
}

local function is_table(v: any): boolean
  return v is {any:any}
end

local function as_map(v: any): {any:any}
  if v is {any:any} then
    return v
  end
  return {}
end

--- The pairs already under comparison, the before side keying a set of
--- the after sides it has been held against.
local type Pairs = {any:{any:boolean}}

local compare: function(any, any, string, Pairs): boolean, string

local function has_metadata(t: {any:any}): boolean
  -- Parser nodes, types, operators, and comments carry positions. Field
  -- maps carry type objects, even under names such as kind or typename.
  local kind, typename, op, text = t["kind"], t["typename"], t["op"], t["text"]
  return kind is string or typename is string or op is string or text is string
end

--- The keys worth comparing on one table, both sides' keys together.
local function keys_of(a: {any:any}, b: {any:any}): {any}
  local metadata = has_metadata(a) and has_metadata(b)
  local seen: {any:boolean} = {}
  local out: {any} = {}
  for k in pairs(a) do
    if not metadata or not (k is string) or not positional[k] then
      seen[k] = true
      out[#out + 1] = k
    end
  end
  for k in pairs(b) do
    if not seen[k] and (not metadata or not (k is string) or not positional[k]) then
      out[#out + 1] = k
    end
  end
  return out
end

compare = function(a: any, b: any, path: string,
                   seen: Pairs): boolean, string
  if is_table(a) ~= is_table(b) then
    return false, path .. ": one side is a node and the other is not"
  end
  if not is_table(a) then
    if a ~= b then
      return false, path .. ": " .. tostring(a) .. " became " .. tostring(b)
    end
    return true, ""
  end
  local against = seen[a]
  if against == nil then
    against = {}
    seen[a] = against
  elseif against[b] then
    return true, ""
  end
  against[b] = true
  local ma, mb = as_map(a), as_map(b)
  for _, k in ipairs(keys_of(ma, mb)) do
    local ok, why = compare(ma[k], mb[k], path .. "." .. tostring(k), seen)
    if not ok then
      return false, why
    end
  end
  return true, ""
end

--- Whether `before` and `after` are the same tree once positions are
--- set aside.
--- @param before Node
--- @param after Node
--- @return boolean
--- @return string What differs, when they are not the same
local function same_tree(before: Node, after: Node): boolean, string
  return compare(before, after, "ast", {})
end

--- Every comment one parse carries, in source order.
--- @param tokens {compiler.Token}
--- @return {string}
local function comments(tokens: {compiler.Token}): {string}
  local out: {string} = {}
  for _, t in ipairs(tokens) do
    local carried = t.comments
    if carried ~= nil then
      for _, c in ipairs(carried) do
        out[#out + 1] = c.text
      end
    end
  end
  return out
end

--- Whether both parses carry the same comments in the same order.
--- @param before {compiler.Token}
--- @param after {compiler.Token}
--- @return boolean
--- @return string What differs, when they do not
local function same_comments(before: {compiler.Token},
                             after: {compiler.Token}): boolean, string
  local was, now = comments(before), comments(after)
  if #was ~= #now then
    return false, "had " .. #was .. " comments, now has " .. #now
  end
  for i, text in ipairs(was) do
    if now[i] ~= text then
      return false, "comment " .. i .. ": " .. text .. " became " .. now[i]
    end
  end
  return true, ""
end

local record EquivModule
  same_tree: function(before: Node, after: Node): boolean, string
  comments: function(tokens: {compiler.Token}): {string}
  same_comments: function(before: {compiler.Token},
                          after: {compiler.Token}): boolean, string
end

local M: EquivModule = {
  same_tree = same_tree,
  comments = comments,
  same_comments = same_comments,
}

return M
