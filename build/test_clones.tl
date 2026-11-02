--- The top-level helpers of a file as the check for a copied test helper ([`build.tree_checks`]'s `test_clones`)
--- compares them: each `local function` that is no test, as its name, its line, its size in tokens and its tokens as
--- one string.
---
--- A helper is found where `bin/cosmic fix` lays a file out ([`build.fix.format`]): a line of `local function` at the
--- left margin. Parsing every file of the tree costs more than the check may, so the text is read for a head of each
--- helper ([`TestClones.scan`]) and only the helpers whose head another file shares are read ([`TestClones.read`]):
--- the lines from the head to a line of `end` alone that make a whole function ([`lang.parser`]), or the head line
--- where that is a function by itself. A string that holds Teal source, with its own `end` lines, is then no end of it.
---
--- The tokens are the parser's ([`lang.ast`]), so a comment and the layout of a line are not in them; a name, a literal
--- and the order of the tokens are, so two helpers are the same where they are written alike token for token, and a
--- copy whose names were changed is not found.
local Ast = require("lang.ast")
local Node = require("build.syntax_node")

local record TestClones
  --- Where a helper begins and what it begins with.
  record Head
    name: string
    line: integer
    --- The parameters and results on its line, without the name, and the first three lines of code after it, all
    --- without comments: equal for two copies.
    key: string
  end

  --- A file's text as lines, and the head of each helper in it.
  record Scan
    lines: {string}
    heads: {Head}
  end

  --- A helper as it is compared.
  record Helper
    name: string
    line: integer
    --- How many tokens it has, its parameters and its `end` included.
    size: integer
    --- Their text, joined: equal for two helpers written alike.
    body: string
  end

  --- The lines of `text` and the head of each top-level `local function` of it that is no test.
  scan: function(text: string): Scan

  --- The helper `head` begins in `scan`, `file` being the file's name; nil and why where no run of lines from it is a
  --- whole function.
  read: function(scan: Scan, head: Head, file: string): Helper?, string
end

--- Whether `line` is code: not blank and not a comment. Its trailing comment is cut off.
local function code_of(line: string): string?
  local code = (line:gsub("%s*%-%-.*$", "")):match("^%s*(.-)%s*$")
  if code == nil or code == "" then return nil end
  return code
end

function TestClones.scan(text: string): TestClones.Scan
  local lines: mut {string} = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = line end
  local heads: mut {TestClones.Head} = {}
  for i, line in ipairs(lines) do
    local name, rest = line:match("^local function ([%w_]+)(.*)$")
    if name ~= nil and rest ~= nil and name:match("^test_") == nil then
      local key = rest:gsub("%s*%-%-.*$", "")
      local taken = 0
      for j = i + 1, math.min(#lines, i + 12) do
        local code = code_of(assert(lines[j]))
        if code ~= nil then
          key = key .. "\n" .. code
          taken = taken + 1
          if taken == 3 then break end
        end
      end
      heads[#heads + 1] = { name = name, line = i, key = key }
    end
  end
  return { lines = lines, heads = heads }
end

--- The helper in `chunk` if its one statement is a `local function`.
local function helper_of(chunk: Ast.Chunk, head: TestClones.Head): TestClones.Helper?
  local stats = chunk.body.stats
  local top = stats[1]
  if #stats ~= 1 or top == nil or top.kind ~= "LocalFunction" then return nil end
  local words: mut {string} = {}
  for i = top.fn.first, top.fn.last do
    words[#words + 1] = assert(chunk.tokens.text[i])
  end
  return { name = head.name, line = head.line, size = #words, body = table.concat(words, "\1") }
end

function TestClones.read(scan: TestClones.Scan, head: TestClones.Head, file: string): TestClones.Helper?, string
  local lines = scan.lines
  local piece: mut {string} = {}
  -- The ends tried: the head's own line, then each line of `end` alone, a few of them (a string of source holds
  -- more, nested in the function).
  local tried = 0
  local first_error = "no line of `end` alone ends it"
  for i = head.line, #lines do
    local line = assert(lines[i])
    piece[#piece + 1] = line
    local ends = line == "end"
    if i == head.line then
      ends = line:match("%f[%w]end%s*$") ~= nil or line:match("%f[%w]end%s*%-%-") ~= nil
    end
    if ends then
      local chunk, trouble = Node.parse(table.concat(piece, "\n") .. "\n", file)
      if chunk ~= nil then
        local found = helper_of(chunk, head)
        if found ~= nil then return found, "" end
        first_error = "it is not one function"
      else
        first_error = trouble
      end
      tried = tried + 1
      if tried == 6 then break end
    end
  end
  return nil, first_error
end

return TestClones
