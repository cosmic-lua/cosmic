#!/usr/bin/env cosmic
--- reads: docs skills README.md AGENTS.md o/cmd/cosmic/embed_gen/embed/.docs/index.lua
-- Every backtick `cosmic.<mod>.<sym>` span in the prose names a symbol
-- the doc index carries.
--
-- `_build/doc_paths_test.tl` holds a PATH span to a file that exists;
-- this is its symbol sibling. A guide that says `cosmic.fs_walk.walk`
-- reads as authoritative long after the module was renamed, and a
-- reader who pastes it gets `module not found` — nothing but a reader
-- following the pointer notices, because no other gate reads a
-- backtick span as a symbol reference. The doc index embedded in the
-- binary already carries every module, function, record, record field
-- and example, so this test asks it the same question `--docs` would.
--
-- The index is read from THIS TREE'S OWN BUILD, never `/zip` (the
-- running binary's embedded copy): a gate that read the running
-- binary's index would judge whatever tree built that binary, not the
-- one under test — the same reason `_build/doc_paths_test.tl` reads
-- the tree directly rather than asking a binary what files it shipped.
-- The declared `--- reads:` path above is this generator's OUTPUT, so
-- a rebuilt index re-runs this test.
--
-- Only `cosmic.<mod>.<sym>` is in scope: it is exactly the form
-- `cosmic --docs` accepts, which is what makes a span checkable at
-- all. A bare `fs.read` cannot be resolved without knowing which `fs`
-- the sentence means, and stays out (see the item's Non-goals).
--
-- The excuses come in three shapes, same discipline as
-- `doc_paths_test.tl`: a HISTORY file whose spans name the tree of its
-- day; every file under `docs/decisions/`, a record of a tradeoff as
-- it stood when written; and a literal SPAN — the reader's own example
-- symbol. A stale span is fixed in the prose, never excused here, and
-- an excuse nothing needs any more fails too.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fuzzy = require("cosmic.fuzzy")
local docs = require("cosmic.doc")
local type DocIndex = docs.DocIndex
local type ModuleDoc = docs.ModuleDoc
local type RecordDoc = docs.RecordDoc

local ROOTS < const >: {string} = {"docs", "skills"}
local EXTRA_FILES < const >: {string} = {"README.md", "AGENTS.md"}

--- Where the tree's own build wrote the doc index — this generation
--- unit's payload output, not the running binary's `/zip` copy.
local INDEX_PATH < const > = "o/cmd/cosmic/embed_gen/embed/.docs/index.lua"

--- Files excused whole, by path prefix: each names the tree as it was
--- when a slice landed, so a span in it was right the day it was
--- written and names history after. Copied from `doc_paths_test.tl`
--- and extended with the dated usability study, whose own header says
--- the same thing.
local HISTORY < const >: {string: string} = {
  ["docs/design/make/log/"] = "the design log names the tree of each phase's day",
  ["docs/agent-usability.md"] = "a dated study log; its header says so",
}

--- The prefix under which a span names a decision record, which
--- documents the tree as it stood the day the tradeoff was settled —
--- not live guidance a reader pastes today.
local DECISIONS_PREFIX < const > = "docs/decisions/"
local DECISIONS_WHY < const > = "a record names the tree of its day"

--- Spans excused by name: a symbol that is the reader's own, from a
--- guide's worked example (`cosmic.mymod.greet`), never a pointer into
--- this tree. Empty today — nothing in the prose currently needs it —
--- kept so the next worked example that invents its own module name
--- has somewhere to go besides a HISTORY or decisions excuse that
--- would not fit it.
local SPANS < const >: {string: string} = {}

--- One backtick span, with where it was read.
local record Span
  file: string
  line: integer
  text: string
end

--- Every markdown file this gate covers, in path order: every `.md`
--- under the roots, plus the two individually-named files at the repo
--- root.
--- @return {string} Paths relative to the repo root
local function prose_files(): {string}
  local out: {string} = {}
  for _, root in ipairs(ROOTS) do
    for _, path in ipairs(check.must(fs.find(root, {glob = "*.md"}))) do
      out[#out + 1] = path
    end
  end
  for _, path in ipairs(EXTRA_FILES) do
    out[#out + 1] = path
  end
  table.sort(out)
  assert(#out > 0, "no markdown found under " .. table.concat(ROOTS, ", "))
  return out
end

--- The backtick spans of one file's prose. A fenced block is code, not
--- prose, and is skipped whole: a backtick inside it is the
--- language's, not markdown's.
--- @param path string The markdown file
--- @param out {Span} Accumulator
local function spans_of(path: string, out: {Span})
  local lineno = 0
  local in_fence = false
  for line in (check.must(fs.read(path)) .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    if line:match("^%s*```") then
      in_fence = not in_fence
    elseif not in_fence then
      for text in line:gmatch("`([^`]+)`") do
        out[#out + 1] = {file = path, line = lineno, text = text}
      end
    end
  end
end

--- Strip a trailing balanced call suffix (`encode(x, y)` -> `encode`),
--- so a symbol reference followed by an example call still names the
--- symbol. A span with no such suffix is returned unchanged.
--- @param text string The span's raw text
--- @return string The span with any trailing `(...)` removed
local function strip_call_suffix(text: string): string
  local base = text:match("^([^%(]*)%b()$")
  return base or text
end

--- Whether a span is shaped like a `cosmic.<mod>.<sym>` symbol
--- reference: it holds no space, `<`, or `*` (each rules it out as a
--- placeholder or a family of names, not one symbol), and starts with
--- `cosmic.` followed by a module segment, a `.` or `:` separator, and
--- at least one more segment. A method spelled with `:` is in scope —
--- it resolves exactly as `.` would.
--- @param text string The span's text, call suffix already stripped
--- @return boolean
local function is_symbol_shaped(text: string): boolean
  if text:find(" ", 1, true) or text:find("<", 1, true) or text:find("*", 1, true) then
    return false
  end
  return text:match("^cosmic%.[%w_]+[%.:][%w_]+") ~= nil
end

--- Every `cosmic.<mod>.<sym>`-shaped span in the prose, in file order.
--- @return {Span}
local function symbol_spans(): {Span}
  local all: {Span} = {}
  for _, path in ipairs(prose_files()) do
    spans_of(path, all)
  end
  local out: {Span} = {}
  for _, span in ipairs(all) do
    local text = strip_call_suffix(span.text)
    if is_symbol_shaped(text) then
      out[#out + 1] = {file = span.file, line = span.line, text = text}
    end
  end
  assert(#out > 0, "no cosmic.<mod>.<sym> span found in any prose file")
  return out
end

--- Load the doc index this tree's own build just wrote.
--- @return DocIndex | nil The parsed index
--- @return string Why it could not be loaded
local function load_index(): DocIndex | nil, string
  local source, rerr = fs.read(INDEX_PATH)
  if not source then
    return nil, INDEX_PATH .. ": " .. (rerr or "cannot read") ..
    " — run `cosmic --make build` first"
  end
  local chunk, cerr = load("return " .. source, "=docindex", "t", {})
  if not chunk then
    return nil, "failed to parse index: " .. (cerr or "unknown")
  end
  local ok, result = pcall(chunk)
  if not ok then
    return nil, "failed to load index: " .. tostring(result)
  end
  if not (result is DocIndex) then
    return nil, "index is not a doc index"
  end
  return result
end

--- Whether a record carries a field of the given name.
--- @param rec RecordDoc
--- @param field_name string
--- @return boolean
local function has_field(rec: RecordDoc, field_name: string): boolean
  for _, field in ipairs(rec.fields) do
    if field[1] == field_name then return true end
  end
  return false
end

--- Whether a module carries a function, record, record field, or
--- example of the given name.
--- @param mod ModuleDoc
--- @param symbol string
--- @return boolean
local function has_module_symbol(mod: ModuleDoc, symbol: string): boolean
  for _, fn in ipairs(mod.functions) do
    if fn.name == symbol then return true end
  end
  for _, rec in ipairs(mod.records) do
    if rec.name == symbol or has_field(rec, symbol) then return true end
  end
  for _, ex in ipairs(mod.examples) do
    if ex.name == symbol then return true end
  end
  return false
end

--- Split a dotted symbol reference into its segments.
--- @param text string
--- @return {string}
local function segments_of(text: string): {string}
  local out: {string} = {}
  for seg in text:gmatch("[^%.]+") do
    out[#out + 1] = seg
  end
  return out
end

--- Whether the index resolves a symbol span: the whole span as a
--- module name, `<module>` plus a function, record, record field, or
--- example of that name, or `<module>.<Record>` plus a field of that
--- record. Tries the longest module-name prefix first, so a dotted
--- module name (`cosmic.fs.walk`) is preferred over misreading its
--- tail as a symbol.
--- @param index DocIndex
--- @param text string A `cosmic.` span, `:` already normalized to `.`
--- @return boolean
local function resolves(index: DocIndex, text: string): boolean
  local parts = segments_of(text)
  local total = #parts
  for prefix_len = total, 2, -1 do
    local mod_name = table.concat(parts, ".", 1, prefix_len)
    local mod = index.modules[mod_name]
    if mod then
      if prefix_len == total then
        return true
      end
      local left = total - prefix_len
      if left == 1 then
        if has_module_symbol(mod, parts[prefix_len + 1]) then return true end
      elseif left == 2 then
        for _, rec in ipairs(mod.records) do
          if rec.name == parts[prefix_len + 1] and has_field(rec, parts[prefix_len + 2]) then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Every resolvable `cosmic.<mod>...` name the index carries, for the
--- "did you mean?" suggestion — the same fuzzy match `--docs` uses on
--- a miss (`cosmic.doc.show`'s `find_suggestions`), computed once and
--- reused across every failing span in one run.
--- @param index DocIndex
--- @return {string}
local function candidates_of(index: DocIndex): {string}
  local out: {string} = {}
  for mod_name, mod in pairs(index.modules) do
    if mod_name:match("^cosmic%.") then
      out[#out + 1] = mod_name
      for _, fn in ipairs(mod.functions) do
        out[#out + 1] = mod_name .. "." .. fn.name
      end
      for _, rec in ipairs(mod.records) do
        out[#out + 1] = mod_name .. "." .. rec.name
        for _, field in ipairs(rec.fields) do
          out[#out + 1] = mod_name .. "." .. rec.name .. "." .. field[1]
        end
      end
      for _, ex in ipairs(mod.examples) do
        out[#out + 1] = mod_name .. "." .. ex.name
      end
    end
  end
  return out
end

--- Up to 3 nearest known names, by edit distance under 4 — the same
--- bound `--docs`'s not-found path uses.
--- @param text string The span that failed to resolve
--- @param candidates {string} Every resolvable name, from candidates_of
--- @return string A comma-separated list, or "none"
local function nearest(text: string, candidates: {string}): string
  local similar = fuzzy.find_similar(text, candidates, {max_distance = 3, limit = 3})
  if #similar == 0 then return "none" end
  local names: {string} = {}
  for _, m in ipairs(similar) do
    names[#names + 1] = m.value
  end
  return table.concat(names, ", ")
end

--- The excuses a span carries: one entry per list that claims it, so
--- the ratchet below can tell which excuses are still doing work.
--- @param span Span
--- @return {string} The keys of every excuse that matches
local function excuses_of(span: Span): {string}
  local out: {string} = {}
  for prefix in pairs(HISTORY) do
    if span.file:sub(1, #prefix) == prefix then
      out[#out + 1] = prefix
    end
  end
  if span.file:sub(1, #DECISIONS_PREFIX) == DECISIONS_PREFIX then
    out[#out + 1] = DECISIONS_PREFIX
  end
  if SPANS[span.text] then
    out[#out + 1] = span.text
  end
  return out
end

-- The gate: a `cosmic.<mod>.<sym>` span either resolves against the
-- doc index or is excused. The failure names file:line, the span, and
-- up to 3 near misses — the same fuzzy search `--docs` runs on a typo,
-- so the fix is right there in the message.
local function test_every_symbol_reference_resolves_in_the_doc_index()
  local index, ierr = load_index()
  assert(index, ierr)
  local candidates = candidates_of(index)
  local missing: {string} = {}
  for _, span in ipairs(symbol_spans()) do
    local normalized = span.text:gsub(":", ".")
    if not resolves(index, normalized) and #excuses_of(span) == 0 then
      missing[#missing + 1] = span.file .. ":" .. span.line .. ": `" ..
      span.text .. "` names no symbol in the doc index (nearest: " ..
      nearest(span.text, candidates) .. ")"
    end
  end
  assert(#missing == 0, #missing .. " unresolved symbol reference(s) — fix the " ..
    "prose, or excuse the span in _build/doc_symbols_test.tl with a " ..
    "reason:\n  " .. table.concat(missing, "\n  "))
end

-- The ratchet: every excuse still excuses something that would fail
-- without it. A rename that made a span resolve, a history file
-- rewritten, an example that got a real symbol — each leaves an entry
-- nothing needs, and an allowlist only grows unless its entries earn
-- their place.
local function test_every_excuse_is_still_needed()
  local index, ierr = load_index()
  assert(index, ierr)
  local needed: {string: boolean} = {}
  for _, span in ipairs(symbol_spans()) do
    local normalized = span.text:gsub(":", ".")
    if not resolves(index, normalized) then
      for _, key in ipairs(excuses_of(span)) do
        needed[key] = true
      end
    end
  end
  local idle: {string} = {}
  for prefix, why in pairs(HISTORY) do
    if not needed[prefix] then
      idle[#idle + 1] = "history " .. prefix .. " (" .. why .. ")"
    end
  end
  if not needed[DECISIONS_PREFIX] then
    idle[#idle + 1] = "prefix " .. DECISIONS_PREFIX .. " (" .. DECISIONS_WHY .. ")"
  end
  for text, why in pairs(SPANS) do
    if not needed[text] then
      idle[#idle + 1] = "span `" .. text .. "` (" .. why .. ")"
    end
  end
  table.sort(idle)
  assert(#idle == 0, #idle .. " excuse(s) in _build/doc_symbols_test.tl " ..
    "match no unresolved span any more — delete them:\n  " ..
    table.concat(idle, "\n  "))
end

print("all doc symbol tests passed")
