--- Every code snippet a page shows a reader is real code: the checker
--- and the formatter hold each fence to the same bar as a file in a
--- gated project. This module is the shared half of that gate: the
--- fence scanner, the example project the pages describe, and the two
--- checks. `_build/snippets_test.tl` runs them over the whole repo;
--- this file run as a script checks the files named on its command
--- line, which is the inner loop while a page is being written:
---
---     bin/cosmic _docs/snippets.tl docs/howto/test.md
---
--- Two rules, one population:
---   * the FORMATTER is the authority on shape: every fence is a
---     formatter fixpoint, so a snippet copied into a gated project does
---     not fail `--make fmt` on arrival;
---   * the CHECKER is the authority on meaning: every fence compiles at
---     full strictness, warnings included, because that is what the
---     reader's own files are held to.
---
--- There is no opt-out word. A fence tagged `teal` claims to be Teal;
--- prose that shows a compile error, a deliberate mis-format, or a
--- skeleton with `...` in it is not Teal, and says so by not claiming to
--- be (```text).

local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local seam = require("_tool.seam")
local teal = require("cosmic.teal")

local record SnippetsModule
  --- One fenced block, as a reader sees it.
  record Fence
    file: string
    line: integer
    lang: string
    --- Everything after the language on the fence line: `file=<path>`
    --- names the file a tutorial has the reader create.
    info: string
    body: string
  end
  FIXTURES: {string: string}
  markdown_fences: function(path: string, out: {Fence})
  doc_comment_fences: function(path: string, out: {Fence})
  fences_of: function(paths: {string}): {Fence}
  write_fixtures: function(dir: string): boolean, string
  formatter_offenders: function(fences: {Fence}): {string}, integer
  compile_offenders: function(fences: {Fence}, fixture_dir: string): {string}, integer
end

local type Fence = SnippetsModule.Fence

--- The example project the pages describe — `greet.text` in the
--- quickstart, `mymod` in the module how-to, `cosmic.mymod` in the
--- contributor walkthrough. A snippet about the reader's project is
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

--- Fenced blocks in a markdown file.
--- @param path string The markdown file
--- @param out {Fence} Accumulator
local function markdown_fences(path: string, out: {Fence})
  local text = fs.read(path) or ""
  local in_code = false
  local lineno, start = 0, 0
  local lang, indent, info = "", "", ""
  local body: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    -- A fence may be indented (a snippet inside a list item); anchoring
    -- at column 0 let an indented block escape the gate entirely, so it
    -- was "real code" only until someone read it.
    local lead, fence, rest = line:match("^(%s*)```(%w*)(.*)$")
    if fence then
      if in_code then
        out[#out + 1] = {
          file = path, line = start, lang = lang, info = info,
          body = table.concat(body, "\n"),
        }
        in_code = false
      else
        in_code, lang, indent, info, start, body = true, fence, lead, rest, lineno, {}
      end
    elseif in_code then
      -- Body lines carry the list indentation of their opening fence;
      -- strip exactly that prefix so the checkers see the code as its
      -- reader does.
      if indent ~= "" and line:sub(1, #indent) == indent then
        line = line:sub(#indent + 1)
      end
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
  local text = fs.read(path) or ""
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
            file = path, line = start, lang = lang, info = "",
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

--- Every fence the named files show a reader.
--- @param paths {string} Markdown and Teal files
--- @return {Fence} In file order
local function fences_of(paths: {string}): {Fence}
  local out: {Fence} = {}
  for _, path in ipairs(paths) do
    if path:sub(-3) == ".md" then
      markdown_fences(path, out)
    elseif path:sub(-3) == ".tl" then
      doc_comment_fences(path, out)
    end
  end
  return out
end

--- Write the example project the pages describe.
--- @param dir string Where
--- @return boolean, string Success, or false plus the reason
local function write_fixtures(dir: string): boolean, string
  for path, source in pairs(FIXTURES) do
    local full = fs.join(dir, path)
    local mok, merr = fs.make_dirs(fs.dirname(full))
    if not mok then
      return false, fs.dirname(full) .. ": " .. (merr or "cannot create")
    end
    local wok, werr = fs.write(full, source)
    if not wok then
      return false, full .. ": " .. (werr or "cannot write")
    end
  end
  return true
end

--- Fences the formatter would rewrite.
--- @return {string} One line per offender, with the formatted form
--- @return integer How many fences the formatter parsed
local function formatter_offenders(fences: {Fence}): {string}, integer
  local format = require("cosmic.format")
  local offenders: {string} = {}
  local checked = 0
  for _, fence in ipairs(fences) do
    if fence.lang == "teal" or fence.lang == "lua" then
      local ext = fence.lang == "lua" and ".lua" or ".tl"
      local result = format.format(fence.body .. "\n", "snippet" .. ext)
      if result.ok then
        checked = checked + 1
        if result.code ~= fence.body .. "\n" then
          offenders[#offenders + 1] = fence.file .. ":" .. fence.line ..
          ": formatter disagrees; formatted form:\n" .. (result.code or "")
        end
      end
    end
  end
  return offenders, checked
end

--- Fences that do not compile at full strictness.
---
--- A tutorial's files are its own fixtures: every fence whose info
--- string names a file is written under the fixture directory first,
--- so a later fence that requires an earlier one resolves it. A fence
--- saved as a `*_test.tl` is a test file, and is checked the way the
--- build checks one: with the runner tail appended, so its `test_*`
--- functions count as used.
--- @param fixture_dir string Where `write_fixtures` put the example project
--- @return {string} One line per offender
--- @return integer How many fences were compiled
local function compile_offenders(fences: {Fence}, fixture_dir: string): {string}, integer
  local offenders: {string} = {}
  local checked = 0
  for _, fence in ipairs(fences) do
    local named = fence.info:match("file=(%S+)")
    if named and named:sub(-3) == ".tl" then
      local full = fs.join(fixture_dir, named)
      local _mk, _mkerr = fs.make_dirs(fs.dirname(full))
      local _w, _werr = fs.write(full, fence.body .. "\n")
    end
  end
  for _, fence in ipairs(fences) do
    if fence.lang == "teal" or fence.lang == "lua" then
      checked = checked + 1
      local source = fence.body .. "\n"
      local named = fence.info:match("file=(%S+)")
      if named then
        source = seam.augment_source(named, source).source
      end
      local result = teal.check(source, {include_dirs = {fixture_dir}})
      local issue = result.errors[1] or result.warnings[1]
      if issue then
        offenders[#offenders + 1] = fence.file .. ":" .. fence.line ..
        ": " .. (issue.message or "does not compile")
      end
    end
  end
  return offenders, checked
end

local M: SnippetsModule = {
  FIXTURES = FIXTURES,
  markdown_fences = markdown_fences,
  doc_comment_fences = doc_comment_fences,
  fences_of = fences_of,
  write_fixtures = write_fixtures,
  formatter_offenders = formatter_offenders,
  compile_offenders = compile_offenders,
}

if proc.is_main() then
  local paths: {string} = {}
  for i = 1, #arg do
    paths[#paths + 1] = arg[i]
  end
  if #paths == 0 then
    io.stderr:write("usage: cosmic _docs/snippets.tl <file.md|file.tl>...\n")
    os.exit(2)
  end
  local dir, derr = fs.temp_dir(fs.join(os.getenv("TMPDIR") or "/tmp", "snippets-XXXXXX"))
  if not dir then
    io.stderr:write("snippets: " .. tostring(derr) .. "\n")
    os.exit(1)
  end
  local wok, werr = write_fixtures(dir)
  if not wok then
    io.stderr:write("snippets: " .. werr .. "\n")
    os.exit(1)
  end
  local found = fences_of(paths)
  local bad_fmt, formatted = formatter_offenders(found)
  local bad_check, compiled = compile_offenders(found, dir)
  for _, line in ipairs(bad_fmt) do
    io.stderr:write(line .. "\n")
  end
  for _, line in ipairs(bad_check) do
    io.stderr:write(line .. "\n")
  end
  local _ok, _err = fs.remove_all(dir)
  print("snippets: " .. compiled .. " compiled, " .. formatted ..
    " formatted, " .. (#bad_fmt + #bad_check) .. " offender(s)")
  if #bad_fmt + #bad_check > 0 then
    os.exit(1)
  end
end

return M
