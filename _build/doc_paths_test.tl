#!/usr/bin/env cosmic
--- reads: docs
--- reads: skills
-- Every backtick path in the prose names a file that exists.
--
-- Prose points at code by path: a goal sends its reader to the skill
-- that holds the method, a decision record to the module that carries
-- it. Nothing but a reader following the pointer notices when the
-- target moves, because no other gate reads a backtick span as a
-- path — the formatter, the checker and the snippet gate all look
-- past it. So this one does: every span shaped like a repo path (a
-- `/` in it, a known source extension at its end) must name a file
-- or directory in the tree, or carry a one-line reason below for why
-- it is not a reference at all.
--
-- The reasons come in three shapes and the three lists ARE the whole
-- allowlist: a RULE over the span's text (a glob, a `<name>`
-- placeholder, a build output, the artifact's own tree, the board
-- branch); a HISTORY file whose paths name the tree of its day; a
-- literal SPAN — the reader's example project, a sibling repository, a
-- deletion recorded by name. A stale pointer is fixed in the prose,
-- never excused here, and an excuse nothing needs any more fails too,
-- so the lists shrink as readily as they grow.

local check = require("cosmic.check")
local fs = require("cosmic.fs")

local ROOTS < const >: {string} = {"docs", "skills"}

--- The extensions that make a span a path and not a phrase.
local EXTENSIONS < const >: {string: boolean} = {
  md = true, tl = true, lua = true, mk = true, yml = true, sh = true,
}

--- One excuse by shape: a Lua pattern over the span's text, and why a
--- span matching it is not a reference to this tree.
local record Rule
  pattern: string
  why: string
end

local RULES < const >: {Rule} = {
  {pattern = "%*", why = "a glob names a family of files, not one"},
  {pattern = "<", why = "a <name> placeholder stands for the reader's own file"},
  {pattern = "^o/", why = "a build output exists only after a build"},
  {pattern = "^/", why = "an absolute path is the artifact's /zip/ tree, not the repo's"},
  {pattern = "^_work/", why = "the board's machinery lives on the orphan board branch"},
}

--- Files excused whole, by path prefix: each is a record of the tree
--- as it was when a slice landed, so a path in it was right the day it
--- was written and names history after.
local HISTORY < const >: {string: string} = {}

local EXAMPLE < const > = "the guides' example project: the reader's tree, not this one"
local COSMOPOLITAN < const > = "a path in cosmic-lua/cosmopolitan"

--- Spans excused by name.
local SPANS < const >: {string: string} = {
  ["greet/init.tl"] = EXAMPLE,
  ["./greet/init.tl"] = EXAMPLE,
  ["greet/text.tl"] = EXAMPLE,
  ["greet/text_test.tl"] = EXAMPLE,
  ["cmd/greet/main.tl"] = EXAMPLE,
  ["pkg/db.tl"] = EXAMPLE,
  ["pkg/init.tl"] = EXAMPLE,
  ["3p/lpeg/lpeg_pin.tl"] = EXAMPLE,
  ["cosmic/mymod.tl"] = EXAMPLE,
  ["cosmic/mymod_example.tl"] = EXAMPLE,
  ["cosmic/mymod_test.tl"] = EXAMPLE,
  ["cmd/app/main.tl"] = EXAMPLE,
  ["types/ext.d.tl"] = EXAMPLE,
  ["notes/store.tl"] = EXAMPLE,
  ["notes/store_test.tl"] = EXAMPLE,
  ["notes/store_example.tl"] = EXAMPLE,
  ["cmd/notes/main.tl"] = EXAMPLE,
  ["tool/net/definitions.lua"] = COSMOPOLITAN,
  ["build/config.mk"] = COSMOPOLITAN,
  ["doc/gendoc.tl"] = "a deletion, recorded by the name it had",
}

--- One backtick span, with where it was read.
local record Span
  file: string
  line: integer
  text: string
end

--- Every markdown file under the roots, in path order.
--- @return {string} Paths relative to the repo root
local function prose_files(): {string}
  local out: {string} = {}
  for _, root in ipairs(ROOTS) do
    for _, path in ipairs(check.must(fs.find(root, {glob = "*.md"}))) do
      out[#out + 1] = path
    end
  end
  table.sort(out)
  assert(#out > 0, "no markdown found under " .. table.concat(ROOTS, ", "))
  return out
end

--- The backtick spans of one file's prose. A fenced block is code, not
--- prose, and is skipped whole: a backtick inside it is the language's,
--- not markdown's.
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

--- Whether a span is shaped like a repo path: path characters only, a
--- `/` somewhere in it, and a known source extension at its end. A
--- bare `main.tl` is a name, not a place, and stays out.
--- @param text string The span's text
--- @return boolean
local function is_path_shaped(text: string): boolean
  if not text:match("^[%w_%./<>%*%-]+$") then
    return false
  end
  if not text:find("/", 1, true) then
    return false
  end
  local ext = text:match("%.(%a+)$")
  return ext ~= nil and EXTENSIONS[ext] == true
end

--- Every path-shaped span in the prose, in file order.
--- @return {Span}
local function path_spans(): {Span}
  local all: {Span} = {}
  for _, path in ipairs(prose_files()) do
    spans_of(path, all)
  end
  local out: {Span} = {}
  for _, span in ipairs(all) do
    if is_path_shaped(span.text) then
      out[#out + 1] = span
    end
  end
  assert(#out > 0, "no path-shaped backtick span found in any prose file")
  return out
end

--- Whether a span names something in the tree.
--- @param span Span
--- @return boolean
local function resolves(span: Span): boolean
  return fs.is_file(span.text) or fs.is_dir(span.text)
end

--- The excuses a span carries: one entry per list that claims it, so
--- the ratchet below can tell which excuses are still doing work.
--- @param span Span
--- @return {string} The keys of every excuse that matches, in list order
local function excuses_of(span: Span): {string}
  local out: {string} = {}
  for _, rule in ipairs(RULES) do
    if span.text:find(rule.pattern, 1, false) then
      out[#out + 1] = rule.pattern
    end
  end
  for prefix in pairs(HISTORY) do
    if span.file:sub(1, #prefix) == prefix then
      out[#out + 1] = prefix
    end
  end
  if SPANS[span.text] then
    out[#out + 1] = span.text
  end
  return out
end

-- The gate: a path-shaped span either resolves or is excused. The
-- failure names file:line and the missing path — the same report that
-- is the fix list when a target moves.
local function test_every_path_reference_names_a_file_in_the_tree()
  local missing: {string} = {}
  for _, span in ipairs(path_spans()) do
    if not resolves(span) and #excuses_of(span) == 0 then
      missing[#missing + 1] = span.file .. ":" .. span.line .. ": `" ..
      span.text .. "` names no file or directory in the tree"
    end
  end
  assert(#missing == 0, #missing .. " stale path reference(s) — fix the " ..
    "prose, or excuse the span in _build/doc_paths_test.tl with a " ..
    "reason:\n  " .. table.concat(missing, "\n  "))
end

-- The ratchet: every excuse still excuses something that would fail
-- without it. An example project that got a fixture, a history file
-- rewritten, a sibling repo's path that moved into this tree — each
-- leaves an entry nothing needs, and an allowlist only grows unless
-- its entries have to earn their place.
local function test_every_excuse_is_still_needed()
  local needed: {string: boolean} = {}
  for _, span in ipairs(path_spans()) do
    if not resolves(span) then
      for _, key in ipairs(excuses_of(span)) do
        needed[key] = true
      end
    end
  end
  local idle: {string} = {}
  for _, rule in ipairs(RULES) do
    if not needed[rule.pattern] then
      idle[#idle + 1] = "rule " .. rule.pattern .. " (" .. rule.why .. ")"
    end
  end
  for prefix, why in pairs(HISTORY) do
    if not needed[prefix] then
      idle[#idle + 1] = "history " .. prefix .. " (" .. why .. ")"
    end
  end
  for text, why in pairs(SPANS) do
    if not needed[text] then
      idle[#idle + 1] = "span `" .. text .. "` (" .. why .. ")"
    end
  end
  table.sort(idle)
  assert(#idle == 0, #idle .. " excuse(s) in _build/doc_paths_test.tl " ..
    "match no missing span any more — delete them:\n  " ..
    table.concat(idle, "\n  "))
end

print("all doc path tests passed")
