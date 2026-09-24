--- Lays out an arena for one eval: the binary at bin/cosmic, the task
--- at project/TASK.md, scratch space at tmp/. The agent runs in
--- project/ with bin/ first on PATH and TMPDIR set to tmp/.
---
---     cosmic --standalone eval/arena.tl <task> <cosmic-binary> <dir>
---
--- `<task>` names eval/task/<task>.md; eval/journal.md is appended to
--- it. `eval/arena` runs this on the bootstrap cosmic, as bin/vendor
--- runs build/vendor.tl: it requires `cosmic.*` modules only, and finds
--- eval/ from this script's own path.
local Fs = require("cosmic.fs")
local Hash = require("cosmic.hash")
local sys = require("cosmic.sys")

local record Arena
end

local function under(path: string, dir: string): boolean
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- The prompt the solver is given, naming the arena's own paths.
function Arena.prompt(dir: string): string
  return "Your working directory is " .. dir .. "/project. Set that working directory explicitly\n"
    .. "for every shell call, prepend " .. dir .. "/bin to PATH, and set TMPDIR=" .. dir .. "/tmp in\n"
    .. "every shell call.\n"
    .. "Read TASK.md there and do exactly what it says. Work independently without\n"
    .. "sub-agents or coaching. Use the binary as your only source about cosmic.\n"
end

--- Lays out a new arena at `dir` for `task`, with eval/ at `eval`,
--- answering the arena's absolute path. `dir` must not exist yet, and
--- must be outside the repository eval/ sits in, links resolved.
function Arena.lay(eval: string, task: string, binary: string, dir: string): string | nil, string
  local task_text = not task:find("/", 1, true) and Fs.read(eval .. "/task/" .. task .. ".md") or nil
  if task_text == nil then
    return nil, "no task eval/task/" .. task .. ".md"
  end
  local st = Fs.stat(binary)
  if st == nil or st.kind ~= "file" or st.mode & 0x49 == 0 then
    return nil, binary .. " is not an executable"
  end
  local repo = eval:match("^(.*)/[^/]+$")
  if repo == "" then
    repo = "/"
  end
  dir = dir:gsub("(.)/+$", "%1")
  if under(dir, eval) or under(dir, repo) then
    return nil, dir .. " is inside the repository; put the arena outside it"
  end
  local name = dir:match("([^/]+)$")
  if name == nil or name == "." or name == ".." then
    return nil, "destination must be new: " .. dir
  end
  -- Resolve the parent physically before checking the repository
  -- boundary: its nearest ancestor that exists, with the rest of it
  -- after, so nothing is made inside the repository before the check.
  local parent = dir:match("^(.*)/[^/]+$") or "."
  if parent == "" then
    parent = "/"
  end
  local existing, rest = parent, ""
  while not Fs.exists(existing) do
    rest = "/" .. existing:match("([^/]+)$") .. rest
    existing = existing:match("^(.*)/[^/]+$") or "."
    if existing == "" then
      existing = "/"
    end
  end
  local physical, ptrouble = Fs.absolute(existing)
  if physical == nil then
    return nil, ptrouble
  end
  dir = (physical == "/" and "" or physical) .. rest .. "/" .. name
  if under(dir, repo) then
    return nil, "put the arena outside the repository"
  end
  local made, mtrouble = Fs.mkdirs(dir:match("^(.*)/[^/]+$"))
  if not made then
    return nil, mtrouble
  end
  -- Again, now the parent is there: a `..` in what did not exist yet is
  -- resolved only now.
  physical, ptrouble = Fs.absolute(dir:match("^(.*)/[^/]+$"))
  if physical == nil then
    return nil, ptrouble
  end
  dir = (physical == "/" and "" or physical) .. "/" .. name
  if under(dir, repo) then
    return nil, "put the arena outside the repository"
  end
  local new, ntrouble, errno = sys.mkdir(dir)
  if not new then
    return nil, errno == sys.EEXIST and "destination must be new: " .. dir or dir .. ": " .. ntrouble
  end
  local binary_bytes, btrouble = Fs.read(binary)
  if binary_bytes == nil then
    return nil, btrouble
  end
  local journal, jtrouble = Fs.read(eval .. "/journal.md")
  if journal == nil then
    return nil, jtrouble
  end
  local files: {{string}} = {
    { "bin/cosmic", binary_bytes },
    { "project/TASK.md", task_text .. journal },
    { "PROMPT.md", Arena.prompt(dir) },
  }
  for _, sub in ipairs({ "bin", "project", "tmp" }) do
    local ok, why = sys.mkdir(dir .. "/" .. sub)
    if not ok then
      return nil, dir .. "/" .. sub .. ": " .. why
    end
  end
  -- These records are for the evaluator, not the solver.
  local hashes: {string} = {}
  for _, file in ipairs(files) do
    local wrote, wtrouble = Fs.write(dir .. "/" .. file[1], file[2])
    if not wrote then
      return nil, wtrouble
    end
    hashes[#hashes + 1] = Hash.hex_sha256(file[2]) .. "  " .. file[1] .. "\n"
  end
  -- The binary is 0755 whatever the umask, as `chmod 755` made it.
  local executable, etrouble = sys.chmod(dir .. "/bin/cosmic", 0x1ed)
  if not executable then
    return nil, dir .. "/bin/cosmic: " .. etrouble
  end
  local wrote, wtrouble = Fs.write(dir .. "/inputs.sha256", table.concat(hashes))
  if not wrote then
    return nil, wtrouble
  end
  return dir, ""
end

local function complain(message: string)
  Fs.put(Fs.stderr, "arena: " .. message .. "\n")
end

function Arena.main(argv: {integer: string}): integer
  local task, binary, dir = argv[1], argv[2], argv[3]
  if task == nil or binary == nil or dir == nil or argv[4] ~= nil then
    Fs.put(Fs.stderr, "usage: eval/arena <task> <cosmic-binary> <dir>\n")
    return 2
  end
  local script, strouble = Fs.absolute(argv[0])
  if script == nil then
    complain(strouble)
    return 2
  end
  local eval = script:match("^(.*)/[^/]+%.tl$")
  if eval == nil then
    complain(argv[0] .. ": expected to run as .../eval/arena.tl")
    return 2
  end
  local laid, trouble = Arena.lay(eval, task, binary, dir)
  if laid == nil then
    complain(trouble)
    return 2
  end
  Fs.put(Fs.stdout, "arena: " .. laid .. " (task " .. task .. ")\n")
  return 0
end

return Arena
