#!/usr/bin/env cosmic
--- reads: .github 3p _build _cli _docs _eval _make _perf _tool _types cmd cosmic docs embed skills sys
--- ref: refs/remotes/work/main
-- Every backtick path in the prose names a file that exists.
--
-- A path-shaped span can resolve anywhere in the tree, so this
-- test's real input is every root above, not the prose alone: a
-- rename under any of them can turn a span stale even though the
-- sentence carrying it never changed.
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
-- One family of spans names a file that exists, but not here: the
-- board's machinery under `_work/` lives in the repository
-- cosmic-lua/work, so those spans are checked against that repository's
-- main branch as git last fetched it, and skipped aloud when no
-- fetched ref can answer. The ref is declared as an input above
-- (`--- ref:`), so a fetch that moves it re-runs this file instead of
-- replaying its verdict.
--
-- The reasons come in three shapes and the three lists ARE the whole
-- allowlist: a RULE over the span's text (a glob, a `<name>`
-- placeholder, a build output, the artifact's own tree); a HISTORY
-- file whose paths name the tree of its day; a literal SPAN — the
-- reader's example project, a sibling repository, a deletion recorded
-- by name. A stale pointer is fixed in the prose, never excused here,
-- and an excuse nothing needs any more fails too, so the lists shrink
-- as readily as they grow.

local check = require("cosmic.check")
local child = require("cosmic.child")
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
}

--- Files excused whole, by path prefix: each is a record of the tree
--- as it was when a slice landed, so a path in it was right the day it
--- was written and names history after.
local HISTORY < const >: {string: string} = {
  ["docs/design/make/log/"] = "the design log names the tree of each phase's day",
  ["docs/design/make/phasing.md"] = "phases 1-3 are the record of work done",
}

local EXAMPLE < const > = "the guides' example project: the reader's tree, not this one"
local COSMOPOLITAN < const > = "a path in cosmic-lua/cosmopolitan"

--- Spans excused by name.
local SPANS < const >: {string: string} = {
  ["greet/init.tl"] = EXAMPLE,
  ["./greet/init.tl"] = EXAMPLE,
  ["greet/text.tl"] = EXAMPLE,
  ["greet/text_test.tl"] = EXAMPLE,
  ["cmd/greet/main.tl"] = EXAMPLE,
  ["./x/y.tl"] = EXAMPLE,
  ["pkg/db.tl"] = EXAMPLE,
  ["pkg/init.tl"] = EXAMPLE,
  ["3p/lpeg/lpeg_pin.tl"] = EXAMPLE,
  ["3p/mylib/mylib_pin.tl"] = EXAMPLE,
  ["cosmic/mymod.tl"] = EXAMPLE,
  ["cosmic/mymod_example.tl"] = EXAMPLE,
  ["cosmic/mymod_test.tl"] = EXAMPLE,
  ["tool/net/definitions.lua"] = COSMOPOLITAN,
  ["build/config.mk"] = COSMOPOLITAN,
  ["doc/gendoc.tl"] = "a deletion, recorded by the name it had",
}

--- The prefix under which a span names the work repository's tree, and
--- the ref that tree is read from — the remote-tracking ref a fetch
--- of cosmic-lua/work's `main` leaves behind, never a local branch, so
--- the check reads what the remote has and not a checkout's own edits.
local BOARD_PREFIX < const > = "_work/"
local WORK_REF < const > = "refs/remotes/work/main"

--- How long the board read waits for `git` to answer. A hung `git`
--- (a lock held by another process) must not hang the whole gate.
local GIT_MS < const > = 10000

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

--- Whether a span names the work repository's tree rather than this one.
--- @param span Span
--- @return boolean
local function is_board_path(span: Span): boolean
  return span.text:sub(1, #BOARD_PREFIX) == BOARD_PREFIX
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

--- The work repository's files under the prefix, as the fetched ref
--- has them: one bounded `git ls-tree` per run, read the first time it
--- is asked for. Nil, and why, when git cannot answer — no
--- `refs/remotes/work/main` fetched, no git, a timeout — so the caller
--- can skip aloud instead of mistaking silence for an empty tree.
--- @return {string: boolean} | nil The board paths under the prefix
--- @return string Why git could not answer
local function work_paths(): {string: boolean} | nil, string
  local argv = {"git", "ls-tree", "-r", "--name-only", WORK_REF, "--",
    BOARD_PREFIX:sub(1, -2)}
  local h, serr = child.start(argv, {stdin = ""})
  if not (h is child.Handle) then
    return nil, "git could not start: " .. tostring(serr)
  end
  local r = h:wait(GIT_MS)
  if not (r is child.Result) then
    local _ok, _err = h:stop() -- start's partner, so the child does not leak
    return nil, "git did not answer within " .. GIT_MS .. "ms"
  end
  if not r.ok then
    return nil, WORK_REF .. " is not readable here (" ..
    (r.stderr:gsub("%s+$", "")) .. ")"
  end
  local out: {string: boolean} = {}
  for path in r.stdout:gmatch("[^\n]+") do
    out[path] = true
  end
  return out
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
-- is the fix list when a target moves. A board span is the next
-- case's, not an excuse: it is checked against the branch it names.
local function test_every_path_reference_names_a_file_in_the_tree()
  local missing: {string} = {}
  for _, span in ipairs(path_spans()) do
    if not is_board_path(span) and not resolves(span) and
    #excuses_of(span) == 0 then
      missing[#missing + 1] = span.file .. ":" .. span.line .. ": `" ..
      span.text .. "` names no file or directory in the tree"
    end
  end
  assert(#missing == 0, #missing .. " stale path reference(s) — fix the " ..
    "prose, or excuse the span in _build/doc_paths_test.tl with a " ..
    "reason:\n  " .. table.concat(missing, "\n  "))
end

-- The board gate: a `_work/` span names a file on cosmic-lua/work's
-- `main` branch. A rename there strands a pointer in this tree's
-- prose, and no gate on either repository reads across, so this one
-- does — against the ref as fetched, which is why a checkout without
-- it skips with the reason printed rather than passing on an answer it
-- never had.
local function test_every_board_reference_names_a_file_in_the_work_repo()
  local spans: {Span} = {}
  for _, span in ipairs(path_spans()) do
    if is_board_path(span) then
      spans[#spans + 1] = span
    end
  end
  assert(#spans > 0, "no `" .. BOARD_PREFIX .. "` span in any prose file — " ..
    "the board gate in _build/doc_paths_test.tl has nothing left to check")
  local paths, why = work_paths()
  if not paths then
    if os.getenv("CI") then
      error(WORK_REF .. " board paths unchecked in CI: " .. why ..
        " — pr.yml's fetch step should have brought " .. WORK_REF .. " down")
    end
    print("skipped: " .. WORK_REF .. " board paths unchecked: " .. why ..
      " — `git fetch https://github.com/cosmic-lua/work " ..
      "+refs/heads/main:refs/remotes/work/main` to check them")
    return
  end
  local missing: {string} = {}
  for _, span in ipairs(spans) do
    if not paths[span.text] then
      missing[#missing + 1] = span.file .. ":" .. span.line .. ": `" ..
      span.text .. "` names no file on " .. WORK_REF
    end
  end
  assert(#missing == 0, #missing .. " stale board reference(s) — fix the " ..
    "prose to name what " .. WORK_REF .. " has:\n  " ..
    table.concat(missing, "\n  "))
end

-- The ratchet: every excuse still excuses something that would fail
-- without it. An example project that got a fixture, a history file
-- rewritten, a sibling repo's path that moved into this tree — each
-- leaves an entry nothing needs, and an allowlist only grows unless
-- its entries have to earn their place.
local function test_every_excuse_is_still_needed()
  local needed: {string: boolean} = {}
  for _, span in ipairs(path_spans()) do
    if not is_board_path(span) and not resolves(span) then
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
