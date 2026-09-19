--- Whether two parses mean the same thing.
---
--- A renderer that only ever checked its own output against a golden
--- string, or against itself run twice, would be checking that it is
--- CONSISTENT, not that it is right: `local x <const> = 5` re-emitted
--- as `local x < const > = 5` is stable, idempotent, and wrong. So
--- `cosmic fix` reparses what it wrote and compares the two trees here,
--- field by field, ignoring only what a rewrite is allowed to move.
---
--- What is ignored: a node's own position (`y`, `x`, `yend`, `xend`),
--- the filename stamped on it, the type identifier tl hands out from a
--- counter, and the comments the parser attached to statements -- those
--- are compared separately, off the token stream, where every comment
--- in the file appears exactly once. What is compared: everything else,
--- including the fields a type object carries, so a record body that
--- lost a field or a `<const>` that became something else is a
--- difference.
---
--- `if_parent` is skipped rather than followed: an "if_block" node
--- points back at its own enclosing "if" statement, a real cycle. The
--- enclosing statement is compared anyway, from the top.

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

local compare: function(any, any, string, {any:boolean}): boolean, string

--- The keys worth comparing on one table, both sides' keys together.
local function keys_of(a: {any:any}, b: {any:any}): {any}
  local seen: {any:boolean} = {}
  local out: {any} = {}
  for k in pairs(a) do
    if not (k is string) or not positional[k] then
      seen[k] = true
      out[#out + 1] = k
    end
  end
  for k in pairs(b) do
    if not seen[k] and (not (k is string) or not positional[k]) then
      out[#out + 1] = k
    end
  end
  return out
end

compare = function(a: any, b: any, path: string,
                   seen: {any:boolean}): boolean, string
  if is_table(a) ~= is_table(b) then
    return false, path .. ": one side is a node and the other is not"
  end
  if not is_table(a) then
    if a ~= b then
      return false, path .. ": " .. tostring(a) .. " became " .. tostring(b)
    end
    return true, ""
  end
  if seen[a] then
    return true, ""
  end
  seen[a] = true
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
