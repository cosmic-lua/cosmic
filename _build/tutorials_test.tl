#!/usr/bin/env cosmic
--- reads: docs/tutorial
-- Every tutorial runs. A tutorial is a lesson the reader follows step by
-- step to a working result, so the page IS a script: the files it tells
-- the reader to create, and the commands it tells the reader to run, in
-- page order. This test follows it the way the reader does, in a scratch
-- project, with `cosmic` resolving to the binary under test.
--
-- The grammar is the page's own markdown:
--   * a ```teal (or ```lua, ```text) fence whose info string carries
--     `file=<path>` is written to that path before the next command;
--   * each non-comment line of a ```bash fence is one command, argv
--     split on whitespace, no shell — a metacharacter fails the parse
--     rather than being interpreted, exactly as `--make`'s recipe lines
--     are. `mkdir` and `cd` are the two the runner performs itself,
--     because a reader's shell does and a child process cannot;
--   * a `# ` line directly under a command is an assertion: the
--     command's combined output must contain it. `# ...` is a skip.
--
-- A command's exit status must be zero. A tutorial that wants to show a
-- failure shows it in a ```text fence, which nothing runs.

local check = require("cosmic.check")
local child = require("cosmic.child")
local fs = require("cosmic.fs")

local TUTORIALS < const > = "docs/tutorial"

local cosmic = fs.absolute_path(fs.join(check.must(os.getenv("TEST_BIN")), "cosmic"))
local tmpdir = check.must(os.getenv("TEST_TMPDIR"))
local make_bin = fs.absolute_path(os.getenv("COSMIC_MAKE") or "o/make")
check.needs("the make engine at " .. make_bin, fs.is_file(make_bin))

--- One thing the page tells the reader to do.
local record Step
  --- `file` writes `path`; `command` runs `argv`.
  kind: string
  line: integer
  path: string
  body: string
  argv: {string}
  --- Substrings the command's output must contain.
  expect: {string}
end

--- Argv from one command line, comments dropped.
--- @return {string} | nil Nil for a blank line
local function split_argv(line: string): {string} | nil
  local argv: {string} = {}
  for word in line:gmatch("%S+") do
    if word:sub(1, 1) == "#" then
      break
    end
    argv[#argv + 1] = word
  end
  if #argv == 0 then
    return nil
  end
  return argv
end

--- The steps of one tutorial, in page order.
local function steps_of(path: string): {Step}
  local text = check.must(fs.read(path))
  local out: {Step} = {}
  local in_code = false
  local lineno, start = 0, 0
  local lang, indent, info = "", "", ""
  local body: {string} = {}
  local command: Step = nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    lineno = lineno + 1
    local lead, fence, rest = line:match("^(%s*)```(%w*)(.*)$")
    if fence then
      if in_code then
        local file = info:match("file=(%S+)")
        if file then
          out[#out + 1] = {
            kind = "file", line = start, path = file,
            body = table.concat(body, "\n") .. "\n",
          }
        end
        in_code, command = false, nil
      else
        in_code, lang, indent, info, start, body = true, fence, lead, rest, lineno, {}
      end
    elseif in_code then
      if indent ~= "" and line:sub(1, #indent) == indent then
        line = line:sub(#indent + 1)
      end
      if lang == "bash" then
        if line:match("^%s*$") then
          command = nil
        elseif line:match("^%s*#") then
          local said = line:match("^%s*#%s?(.-)%s*$")
          if command and said ~= "..." and said ~= "" then
            command.expect[#command.expect + 1] = said
          end
        else
          local argv = split_argv(line)
          if argv then
            for _, word in ipairs(argv) do
              assert(not word:find("[&|;<>`$]"), path .. ":" .. lineno ..
                ": a tutorial command is argv, not shell: " .. line)
            end
            command = {kind = "command", line = lineno, argv = argv, expect = {}}
            out[#out + 1] = command
          end
        end
      else
        body[#body + 1] = line
      end
    end
  end
  return out
end

--- Run one command inside the scratch project.
--- @return integer The exit code
--- @return string stdout and stderr, in that order
local function run_in(root: string, argv: {string}): integer, string
  local env: {string} = {
    "PATH=" .. (os.getenv("PATH") or ""),
    "HOME=" .. tmpdir,
    "COSMIC_MAKE=" .. make_bin,
    "TMPDIR=" .. tmpdir,
    "NO_COLOR=1",
    "COSMIC_NO_WELCOME=1",
  }
  local cmd: {string} = {}
  for i, word in ipairs(argv) do
    cmd[i] = word
  end
  if cmd[1] == "cosmic" then
    cmd[1] = cosmic
  end
  local h = check.must(child.start(cmd, {cwd = root, env = env}))
  local r = check.must(h:wait())
  return r.code or 128, (r.stdout or "") .. (r.stderr or "")
end

--- Follow one tutorial from a clean directory.
local function follow(page: string)
  local stem = fs.basename(page):gsub("%.md$", "")
  local root = fs.join(tmpdir, "tutorials", stem)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  local steps = steps_of(page)
  local commands = 0
  for _, step in ipairs(steps) do
    local where = page .. ":" .. step.line
    if step.kind == "file" then
      local full = fs.join(root, step.path)
      assert(fs.make_dirs(fs.dirname(full)))
      assert(fs.write(full, step.body))
    elseif step.argv[1] == "mkdir" then
      commands = commands + 1
      assert(step.argv[2] and not step.argv[3], where .. ": mkdir takes one directory")
      assert(fs.make_dirs(fs.join(root, step.argv[2])))
    elseif step.argv[1] == "cd" then
      commands = commands + 1
      assert(step.argv[2] and not step.argv[3], where .. ": cd takes one directory")
      root = fs.join(root, step.argv[2])
      assert(fs.is_dir(root), where .. ": cd into a directory that is not there: " .. root)
    else
      commands = commands + 1
      local shown = table.concat(step.argv, " ")
      local code, output = run_in(root, step.argv)
      assert(code == 0, where .. ": `" .. shown .. "` exited " .. code ..
        " where the page shows it succeeding:\n" .. output)
      for _, said in ipairs(step.expect) do
        assert(output:find(said, 1, true), where .. ": `" .. shown ..
          "` did not print `" .. said .. "`, which the page says it does:\n" ..
          output)
      end
    end
  end
  assert(commands > 0, page .. ": a tutorial with no command teaches nothing " ..
    "the reader can follow")
  print("followed " .. page .. ": " .. commands .. " commands")
end

local function test_every_tutorial_runs()
  local pages = check.must(fs.find(TUTORIALS, {glob = "*.md"}))
  table.sort(pages)
  assert(#pages > 0, "no tutorial under " .. TUTORIALS)
  for _, page in ipairs(pages) do
    follow(page)
  end
end
