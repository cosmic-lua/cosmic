--- The header's `Kind` ([`sys.Kind`]) against the core that answers it.
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local gen_syscalls = require("build.gen_syscalls")

Test.needs{ reads = { "core/syscalls.h", "core/syscalls_fs.c" } }

--- Every kind the core can answer is a member of the enum, and every
--- member is one it answers: the header's `Kind` and the words
--- core/syscalls_fs.c's `mode_kind` and `readdir` push are one set, so
--- a kind added to the C cannot be left out of the type.
local function test_the_enum_is_what_the_core_answers()
  local found = assert(gen_syscalls.read((assert(Fs.read("core/syscalls.h")))))
  local declared: {string:boolean} = {}
  for _, alias in ipairs(found.aliases) do
    if alias.name == "Kind" then
      for _, member in ipairs(alias.members) do declared[member.value] = true end
    end
  end
  local c = assert(Fs.read("core/syscalls_fs.c"))
  local mode_kind = assert(c:match("mode_kind %(mode_t mode%) {(.-)\n}"), "no mode_kind")
  local answered: {string:boolean} = {}
  for word in mode_kind:gmatch('return "(%w+)";') do answered[word] = true end
  local readdir = assert(c:match("COSMIC_SYSCALL%(readdir, 1%) {(.-)\n}"), "no readdir")
  for word in readdir:gmatch('kind = "(%w+)";') do answered[word] = true end
  for word in pairs(answered) do
    assert(declared[word], "the core answers \"" .. word .. "\", which Kind does not declare")
  end
  for word in pairs(declared) do
    assert(answered[word], "Kind declares \"" .. word .. "\", which the core never answers")
  end
end
