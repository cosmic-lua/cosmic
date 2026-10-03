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

local Patch = require("build.patch")
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

--- `source`'s lines, each without its line break or a `\r` before it.
local function lines_of(source: string): {string}
  local lines: {string} = {}
  for line in String.lines(source) do
    lines[#lines + 1] = (line:gsub("\r$", ""))
  end
  if source:sub(-1) == "\n" then
    lines[#lines] = nil
  end
  return lines
end

--- Every TODO in one file's text, in order.
function todo_scan.scan(source: string): {todo_scan.Found}
  local lines = lines_of(source)
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

--- The line of `source` that byte `at` is on.
local function line_at(source: string, at: integer): integer
  local _, breaks = source:sub(1, at - 1):gsub("\n", "")
  return breaks + 1
end

--- The TODO a record's note holds, if one opens it or one of its
--- sentences: from there to the note's end. The note is its `note:`
--- line, at `first`, and the lines under it up to the find fence's,
--- before `after`.
local function note_todo(lines: {string}, first: integer, after: integer): todo_scan.Found | nil
  local joined = ""
  local starts: {integer} = {}
  local rows: {integer} = {}
  for index = first, after - 1 do
    local text = (index == first and lines[index]:sub(7) or lines[index]):
      gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
    if text ~= "" then
      if joined ~= "" then joined = joined .. " " end
      starts[#starts + 1] = #joined + 1
      rows[#rows + 1] = index
      joined = joined .. text
    end
  end
  local from = joined:find("^TODO:")
  if from == nil then
    local sentence = joined:find("[.!?][ \t]+TODO:")
    from = sentence and joined:find("TODO:", sentence, true)
  end
  if from == nil then
    return nil
  end
  local line = first
  for k, start in ipairs(starts) do
    if start <= from then line = rows[k] end
  end
  return { line = line, last = rows[#rows], text = (joined:sub(from + 5):gsub("^[ \t]+", "")) }
end

--- Every TODO in a patch record's text (see [`build/patch.tl`], whose
--- [`Patch.parse`] reads it) that is the tree's own, or nil when the
--- text is no record. Its note's is, from a `TODO:` that opens the note
--- or one of its sentences to the note's end; so is each in its replace
--- block, as [`scan`] finds them, that has a line the find block does
--- not. The find block is upstream's code, matched rather than written
--- here, so its TODOs, and the ones a replace block carries over from it
--- line for line, moved or cut short, are upstream's; one a line of the
--- tree's own runs into is the tree's, upstream's lines and all.
function todo_scan.scan_record(source: string): {todo_scan.Found} | nil
  local record, _ = Patch.parse(source, "")
  if record == nil then
    return nil
  end
  local lines = lines_of(source)
  local note = source:sub(1, 7) == "fence: " and 3 or 2
  local found: {todo_scan.Found} = {}
  local from_note = note_todo(lines, note, line_at(source, record.find_at) - 1)
  if from_note ~= nil then
    found[1] = from_note
  end
  local upstream: {string:boolean} = {}
  for _, line in ipairs(lines_of(record.find)) do
    upstream[line] = true
  end
  local replaced = lines_of(record.replace)
  local offset = line_at(source, record.replace_at) - 1
  for _, each in ipairs(todo_scan.scan(record.replace)) do
    local own = false
    for index = each.line, each.last do
      own = own or not upstream[replaced[index]]
    end
    if own then
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
