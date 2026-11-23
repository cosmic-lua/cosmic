--- `cosmic docs` answers a field of a global [`cosmic.removed`] lists as
--- withheld with what to write instead, not with a search's nearest
--- member. The tree each test builds holds a function whose comment
--- mentions the withheld name, which is what a search would answer.

local docs = require("build.docs")
local Doc = require("cosmic.doc")
local fixture = require("build.docs_fixture")
local support = require("build.test_support_fixture")

local function source(...: string): string
  return table.concat({ ... }, "\n") .. "\n"
end

--- The standard-library module `env`, whose [`Env.get`] the
--- `os.getenv` query finds.
local function env_module(): string
  return source(
    "--- The env module.",
    "",
    "local record Env",
    "end",
    "",
    "--- One variable; this is the os.getenv operation.",
    "function Env.get(name: string): string?",
    "  return name",
    "end",
    "",
    "return Env")
end

--- The tree each test queries.
local function tree(): {string: string}
  return {
    ["cosmic/env.tl"] = env_module(),
  }
end

--- The page `query` answers, as `cosmic docs` prints it: every entry's
--- lines in turn.
local function page(view: Doc.View, found: Doc.Lookup): string
  local out: mut {string} = {}
  for _, entry in ipairs(found) do
    for _, line in ipairs((assert(Doc.render(view, entry)))) do
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

--- A field of a removed global (`os.getenv`) answers what
--- [`cosmic.removed`]'s `message` says of it, which a compile error and
--- a run-time failure say too, and not the function whose comment only
--- mentions the old name.
local function test_a_removed_global_s_field_answers_its_replacement(dir: string)
  local view = assert(docs.view({ fixture.database(dir, tree()) }))
  local found = assert(Doc.lookup(view, "os.getenv"))
  assert(found.exact and #found == 1 and support.nth(found, 1).kind == "removed")
  assert(support.nth(found, 1).module == "cosmic.removed", support.nth(found, 1).module)
  local shown = page(view, found)
  assert(shown:find("os.getenv is not available: use Env.get(name)", 1, true), shown)
  assert(not shown:find("One variable", 1, true), shown)
end

--- A removed field of `package` answers the catalog too, though
--- `package` itself is no removed name: its other fields keep theirs.
local function test_a_removed_package_field_answers_its_replacement(dir: string)
  local view = assert(docs.view({ fixture.database(dir, tree()) }))
  local found = assert(Doc.lookup(view, "package.path"))
  assert(found.exact and #found == 1 and support.nth(found, 1).kind == "removed")
  assert(page(view, found):find("package.path is not available: there is no file search path",
    1, true))
end
