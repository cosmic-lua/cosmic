--- Fenced code blocks out of a markdown doc, in document order. This
--- is the whole of what `build.doctest` reads from the markdown itself;
--- everything the grammar in doc/meta.md means by a block's tag
--- (`teal`, `lua`, `output`, `sh`, `text`, and the `continue`/`file=`/
--- `skip=` modifiers on `teal`/`lua`) is decided here, once, so
--- `build.doctest.generate` never re-parses a tag string.
---
--- Prose outside a fence is not read at all: a line only matters here
--- once it opens or closes a fence.
---
--- A fence opens with either a backtick or a tilde run of three,
--- CommonMark's own two marker styles, and closes only with the same
--- marker it opened with.

local record Modifiers
  continue: boolean
  file: string | nil
  skip: string | nil
end

local record Block
  --- `"text"`, `"output"`, `"sh"`, `"teal"`, or `"lua"`.
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
  sh = true,
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
  if (lang == "text" or lang == "output" or lang == "sh") and #words > 1 then
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

--- Whether `line` opens a fence, and with which marker character.
--- CommonMark allows either a backtick or a tilde run of three or more
--- as a fence marker; the two are not interchangeable for one fence
--- -- a fence opened with `` ``` `` closes only with `` ``` ``, and one
--- opened with `~~~` closes only with `~~~`. This lets a `~~~`-fenced
--- block hold literal `` ``` `` content, which is the main reason
--- CommonMark gives docs two marker styles at all.
--- @return string | nil the marker character (`` ` `` or `~`), or nil
---   when `line` opens neither
--- @return string the info string after the marker run, when one was found
local function open_marker(line: string): string | nil, string
  local backtick_info = line:match("^```(.*)$")
  if backtick_info ~= nil then
    return "`", backtick_info
  end
  local tilde_info = line:match("^~~~(.*)$")
  if tilde_info ~= nil then
    return "~", tilde_info
  end
  return nil, ""
end

--- Whether `line` closes a fence opened with `marker`: the same
--- character, alone on the line but for surrounding whitespace. This
--- grammar does not check the closing run is at least as long as the
--- opening one (CommonMark's full rule) -- every fence here is authored
--- by hand at exactly three characters, so the extra check buys nothing
--- a real doc would ever trip.
local function closes_fence(line: string, marker: string): boolean
  if marker == "`" then
    return line:match("^%s*```%s*$") ~= nil
  end
  return line:match("^%s*~~~%s*$") ~= nil
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
  for line in (source .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local blocks: {Block} = {}
  local i = 1
  while i <= #lines do
    local marker, info = open_marker(lines[i])
    if marker == nil then
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
        if closes_fence(lines[j], marker) then
          closed = true
          break
        end
        content_lines[#content_lines + 1] = lines[j]
        j = j + 1
      end
      if not closed then
        return nil, "line " .. open_line .. ": a fenced code block never closes"
      end
      local trimmed = info:match("^%s*(.-)%s*$") or ""
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
