--- Fuzz properties for `build.links`' parser: `parse` is total over any
--- text, and each link it finds lies inside that text -- on one of its
--- lines, its `[` at the column it names -- with a target unless it is
--- a reference nothing defines.
--- `FUZZ_SEED` and `FUZZ_ITERS` pick the inputs (build/fuzz/init.tl).

local Fuzz = require("build.fuzz")
local links = require("build.links")

--- Pieces of text that reach each part of the parser: every form a
--- link takes, and what hides or breaks one.
local PIECES <const> = {
  "[", "]", "(", ")", "`", "``", "\\", "\n", "\n\n", " ", "x", "t", "%", "!",
  "[`a.b`]", "[text](doc/a.md)", "[t][l]", "[l]: b.md\n", "[l]", "[]", "[t][]",
  "```\n", "~~~\n", "--[[", "[=[", "<x>", "#h", "\u{e9}", "\xff",
}

local function gen_text(src: Fuzz.Source): string
  local parts: {string} = {}
  local count = 0
  while Fuzz.more(src, count, 24) do
    count = count + 1
    parts[#parts + 1] = Fuzz.pick(src, PIECES)
  end
  local text = table.concat(parts)
  if src:int(0, 3) == 0 then return Fuzz.mutate(src, text, 3) end
  return text
end

local FORMS <const>: {string: boolean} = {
  shortcut = true, inline = true, reference = true, definition = true,
}

local function parse_holds(input: string): boolean, string
  local found = links.parse(input)
  local lines: {string} = {}
  for line in (input .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
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
  local again = links.parse(input)
  if #again ~= #found then return false, "a second parse differs" end
  return true, ""
end

local function test_parse_finds_links_inside_the_text(tmp: string)
  Fuzz.run({
    name = "links parse",
    dir = tmp,
    gen = gen_text,
    check = parse_holds,
    requires = { "shortcut", "inline", "reference", "definition", "none" },
  })
end
