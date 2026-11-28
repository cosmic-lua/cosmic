--- @public
--- Checks that a text is the text a test expects, and when it is not fails the test with the change as a unified
--- diff. It is its own module, so only a test that compares texts loads [`cosmic.diff`]: [`cosmic.test`], which
--- every test loads, does not.
---
---     local Equal = require("cosmic.test.equal")
---     Equal.equal("a\nb\n", rendered, "the rendered table")
---
--- The diff is `--- want`, `+++ got`. It is cut after 60 lines with a count of the rest, each line is cut after 200
--- bytes, and a control character is spelt out (`\r`, `\t`, `\x1b`), so a difference the eye cannot see shows.

local Diff = require("cosmic.diff")

local record Equal
end

--- How many lines of the diff [`Equal.equal`] shows, and how many bytes of each.
local DIFF_LINES <const> = 60
local LINE_BYTES <const> = 200

--- `line` for a person to read: a control character (a `\r` that makes two lines look alike) is spelt out, and a
--- line over [`LINE_BYTES`] is cut with a note of how much it lost.
local function shown_line(line: string): string
  local plain = line:gsub("%c", function(c: string): string
    if c == "\r" then return "\\r" end
    if c == "\t" then return "\\t" end
    return string.format("\\x%02x", c:byte()!)
  end)
  if #plain <= LINE_BYTES then return plain end
  return plain:sub(1, LINE_BYTES) .. " ... [line cut here, bytes lost: " .. tostring(#plain - LINE_BYTES) .. "]"
end

--- Checks that the text `got` is the text `want`, and when it is not fails the test with the change as a unified diff
--- (`--- want`, `+++ got`) of the lines instead of only saying that the texts differ. `what` names the thing compared
--- and heads the message, `text` if none or empty. The call counts as a call to `assert`.
---
---     Equal.equal("a\nb\n", rendered, "the rendered table")
--- @param want the text the test expects
--- @param got the text the code made
--- @param what names what is compared, `text` if none
function Equal.equal(want: string, got: string, what?: string)
  if want == got then
    assert(true)
    return
  end
  local text = Diff.unified(Diff.lines(want, got), { old_name = "want", new_name = "got" })
  local lines: mut {string} = {}
  for line in text:gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  local shown: mut {string} = {}
  for i, line in ipairs(lines) do
    if i > DIFF_LINES then break end
    shown[#shown + 1] = shown_line(line)
  end
  if #lines > DIFF_LINES then
    shown[#shown + 1] = "... " .. tostring(#lines - DIFF_LINES) .. " more diff lines"
  end
  local name = if what == nil or what == "" then "text" else what end
  assert(false, "test: " .. name .. " differs from what was expected (got against want):\n" .. table.concat(shown, "\n"))
end

return Equal
