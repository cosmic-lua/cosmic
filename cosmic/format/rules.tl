--- Formatting rules and classification functions for the code formatter.
--- Contains lookup tables, token classifiers, and indent computation.
---
--- Whether a token belongs to a TYPE rather than to code lives next
--- door in `format/types.tl`: that question depends on what the
--- previous line left open, and everything here is decidable from the
--- tokens in front of it.

local ftypes = require("cosmic.format.types")

-- The token-stream contract, defined once next door and imported here.
-- Two declarations of the same shape are two NOMINAL types to Teal, so
-- a line's items could not be passed across the seam -- and `types.tl`
-- is where it lives because it is the module underneath this one.
local type Item = ftypes.Item

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

--- Teal's type-declaration keywords. They are IDENTIFIERS to the lexer
--- (Teal keeps them usable as names), so the scanner has to decide from
--- context whether one opens a block.
local type_decl_kw: {string: boolean} = {
  ["record"] = true,
  ["enum"] = true,
  ["interface"] = true,
}

--- Check if an item is a block-opening keyword.
---
--- `next_item` is what disambiguates the type-declaration words, and it
--- is not optional politeness. `record` is a perfectly ordinary table
--- key, and `record = {…},` inside a table constructor is a KEY
--- followed by `=` -- not a declaration opening a block that never
--- closes. Read as an opener it indents every following line one level
--- deeper, forever, and because the result is idempotent the format
--- gate passes on its own damage: the `-c` vocabulary's `test` verb was
--- renamed to `record`, and two files silently acquired an extra level
--- from that line down with `--make fmt` reporting PASS.
---
--- The same shape reaches `enum` and `interface`, which are equally
--- legal keys — and it reaches ACCESS and CALL positions too:
--- `work.record(args)` is a field access followed by a call, found
--- the day the `-c` verbs moved behind a module named for them, and
--- read as an opener it cascaded an extra indent per call, forever,
--- with the gate passing on its own idempotent damage again.
--- @param item Item The token to test
--- @param next_item Item The token after it, nil at end of line
--- @param prev_item Item The token before it, nil at start of line
--- @return boolean Whether it opens a block
local function is_block_opener(item: Item, next_item: Item,
    prev_item: Item): boolean
  if item.kind == "keyword" and block_openers[item.tk] then
    return true
  end
  if item.kind == "identifier" and type_decl_kw[item.tk] then
    -- `record =` and `record:` are a table key and a field name;
    -- `record(`, `record,`, `record)` are a call and its arguments;
    -- `x.record` and `x:record` are member access. A declaration is
    -- `record Name` or `record` alone on the line.
    if next_item ~= nil and (next_item.tk == "=" or next_item.tk == ":"
      or next_item.tk == "(" or next_item.tk == ","
      or next_item.tk == ")") then
      return false
    end
    if prev_item ~= nil and (prev_item.tk == "." or prev_item.tk == ":") then
      return false
    end
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
    -- `as` is an OPERATOR the lexer hands back as an identifier (Teal
    -- keeps it usable as a name), so the callee rule below claims it and
    -- rewrites the parenthesized type `x as (T | nil)` to `x as(T | nil)`
    -- -- legal, and wrong about what the code is.
    if prev.tk == "as" then
      return true
    end
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
  -- `?` has two jobs in Teal, and the spacing rule differs. As a
  -- SUFFIX it marks an optional record field or parameter name
  -- (`name?: string`) and binds tight. As a PREFIX it marks an optional
  -- argument TYPE inside a function type
  -- (`function(? boolean, ? string)`), where it opens an item and takes
  -- the space any item gets after a separator. Without this, the
  -- formatter rewrote every generated `.d.tl` signature to `,? string`.
  if cur.tk == "?" and (prev.tk == "," or prev.tk == "(") then
    return prev.tk == ","
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

--- Compute the net indent change for all items on a line.
--- Returns (pre_change, post_change).
local function compute_indent_change(line_items: {Item},
    continues_type?: boolean): integer, integer
  local pre_change = 0
  local post_change = 0

  local type_ctx = ftypes.type_marks(line_items, continues_type)

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
      if is_block_opener(item, line_items[idx + 1], line_items[idx - 1]) then
        post_change = post_change + 1
      elseif item.tk == "{" or item.tk == "(" then
        post_change = post_change + 1
      elseif item.kind == "keyword" and item.tk == "function" then
        if ftypes.is_function_block_opener(line_items, idx, continues_type) then
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
  compute_indent_change: function(line_items: {Item},
  continues_type?: boolean): integer, integer
  opens_type_position: function(line_items: {Item}, continues_type?: boolean,
  carry_depth?: integer): boolean, integer
end

local M: FormatRulesModule = {}
M.is_long_comment = is_long_comment
-- Re-exported: `format/init.tl` drives the line loop and needs this
-- one fact from next door; one import for the rules it applies.
M.opens_type_position = ftypes.opens_type_position
M.needs_space = needs_space
M.compute_indent_change = compute_indent_change

return M
