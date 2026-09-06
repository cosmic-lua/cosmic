#!/usr/bin/env cosmic
-- A function's `@return` tags and its declared return slots are two
-- statements of one contract, and this is the gate that holds them to
-- each other. `FunctionDoc` carries the tags (`returns`) and the
-- signature TEXT (`signature`) but not a parsed return-slot count, so
-- the count comes from a fresh AST read of the function's own source
-- file, one file at a time, through `_tool.doc.signature` -- the same
-- reader `_tool/doc/init.tl` itself builds the index from.
--
-- Matching an index entry to its AST node is done by (file, line), not
-- by name: a module's OWN file (`ModuleDoc.file`) is parsed directly,
-- so every line in it is unambiguous, and matching by line rather than
-- name means an EXPORTED ALIAS (`cosmic.log`'s `debug` for the local
-- `debug_msg`) is still found correctly, at the line its real
-- definition sits on. A directory module's MERGED-IN shard functions
-- (e.g. `cosmic.fs`'s functions folded in from `cosmic.fs.path`) are
-- simply not found at their line in the PARENT's own file and are
-- skipped here -- harmless, since that exact function is independently
-- checked when this loop reaches its own true shard module, whose
-- `.file` is the file it is actually defined in.
--
-- These tests are about the embedded index and must run in the built
-- binary, where the index is always present (the same reliance
-- `cosmic/doc/public_test.tl` rests on); the source tree itself must
-- also be present at the repo-relative paths `ModuleDoc.file` names,
-- true for every other `_build/*_test.tl` ratchet that re-scans source.
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
local fs = require("cosmic.fs")
local doc_signature = require("_tool.doc.signature")

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

--- Every declared return slot count this file's own AST carries,
--- keyed by line -- one fresh parse per unique file, shared across
--- every mod entry that names it.
--- @param file_path string The source file to parse
--- @return {integer: integer} Return slot count by 1-based source line
local function declared_slots_by_line(file_path: string): {integer: integer}
  local by_line: {integer: integer} = {}
  local source = fs.read(file_path)
  if not source then return by_line end
  local sigs = doc_signature.function_signatures(source, file_path)
  if not sigs then return by_line end
  for _, s in ipairs(sigs) do
    by_line[s.line] = s.return_slots
  end
  return by_line
end

local function test_return_tag_count_matches_declared_slots()
  local bad: {string} = {}
  local cache: {string: {integer: integer}} = {}
  for mod, m in pairs(idx.modules) do
    if mod:match("^cosmic%.") and not m.internal and m.file then
      cache[m.file] = cache[m.file] or declared_slots_by_line(m.file)
      local by_line = cache[m.file]
      for _, f in ipairs(m.functions or {}) do
        if #(f.returns or {}) > 0 then
          local declared = by_line[f.line]
          if declared and declared ~= #f.returns then
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
