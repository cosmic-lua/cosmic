--- The list ci/bootstrap-files.txt and the check ci/'s code makes before it runs a file standalone on the pinned
--- release: the reading of the list, and the refusals, which are those of bin/cosmic-bootstrap (bootstrap_test.tl).
local BootstrapList = require("cosmic_ci.bootstrap_list")
local BuildPaths = require("cosmic_ci.build_paths")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")

Test.policy{ profiles = { "cosmic" } }

local function test_the_list_is_one_path_a_line_without_comments_or_white_space()
  local paths = BootstrapList.paths("# why\n\nbuild/a.tl  # trailing\r\n  build/b.tl \n\t\nci/\n# build/c.tl\n")
  assert(#paths == 3 and paths[1] == "build/a.tl" and paths[2] == "build/b.tl" and paths[3] == "ci/",
    table.concat(paths, ","))
end

--- A checkout at `tmp/root`: a pin, a list naming build/listed.tl, and the files.
local function checkout(tmp: string, list?: string): string
  local root = tmp .. "/root"
  assert(Fs.mkdirs(root .. "/ci") and Fs.mkdirs(root .. "/build") and Fs.mkdirs(tmp .. "/outside"))
  assert(Fs.write(root .. "/ci/cosmic-driver.pin", "pin\n"))
  if list ~= nil then assert(Fs.write(root .. "/ci/bootstrap-files.txt", list)) end
  for _, name in ipairs({ "listed.tl", "listed.tl.evil", "unlisted.tl" }) do
    assert(Fs.write(root .. "/build/" .. name, "return 1\n"))
  end
  assert(Fs.write(tmp .. "/outside/free.tl", "return 1\n"))
  assert(Fs.symlink(root .. "/build/unlisted.tl", tmp .. "/outside/link.tl"))
  return root
end

--- A file of a checkout runs only where its list names it, a file outside every checkout runs, and what cannot be
--- told is refused.
local function test_a_file_of_a_checkout_must_be_listed(tmp: string)
  local root = checkout(tmp, "# why\r\n  build/listed.tl \r\n")
  assert(BootstrapList.refusal(root .. "/build/listed.tl") == nil)
  assert(BootstrapList.refusal(tmp .. "/outside/free.tl") == nil)
  for _, file in ipairs({ root .. "/build/unlisted.tl", root .. "/build/listed.tl.evil", root .. "/build",
      root .. "/build/gone.tl", tmp .. "/outside/link.tl" }) do
    local why = assert(BootstrapList.refusal(file), file .. " was let by")
    assert(why:find("is not in " .. assert(Fs.absolute(root)) .. "/ci/bootstrap-files.txt", 1, true) ~= nil, why)
  end
  local why = assert(BootstrapList.refusal(tmp .. "/nowhere/x.tl"))
  assert(why:find("cannot resolve its directory", 1, true) ~= nil, why)
  assert(Fs.remove(root .. "/ci/bootstrap-files.txt"))
  assert(BootstrapList.refusal(root .. "/build/listed.tl") ~= nil, "a checkout with no list was let by")
end

--- The one helper of ci/ that runs a file standalone by the driver's own path makes the check first.
local function test_the_helper_refuses_an_unlisted_file_and_gives_the_command_of_a_listed_one(tmp: string)
  local root = checkout(tmp, "build/listed.tl\n")
  local driver, why = BuildPaths.standalone(root .. "/build/unlisted.tl", { "x" }, {})
  assert(driver == nil and why:find("is not in", 1, true) ~= nil, why)
  local listed = assert(BuildPaths.standalone(root .. "/build/listed.tl", { "x", "y" }, {}))
  local argv = listed.argv
  assert(argv[#argv] == "y" and argv[#argv - 1] == "x" and argv[#argv - 2] == root .. "/build/listed.tl" and
      argv[#argv - 3] == "--standalone", table.concat(argv, " "))
end
