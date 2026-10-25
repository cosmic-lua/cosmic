--- What the fork's compiler said of the programs the new checker's tests were once held to it on, kept as text. The fork is
--- gone from the tree, so each program a test compared the new checker's answer with has the fork's answer beside the
--- test, recorded once from the tool of main before the switch. A file is a list of entries,
---
---     @@ source
---     <the program, as the test hands it to the oracle>
---     @@ answer
---     <what the fork answered>
---     @@ end
---
--- or `@@ none` in place of the answer where the fork refused the program or gave none. A test that reads such a file
--- declares it for reading with [`Test.policy`].
local Fs = require("cosmic.fs")

local record Forked
  --- What the fork answered of one program.
  record Said
    --- Whether the file holds the program at all.
    known: boolean
    --- The answer, or nil where the fork gave none.
    text: string?
  end

  --- The entries of `path`, by the program of each ([`Forked.key`]). Fails where the file is missing, holds no entry or is
  --- malformed.
  load: function(path: string): {string: Forked.Said}

  --- What `kept` ([`Forked.load`]) holds for the program `key`.
  said: function(kept: {string: Forked.Said}, key: string): Forked.Said

  --- The key of a program `source` that was read with the `modules` (by name) it requires and the exemptions `given`
  --- (one line each), as the entries spell it.
  key: function(source: string, modules: {string: string}, given: {string}): string
end

--- A text with the one line end the entries give every text.
local function normal(text: string): string
  if text:sub(-1) == "\n" then
    return text
  end
  return text .. "\n"
end

function Forked.key(source: string, modules: {string: string}, given: {string}): string
  local names: mut {string} = {}
  for name in pairs(modules) do
    names[#names + 1] = name
  end
  table.sort(names)
  local parts: mut {string} = { normal(source) }
  if #names > 0 or #given > 0 then
    parts[#parts + 1] = "-- modules --\n"
    for _, name in ipairs(names) do
      parts[#parts + 1] = "== " .. name .. "\n" .. normal(modules[name] or "")
    end
    parts[#parts + 1] = "-- given --\n"
    local lines: mut {string} = {}
    for _, line in ipairs(given) do
      lines[#lines + 1] = line
    end
    table.sort(lines)
    for _, line in ipairs(lines) do
      parts[#parts + 1] = line .. "\n"
    end
  end
  return table.concat(parts)
end

function Forked.load(path: string): {string: Forked.Said}
  local text = assert(Fs.read(path))
  local kept: mut {string: Forked.Said} = {}
  local source: mut {string} = {}
  local answer: mut {string} = {}
  local into = "none"
  local none = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == "@@ source" then
      into = "source"
      source, answer, none = {}, {}, false
    elseif line == "@@ answer" then
      into = "answer"
    elseif line == "@@ none" then
      into = "none"
      none = true
    elseif line == "@@ end" then
      local key = table.concat(source, "\n") .. "\n"
      if none then
        kept[key] = { known = true, text = nil }
      else
        kept[key] = { known = true, text = table.concat(answer, "\n") }
      end
      into = "none"
    elseif into == "source" then
      source[#source + 1] = line
    elseif into == "answer" then
      answer[#answer + 1] = line
    end
  end
  assert(next(kept) ~= nil, path .. " holds no entry")
  return kept
end

function Forked.said(kept: {string: Forked.Said}, key: string): Forked.Said
  return kept[normal(key)] or { known = false, text = nil }
end

return Forked
