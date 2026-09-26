--- Finds the `TODO:` comments in one file's text, for `build.work` to
--- index as it stages and `build.todos` to list: apart from the verb, so
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
--- listed.

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

--- The marker a line carrying a comment on is written with: a block
--- comment's lines go on with `*`, a column in or not, every other
--- comment with its own.
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

return todo_scan
