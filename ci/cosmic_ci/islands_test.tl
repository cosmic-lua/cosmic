--- `check-islands` type-checks each bootstrap script by running it with `--help`, and
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

--- A clean script passes and a script the new grammar refuses fails by name, with the compiler's complaint: a syntax
--- error and a type error. The scripts are run, with `--help`, as the bootstrap runs them.
local function test_a_script_is_checked_and_run_with_help(tmp: string)
  local marker = tmp .. "/ran"
  local root = checkout(tmp, "", {
    ["build/ok.tl"] = 'local Fs = require("cosmic.fs")\nassert(Fs.write("' .. marker .. '", "ran"))\nreturn function(_: {string}): integer return 0 end\n',
    ["build/syntax.tl"] = "local x: integer =\n",
    ["build/typed.tl"] = 'local x: integer = "a"\nprint(x)\n',
  })
  local report = Islands.check(root, { "build/ok.tl", "build/syntax.tl", "build/typed.tl" }, Env.all())
  local complaints, checked = report.complaints, report.checked
  assert(checked == 3, tostring(checked))
  assert(#complaints == 2, table.concat(complaints, "\n"))
  local syntax, typed = assert(complaints[1]), assert(complaints[2])
  assert(syntax:find("^build/syntax.tl: ") and syntax:find("build/syntax.tl:2:", 1, true), syntax)
  assert(typed:find("^build/typed.tl: ") and typed:find("(not_assignable)", 1, true), typed)
  assert(Fs.read(marker) == "ran", "the clean script was not run")
end

--- A script that prints its usage and exits with `status`.
local function exiting(status: integer): string
  return 'print("usage")\nreturn function(_: {string}): integer\n  return ' .. tostring(status) .. "\nend\n"
end

--- A script that checks clean and then stops for another reason is no clean script: its exit status is held to what its
--- `--help` gives ([`Islands.help_exits`], 0 for a script the table does not name).
local function test_a_script_that_fails_for_another_reason_is_a_complaint(tmp: string)
  local root = checkout(tmp, "", {
    ["build/crash.tl"] = 'error("no such module")\n',
    ["build/exits.tl"] = exiting(7),
    ["build/perf.tl"] = exiting(1),
    ["build/paths.tl"] = exiting(0),
  })
  local report = Islands.check(root, { "build/crash.tl", "build/exits.tl", "build/perf.tl", "build/paths.tl" }, Env.all())
  local complaints = report.complaints
  assert(#complaints == 3, table.concat(complaints, "\n"))
  assert(assert(complaints[1]):find("build/crash.tl: exited 1 with --help, not 0: ", 1, true) == 1 and
      assert(complaints[1]):find("no such module", 1, true) ~= nil, complaints[1])
  assert(assert(complaints[2]):find("build/exits.tl: exited 7 with --help, not 0", 1, true) == 1, complaints[2])
  -- perf.tl gives 1 as it does; paths.tl, which gives 1 too, giving 0 is not what the table says.
  assert(assert(complaints[3]):find("build/paths.tl: exited 0 with --help, not 1", 1, true) == 1, complaints[3])
end

--- A script the new grammar's checker refuses and the fork's would let by is the point of the check: a write to a
--- view.
local function test_a_write_to_a_view_is_a_complaint(tmp: string)
  local root = checkout(tmp, "", {
    ["build/view.tl"] = 'local lines: {string} = {}\nlines[#lines + 1] = "x"\nprint(#lines)\n',
  })
  local report = Islands.check(root, { "build/view.tl" }, Env.all())
  assert(#report.complaints == 1 and assert(report.complaints[1]):find("(view_written)", 1, true) ~= nil,
    table.concat(report.complaints, "\n"))
end

local function test_a_path_that_is_neither_a_file_nor_a_directory_is_refused(tmp: string)
  local root = checkout(tmp, "", { ["build/a.lua"] = "return 1\n" })
  local report = Islands.check(root, { "build/a.lua", "build/gone.tl" }, Env.all())
  local complaints, checked = report.complaints, report.checked
  assert(checked == 1 and #complaints == 2, table.concat(complaints, "\n"))
  local neither, gone = assert(complaints[1]), assert(complaints[2])
  assert(neither:find("not a .tl file", 1, true), neither)
  assert(gone:find("^build/gone.tl: "), gone)
end

local function test_the_command_fails_for_a_refused_script_a_listed_one_and_a_missing_list(tmp: string)
  local files: mut {string:string} = {}
  -- Each prints usage and exits as the real script does with `--help`.
  for _, path in ipairs(Islands.scripts) do
    files[path] = exiting(Islands.help_exits[path] or 0)
  end
  local root = checkout(tmp, "# nothing is listed\n", files)
  assert(Islands.command({ root }) == 0)
  assert(Fs.write(root .. "/build/zig.tl", "return\n  =\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.write(root .. "/build/zig.tl", exiting(0)))
  assert(Fs.write(root .. "/ci/islands.txt", "build/zig.tl\n"))
  assert(Islands.command({ root }) == 1)
  assert(Fs.remove(root .. "/ci/islands.txt"))
  assert(Islands.command({ root }) == 2)
end
