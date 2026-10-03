--- Finds the `TODO:` comments in one file's text, for [`build.work`] to
--- index as it stages and [`build.todos`] to list: apart from the verb, so
--- staging does not import it.
---
--- A TODO is a comment line whose text opens with `TODO:` after the
--- comment's own marker (`--`, `---`, `#`, `//`, `/*`, `*`, `;`), and
--- the lines under it that carry on the same paragraph: the same
--- indentation and marker, with text, up to a blank comment line, a
--- line that is not a comment, the next TODO, or a line that opens a
--- sentence after one that ended one -- a script's header often runs
--- its TODO straight into what the script does, with no blank line. A
--- `TODO:` anywhere else on a line -- in a string, in prose, after code
--- -- is not one, so a test can hold the text of a TODO without being
--- listed. A patch record's TODOs are its note's and its replace
--- block's, never its find block's ([`scan_record`]).

local String = require("cosmic.string")

local record todo_scan
  --- One TODO where it is written: its first line, its last, and its
  --- text, the paragraph's lines joined by single spaces.
  record Found
    line: integer
    last: integer
    text: string
  end
end

--- The comment markers a TODO may follow.
local markers: {string:boolean} = {
  ["--"] = true,
  ["---"] = true,
  ["#"] = true,
  ["##"] = true,
  ["//"] = true,
  ["///"] = true,
  ["/*"] = true,
  ["/**"] = true,
  ["*"] = true,
  [";"] = true,
  [";;"] = true,
}

--- A line as a comment: its indentation, its marker, and its text with
--- the space after the marker dropped. nil for a line that is not a
--- comment on its own.
local function comment_of(line: string): string, string, string
  -- TODO: a TODO after code on its line (`x = 1 -- TODO: ...`) is not
  -- found, since a line alone cannot tell a comment from a string. Take a
  -- Teal file's comments from the tree tl's parser attaches them to
  -- (build/ast/node.tl), and a C file's from clang's, and scan only those.
  local indent, marker, rest = line:match("^([ \t]*)([-#/*;]+)(.*)$")
  if indent == nil or not markers[marker] then
    return nil, nil, nil
  end
  if rest ~= "" and not rest:match("^[ \t]") then
    return nil, nil, nil
  end
  rest = rest:gsub("^[ \t]+", ""):gsub("[ \t]*%*/[ \t]*$", ""):gsub("[ \t]+$", "")
  return indent, marker, rest
end

--- The marker the lines that carry on a comment opened with `marker`
--- are written with: `*` for a block comment, whether or not it sits in
--- a column, else the opener's own.
local function continued(marker: string): string
  if marker:sub(1, 1) == "/" and marker:sub(2, 2) == "*" then
    return "*"
  end
  return marker
end

--- Every TODO in one file's text, in order.
function todo_scan.scan(source: string): {todo_scan.Found}
  local lines: {string} = {}
  for line in String.lines(source) do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  if source:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  local found: {todo_scan.Found} = {}
  local index = 1
  while index <= #lines do
    local indent, marker, rest = comment_of(lines[index])
    local text = rest ~= nil and rest:match("^TODO:[ \t]*(.*)$") or nil
    if text == nil then
      index = index + 1
    else
      local first = index
      local parts: {string} = { text }
      local following = continued(marker)
      index = index + 1
      while index <= #lines do
        local next_indent, next_marker, next_rest = comment_of(lines[index])
        -- TODO: a line ending in `.` followed by one starting with a
        -- capital ends the TODO below, which cuts a TODO of several
        -- sentences short (build/tree_checks.tl's and build/test.tl's
        -- lose their second halves today); apply that break only to a
        -- script's leading `#` header, or take comments from the parser
        -- as the TODO in [`comment_of`] proposes, and drop it here.
        local aligned = next_indent == indent or
          (following ~= marker and next_indent == indent .. " ")
        if not aligned or
            (next_marker ~= marker and next_marker ~= following) or
            next_rest == "" or next_rest:match("^TODO:") or
            (parts[#parts]:match("%.$") and next_rest:match("^%u")) then
          break
        end
        parts[#parts + 1] = next_rest
        index = index + 1
      end
      found[#found + 1] = {
        line = first,
        last = index - 1,
        text = table.concat(parts, " "),
      }
    end
  end
  return found
end

--- Where a patch record's parts sit, by line (see [`build/patch.tl`]):
--- its `note:` line, the first line of its find and of its replace
--- block, and its closing `end` fence.
local record Record
  note: integer
  find: integer
  replace: integer
  last: integer
end

--- Where `lines`' record parts sit, as [`build/patch.tl`]'s [`Patch.parse`]
--- reads them: an optional `fence:` line, `file:`, `note:`, then the
--- first lines that are exactly the fence and `find`, `replace` and
--- `end`, in that order.
local function record_of(lines: {string}): Record | nil
  local at = 1
  local fence = "---"
  if lines[1] ~= nil and lines[1]:sub(1, 7) == "fence: " then
    fence = lines[1]:sub(8)
    at = 2
  end
  if lines[at] == nil or lines[at]:sub(1, 6) ~= "file: " or
      lines[at + 1] == nil or lines[at + 1]:sub(1, 6) ~= "note: " then
    return nil
  end
  local found: {integer} = {}
  local index = at + 2
  for _, word in ipairs({ "find", "replace", "end" }) do
    while lines[index] ~= nil and lines[index] ~= fence .. " " .. word do
      index = index + 1
    end
    if lines[index] == nil then
      return nil
    end
    found[#found + 1] = index
    index = index + 1
  end
  return { note = at + 1, find = found[1] + 1, replace = found[2] + 1, last = found[3] }
end

--- The lines `lines` holds from `first` up to but not including `after`,
--- as one text.
local function block(lines: {string}, first: integer, after: integer): string
  if after <= first then
    return ""
  end
  return table.concat(lines, "\n", first, after - 1) .. "\n"
end

--- Every TODO in a patch record's text (see [`build/patch.tl`]) that is
--- the tree's own: its note's, from a `TODO:` that opens the note or one
--- of its sentences to the note's end, and each in its replace block, as
--- [`scan`] finds them, but one the find block holds too. The find block
--- is upstream's code, matched rather than written here, so its TODOs,
--- and the ones a replace block carries over from it, are upstream's. A
--- text that is no record holds none.
function todo_scan.scan_record(source: string): {todo_scan.Found}
  local lines: {string} = {}
  for line in String.lines(source) do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  if source:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  local record = record_of(lines)
  if record == nil then
    return {}
  end
  local found: {todo_scan.Found} = {}
  local note = lines[record.note]:sub(7)
  local from = note:find("^TODO:")
  if from == nil then
    local sentence = note:find("[.!?][ \t]+TODO:")
    from = sentence and note:find("TODO:", sentence, true)
  end
  if from ~= nil then
    local text = note:sub(from + 5):gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
    found[1] = { line = record.note, last = record.note, text = text }
  end
  local upstream: {string:boolean} = {}
  for _, each in ipairs(todo_scan.scan(block(lines, record.find, record.replace - 1))) do
    upstream[each.text] = true
  end
  local offset = record.replace - 1
  for _, each in ipairs(todo_scan.scan(block(lines, record.replace, record.last))) do
    if not upstream[each.text] then
      found[#found + 1] = {
        line = each.line + offset,
        last = each.last + offset,
        text = each.text,
      }
    end
  end
  return found
end

return todo_scan
