--- Turns the block sequence [`build.doctest.markdown`] reads out of a doc
--- into one Teal source string: the compiled file doc/writing.md promises,
--- shaped like a hand-written `_test.tl`. Every example is a top-level
--- function. Running them and discovering them stay [`build.test`]'s and
--- [`build.syntax_analyzer`]'s jobs.
local markdown = require("build.doctest.markdown")
local String = require("cosmic.string")

local type Block = markdown.Block

local record FileWrite
  path: string
  content: string
  line: integer
end

--- One command line of a `sh` block.
local record Command
  --- The words after `cosmic`.
  words: {string}
  --- The status it exits with: 0, or what a trailing `# exits <n>` says.
  status: integer
end

local record Example
  files: mut {FileWrite}
  --- Each opening statement (`teal`/`lua`) or `continue` block's own
  --- content, in doc order, joined with a blank line between them when
  --- rendered.
  statements: mut {string}
  mut has_output: boolean
  --- The `output` block's own text, exactly as authored; comparison
  --- semantics (right-trimmed, otherwise exact) live in `render`.
  mut output_text: string
  --- `test_<n>` when `has_output`, `example_<n>` otherwise; assigned
  --- once every block has been read, so numbering never depends on
  --- which examples turn out runnable.
  mut name: string
  --- The doc line of the block that opens it.
  line: integer
  --- For an example a `sh` block opens, each of its command lines;
  --- nil for a Teal or Lua one.
  commands?: {Command}
end

local record Item
  --- `"comment"` or `"example"`.
  kind: string
  text?: string
  example?: Example
end

local record generate
  --- One guide example as a reader copies it: the statements of its
  --- opening block and its `continue` blocks, joined as the generated
  --- test joins them.
  record Entry
    source: string
    --- The doc line of the block that opens it.
    line: integer
    --- Whether `file=` companions come with it: its code then reads
    --- them through the generated test's `tmp`, and is a project's
    --- entry rather than a script to run alone.
    companions: boolean
    output: boolean
  end
end

--- Whether a block's content opens with a shebang line. A shebang is
--- valid only as a file's first line, never as function-body code, so it
--- forces a skip whatever the block's tag. A `file=` block is a real
--- file's content, where a shebang is ordinary, so this is never asked
--- of one.
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

--- A command line's words, and the text of a `#` comment after them
--- ("" for none).
local record Split
  words: {string}
  comment: string
end

--- The characters a shell would read as more than a word outside
--- quotes: a pipe, a redirect, a variable, a glob, a subshell. A `sh`
--- block runs `cosmic` alone, with no shell, so it refuses them rather
--- than run something other than what a reader's shell would.
local shell_special <const> = "|&;<>()$`*?[]{}~"

--- The words of one command line of a `sh` block, as a POSIX shell
--- splits them: spaces apart, `'...'` literal, `"..."` with `\` before
--- `"`, `\`, `$` or a backquote, and `\` before any one character
--- outside quotes. A `#` that begins a word ends the line.
--- @return Split | nil nil for an unclosed quote or a character
---   from `shell_special` outside quotes
--- @return string why
local function words_of(line: string): Split?, string
  local words: mut {string} = {}
  local word: string? = nil
  local comment = ""
  local i = 1
  while i <= #line do
    local c = line:sub(i, i)
    if c == " " or c == "\t" or (c == "\r" and i == #line) then
      if word ~= nil then
        words[#words + 1] = word
        word = nil
      end
    elseif c == "#" and word == nil then
      comment = String.trim(line:sub(i + 1))
      break
    elseif c == "'" then
      local close = line:find("'", i + 1, true)
      if close == nil then
        return nil, "a ' is never closed"
      end
      word = (word or "") .. line:sub(i + 1, close - 1)
      i = close
    elseif c == '"' then
      local text = ""
      local j = i + 1
      local closed = false
      while j <= #line do
        local d = line:sub(j, j)
        if d == '"' then
          closed = true
          break
        elseif d == "\\" and j < #line and ('"\\$`'):find(line:sub(j + 1, j + 1), 1, true) ~= nil then
          text = text .. line:sub(j + 1, j + 1)
          j = j + 1
        elseif d == "$" or d == "`" then
          return nil, "a " .. d .. " inside \"...\" is the shell's, which a sh block does not run"
        else
          text = text .. d
        end
        j = j + 1
      end
      if not closed then
        return nil, 'a " is never closed'
      end
      word = (word or "") .. text
      i = j
    elseif c == "\\" then
      if i == #line then
        return nil, "a line ends in \\; write the command on one line"
      end
      word = (word or "") .. line:sub(i + 1, i + 1)
      i = i + 1
    elseif shell_special:find(c, 1, true) ~= nil then
      return nil, "a " .. c .. " outside quotes is the shell's, which a sh block does not run; " ..
        "quote it, or show the line in a text block"
    else
      word = (word or "") .. c
    end
    i = i + 1
  end
  if word ~= nil then
    words[#words + 1] = word
  end
  return { words = words, comment = comment }, ""
end

--- The commands of a `sh` block: a blank line or a comment is none,
--- and every other line runs `cosmic`. A comment `# exits <n>` after a
--- command is the status it exits with, 0 where it has none.
--- @return {Command} | nil nil for a line [`words_of`] refuses, or one
---   that runs anything but `cosmic`
--- @return string why, naming the doc line
local function commands_of(b: Block): {Command}?, string
  local commands: mut {Command} = {}
  local at = b.line
  for line in String.lines(b.content) do
    at = at + 1
    local split, trouble = words_of(line)
    if split == nil then
      return nil, "line " .. tostring(at) .. ": " .. trouble
    end
    local words = split.words
    if #words > 0 then
      if words[1] ~= "cosmic" then
        return nil, "line " .. tostring(at) .. ": a sh block runs cosmic alone, so each line begins " ..
          "`cosmic`; show any other command in a text block"
      end
      local after: mut {string} = {}
      for k = 2, #words do after[#after + 1] = assert(words[k]) end
      local status = math.tointeger(tonumber(split.comment:match("^exits (%d+)$")))
      local command: Command = { words = after, status = status or 0 }
      commands[#commands + 1] = command
    end
  end
  if #commands == 0 then
    return nil, "line " .. tostring(b.line) .. ": a sh block runs no command"
  end
  return commands, ""
end

--- Turns the block sequence into the [`Item`] list `render` walks: one
--- entry per skip comment or per example, in the order examples become
--- runnable functions.
--- @return {Item} | nil nil on a grammar error -- an `output` or
---   `continue` with nothing open to attach to, or a
---   `file=` block no entry block ever claims
--- @return string why, naming the source line the block sits at
local function to_items(blocks: {Block}): {Item}?, string
  local items: mut {Item} = {}
  local pending_files: mut {FileWrite} = {}
  local current: Example? = nil

  for _, b in ipairs(blocks) do
    if b.lang == "policy" then
      -- The doc's declaration, which [`from_blocks`] writes at the top.
    elseif b.lang == "text" then
      current = nil
    elseif b.lang == "sh" then
      local commands, why = commands_of(b)
      if commands == nil then
        return nil, why
      end
      local example: Example = {
        files = pending_files,
        statements = {},
        has_output = false,
        output_text = "",
        name = "",
        line = b.line,
        commands = commands,
      }
      pending_files = {}
      items[#items + 1] = { kind = "example", example = example }
      current = example
    elseif b.lang == "output" then
      if current == nil then
        return nil, "line " .. tostring(b.line) ..
          ": an output block must immediately follow an example"
      end
      if current.has_output then
        return nil, "line " .. tostring(b.line) .. ": this example already has an output block"
      end
      current.has_output = true
      current.output_text = b.content
      current = nil
    else
      -- b.lang is "teal" or "lua": markdown.parse_tag refuses anything else.
      local file_modifier = b.modifiers.file
      local shebang_here = file_modifier == nil and is_shebang(b.content)
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
      elseif file_modifier ~= nil then
        -- A `file=` block attaches to the open example, so a later
        -- `continue` or `output` still finds that example open. With
        -- none open (before any entry in its run, or after the run
        -- closed) it waits in `pending_files` for the next entry, and is
        -- refused below if none follows.
        local write: FileWrite = { path = file_modifier, content = b.content,
          line = b.line }
        if current ~= nil then
          current.files[#current.files + 1] = write
        else
          pending_files[#pending_files + 1] = write
        end
      elseif b.modifiers.continue then
        if current == nil then
          return nil, "line " .. tostring(b.line) ..
            ": 'teal continue' has no open example to continue"
        end
        if current.commands ~= nil then
          return nil, "line " .. tostring(b.line) ..
            ": 'teal continue' cannot continue a sh block"
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
    return nil, "line " .. tostring(pending_files[1].line) ..
      ": a file= block has no entry block to attach it to"
  end

  local n = 0
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil then
      n = n + 1
      example.name = (if example.has_output then "test_" else "example_" end) .. tostring(n)
    end
  end
  return items, ""
end

--- The Teal and Lua examples a doc's blocks make, as [`Entry`] values,
--- skips and `sh` blocks left out:
--- what [`from_blocks`] turns into functions, without the wrapping, so a
--- check can hold each to compiling on its own.
--- @return {generate.Entry} | nil nil on the grammar error [`from_blocks`] names
--- @return string why
function generate.entries(blocks: {Block}): {generate.Entry}?, string
  local items, trouble = to_items(blocks)
  if items == nil then
    return nil, trouble
  end
  local out: mut {generate.Entry} = {}
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil and example.commands == nil then
      out[#out + 1] = { source = table.concat(example.statements, "\n\n"),
        line = example.line, companions = #example.files > 0,
        output = example.has_output }
    end
  end
  return out, ""
end

--- Appends the lines of `text` to `out`, indenting every non-blank one
--- so a build failure quoting the generated source reads like a
--- function body. Teal does not care.
local function emit_indented(out: mut {string}, text: string)
  for line in String.lines(text) do
    if line == "" then
      out[#out + 1] = ""
    else
      out[#out + 1] = "  " .. line
    end
  end
end

--- Renders one example's function: its companion files first, then its
--- statements verbatim, then, only when it has an `output` block, the
--- print capture and the assertion on it.
local function emit_example(out: mut {string}, file: string, example: Example)
  out[#out + 1] = "local function " .. example.name .. "(tmp: string)"
  out[#out + 1] = "  local _ = tmp"
  for _, f in ipairs(example.files) do
    table.insert(out, "  __doctest_write(tmp, " .. quote(f.path) .. ", " ..
        quote(f.content) .. ")")
  end
  if example.has_output then
    out[#out + 1] = "  local print, __doctest_get = __doctest_capture()"
    out[#out + 1] = "  local _ = print"
  end
  for _, statement in ipairs(example.statements) do
    emit_indented(out, statement)
  end
  for _, command in ipairs(example.commands or {}) do
    local quoted: mut {string} = {}
    for _, word in ipairs(command.words) do quoted[#quoted + 1] = quote(word) end
    out[#out + 1] = "  do"
    local call = "    local said = __doctest_cosmic(tmp, { " .. table.concat(quoted, ", ") .. " }, " ..
      tostring(command.status) .. ")"
    out[#out + 1] = call
    out[#out + 1] = '    if said ~= "" then print((said:gsub("\\n$", ""))) end'
    out[#out + 1] = "  end"
  end
  if example.has_output then
    out[#out + 1] = "  local __doctest_got = __doctest_get()"
    table.insert(out, "  local __doctest_want = " .. quote(example.output_text))
    out[#out + 1] =
      '  assert((__doctest_got):gsub("%s+$", "") == (__doctest_want):gsub("%s+$", ""),'
    table.insert(out, '    "doctest: " .. ' .. quote(file) ..
        ' .. ": output did not match\\nwant:\\n" .. __doctest_want ..')
    out[#out + 1] = '      "\\ngot:\\n" .. __doctest_got)'
  end
  out[#out + 1] = "end"
  if not example.has_output then
    -- Nothing calls an `example_` function: [`build.syntax_analyzer`]'s `analysis_of`
    -- discovers only `^test_`. Reading it here keeps tl from warning
    -- that it is unused, as `local _ = tmp` does for an argument no
    -- statement reads.
    out[#out + 1] = "local _ = " .. example.name
  end
  out[#out + 1] = ""
end

--- Why `fields`, a doc's `policy` line, cannot stand between the braces
--- of a table literal as it is, or "" when it can: a brace closing one
--- it did not open, one left open, or a comment or long bracket that
--- would swallow the close. Strings are skipped; the build reads what
--- is left field by field ([`build.syntax_analyzer`]), so this holds only that
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

--- A doc's prose as a module's own documentation: its markdown less the
--- title line (the module's name says it), the `policy` line, which
--- renders as nothing, and blank lines around them. `cosmic docs` shows
--- it, its first paragraph in the list of modules. "" for a doc with no
--- prose.
function generate.prose(source: string): string
  local kept: mut {string} = {}
  local fence: string? = nil
  local titled = false
  for line in String.lines(source) do
    -- A fence closes with the opener's own marker in a run at least as
    -- long ([`build.doctest.markdown`]).
    local marker = line:match("^%s*([`~][`~][`~]+)")
    if fence == nil and marker ~= nil then
      fence = marker
    elseif fence ~= nil and marker ~= nil and marker:sub(1, 1) == fence:sub(1, 1) and
        #marker >= #fence and line:match("^%s*[`~]+%s*$") ~= nil then
      fence = nil
    end
    if fence ~= nil or marker ~= nil then
      kept[#kept + 1] = line
    elseif line:match("^<!%-%- policy:.*%-%->%s*$") then
      -- Renders as nothing.
    elseif not titled and line:match("^#%s") ~= nil then
      titled = true
    else
      if line ~= "" then titled = true end
      kept[#kept + 1] = line
    end
  end
  return String.trim((table.concat(kept, "\n"):gsub("\n%s*\n%s*\n+", "\n\n")))
end

--- The block sequence as one Teal source string: a header comment, the
--- shared `__doctest_write` and `__doctest_capture` helpers when an
--- example needs one, then one function per example (or one comment for
--- a skip), in document order.
---
--- A doc's `policy` block ([`build.doctest.markdown`]) becomes the module's
--- top-level `policy` call ([`cosmic.test`]), which the build reads as it
--- does a test module's. A second is refused.
--- @param file string the doc's own path, named in a generated
---   assertion's failure message and in the header comment; never
---   prefixed onto an error this function itself returns -- the caller
---   already does that for every module, doc-derived or not
--- @param prose the doc's prose ([`generate.prose`]), written first as
---   the module's own documentation; "" or absent for none
function generate.from_blocks(blocks: {Block}, file: string, prose?: string): string?, string
  local items, trouble = to_items(blocks)
  if items == nil then
    return nil, trouble
  end
  local declared: Block? = nil
  for _, b in ipairs(blocks) do
    if b.lang == "policy" and declared ~= nil then
      return nil, "line " .. tostring(b.line) .. ": a doc declares its policy once; line " ..
        tostring(declared.line) .. " did already"
    elseif b.lang == "policy" then
      local why = unspliceable(b.content)
      if why ~= "" then
        return nil, "line " .. tostring(b.line) .. ": the policy line " .. why
      end
      declared = b
    end
  end

  local needs_fs = false
  local needs_capture = false
  local needs_cosmic = false
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil then
      if example.commands ~= nil then
        needs_cosmic = true
      end
      if #example.files > 0 then
        needs_fs = true
      end
      if example.has_output then
        needs_capture = true
      end
    end
  end

  if needs_cosmic and (declared == nil or declared.content:find("[\"']cosmic[\"']") == nil) then
    return nil, "a sh block runs cosmic, which a doc's examples may start only under the cosmic profile: " ..
      'declare <!-- policy: profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } -->'
  end

  local out: mut {string} = {}
  if prose ~= nil and prose ~= "" then
    for line in String.lines(prose) do
      out[#out + 1] = if line == "" then "---" else "--- " .. line end
    end
    out[#out + 1] = ""
  end
  out[#out + 1] = "-- Generated by build.doctest from " .. file .. "."
  out[#out + 1] = "-- A rebuild replaces this file whole from the doc; never edit it here"
  out[#out + 1] = ""
  if declared ~= nil then
    out[#out + 1] = 'local __doctest_test = require("cosmic.test")'
    out[#out + 1] = "__doctest_test.policy { " .. declared.content .. " }"
    out[#out + 1] = ""
  end

  if needs_fs then
    -- Not `Fs`, which a doc's entry would choose for its own
    -- `require("cosmic.fs")`: declaring it again there would shadow this
    -- local. tl's warning for shadowing a local carries a source
    -- position, so [`build.pipeline`]'s `discounted` (which matches only the
    -- message for the global `print`, see `__doctest_capture` below)
    -- would not drop it.
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
      '      error("doctest: could not create " .. tostring(trouble))'
    out[#out + 1] = "    end"
    out[#out + 1] = "  end"
    out[#out + 1] =
      '  local ok, trouble = __doctest_fs.write(tmp .. "/" .. path, content)'
    out[#out + 1] = "  if not ok then"
    out[#out + 1] =
      '    error("doctest: could not write " .. tostring(trouble))'
    out[#out + 1] = "  end"
    out[#out + 1] = "end"
    out[#out + 1] = ""
  end

  if needs_capture then
    -- What it caught is a field of a record, which a closure may write and the new checker takes (an array written, or a
    -- local a closure assigns, it refuses), as a guide's example is a project's code and no ceiling holds it. One text,
    -- since each line written to `out` is a write the checker counts.
    out[#out + 1] = [==[
local record __doctest_caught
  mut text: string
end

--- A fresh `print` and a way to read back everything it caught, one
--- pair per running example. `core/surface.c`'s `surface_print` is a
--- plain global -- tab-separating its arguments and ending every call
--- in one newline -- and this mirrors that exactly.
local function __doctest_capture(): function(...: any), function(): string
  local caught: __doctest_caught = { text = "" }
  local into = function(...: any): ()
    local line = ""
    local n = select("#", ...)
    for i = 1, n do
      if i > 1 then
        line = line .. "\t"
      end
      line = line .. tostring((select(i, ...)))
    end
    caught.text = caught.text .. line .. "\n"
  end
  local get = function(): string
    return caught.text
  end
  return into, get
end
]==]
    out[#out + 1] = ""
  end

  if needs_cosmic then
    out[#out + 1] = [==[
local __doctest_child = require("cosmic.child")
local __doctest_clock = require("cosmic.clock")
local __doctest_env = require("cosmic.env")
local __doctest_files = require("cosmic.fs")
local __doctest_proc = require("cosmic.proc")

--- What a `sh` block's line prints on stdout: the `cosmic` running
--- this test, given `words`, in the example's directory `tmp`. Its build
--- directory and caches go in a fresh directory beside `tmp`, never
--- inside it: a build directory inside the project is refused. A run
--- that does not exit with `status` raises, with what it said on stderr.
--- The limit is a minute, as a file run builds the tree around it.
local function __doctest_cosmic(tmp: string, words: {string}, status: integer): string
  local relaunch = assert(__doctest_proc.relaunch())
  local home = assert(__doctest_files.mkdtemp("doctest-home-"))
  local env = __doctest_env.all()
  for name, value in pairs(relaunch.env) do env[name] = value end
  env["COSMIC_BUILD_HOME"] = home .. "/build"
  env["XDG_CACHE_HOME"] = home .. "/cache"
  local argv = { table.unpack(relaunch.argv) }
  for _, word in ipairs(words) do argv[#argv + 1] = word end
  local said, trouble = __doctest_child.run(argv, { env = env, fds = relaunch.fds, cwd = tmp,
    stdout = "capture", stderr = "capture", timeout_ns = __doctest_clock.seconds(60) })
  assert(__doctest_files.remove_tree(home))
  local shown: mut {string} = {}
  for _, word in ipairs(words) do shown[#shown + 1] = string.format("%q", word) end
  local line = "cosmic " .. table.concat(shown, " ")
  if said == nil then
    error("doctest: " .. line .. " did not start: " .. trouble)
  elseif said.timed_out then
    error("doctest: " .. line .. " ran past a minute:\n" .. (said.stderr or ""))
  elseif said.code ~= status then
    error("doctest: " .. line .. " exited " .. tostring(said.code) .. ", where the doc says " ..
      tostring(status) .. ":\n" .. (said.stderr or ""))
  end
  return said.stdout or ""
end
]==]
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
  -- place of this file's own lines ([`build.syntax_derivation`]'s `origin_lines`).
  for _, item in ipairs(items) do
    local example = item.example
    if item.kind == "example" and example ~= nil then
      table.insert(out, "-- line " .. example.name .. " " .. tostring(example.line))
    end
  end

  return table.concat(out, "\n") .. "\n", ""
end

return generate
