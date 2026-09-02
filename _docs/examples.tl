--- Derived example fences: a markdown fence whose info string names an
--- `Example_*` function carries that function's body, verbatim.
---
---     ```teal example=cosmic/json_example.tl#Example_decode
---     ```
---
--- The body is what `--make example` runs and checks, `-- Output:`
--- block included, so a page shows code that ran and the output it
--- produced. `bin/cosmic _docs/derive.tl` rewrites every such fence;
--- `_build/docs_test.tl` fails when a committed fence differs from its
--- source. A reference that names no function, or a function that is
--- not there, is reported rather than skipped: a fence silently left as
--- typed is the hand-written output claim this mechanism replaces.

local fs = require("cosmic.fs")

local record ExamplesModule
  --- One `example=<path>#<name>` reference.
  record Ref
    path: string
    name: string
  end
  --- One derived fence as committed in a document.
  record Fence
    --- Line number of the opening fence.
    line: integer
    --- Leading whitespace of the opening fence (a fence inside a list).
    indent: string
    ref: Ref
    --- The committed body, indentation stripped, without its final newline.
    body: string
  end
  parse_ref: function(info: string): Ref | nil
  body_of: function(ref: Ref): string | nil, string
  fences: function(text: string): {Fence}
  render: function(text: string): string, {string}
  documents: function(): {string}
end

local type Ref = ExamplesModule.Ref
local type Fence = ExamplesModule.Fence

--- The documents whose fences are derived: the same population the
--- snippet gate compiles, minus nothing.
local DOCUMENTS < const >: {string} = {"docs", "README.md", "AGENTS.md", "skills"}

--- Parse the reference out of a fence's info string.
--- @param info string Everything after the language on the fence line
--- @return Ref | nil The reference, or nil when the fence is not derived
local function parse_ref(info: string): Ref | nil
  local path, name = info:match("example=([^%s#]+)#([%w_]+)")
  if path == nil or name == nil then
    return nil
  end
  return {path = path, name = name}
end

--- The body of one `Example_*` function: one indentation level removed,
--- blank first and last lines trimmed.
---
--- An example is a top-level `local function`, so its body runs from
--- the line after the definition to the first line that is exactly
--- `end` at column 0. Reading the body by that rule rather than by
--- keyword nesting keeps a `local record` inside the body from closing
--- it early.
--- @param ref Ref Which function
--- @return string | nil The body, or nil when the file or function is missing
--- @return string Why
local function body_of(ref: Ref): string | nil, string
  local source = fs.read(ref.path)
  if not source then
    return nil, ref.path .. ": cannot read"
  end
  local lines: {string} = {}
  local inside = false
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    if inside then
      if line == "end" then
        break
      end
      if line:sub(1, 2) == "  " then
        line = line:sub(3)
      end
      lines[#lines + 1] = line
    elseif line:match("^local%s+function%s+" .. ref.name .. "%s*%(%s*%)") then
      inside = true
    end
  end
  if not inside then
    return nil, ref.path .. ": no `local function " .. ref.name .. "()`"
  end
  while #lines > 0 and lines[1]:match("^%s*$") do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

--- Every derived fence in a document.
---
--- The fence grammar is the snippet gate's: any line that is only
--- backticks after optional indentation toggles a fence, and a body
--- line carries the opening fence's indentation, which is stripped.
--- @param text string The document
--- @return {Fence} In document order
local function fences(text: string): {Fence}
  local out: {Fence} = {}
  local in_code = false
  local lineno, start = 0, 0
  local indent = ""
  local ref: Ref = nil
  local body: {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local lead, _lang, info = line:match("^(%s*)```(%w*)(.*)$")
    if lead then
      if in_code then
        if ref then
          out[#out + 1] = {
            line = start, indent = indent, ref = ref,
            body = table.concat(body, "\n"),
          }
        end
        in_code, ref = false, nil
      else
        in_code, indent, start, body = true, lead, lineno, {}
        ref = parse_ref(info)
      end
    elseif in_code and ref then
      if indent ~= "" and line:sub(1, #indent) == indent then
        line = line:sub(#indent + 1)
      end
      body[#body + 1] = line
    end
  end
  return out
end

--- A document with every derived fence rewritten from its source.
--- @param text string The document as committed
--- @return string The document with fresh fence bodies
--- @return {string} References that could not be resolved
local function render(text: string): string, {string}
  local problems: {string} = {}
  local out: {string} = {}
  local in_code = false
  local skipping = false
  local indent = ""
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local lead, _lang, info = line:match("^(%s*)```(%w*)(.*)$")
    if lead then
      out[#out + 1] = line
      if in_code then
        in_code, skipping = false, false
      else
        in_code, indent = true, lead
        local ref = parse_ref(info)
        if ref then
          local body, err = body_of(ref)
          if body then
            skipping = true
            for body_line in (body .. "\n"):gmatch("([^\n]*)\n") do
              out[#out + 1] = body_line == "" and "" or indent .. body_line
            end
          else
            problems[#problems + 1] = err
          end
        end
      end
    elseif not skipping then
      out[#out + 1] = line
    end
  end
  -- The gmatch above appended one line per newline, so the trailing
  -- newline of the input is already accounted for.
  local rendered = table.concat(out, "\n")
  return rendered, problems
end

--- Every document the derivation covers, in path order.
--- @return {string} Paths relative to the repo root
local function documents(): {string}
  local out: {string} = {}
  for _, entry in ipairs(DOCUMENTS) do
    if fs.is_dir(entry) then
      local found = fs.find(entry, {glob = "*.md"})
      for _, path in ipairs(found or {}) do
        out[#out + 1] = path
      end
    elseif fs.is_file(entry) then
      out[#out + 1] = entry
    end
  end
  table.sort(out)
  return out
end

local M: ExamplesModule = {
  parse_ref = parse_ref,
  body_of = body_of,
  fences = fences,
  render = render,
  documents = documents,
}

return M
