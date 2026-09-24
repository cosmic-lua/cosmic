--- `eval/arena.tl` over an eval/ directory built here: what an arena
--- holds, and where it refuses to lay one.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local Arena = require("eval.arena")

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
