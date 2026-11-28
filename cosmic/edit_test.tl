local Edit = require("cosmic.edit")
local Fs = require("cosmic.fs")
local sys = require("cosmic.sys")

--- A file edit changes the text of the file a link names, keeps the link, and changes nothing where one edit fails.
local function test_file_changes_the_file_a_link_names_and_changes_nothing_on_a_failure(tmp: string)
  assert(Fs.write(tmp .. "/a.txt", "one teh two\none two\n"))
  assert(Fs.symlink("a.txt", tmp .. "/link"))
  local made = Edit.file(tmp .. "/link", { { old = "teh", new = "the" } })!
  assert(made == 1, tostring(made))
  assert(assert(Fs.readlink(tmp .. "/link")) == "a.txt")
  assert(assert(Fs.read(tmp .. "/a.txt")) == "one the two\none two\n")
  local none, why = Edit.file(tmp .. "/a.txt", { { old = "the", new = "1" }, { old = "absent", new = "x" } })
  assert(none == nil)
  assert(tostring(why):find("edits[2]", 1, true) ~= nil, tostring(why))
  local twice, twice_why = Edit.file(tmp .. "/a.txt", { { old = "one", new = "1" } })
  assert(twice == nil)
  assert(tostring(twice_why):find("more than one", 1, true) ~= nil, tostring(twice_why))
  assert(assert(Fs.read(tmp .. "/a.txt")) == "one the two\none two\n")
  local absent, absent_why = Edit.file(tmp .. "/absent", { { old = "a", new = "b" } })
  assert(absent == nil)
  assert(absent_why.errno == sys.ENOENT)
end

--- A file of CRLF line ends keeps them.
local function test_file_keeps_crlf_line_ends(tmp: string)
  assert(Fs.write(tmp .. "/c.txt", "a\r\nb\r\n"))
  assert(Edit.file(tmp .. "/c.txt", { { old = "a\nb", new = "x\ny" } })! == 1)
  assert(assert(Fs.read(tmp .. "/c.txt")) == "x\r\ny\r\n")
end
