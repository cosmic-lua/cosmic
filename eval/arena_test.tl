--- [`eval/arena.tl`] over an eval/ directory built here: what an arena
--- holds, and where it refuses to lay one.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Test = require("cosmic.test")
local Arena = require("eval.arena")
local link_resolve = require("build.link_resolve")
local links = require("build.links")
local teal = require("build.teal")
local type compiler = require("build.compiler")

--- The tasks and the journal every arena's TASK.md is made of.
Test.policy{ grants = { { path = "eval/task/", letters = "r" }, { path = "eval/journal.md", letters = "r" } } }

--- A repository at `root` whose eval/ has one task, `t`, and a
--- journal; and an executable beside it.
local function repository(root: string): string, string
  local eval = root .. "/repo/eval"
  assert(Fs.mkdirs(eval .. "/task"))
  assert(Fs.write(eval .. "/task/t.md", "# Task\n"))
  assert(Fs.write(eval .. "/journal.md", "## Journal\n"))
  local binary = root .. "/cosmic"
  assert(Fs.write(binary, "#!/bin/sh\n", 0x1ed))
  return eval, binary
end

local function test_an_arena_holds_the_binary_the_task_and_their_hashes(dir: string)
  local eval, binary = repository(dir)
  local arena = assert(Arena.lay(eval, "t", binary, dir .. "/runs/one"))
  assert(arena == assert(Fs.absolute(dir)) .. "/runs/one", arena)
  assert(Fs.read(arena .. "/project/TASK.md") == "# Task\n## Journal\n")
  assert(Fs.read(arena .. "/PROMPT.md") == Arena.prompt(arena))
  assert(assert(Fs.stat(arena .. "/bin/cosmic")).mode & 0x1ff == 0x1ed)
  assert(Fs.is_dir(arena .. "/tmp"))
  assert(Fs.read(arena .. "/inputs.sha256") ==
      Hash.hex_sha256("#!/bin/sh\n") .. "  bin/cosmic\n" ..
      Hash.hex_sha256("# Task\n## Journal\n") .. "  project/TASK.md\n" ..
      Hash.hex_sha256(Arena.prompt(arena)) .. "  PROMPT.md\n")
end

local function test_an_arena_must_be_new(dir: string)
  local eval, binary = repository(dir)
  assert(Arena.lay(eval, "t", binary, dir .. "/one"))
  local laid, trouble = Arena.lay(eval, "t", binary, dir .. "/one/")
  assert(laid == nil and trouble:find("must be new", 1, true), trouble)
end

local function test_an_arena_stays_outside_the_repository_through_a_link(dir: string)
  local eval, binary = repository(dir)
  local laid, trouble = Arena.lay(eval, "t", binary, dir .. "/repo/run")
  assert(laid == nil and trouble:find("inside the repository", 1, true), trouble)
  assert(Fs.symlink(dir .. "/repo", dir .. "/link"))
  laid, trouble = Arena.lay(eval, "t", binary, dir .. "/link/run")
  assert(laid == nil and trouble == "put the arena outside the repository", trouble)
  assert(not Fs.exists(dir .. "/repo/run"))
end

local function test_a_task_and_an_executable_are_required(dir: string)
  local eval, binary = repository(dir)
  local laid, trouble = Arena.lay(eval, "nope", binary, dir .. "/run")
  assert(laid == nil and trouble == "no task eval/task/nope.md", trouble)
  laid, trouble = Arena.lay(eval, "t", eval .. "/journal.md", dir .. "/run")
  assert(laid == nil and trouble:find("is not an executable", 1, true), trouble)
end

local function test_an_arena_needs_a_name_of_its_own(dir: string)
  local eval, binary = repository(dir)
  for _, bad in ipairs({ "/", "//", "", dir .. "/.." }) do
    local laid, trouble = Arena.lay(eval, "t", binary, bad)
    assert(laid == nil and trouble:find("must be new", 1, true), bad .. ": " .. tostring(trouble))
  end
end

--- A link into the repository is resolved before anything is made, so
--- a refusal leaves nothing behind inside it.
local function test_a_refusal_through_a_link_makes_nothing_inside_the_repository(dir: string)
  local eval, binary = repository(dir)
  assert(Fs.symlink(dir .. "/repo", dir .. "/link"))
  local laid, trouble = Arena.lay(eval, "t", binary, dir .. "/link/new/deeper/run")
  assert(laid == nil and trouble == "put the arena outside the repository", trouble)
  assert(not Fs.exists(dir .. "/repo/new"))
  assert(Fs.mkdirs(dir .. "/out"))
  laid, trouble = Arena.lay(eval, "t", binary, dir .. "/out/gone/../../repo/run")
  assert(laid == nil and trouble == "put the arena outside the repository", trouble)
  assert(not Fs.exists(dir .. "/repo/run"))
end

-- TODO: hold a task's paths to the same rule. Mirror's `sub/b.bin`,
-- `/sub/b.bin` and `./sub/b.bin`, pack's `sub/b.txt` and ledger's
-- `America/New_York` would be linked in a project holding such a
-- file, failing the grader's `fix --check` on TASK.md; quote them as
-- values (`"sub/b.bin"`) or lay TASK.md outside project/, and claim
-- every such file here.

--- A project at /p whose module `task` declares every name asked of
--- it (`jobs.Plan`, `jobs.anything`), in <task>.tl, and whose every
--- capitalized name is a type of that module with every member asked
--- of it (`Plan.order`), as `cosmic docs` answers a type's member. It
--- holds nothing else: no other module's symbol, file or directory,
--- which a task's span would name only by chance.
local function implementing_everything(task: string): link_resolve.Context
  local function declared(module: string, symbol: string): {link_resolve.Symbol}
    return { { module = module, symbol = symbol, file = module .. ".tl" } }
  end
  return {
    root = "/p",
    kind = function(path: string): string | nil
      if path == "/p" then return "dir" end
      if path == "/p/" .. task .. ".tl" then return "file" end
      return nil
    end,
    read = function(_: string): string | nil return nil end,
    real = function(path: string): string | nil return path end,
    unbuilt = function(): string | nil return nil end,
    symbols = function(query: string): {link_resolve.Symbol} | nil, string
      local module, symbol = query:match("^([^.:]+)[.:](.+)$")
      if module == task then return declared(task, symbol), "" end
      if module ~= nil and module:match("^%u") ~= nil then
        return declared(task, module .. "." .. symbol), ""
      end
      return {}, ""
    end,
    member = function(module: string, member: string): {link_resolve.Symbol} | nil, string
      if module ~= task then return {}, "" end
      return declared(module, member), ""
    end,
  }
end

--- What `cosmic fix` would link in `text`, a project's TASK.md.
local function would_link(built: compiler, task: string, text: string): {string}
  local out = links.rewrite(link_resolve.resolver(implementing_everything(task)), "/p/TASK.md",
    "/p/TASK.md", "markdown", text, built)
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
  local built = assert(teal.load())
  -- Such a project links the form tasks took before this rule.
  assert(#would_link(built, "jobs", "- `jobs.Status`, an enum.\n") == 1)
  assert(#would_link(built, "jobs", "Each `Plan.order` is sorted.\n") == 1)
  local tasks = assert(Fs.list("eval/task"))
  table.sort(tasks)
  assert(#tasks > 0)
  local troubles: {string} = {}
  for _, name in ipairs(tasks) do
    local task = name:match("^(.+)%.md$")
    if task ~= nil then
      local text = assert(Arena.task_text("eval", task))
      for _, line in ipairs(would_link(built, task, text)) do
        troubles[#troubles + 1] = task .. ": " .. line
      end
    end
  end
  assert(#troubles == 0, table.concat(troubles, "\n"))
end
