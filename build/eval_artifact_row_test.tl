--- eval/artifact_row.tl is a copy of ci/cosmic_ci/artifact_row.tl, since neither project can require the other's
--- modules: the two hold the same code below their own doc.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{
  grants = {
    { path = "ci/cosmic_ci/artifact_row.tl", letters = "r" },
    { path = "eval/artifact_row.tl", letters = "r" },
  },
}

--- The text of `path` from its first line that is no doc comment.
local function code_of(path: string): string
  local text = assert(Fs.read(path))
  local at = assert(text:find("\n[^-\n]", 1), path .. " has no code")
  return text:sub(at + 1)
end

--- The copy's code is the original's.
local function test_the_copy_holds_the_same_code()
  local ci, eval = code_of("ci/cosmic_ci/artifact_row.tl"), code_of("eval/artifact_row.tl")
  assert(ci == eval, "eval/artifact_row.tl differs from ci/cosmic_ci/artifact_row.tl below its doc: copy it again")
end
