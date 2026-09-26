--- Fenced code blocks out of a markdown doc, in document order. This
--- is the whole of what `build.doctest` reads from the markdown itself;
--- everything the grammar in doc/meta.md means by a block's tag
--- (`teal`, `lua`, `output`, `text`, and the `continue`/`file=`/
--- `skip=` modifiers on `teal`/`lua`) is decided here, once, so
--- `build.doctest.generate` never re-parses a tag string.
---
--- Prose outside a fence is not read at all: a line only matters here
--- once it opens or closes a fence, or is a whole line
--- `<!-- needs: <fields> -->`, what the doc's examples read beyond
--- their default inputs (`cosmic.test`'s `needs`), which renders as
--- nothing and comes back as a block of its own, `needs`, holding
--- `<fields>`. The `<!-- inputs: ... -->` it replaced is refused.
---
--- A fence opens with a backtick or tilde run of at least three. It
--- closes with the same marker in a run at least as long as the opener.

local String = require("cosmic.string")

local record Modifiers
  continue: boolean
  file: string | nil
  skip: string | nil
end

local record Block
  --- `"text"`, `"output"`, `"teal"`, `"lua"`, or `"needs"`.
  lang: string
  modifiers: Modifiers
  --- The block's body, its lines joined by `"\n"`, with neither fence
  --- line included and no trailing newline of its own.
  content: string
  --- The 1-based source line of the opening fence, for error messages.
  line: integer
end

local record markdown
  type Modifiers = Modifiers
  type Block = Block
end

local valid_langs: {string:boolean} = {
  text = true,
  output = true,
  teal = true,
  lua = true,
}

local record Tag
  lang: string
  modifiers: Modifiers
end

--- The trimmed info string after an opening fence (e.g. `teal
--- file=main.tl`) into its language and modifiers, or a reason it is
--- not a tag this grammar knows.
--- @return Tag | nil the language and its modifiers, bundled: a
---   fallible return admits at most two slots, and there is no single
---   value here to carry the other in
--- @return string why `info` was refused
local function parse_tag(info: string): Tag | nil, string
  local words: {string} = {}
  for word in info:gmatch("%S+") do
    words[#words + 1] = word
  end
  local lang = words[1] or ""
  if not valid_langs[lang] then
    return nil, "unknown fenced block tag '" .. lang .. "'"
  end
  if (lang == "text" or lang == "output") and #words > 1 then
    return nil, "a " .. lang .. " block takes no modifiers"
  end
  local modifiers: Modifiers = { continue = false, file = nil, skip = nil }
  for i = 2, #words do
    local word = words[i]
    if word == "continue" then
      modifiers.continue = true
    elseif word:sub(1, 5) == "file=" then
      modifiers.file = word:sub(6)
    elseif word:sub(1, 5) == "skip=" then
      modifiers.skip = word:sub(6)
    else
      return nil, "unknown modifier '" .. word .. "' on a " .. lang .. " block"
    end
  end
  local combos = 0
  if modifiers.continue then combos = combos + 1 end
  if modifiers.file ~= nil then combos = combos + 1 end
  if modifiers.skip ~= nil then combos = combos + 1 end
  if combos > 1 then
    return nil, "'continue', 'file=', and 'skip=' cannot combine on one block"
  end
  return { lang = lang, modifiers = modifiers }, ""
end

local record Fence
  marker: string
  length: integer
  info: string
end

--- The column-0 fence opening `line`, including its marker, run length,
--- and info string, or nil when the line is not an opener.
local function open_fence(line: string): Fence | nil
  local run, info = line:match("^(```+)(.*)$")
  if run == nil then
    run, info = line:match("^(~~~+)(.*)$")
  end
  if run == nil then
    return nil
  end
  return { marker = run:sub(1, 1), length = #run, info = info }
end

--- Whether `line` closes `fence`: only whitespace may surround a same-marker
--- run at least as long as the opening run.
local function closes_fence(line: string, fence: Fence): boolean
  local run: string | nil
  if fence.marker == "`" then
    run = line:match("^%s*(```+)%s*$")
  else
    run = line:match("^%s*(~~~+)%s*$")
  end
  return run ~= nil and #run >= fence.length
end

--- Whether `line`, already ruled out as a column-0 fence opener, still
--- looks like one that was meant to be: an indented run of three or
--- more backticks or tildes. CommonMark allows a fence indented up to
--- three spaces (stripping that indentation from its content); this
--- grammar does not, and silently treating such a line as prose would
--- reproduce the exact silent-gap shape `~~~` support just closed for
--- unindented fences -- a doc author's example quietly never compiled
--- or ran, with nothing to say so. Loud refusal here stands in for that
--- support until indentation is worth handling for real.
local function looks_like_an_indented_fence(line: string): boolean
  local indented = line:match("^%s+(.*)$")
  if indented == nil then
    return false
  end
  return indented:match("^```") ~= nil or indented:match("^~~~") ~= nil
end

--- Every fenced code block in `source`, in document order.
--- @return {Block} | nil nil when a fence never closes, a tag is not
---   one this grammar knows, or a line looks like an indented fence
---   this grammar does not support
--- @return string why, naming the source line
function markdown.parse_blocks(source: string): {Block} | nil, string
  local lines: {string} = {}
  for line in String.lines(source) do
    lines[#lines + 1] = line
  end
  local blocks: {Block} = {}
  local i = 1
  while i <= #lines do
    local fence = open_fence(lines[i])
    local declared = fence == nil and
      lines[i]:match("^<!%-%-%s*needs:%s*(.-)%s*%-%->%s*$") or nil
    if fence == nil and lines[i]:match("^<!%-%-%s*inputs:") ~= nil then
      return nil, "line " .. i .. ": a doc declares what its examples read with " ..
        "<!-- needs: ... --> now"
    elseif declared ~= nil then
      blocks[#blocks + 1] = {
        lang = "needs",
        modifiers = { continue = false, file = nil, skip = nil },
        content = declared,
        line = i,
      }
      i = i + 1
    elseif fence == nil then
      if looks_like_an_indented_fence(lines[i]) then
        return nil, "line " .. i .. ": this line looks like a fenced code " ..
          "block opener but is indented; indented fences are not " ..
          "supported here -- start it at column 1"
      end
      i = i + 1
    else
      local open_line = i
      local content_lines: {string} = {}
      local j = i + 1
      local closed = false
      while j <= #lines do
        if closes_fence(lines[j], fence) then
          closed = true
          break
        end
        content_lines[#content_lines + 1] = lines[j]
        j = j + 1
      end
      if not closed then
        return nil, "line " .. open_line .. ": a fenced code block never closes"
      end
      local trimmed = fence.info:match("^%s*(.-)%s*$") or ""
      local tag, tag_trouble = parse_tag(trimmed)
      if tag == nil then
        return nil, "line " .. open_line .. ": " .. tag_trouble
      end
      blocks[#blocks + 1] = {
        lang = tag.lang,
        modifiers = tag.modifiers,
        content = table.concat(content_lines, "\n"),
        line = open_line,
      }
      i = j + 1
    end
  end
  return blocks, ""
end

return markdown
