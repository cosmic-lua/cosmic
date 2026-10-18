--- `check-islands` type-checks each file of the list without running it, and
--- names the ones the running driver's Teal refuses.
local Fs = require("cosmic.fs")
local Islands = require("cosmic_ci.islands")
local Env = require("cosmic.env")
local Test = require("cosmic.test")

-- The check starts the running driver again, as build_paths_test does.
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

--- A checkout at `tmp` holding the list `paths` and the files `files`
--- (path to text).
local function checkout(tmp: string, paths: string, files: {string:string}): string
  local root = tmp .. "/checkout"
  assert(Fs.mkdirs(root .. "/ci"))
  assert(Fs.mkdirs(root .. "/build"))
  assert(Fs.write(root .. "/ci/islands.txt", paths))
  for path, text in pairs(files) do assert(Fs.write(root .. "/" .. path, text)) end
  return root
end

local function test_the_list_is_one_path_a_line_without_comments()
  local paths = Islands.paths("# why\n\nbuild/a.tl  # trailing\n  build/b.tl\nci/\n")
  assert(#paths == 3 and paths[1] == "build/a.tl" and paths[2] == "build/b.tl" and paths[3] == "ci/",
    table.concat(paths, ","))
end

--- A clean file passes and a file the Teal refuses fails by name, with the
--- compiler's complaint: a syntax error, a type error, and a `require` of
--- the tree around it, which a script run standalone does not have. A
--- directory of the list is not checked, and nothing is run.
local function test_a_file_is_checked_and_never_run(tmp: string)
  local marker = tmp .. "/ran"
  local root = checkout(tmp, "", {
    ["build/ok.tl"] = 'local Fs = require("cosmic.fs")\nassert(Fs.write("' .. marker .. '", "x"))\nreturn 1\n',
    ["build/syntax.tl"] = "local x: integer =\n",
    ["build/typed.tl"] = 'local x: integer = "a"\nreturn x\n',
    ["build/tree.tl"] = 'local Paths = require("build.paths")\nreturn Paths\n',
  })
  local complaints, checked = Islands.check(root,
    { "build/ok.tl", "build/syntax.tl", "build/tree.tl", "build/typed.tl", "ci/" }, Env.all())
  assert(checked == 4, tostring(checked))
  assert(#complaints == 3, table.concat(complaints, "\n"))
  local syntax, tree, typed = assert(complaints[1]), assert(complaints[2]), assert(complaints[3])
  assert(syntax:find("^build/syntax.tl: ") and syntax:find("exited 2", 1, true) and
      syntax:find("build/syntax.tl:2:", 1, true), syntax)
  assert(tree:find("^build/tree.tl: ") and tree:find("module not found", 1, true), tree)
  assert(typed:find("^build/typed.tl: ") and typed:find("got string", 1, true), typed)
  assert(Fs.exists(marker) == false, "the file was run")
end

local function test_a_path_that_is_neither_a_file_nor_a_directory_is_refused(tmp: string)
  local root = checkout(tmp, "", { ["build/a.lua"] = "return 1\n" })
  local complaints, checked = Islands.check(root, { "build/a.lua", "build/gone.tl" }, Env.all())
  assert(checked == 1 and #complaints == 2, table.concat(complaints, "\n"))
  local neither, gone = assert(complaints[1]), assert(complaints[2])
  assert(neither:find("neither a directory nor a .tl file", 1, true), neither)
  assert(gone:find("^build/gone.tl: "), gone)
end

local function test_the_command_fails_for_a_refused_file_and_a_missing_or_empty_list(tmp: string)
  local root = checkout(tmp, "# the files\nbuild/ok.tl\nci/\n", { ["build/ok.tl"] = "return 1\n" })
  assert(Islands.command({ root }) == 0)
  assert(Fs.write(root .. "/build/ok.tl", "return\n  =\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.write(root .. "/ci/islands.txt", "# nothing\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.remove(root .. "/ci/islands.txt"))
  assert(Islands.command({ root }) == 2)
end
