--- The block sequence `build.doctest.markdown` reads out of a doc into
--- one Teal source string: the compiled file doc/meta.md promises,
--- indistinguishable in shape from a hand-written `_test.tl` once it
--- exists. Every example is a top-level function; nothing here runs
--- anything or discovers anything, both stay `build.test`'s and
--- `build.analyzer`'s jobs.
local markdown = require("build.doctest.markdown")
local String = require("cosmic.string")

local type Block = markdown.Block

local record FileWrite
  path: string
  content: string
  line: integer
end

local record Example
  files: {FileWrite}
  --- Each opening statement (`teal`/`lua`) or `continue` block's own
  --- content, in doc order, joined with a blank line between them when
  --- rendered.
  statements: {string}
  has_output: boolean
  --- The `output` block's own text, exactly as authored; comparison
  --- semantics (right-trimmed, otherwise exact) live in `render`.
  output_text: string
  --- `test_<n>` when `has_output`, `example_<n>` otherwise; assigned
  --- once every block has been read, so numbering never depends on
  --- which examples turn out runnable.
  name: string
  --- The doc line of the block that opens it.
  line: integer
end

local record Item
  kind: string -- "comment" | "example"
  text: string | nil
  example: Example | nil
end

local record generate
end

--- Whether a block's content opens with a shebang line: real only as a
--- file's own first line, never as function-body code, so it forces a
--- skip regardless of the block's declared tag -- but only for a block
--- that would otherwise BECOME function-body code. A `file=` block's
--- content is a real file's content, where a shebang is ordinary, so
--- this is never asked of one.
local function is_shebang(content: string): boolean
  local first_line = content:match("^([^\n]*)")
  return first_line ~= nil and first_line:sub(1, 2) == "#!"
end

--- A Lua string literal holding `s`, exactly. `string.format("%q", s)`
--- escapes every byte `s` could hold, including a quote or a newline,
--- so a companion file's content or an expected output block round
--- trips through the generated source whatever bytes it carries.
local function quote(s: string): string
  return string.format("%q", s)
end

--- Turns the block sequence into the `Item` list `render` walks: one
--- entry per skip comment or per example, in the order examples become
--- runnable functions.
--- @return {Item} | nil nil on a grammar error -- an `output` or
---   `continue` with nothing open to attach to, or a
---   `file=` block no entry block ever claims
--- @return string why, naming the source line the block sits at
local function to_items(blocks: {Block}): {Item} | nil, string
  local items: {Item} = {}
  local pending_files: {FileWrite} = {}
  local current: Example | nil = nil

  for _, b in ipairs(blocks) do
    if b.lang == "needs" then
      -- The doc's declaration, which `from_blocks` writes at the top.
    elseif b.lang == "text" then
      current = nil
    elseif b.lang == "output" then
      if current == nil then
        return nil, "line " .. b.line ..
          ": an output block must immediately follow an example"
      end
      if current.has_output then
        return nil, "line " .. b.line .. ": this example already has an output block"
      end
      current.has_output = true
      current.output_text = b.content
      current = nil
    else
      -- b.lang is "teal" or "lua": markdown.parse_tag refuses anything else.
      local shebang_here = b.modifiers.file == nil and is_shebang(b.content)
      if b.modifiers.skip ~= nil or shebang_here then
        local reason: string
        if shebang_here then
          reason = "a shebang line is only ever valid as a real file's " ..
            "first line, never as function-body code"
        else
          reason = b.modifiers.skip or ""
        end
        items[#items + 1] = { kind = "comment", text = "-- skipped: " .. reason }
        pending_files = {}
        current = nil
      elseif b.modifiers.file ~= nil then
        -- A `file=` block attaches to whichever example is open,
        -- whether it was written before the entry (queued in
        -- `pending_files` until an entry claims them) or after it
        -- (attached to `current` directly, in place, so a later
        -- `continue` or `output` still finds the same example open).
        -- Only a `file=` with nothing open at all -- before any entry
        -- in its run, or after the run already closed -- falls back
        -- to `pending_files`, and is refused below if no entry ever
        -- follows to claim it.
        local write: FileWrite = { path = b.modifiers.file, content = b.content,
                                    line = b.line }
        if current ~= nil then
          current.files[#current.files + 1] = write
        else
          pending_files[#pending_files + 1] = write
        end
      elseif b.modifiers.continue then
        if current == nil then
          return nil, "line " .. b.line ..
            ": 'teal continue' has no open example to continue"
        end
        current.statements[#current.statements + 1] = b.content
      else
        local example: Example = {
          files = pending_files,
          statements = { b.content },
          has_output = false,
          output_text = "",
          name = "",
          line = b.line,
        }
        pending_files = {}
        items[#items + 1] = { kind = "example", example = example }
        current = example
      end
    end
  end

  if #pending_files > 0 then
    return nil, "line " .. pending_files[1].line ..
      ": a file= block has no entry block to attach it to"
  end

  local n = 0
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil then
      n = n + 1
      example.name = (example.has_output and "test_" or "example_") .. n
    end
  end
  return items, ""
end

--- Splits `text` back into its own lines, indenting every non-blank one
--- so the generated source reads like a function body -- Teal itself
--- does not care, but a build failure quoting this file should.
local function emit_indented(out: {string}, text: string)
  for line in String.lines(text) do
    if line == "" then
      out[#out + 1] = ""
    else
      out[#out + 1] = "  " .. line
    end
  end
end

--- Renders one example's function, its companion files materialized
--- first, its own statements verbatim, and -- only when it declared an
--- `output` block -- its own print capture and assertion appended
--- after them.
local function emit_example(out: {string}, file: string, example: Example)
  out[#out + 1] = "local function " .. example.name .. "(tmp: string)"
  out[#out + 1] = "  local _ = tmp"
  for _, f in ipairs(example.files) do
    out[#out + 1] = "  __doctest_write(tmp, " .. quote(f.path) .. ", " ..
      quote(f.content) .. ")"
  end
  if example.has_output then
    out[#out + 1] = "  local print, __doctest_get = __doctest_capture()"
    out[#out + 1] = "  local _ = print"
  end
  for _, statement in ipairs(example.statements) do
    emit_indented(out, statement)
  end
  if example.has_output then
    out[#out + 1] = "  local __doctest_got = __doctest_get()"
    out[#out + 1] = "  local __doctest_want = " .. quote(example.output_text)
    out[#out + 1] =
      '  if (__doctest_got):gsub("%s+$", "") ~= (__doctest_want):gsub("%s+$", "") then'
    out[#out + 1] = '    error("doctest: " .. ' .. quote(file) ..
      ' .. ": output did not match\\nwant:\\n" .. __doctest_want ..'
    out[#out + 1] = '      "\\ngot:\\n" .. __doctest_got)'
    out[#out + 1] = "  end"
  end
  out[#out + 1] = "end"
  if not example.has_output then
    -- Never called: `build.analyzer.analyze`'s `^test_` discovery only
    -- ever names this a test when it is one, so nothing after this
    -- compile step calls it, and tl's own "unused function" warning
    -- about it is not a false positive the way a real test's is --
    -- this line is what makes it true anyway, on purpose, the same
    -- shape `local _ = tmp` above already uses for an argument no
    -- statement here happens to read.
    out[#out + 1] = "local _ = " .. example.name
  end
  out[#out + 1] = ""
end

--- The block sequence into one Teal source string: a header comment,
--- the shared `__doctest_write`/`__doctest_capture` helpers when any
--- example actually needs one, then one function per example (or one
--- comment for a skip), in document order.
--- @param file string the doc's own path, named in a generated
---   assertion's failure message and in the header comment; never
---   prefixed onto an error this function itself returns -- the caller
---   already does that for every module, doc-derived or not
--- Why `fields`, a doc's `needs` line, cannot stand between the braces
--- of a table literal as it is, or "" when it can: a brace closing one
--- it did not open, one left open, or a comment or long bracket that
--- would swallow the close. Strings are skipped; the build reads what
--- is left field by field (`build.analyzer`), so this holds only that
--- the line stays one literal.
local function unspliceable(fields: string): string
  local depth = 0
  local i = 1
  while i <= #fields do
    local c = fields:sub(i, i)
    if c == '"' or c == "'" then
      local j = i + 1
      while j <= #fields and fields:sub(j, j) ~= c do
        if fields:sub(j, j) == "\\" then j = j + 1 end
        j = j + 1
      end
      if j > #fields then return "leaves a string open" end
      i = j
    elseif c == "{" then
      depth = depth + 1
    elseif c == "}" then
      depth = depth - 1
      if depth < 0 then return "closes a brace it never opened" end
    elseif fields:sub(i, i + 1) == "--" then
      return "holds a comment"
    elseif fields:sub(i, i + 1) == "[[" or fields:sub(i, i + 1) == "[=" then
      return "holds a long bracket"
    end
    i = i + 1
  end
  if depth ~= 0 then return "leaves a brace open" end
  return ""
end

--- A doc's `needs` block (`build.doctest.markdown`) becomes the
--- module's top-level `needs` call (`cosmic.test`), which the build
--- reads as it does a test module's. A second is refused.
-- TODO: confine what a doc's examples start (doc/guides start this
-- program and /bin/sh, so their verdicts never stand), once a generated
-- module can declare it where build.filesystem_observations is out of
-- reach: another project's docs compile without cosmic's build/.
function generate.from_blocks(blocks: {Block}, file: string): string | nil, string
  local items, trouble = to_items(blocks)
  if items == nil then
    return nil, trouble
  end
  local declared: Block = nil
  for _, b in ipairs(blocks) do
    if b.lang == "needs" and declared ~= nil then
      return nil, "line " .. b.line .. ": a doc declares its needs once; line " ..
        declared.line .. " did already"
    elseif b.lang == "needs" then
      local why = unspliceable(b.content)
      if why ~= "" then
        return nil, "line " .. b.line .. ": the needs line " .. why
      end
      declared = b
    end
  end

  local needs_fs = false
  local needs_capture = false
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil then
      if #example.files > 0 then
        needs_fs = true
      end
      if example.has_output then
        needs_capture = true
      end
    end
  end

  local out: {string} = {}
  out[#out + 1] = "-- Generated by build.doctest from " .. file .. "."
  out[#out + 1] = "-- A rebuild replaces this file whole from the doc; never edit it here"
  out[#out + 1] = ""
  if declared ~= nil then
    out[#out + 1] = 'local __doctest_test = require("cosmic.test")'
    out[#out + 1] = "__doctest_test.needs { " .. declared.content .. " }"
    out[#out + 1] = ""
  end

  if needs_fs then
    -- Named `__doctest_fs`, never the bare `Fs` a doc's own entry
    -- statements would naturally choose for their own
    -- `require("cosmic.fs")`: that name has to stay free for a doc
    -- author to declare again, inside their own entry, without
    -- shadowing a module-level local of the same name -- unlike
    -- shadowing the GLOBAL `print` (see `__doctest_capture` below),
    -- shadowing an ordinary LOCAL carries a source position in tl's own
    -- warning, so it would not match the one narrow message
    -- `build.importer`'s discount looks for.
    out[#out + 1] = 'local __doctest_fs = require("cosmic.fs")'
    out[#out + 1] = ""
    out[#out + 1] =
      "--- Materializes one `file=` companion block into an example's own"
    out[#out + 1] = "--- project, under its fresh temp directory, before its entry runs."
    out[#out + 1] =
      "local function __doctest_write(tmp: string, path: string, content: string)"
    out[#out + 1] = '  local dir = path:match("^(.*)/[^/]+$")'
    out[#out + 1] = "  if dir ~= nil then"
    out[#out + 1] = '    local made, trouble = __doctest_fs.mkdirs(tmp .. "/" .. dir)'
    out[#out + 1] = "    if not made then"
    out[#out + 1] =
      '      error("doctest: could not create " .. tmp .. "/" .. dir .. ": " .. trouble)'
    out[#out + 1] = "    end"
    out[#out + 1] = "  end"
    out[#out + 1] =
      '  local ok, trouble = __doctest_fs.write(tmp .. "/" .. path, content)'
    out[#out + 1] = "  if not ok then"
    out[#out + 1] =
      '    error("doctest: could not write " .. tmp .. "/" .. path .. ": " .. trouble)'
    out[#out + 1] = "  end"
    out[#out + 1] = "end"
    out[#out + 1] = ""
  end

  if needs_capture then
    out[#out + 1] =
      "--- A fresh `print` and a way to read back everything it caught, one"
    out[#out + 1] =
      "--- pair per running example. `core/surface.c`'s `surface_print` is a"
    out[#out + 1] =
      "--- plain global -- tab-separating its arguments and ending every call"
    out[#out + 1] = "--- in one newline -- and this mirrors that exactly."
    out[#out + 1] =
      "local function __doctest_capture(): function(any...), function(): string"
    out[#out + 1] = "  local lines: {string} = {}"
    out[#out + 1] = "  local into = function(...: any): ()"
    out[#out + 1] = "    local parts: {string} = {}"
    out[#out + 1] = '    local n = select("#", ...)'
    out[#out + 1] = "    for i = 1, n do"
    out[#out + 1] = "      parts[i] = tostring((select(i, ...)))"
    out[#out + 1] = "    end"
    out[#out + 1] = '    lines[#lines + 1] = table.concat(parts, "\\t") .. "\\n"'
    out[#out + 1] = "  end"
    out[#out + 1] = "  local get = function(): string"
    out[#out + 1] = "    return table.concat(lines)"
    out[#out + 1] = "  end"
    out[#out + 1] = "  return into, get"
    out[#out + 1] = "end"
    out[#out + 1] = ""
  end

  for _, item in ipairs(items) do
    if item.kind == "comment" then
      local text = item.text
      if text ~= nil then
        out[#out + 1] = text
        out[#out + 1] = ""
      end
    else
      local example = item.example
      if example ~= nil then
        emit_example(out, file, example)
      end
    end
  end

  -- Where each example opens in the doc, which `cosmic docs` shows in
  -- place of this file's own lines -- see `build.importer`'s
  -- `origin_lines`.
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil then
      out[#out + 1] = "-- line " .. example.name .. " " .. example.line
    end
  end

  return table.concat(out, "\n") .. "\n", ""
end

return generate
