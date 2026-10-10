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
Test.policy{ profiles = { "cosmic" }, grants = { { path = "o/bin", letters = "rx" } } }

local function fix(root: string, check: boolean): string
  local args: {string} = { "fix" }
  if check then args[#args + 1] = "--check" end
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

--- A file only linked says so; one also laid out does not, and a check
--- fails the link rather than say a fix.
local function test_a_link_rewrite_says_why_only_when_it_is_the_only_change(tmp: string)
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
  assert(out:find("fix: PASS (3 Teal + 1 Markdown files, ", 1, true), out)
end

--- A method named like a command stands in for nothing; a plain function
--- with a callback parameter named `self` is no method.
local function test_a_method_named_like_a_command_earns_no_note(tmp: string)
  local root = tmp .. "/project"
  assert(Fs.mkdirs(root))
  local doc = "--- Drops one entry of the cache, in the way `unlink` drops a name.\n"
  assert(Fs.write(root .. "/lru.tl", "local record Lru\nend\n\n" ..
      doc .. "function Lru:unlink(): boolean\n  return true\nend\n\n" ..
      doc .. "function Lru.drop(self: Lru): boolean\n  return self ~= nil\nend\n\n" ..
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
