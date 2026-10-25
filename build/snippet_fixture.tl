--- A snippet of Teal for a test whose subject is a module's types, not the checker: the new checker reads it as a file
--- alone ([`Pipeline.checked_alone`]), whichever grammar the run asks for, so the verdict and its words are one in both.
---
--- The module that uses it declares `profiles = { "cosmic" }` and the grant `{ path = "o/bin", letters = "rx" }`, which put
--- the declarations of the standard library the tool carries in its store, and requires the `cosmic.*` modules the snippets
--- name with `local type _ = require(...)`, so that the store holds them.
local Pipeline = require("build.pipeline")

local record SnippetFixture
  --- Whether `text`, a module of its own, passes the new checker with no warning: true and "", or false and the lines that
  --- refuse it.
  compiles: function(text: string): boolean, string

end

local record Held
  mut options: Pipeline.Options?
end

local held: Held = { options = nil }

--- The options of a file alone, made once for the module.
local function options(): Pipeline.Options
  local made = held.options
  if made == nil then
    made = assert(Pipeline.alone())
    held.options = made
  end
  return made
end

local function lua(text: string): string?, string
  local made = Pipeline.checked_alone("snippet.tl", text, options())
  if made.code == nil then
    return nil, table.concat(made.lines, "\n")
  end
  return made.code, ""
end

function SnippetFixture.compiles(text: string): boolean, string
  local code, trouble = lua(text)
  if code == nil then
    return false, trouble
  end
  return true, ""
end

return SnippetFixture
