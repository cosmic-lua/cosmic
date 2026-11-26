--- `cosmic fix` links nothing in an eval task: the grader runs `cosmic fix
--- --check` in the solver's project, where TASK.md (the task and the
--- journal, [`eval/arena.tl`]) sits. It reads eval/task/ and
--- eval/journal.md as text, since eval/ is a project of its own.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local link_resolve = require("build.link_resolve")
local SyntaxLinks = require("build.syntax_links")

--- The tasks and the journal every arena's TASK.md is made of.
Test.policy{ grants = { { path = "eval/task/", letters = "r" }, { path = "eval/journal.md", letters = "r" } } }

--- A project at /p whose module `task` declares every name asked of
--- it (`jobs.Plan`, `jobs.anything`), in <task>.tl, and whose every
--- capitalized name is a type of that module with every member asked
--- of it (`Plan.order`), as `cosmic docs` shows a type's member. It
--- holds nothing else: no other module's symbol, file or directory,
--- which a task's span would name only by chance.
local function implementing_everything(task: string): link_resolve.Context
  local function declared(module: string, symbol: string): {link_resolve.Symbol}
    return { { module = module, symbol = symbol, file = module .. ".tl" } }
  end
  return {
    root = "/p",
    kind = function(path: string): string?
      if path == "/p" then return "dir" end
      if path == "/p/" .. task .. ".tl" then return "file" end
      return nil
    end,
    read = function(_: string): string? return nil end,
    real = function(path: string): string? return path end,
    unbuilt = function(): string? return nil end,
    symbols = function(query: string): {link_resolve.Symbol}?, string
      local module, symbol = query:match("^([^.:]+)[.:](.+)$")
      if module == nil or symbol == nil then return {}, "" end
      if module == task then return declared(task, symbol), "" end
      if module:match("^%u") ~= nil then
        return declared(task, module .. "." .. symbol), ""
      end
      return {}, ""
    end,
    member = function(module: string, member: string): {link_resolve.Symbol}?, string
      if module ~= task then return {}, "" end
      return declared(module, member), ""
    end,
  }
end

--- What `cosmic fix` would link in `text`, a project's TASK.md.
local function would_link(task: string, text: string): {string}
  local out = SyntaxLinks.rewrite(link_resolve.resolver(implementing_everything(task)), "/p/TASK.md",
    "/p/TASK.md", "markdown", text)
  local said = out.linked
  if out.source ~= text and #said == 0 then
    said = { "/p/TASK.md: link: its definitions would be rewritten" }
  end
  return said
end

--- The grader runs `cosmic fix --check` in the solver's project, where
--- TASK.md sits: once the project declares the API a task names, a plain
--- span naming it would be linked, failing the check on text the
--- solver never wrote. A task names its API as each list item's head,
--- before a `:`, where a link would read as a definition.
local function test_fix_links_nothing_in_any_task()
  -- Such a project links an API named mid-sentence, or heading a list item with no `:` after it.
  assert(#would_link("jobs", "- `jobs.Status`, an enum.\n") == 1)
  assert(#would_link("jobs", "Each `Plan.order` is sorted.\n") == 1)
  local tasks = assert(Fs.list("eval/task"))
  table.sort(tasks) -- checked: overload_none
  assert(#tasks > 0)
  local troubles: mut {string} = {}
  for _, name in ipairs(tasks) do
    local task = name:match("^(.+)%.md$")
    if task ~= nil then
      local text = assert(Fs.read("eval/task/" .. name)) .. assert(Fs.read("eval/journal.md"))
      for _, line in ipairs(would_link(task, text)) do
        troubles[#troubles + 1] = task .. ": " .. line
      end
    end
  end
  assert(#troubles == 0, table.concat(troubles, "\n"))
end
