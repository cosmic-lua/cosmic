--- Fuzz properties for [`build.link_text`]'s parser: `parse` is total over any
--- text, and each link it finds lies inside that text -- on one of its
--- lines, its `[` at the column it names -- with a target unless it is
--- a reference nothing defines -- and [`link_text.without_code`] keeps
--- every line of the text, and every byte of a line it does not empty
--- but those of an HTML comment, which it blanks.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local link_text = require("build.link_text")
local String = require("cosmic.string")

--- Pieces of text that reach each part of the parser: every form a
--- link takes, and what hides or breaks one.
local PIECES <const> = {
  "[", "]", "(", ")", "`", "``", "\\", "\n", "\n\n", " ", "x", "t", "%", "!",
  "[`a.b`]", " [`c.d`]", "[text](doc/a.md)", "[t][l]", "[l]: b.md\n", "\n[l]: b.md\n", "[l]", "[]", "[t][]",
  "```\n", "~~~\n", "--[[", "[=[", "<x>", "#h", "\u{e9}", "\xff",
}

--- What opens or closes a block that hides a link, drawn in a share of
--- the inputs only, so that the rest still reach every form: an indent,
--- a list item, a quote, a heading's underline and an HTML comment.
local BLOCK_PIECES <const> = {
  "<!--", "-->", "    ", "\t", "- ", "1. ", "> ", "---\n", "=\n",
}

local function gen_text(src: Fuzz.Source): string
  local parts: {string} = {}
  local count = 0
  -- One input in four draws them, so the rest reach a reference.
  local blocks = src:int(0, 3) == 0
  while Fuzz.more(src, count, 24) do
    count = count + 1
    parts[#parts + 1] = Fuzz.pick(src, blocks and src:int(0, 2) == 0 and BLOCK_PIECES or PIECES)
  end
  local text = table.concat(parts)
  if src:int(0, 3) == 0 then return Fuzz.mutate(src, text, 3) end
  return text
end

local FORMS <const>: {string: boolean} = {
  shortcut = true, inline = true, reference = true, definition = true,
}

local function parse_holds(input: string): boolean, string
  local found = link_text.parse(input)
  local lines: {string} = {}
  for line in String.lines(input) do lines[#lines + 1] = line end
  if #found == 0 then
    Fuzz.label("none")
  end
  for _, link in ipairs(found) do
    Fuzz.label(link.form)
    if not FORMS[link.form] then return false, "an unknown form: " .. link.form end
    local line = lines[link.line]
    if line == nil then return false, "a link past the last line: " .. link.line end
    if line:sub(link.column, link.column) ~= "[" then
      return false, "no [ at line " .. link.line .. ", column " .. link.column
    end
    if link.target == nil and link.form ~= "reference" then
      return false, "a " .. link.form .. " with no target"
    end
    if link.target == "" then return false, "an empty target" end
  end
  local shown: {string} = {}
  for line in String.lines(link_text.without_code(input)) do shown[#shown + 1] = line end
  if #shown ~= #lines then return false, "without_code made " .. #lines .. " lines " .. #shown end
  for number, line in ipairs(shown) do
    local was = lines[number]
    if line ~= "" and #line ~= #was then
      return false, "without_code moved the bytes of line " .. number
    end
    -- A line it keeps is the same, but for a comment's bytes blanked.
    for at = 1, #line do
      local c = line:sub(at, at)
      if c ~= was:sub(at, at) and c ~= " " then
        return false, "without_code changed byte " .. at .. " of line " .. number
      end
    end
    if line ~= was then Fuzz.label("hidden") end
  end
  local again = link_text.parse(input)
  if #again ~= #found then return false, "a second parse differs" end
  return true, ""
end

local function test_parse_finds_links_inside_the_text(tmp: string)
  Fuzz.run({
    name = "links parse",
    dir = tmp,
    gen = gen_text,
    check = parse_holds,
    requires = { "shortcut", "inline", "reference", "definition", "none", "hidden" },
  })
end
