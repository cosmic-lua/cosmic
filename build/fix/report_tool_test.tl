--- What `cosmic fix` says of a project of its own: the verdict's kinds,
--- the reason a link rewrite gives, and the note a function named like a
--- command earns (a method earns none). It declares `tool` because it
--- starts this program.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local this_program = require("build.this_program")
local Test = require("cosmic.test")
local Clock = require("cosmic.clock")

--- The program itself, which its test starts.
Test.policy{ cpu_features = true, profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function fix(root: string, check: boolean, paths?: {string}): string
  local args: mut {string} = { "fix" }
  if check then args[#args + 1] = "--check" end
  for _, path in ipairs(paths or {}) do args[#args + 1] = path end
  local started = this_program.program(args, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60) })
  return assert((assert(Child.run(started.argv, started.options))).stdout)
end

local OTHER = "local record other\nend\n\n--- Answers one.\n" ..
  "function other.thing(): integer\n  return 1\nend\n\nreturn other\n"

local function user(name: string, indent: string): string
  return 'local Other = require("other")\n\n--- Two, from `Other.thing`.\n' ..
    "local function " .. name .. "(): integer\n" .. indent .. "return Other.thing() + 1\nend\n\n" ..
    "return " .. name .. "\n"
end

--- A file the run only links says so, each one; a file it also lays out is fixed without the mark. A check fails the
--- link rather than say a fix.
local function test_a_link_rewrite_says_why(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  assert(Fs.write(root .. "/other.tl", OTHER))
  assert(Fs.write(root .. "/linked.tl", user("one", "  ")))
  assert(Fs.write(root .. "/both.tl", user("two", "    ")))
  assert(Fs.write(root .. "/notes.md", "Mentions `Other.thing` here.\n"))
  local checked = fix(root, true)
  assert(checked:find("link: `Other.thing` would link", 1, true), checked)
  assert(not checked:find("(links)", 1, true), checked)
  local out = fix(root, false)
  assert(out:find("fixed  linked.tl (links)\n", 1, true), out)
  assert(out:find("fixed  both.tl\n", 1, true), out)
  assert(out:find("fix: 3 Teal + 1 Markdown files, ", 1, true), out)
end

--- A method named like a command stands in for nothing; a plain function
--- with a callback parameter named `self` is no method.
local function test_a_method_named_like_a_command_earns_no_note(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local doc = "--- Drops one entry of the cache, in the way `unlink` drops a name.\n"
  assert(Fs.write(root .. "/lru.tl", "local class Lru\n" ..
      "  " .. doc .. "  function unlink(self): boolean\n    return true\n  end\n" ..
      "  " .. doc .. "  function drop(self): boolean\n    return true\n  end\nend\n\n" ..
      "return Lru\n"))
  local out = fix(root, false)
  assert(not out:find("stands in for", 1, true), out)
  assert(Fs.write(root .. "/lru.tl", "local record Lru\nend\n\n" ..
      "--- Drops one entry of the cache, in the way `unlink` drops a name.\n" ..
      "function Lru.unlink(_cb: function(self: Lru)): boolean\n  return true\nend\n\n" ..
      "return Lru\n"))
  local again = fix(root, false)
  assert(again:find("stands in for `unlink`", 1, true), again)
end

--- A file named under `static/` is refused, saying why, and the run ends in
--- a failure; the same project's whole-tree run passes it over.
local function test_a_path_under_static_is_refused(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root .. "/static"))
  assert(Fs.write(root .. "/static/notes.tl", "not   teal {{\n"))
  assert(Fs.write(root .. "/main.tl", "local n: integer = 1\nreturn n\n"))
  local named = fix(root, false, { "static/notes.tl" })
  assert(named:find("carried verbatim", 1, true), named)
  assert(named:find("fix: 1 of 1 file refused, ", 1, true), named)
  assert(assert(Fs.read(root .. "/static/notes.tl")) == "not   teal {{\n", "the asset is untouched")
  local whole = fix(root, false)
  assert(whole:find("fix: [^\n]*, 0 fixed, ") and not whole:find("carried verbatim", 1, true), whole)
end

--- `fix` with its verdict: the output and whether it exited 0.
local function fix_status(root: string, paths: {string}): string, boolean
  local args: mut {string} = { "fix", "--check" }
  for _, path in ipairs(paths) do args[#args + 1] = path end
  local started = this_program.program(args, { cwd = root,
    stdout = "capture", stderr = "stdout", timeout_ns = Clock.seconds(60) })
  local ran = assert(Child.run(started.argv, started.options))
  return assert(ran.stdout), ran.ok
end

--- A named Teal file the build never reads (under `bin/`, which no project builds) is not passed for its layout alone: it is
--- checked on its own, as `--standalone` checks a file, and the compiler's refusal fails the run, from the project's root as
--- from any other directory.
local function test_a_named_file_outside_the_build_is_checked_alone(tmp: string)
  local root = tmp .. "/unit"
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.write(root .. "/bin/broken.tl", 'local broken: integer = "definitely a string"\n'))
  assert(Fs.write(root .. "/bin/fine.tl", "local function main(): integer\n  return 0\nend\n\nreturn main\n"))
  local out, ok = fix_status(root, { "bin/broken.tl" })
  assert(not ok, out)
  assert(out:find("not an input of the tree at", 1, true) and out:find("checked alone", 1, true), out)
  assert(out:find("not_assignable", 1, true), out)
  local inside, inside_ok = fix_status(root .. "/bin", { "broken.tl" })
  assert(not inside_ok, inside)
  local fine, fine_ok = fix_status(root, { "bin/fine.tl" })
  assert(fine_ok, fine)
  assert(fine:find("checked alone", 1, true), fine)
end

--- A directory named that the build never reads is checked alone file by file, the file named twice is one, and a link inside
--- the build to a file under `bin/` is the build's, reported once.
local function test_a_named_directory_outside_the_build_is_checked_alone(tmp: string)
  local root = tmp .. "/unit"
  assert(Fs.mkdirs(root .. "/bin"))
  assert(Fs.mkdirs(root .. "/lib"))
  assert(Fs.write(root .. "/bin/broken.tl", 'local broken: integer = "definitely a string"\n'))
  assert(Fs.write(root .. "/bin/needs.tl", 'local X = require("lib.x")\n\nreturn X\n'))
  local out, ok = fix_status(root, { "bin" })
  assert(not ok, out)
  assert(out:find("not_assignable", 1, true), out)
  assert(out:find("sibling declaration file", 1, true), out)
  local twice, twice_ok = fix_status(root, { "bin/broken.tl", "./bin/broken.tl", root .. "/bin/broken.tl", "bin/../bin/broken.tl" })
  assert(not twice_ok, twice)
  assert(twice:find("1 of 1 file refused", 1, true), twice)
  assert(Fs.symlink("../bin/broken.tl", root .. "/lib/link.tl"))
  local linked, linked_ok = fix_status(root, { "lib/link.tl" })
  assert(not linked_ok, linked)
  assert(not linked:find("checked alone", 1, true), linked)
end
