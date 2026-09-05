#!/usr/bin/env cosmic
-- A function's `@return` tags and its declared return slots are two
-- statements of one contract, and this is the gate that holds them to
-- each other. `FunctionDoc` carries both -- `returns` from the tags,
-- `signature` from the source -- so the check is a census over the
-- embedded doc index, not a re-parse of the tree: these tests are about
-- the embedded index and must run in the built binary, where the index
-- is always present (the same reliance `cosmic/doc/public_test.tl`
-- rests on).
--
-- A function with NO `@return` tags is not judged: a bare-value
-- infallible function documents its value in prose today, and requiring
-- tags everywhere is a different, larger change. The same pass also
-- normalizes the one spelling difference the tree carries for optional
-- parameters -- a tag `@param name?` and a signature `name?:` name the
-- same parameter -- so a real mismatch (the tag names something the
-- signature does not have at all) is never lost in that noise.

local check = require("cosmic.check")
local docs = require("cosmic.doc")
local exports = require("_tool.doc.exports")

--- The parameter names a signature's leading `(...)` declares, keyed by
--- name with any trailing `?` stripped. The first point the signature's
--- paren depth returns to zero (started at 1, for the leading `(`
--- itself) is the parameter list's real close, whatever a parameter's
--- own type nests inside it -- the same rule `return_slots` uses to find
--- where the list ends, applied here to what is INSIDE it instead of
--- what follows.
--- @param signature string A function's full signature
--- @return {string: boolean} The declared parameter names
local function signature_param_names(signature: string): {string: boolean}
  local names: {string: boolean} = {}
  if signature:sub(1, 1) ~= "(" then
    return names
  end
  local depth = 1
  local body_end: integer = nil
  for i = 2, #signature do
    local c = signature:sub(i, i)
    if c == "(" or c == "{" then
      depth = depth + 1
    elseif c == ")" or c == "}" then
      depth = depth - 1
      if depth == 0 then
        body_end = i - 1
        break
      end
    end
  end
  local body = signature:sub(2, body_end or #signature)
  local function flush(chunk: string)
    local variadic = chunk:match("^%s*(%.%.%.)%s*:")
    local name = variadic or chunk:match("^%s*([%w_]+)%s*%??%s*:")
    if name then
      names[name] = true
    end
  end
  local chunk_start, d = 1, 0
  for i = 1, #body do
    local c = body:sub(i, i)
    if c == "(" or c == "{" then
      d = d + 1
    elseif c == ")" or c == "}" then
      d = d - 1
    elseif c == "," and d == 0 then
      flush(body:sub(chunk_start, i - 1))
      chunk_start = i + 1
    end
  end
  flush(body:sub(chunk_start))
  return names
end

local idx = check.must(docs.embedded_index(),
  "docs index must be embedded (run tests via the binary)")

local function test_return_tag_count_matches_declared_slots()
  local bad: {string} = {}
  for mod, m in pairs(idx.modules) do
    if mod:match("^cosmic%.") and not m.internal then
      for _, f in ipairs(m.functions or {}) do
        if f.signature and #(f.returns or {}) > 0 then
          local declared = exports.return_slots(f.signature)
          if declared ~= #f.returns then
            bad[#bad + 1] = string.format(
              "%s.%s: %d @return tags, %d declared slots — %s",
              mod, f.name, #f.returns, declared, f.signature)
          end
        end
      end
    end
  end
  table.sort(bad)
  assert(#bad == 0,
    "function(s) whose @return tag count disagrees with their " ..
    "signature's declared return slots:\n  " .. table.concat(bad, "\n  "))
end

local function test_param_tags_name_real_parameters()
  local bad: {string} = {}
  for mod, m in pairs(idx.modules) do
    if mod:match("^cosmic%.") and not m.internal then
      for _, f in ipairs(m.functions or {}) do
        if f.signature and #(f.params or {}) > 0 then
          local declared = signature_param_names(f.signature)
          for _, p in ipairs(f.params) do
            local name = p.name:gsub("%?$", "")
            if not declared[name] then
              bad[#bad + 1] = string.format(
                "%s.%s: @param %s is not a parameter of %s",
                mod, f.name, p.name, f.signature)
            end
          end
        end
      end
    end
  end
  table.sort(bad)
  assert(#bad == 0,
    "function(s) whose @param tag names a parameter their signature " ..
    "does not have:\n  " .. table.concat(bad, "\n  "))
end

print("all doc-return tests passed")
