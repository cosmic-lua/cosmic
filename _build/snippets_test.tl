#!/usr/bin/env cosmic
--- reads: README.md
--- reads: AGENTS.md
--- reads: docs
--- reads: skills
--- reads: sys
--- reads: cmd
--- reads: cosmic
--- reads: _build
--- reads: _cli
--- reads: _docs
--- reads: _make
--- reads: _perf
--- reads: _tool
--- reads: _types
-- Every code snippet this repository shows a reader is real code.
--
-- "Shows a reader" is the whole surface, not one directory: the guides
-- `--docs guide.*` serves, the fenced examples inside module doc
-- comments that `--docs cosmic.shm` prints, the README a visitor lands
-- on, and the markdown under docs/. A snippet is advice, and advice
-- that does not compile is worse than no advice — the reader pastes it,
-- their gate rejects it, and the page was the thing that lied.
--
-- Two rules, one population:
--   * the FORMATTER is the authority on shape: every fence is a
--     formatter fixpoint, so a snippet copied into a gated project does
--     not fail `--make fmt` on arrival;
--   * the CHECKER is the authority on meaning: every fence compiles at
--     full strictness, warnings included, because that is what the
--     reader's own files are held to.
--
-- There is no opt-out word. A fence tagged `teal` claims to be Teal;
-- prose that shows a compile error, a deliberate mis-format, or a
-- skeleton with `...` in it is not Teal, and says so by not claiming to
-- be (```text). Nothing in this repository is exempt from the gate it
-- teaches.

local check = require("cosmic.check")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local teal = require("cosmic.teal")

--- The files this test reads, from its own `--- reads:` declarations
--- above. One list, two consumers: make takes it as the prerequisite
--- set and the content key — so editing a guide re-runs this test
--- rather than replaying its verdict — and the scan below takes it as
--- the population. Deriving the second from the first is what keeps
--- them from drifting, and the model refuses a declaration naming a
--- path that does not exist.
local function declared_files(): {string}
  local imports = require("_make.imports")
  return check.must(imports.reads_of_file(".", "_build/snippets_test.tl"))
end

--- The example project the guides describe — `greet.text` in the
--- quickstart, `mymod` in the module guide, `cosmic.mymod` in the
--- contributing walkthrough. A snippet about the reader's project is
--- still real code; it just needs the project to exist, so here it is.
local FIXTURES < const >: {string: string} = {
  ["greet/text.tl"] = [[
local record TextModule
  greeting: function(name: string): string
end
local function greeting(name: string): string
  return "hello, " .. name .. "!"
end
local M: TextModule = {
  greeting = greeting,
}
return M
]],
  ["mymod.tl"] = [[
local record MyModule
  value: integer
end
local M: MyModule = {
  value = 1,
}
return M
]],
  ["subdir/mymod.tl"] = [[
local record SubModule
  value: integer
end
local M: SubModule = {
  value = 2,
}
return M
]],
  ["cosmic/mymod.tl"] = [[
local record Widget
  name: string
  size: integer
end
local record MyModule
  record Widget
    name: string
    size: integer
  end
  new: function(name: string, size: integer): Widget
end
local function new(name: string, size: integer): Widget
  return {name = name, size = size}
end
local M: MyModule = {
  new = new,
}
return M
]],
}

local record Fence
  file: string
  line: integer
  lang: string
  body: string
end

--- Fenced blocks in a markdown file.
--- @param path string The markdown file
--- @param out {Fence} Accumulator
local function markdown_fences(path: string, out: {Fence})
  local text = check.must(fs.read(path))
  local in_code = false
  local lineno, start = 0, 0
  local lang = ""
  local body: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local fence, _info = line:match("^```(%w*)(.*)$")
    if fence then
      if in_code then
        out[#out + 1] = {
          file = path, line = start, lang = lang,
          body = table.concat(body, "\n"),
        }
        in_code = false
      else
        in_code, lang, start, body = true, fence, lineno, {}
      end
    elseif in_code then
      body[#body + 1] = line
    end
  end
end

--- Fenced blocks inside `---` doc comments in a Teal source. These
--- reach the reader through `--docs <module>`, which is the surface a
--- user with only the binary actually has.
--- @param path string The .tl source
--- @param out {Fence} Accumulator
local function doc_comment_fences(path: string, out: {Fence})
  local text = check.must(fs.read(path))
  local in_code = false
  local lineno, start = 0, 0
  local lang = ""
  local body: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local doc = line:match("^%s*%-%-%-%s?(.*)$")
    if doc then
      local fence = doc:match("^```(%w*)")
      if fence then
        if in_code then
          out[#out + 1] = {
            file = path, line = start, lang = lang,
            body = table.concat(body, "\n"),
          }
          in_code = false
        else
          in_code, lang, start, body = true, fence, lineno, {}
        end
      elseif in_code then
        body[#body + 1] = doc
      end
    elseif in_code then
      -- A doc comment that stops mid-fence is malformed; drop it rather
      -- than swallow the rest of the file.
      in_code = false
    end
  end
end

--- Every fence this repository shows a reader.
local function all_fences(): {Fence}
  local out: {Fence} = {}
  for _, path in ipairs(declared_files()) do
    if path:sub(-3) == ".md" then
      markdown_fences(path, out)
    elseif path:sub(-3) == ".tl" then
      doc_comment_fences(path, out)
    end
  end
  return out
end

--- Write the example project the docs describe.
local function fixture_dir(): string
  local dir = fs.join(check.must(env.get("TEST_TMPDIR")), "doc-fixtures")
  for path, source in pairs(FIXTURES) do
    local full = fs.join(dir, path)
    check.must(fs.make_dirs(fs.dirname(full)))
    check.must(fs.write(full, source))
  end
  return dir
end

local FENCES < const > = all_fences()

local function test_every_snippet_is_a_formatter_fixpoint()
  local format = require("cosmic.format")
  local offenders: {string} = {}
  local checked = 0
  for _, fence in ipairs(FENCES) do
    if fence.lang == "teal" or fence.lang == "lua" then
      local ext = fence.lang == "lua" and ".lua" or ".tl"
      local result = format.format(fence.body .. "\n", "snippet" .. ext)
      if result.ok then
        checked = checked + 1
        if result.code ~= fence.body .. "\n" then
          offenders[#offenders + 1] = fence.file .. ":" .. fence.line ..
          ": formatter disagrees; formatted form:\n" .. result.code
        end
      end
    end
  end
  assert(checked > 0, "no fence parsed; the harness is broken")
  assert(#offenders == 0,
    "snippet(s) the formatter would rewrite — advice must pass the " ..
    "gate it teaches; a fence ABOUT wrong formatting is prose, so tag " ..
    "it ```text:\n" .. table.concat(offenders, "\n"))
  print("formatter fixpoint: " .. checked .. " snippets")
end
test_every_snippet_is_a_formatter_fixpoint()

local function test_every_snippet_compiles()
  local dir = fixture_dir()
  local offenders: {string} = {}
  local checked = 0
  for _, fence in ipairs(FENCES) do
    if fence.lang == "teal" or fence.lang == "lua" then
      checked = checked + 1
      local result = teal.check(fence.body .. "\n", {include_dirs = {dir}})
      local issue = result.errors[1] or result.warnings[1]
      if issue then
        offenders[#offenders + 1] = fence.file .. ":" .. fence.line ..
        ": " .. (issue.message or "does not compile")
      end
    end
  end
  assert(checked > 0, "no fence was compiled; the harness is broken")
  assert(#offenders == 0,
    "snippet(s) that do not compile as real code — warnings are errors " ..
    "here, exactly as they are for the reader; a fence ABOUT " ..
    "non-compiling code is prose, so tag it ```text:\n" ..
    table.concat(offenders, "\n"))
  print("compiled: " .. checked .. " snippets")
end
test_every_snippet_compiles()
