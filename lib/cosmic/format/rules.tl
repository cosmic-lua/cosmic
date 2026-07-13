--- Formatting rules and classification functions for the code formatter.
--- Contains lookup tables, token classifiers, and indent computation.

-- An item in the output stream: either a token or a comment.
-- An interface so the formatter's richer Item record (which caches
-- newline counts) subtypes it and the rule functions stay fully typed.
local interface Item
  y: integer
  x: integer
  tk: string
  kind: string
end

-- Block-opening keywords: indent after these.
local block_openers: {string: boolean} = {
  ["do"] = true,
  ["then"] = true,
  ["repeat"] = true,
  ["else"] = true,
}

-- Block-closing keywords: dedent before these.
local block_closers: {string: boolean} = {
  ["end"] = true,
  ["until"] = true,
}

-- Keywords that dedent then indent (same level as opening keyword).
local block_half_closers: {string: boolean} = {
  ["else"] = true,
  ["elseif"] = true,
}

-- Tokens that should NOT have a space before them.
local no_space_before: {string: boolean} = {
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
  [","] = true,
  [";"] = true,
  ["?"] = true,
}

-- Tokens that should NOT have a space after them.
local no_space_after: {string: boolean} = {
  ["("] = true,
  ["["] = true,
  ["{"] = true,
  ["#"] = true,
}

-- Tokens after which `-` is unary (not binary subtraction).
local unary_minus_after: {string: boolean} = {
  ["("] = true,
  ["["] = true,
  ["{"] = true,
  [","] = true,
  [";"] = true,
  ["="] = true,
  ["=="] = true,
  ["~="] = true,
  ["<"] = true,
  [">"] = true,
  ["<="] = true,
  [">="] = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  ["/"] = true,
  ["//"] = true,
  ["%"] = true,
  ["^"] = true,
  [".."] = true,
  ["|"] = true,
  ["&"] = true,
  ["~"] = true,
  ["<<"] = true,
  [">>"] = true,
}

-- Keywords after which `-` is unary.
local unary_minus_after_kw: {string: boolean} = {
  ["return"] = true,
  ["and"] = true,
  ["or"] = true,
  ["not"] = true,
  ["then"] = true,
  ["do"] = true,
  ["else"] = true,
  ["in"] = true,
}

--- Check if an item is a block-opening keyword.
local function is_block_opener(item: Item): boolean
  if item.kind == "keyword" and block_openers[item.tk] then
    return true
  end
  if item.kind == "identifier" and (item.tk == "record" or item.tk == "enum" or item.tk == "interface") then
    return true
  end
  return false
end

--- Check if an item is a block-closing keyword.
local function is_block_closer(item: Item): boolean
  return item.kind == "keyword" and (block_closers[item.tk] or false)
end

--- Check if an item is a half-closer (dedent then indent).
local function is_half_closer(item: Item): boolean
  return item.kind == "keyword" and (block_half_closers[item.tk] or false)
end

--- Check if a comment is a long comment.
local function is_long_comment(tk: string): boolean
  return tk:sub(1, 4) == "--[["
  or (tk:sub(1, 3) == "--[" and tk:sub(4, 4) == "=")
end

--- Determine if we need a space between two adjacent items on the same line.
local function needs_space(prev_prev: Item, prev: Item, cur: Item, next_item: Item): boolean
  if cur.kind == "comment" then
    return true
  end
  if prev.kind == "comment" then
    return true
  end
  if no_space_after[prev.tk] then
    return false
  end
  if cur.tk == "(" then
    if prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]"
    or prev.kind == "string" or (prev.kind == "keyword" and prev.tk == "function") then
      return false
    end
  end
  if cur.tk == "[" then
    if prev.kind == "identifier" or prev.tk == ")" or prev.tk == "]" then
      return false
    end
  end
  if no_space_before[cur.tk] then
    return false
  end
  if prev.tk == "." or cur.tk == "." then
    return false
  end
  if prev.tk == "::" or cur.tk == "::" then
    return false
  end
  if cur.tk == ":" then
    return false
  end
  if prev.tk == ":" then
    if cur.kind == "identifier" and next_item and next_item.tk == "(" then
      return false
    end
    return true
  end
  if prev.tk == "-" and prev.kind == "op" then
    if prev_prev == nil then
      return false
    end
    if unary_minus_after[prev_prev.tk] or (prev_prev.kind == "keyword" and unary_minus_after_kw[prev_prev.tk]) then
      return false
    end
  end
  return true
end

--- Determine if a `function` keyword is a block-opening function definition
--- vs a function TYPE annotation.
local function is_function_block_opener(line_items: {Item}, func_idx: integer): boolean
  -- `type X = function(...)` (optionally local/global-prefixed) declares a
  -- function TYPE alias: no body follows, so it never opens a block.
  -- Without this, everything after such an alias is indented into a
  -- phantom function body that no `end` ever closes.
  local first = line_items[1]
  local second = line_items[2]
  if first and (first.tk == "type"
    or ((first.tk == "local" or first.tk == "global")
      and second and second.tk == "type")) then
    return false
  end
  local paren_depth = 0
  for i = func_idx - 1, 1, -1 do
    local item = line_items[i]
    if item.kind == "comment" then
      -- skip
    elseif item.tk == ")" then
      paren_depth = paren_depth + 1
    elseif item.tk == "(" then
      if paren_depth > 0 then
        paren_depth = paren_depth - 1
      else
        return true
      end
    elseif paren_depth > 0 then
      -- Inside balanced parens; skip
    elseif item.tk == ":" or item.tk == "as" then
      return false
    elseif item.tk == "=" or item.tk == "," then
      return true
    elseif item.kind == "keyword" and (item.tk == "local" or item.tk == "return") then
      return true
    else
      -- Keep scanning
    end
  end
  return true
end

--- Compute the net indent change for all items on a line.
--- Returns (pre_change, post_change).
local function compute_indent_change(line_items: {Item}): integer, integer
  local pre_change = 0
  local post_change = 0

  local type_ctx: {integer: boolean} = {}
  for idx, item in ipairs(line_items) do
    if item.kind == "keyword" and item.tk == "function" and not type_ctx[idx] then
      if not is_function_block_opener(line_items, idx) then
        type_ctx[idx] = true
        local depth = 0
        local j = idx + 1
        while j <= #line_items do
          type_ctx[j] = true
          if line_items[j].tk == "(" then
            depth = depth + 1
          elseif line_items[j].tk == ")" then
            depth = depth - 1
            if depth == 0 then
              j = j + 1
              break
            end
          end
          j = j + 1
        end
        if j <= #line_items and line_items[j].tk == ":" then
          type_ctx[j] = true
          j = j + 1
          if j <= #line_items and line_items[j].tk == "(" then
            depth = 0
            while j <= #line_items do
              type_ctx[j] = true
              if line_items[j].tk == "(" then
                depth = depth + 1
              elseif line_items[j].tk == ")" then
                depth = depth - 1
                if depth == 0 then
                  break
                end
              end
              j = j + 1
            end
          end
        end
      end
    end
  end

  local first_code: Item = nil
  for _, item in ipairs(line_items) do
    if item.kind ~= "comment" then
      first_code = item
      break
    end
  end

  if first_code then
    if is_block_closer(first_code) or is_half_closer(first_code) then
      pre_change = pre_change - 1
    end
    if first_code.tk == "}" or first_code.tk == ")" then
      pre_change = pre_change - 1
    end
  end

  local is_first_code = true
  for idx, item in ipairs(line_items) do
    if item.kind == "comment" then
      -- skip
    elseif type_ctx[idx] then
      is_first_code = false
    else
      if is_block_opener(item) then
        post_change = post_change + 1
      elseif item.tk == "{" or item.tk == "(" then
        post_change = post_change + 1
      elseif item.kind == "keyword" and item.tk == "function" then
        if is_function_block_opener(line_items, idx) then
          post_change = post_change + 1
        end
      end

      if not is_first_code then
        if is_block_closer(item) or is_half_closer(item) then
          post_change = post_change - 1
        end
        if item.tk == "}" or item.tk == ")" then
          post_change = post_change - 1
        end
      end

      is_first_code = false
    end
  end

  return pre_change, post_change
end

local record FormatRulesModule
  type Item = Item
  is_long_comment: function(tk: string): boolean
  needs_space: function(prev_prev: Item, prev: Item, cur: Item, next_item: Item): boolean
  compute_indent_change: function(line_items: {Item}): integer, integer
end

local M: FormatRulesModule = {}
M.is_long_comment = is_long_comment
M.needs_space = needs_space
M.compute_indent_change = compute_indent_change

return M
