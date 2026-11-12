--- What a granted host program is given beside its own file
--- (build/host_program.tl), and that a worker starts one on those files
--- alone: this module grants /bin/cat and /bin/sh and declares no
--- "system".

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Test = require("cosmic.test")
local sys = require("cosmic.sys")
local host_program = require("build.host_program")

--- Two dynamic programs of the host, which it must have. Their loader and
--- libraries come with them.
Test.policy{
  grants = { { path = "/bin/cat", letters = "r" }, { path = "/bin/sh", letters = "r" } },
  requires = { "path:/bin/cat", "path:/bin/sh" },
}

--- A dynamic program starts in a worker given it, its loader and its
--- libraries, with nothing else of the system's.
local function test_a_granted_program_starts_without_the_systems_paths(tmp: string)
  assert(Fs.write(tmp .. "/a", "hello"))
  local ran, why = Child.run({ "/bin/cat", tmp .. "/a" }, { stdout = "capture", stderr = "capture" })
  assert(ran ~= nil, why)
  assert(ran.ok and ran.stdout == "hello", tostring(ran.code) .. " " .. tostring(ran.stderr))
  -- A program the module does not grant is not there, whatever the host
  -- has, where a sandbox holds the worker: one has the tree at /tree.
  if sys.getcwd() == "/tree" then
    local other, _ = Child.run({ "/bin/ls", tmp }, { stdout = "capture", stderr = "capture" })
    assert(other == nil or not other.ok, "/bin/ls ran, which this module does not grant")
  end
end

--- An ELF file of 64 bits whose one program header is `kind`, naming
--- `name` at the offset `offset` its header claims, with its program
--- headers at `phoff`.
local function elf(kind: integer, name: string, phoff: integer, offset: integer): string
  local header = "\127ELF" .. string.char(2, 1) .. string.rep("\0", 26) .. string.pack("<i8", phoff) ..
    string.rep("\0", 14) .. string.pack("<I2I2", 56, 1) .. string.rep("\0", 6)
  local segment = string.pack("<I4I4i8i8i8i8i8i8", kind, 4, offset, 0, 0, #name + 1, #name + 1, 1)
  return header .. segment .. name .. "\0"
end

--- A dynamic program's loader is read from its PT_INTERP segment, and is
--- given with what it needs in turn; a header that names what the file
--- does not hold, or no loader, gives nothing and raises nothing.
local function test_a_dynamic_program_is_given_the_loader_it_names(tmp: string)
  local function given_for(name: string, bytes: string): {string}
    local path = tmp .. "/" .. name
    assert(Fs.write(path, bytes))
    assert(Fs.chmod(path, 0x1ed))
    return host_program.complete({ path }, "/usr/bin:/bin")
  end
  -- The stand-in loader is the shell, which is there and answers no `--list`.
  local dynamic = given_for("dynamic", elf(3, "/bin/sh", 64, 120))
  assert(dynamic[2] == "/bin/sh", table.concat(dynamic, " "))
  assert(#given_for("static", elf(1, "/bin/sh", 64, 120)) == 1, "a file with no PT_INTERP names no loader")
  assert(#given_for("absent", elf(3, "/bin/no-such-loader", 64, 120)) == 1, "a loader that is not there is not given")
  assert(#given_for("relative", elf(3, "bin/sh", 64, 120)) == 1, "a relative loader is not given")
  assert(#given_for("directory", elf(3, "/bin", 64, 120)) == 1, "a directory is not given")
  assert(#given_for("past", elf(3, "/bin/sh", 64, 1 << 40)) == 1)
  assert(#given_for("negative", elf(3, "/bin/sh", 64, -8)) == 1)
  assert(#given_for("headers", elf(3, "/bin/sh", -1, 120)) == 1)
  assert(#given_for("short", "\127ELF") == 1)
end

--- A script comes with its interpreter, and that with its own loader and
--- libraries; a file that is no program names nothing.
local function test_a_script_is_given_its_interpreter(tmp: string)
  local script = tmp .. "/run"
  assert(Fs.write(script, "#!/bin/sh\nexit 0\n"))
  assert(Fs.chmod(script, 0x1ed))
  local given = host_program.complete({ script }, "/usr/bin:/bin")
  assert(given[1] == script and given[2] == "/bin/sh", table.concat(given, " "))
  local of_shell = host_program.complete({ "/bin/sh" }, "/usr/bin:/bin")
  assert(#given == #of_shell + 1, table.concat(given, " "))
  for i = 2, #of_shell do
    assert(given[i + 1] == of_shell[i], "the interpreter's own needs follow it: " .. table.concat(given, " "))
  end
  local to_directory = tmp .. "/to-directory"
  assert(Fs.write(to_directory, "#!/bin/\nexit 0\n"))
  assert(Fs.chmod(to_directory, 0x1ed))
  assert(#host_program.complete({ to_directory }, "/usr/bin:/bin") == 1, "a directory is not given")
  local text = tmp .. "/text"
  assert(Fs.write(text, "#!/bin/sh\n"))
  assert(#host_program.complete({ text }, "/usr/bin:/bin") == 1, "a file no one may run names nothing")
  assert(#host_program.complete({ tmp .. "/absent" }, "/usr/bin:/bin") == 1)
end

--- Each path is given once, a granted one first.
local function test_each_path_is_given_once()
  local given = host_program.complete({ "/bin/sh", "/bin/cat", "/bin/sh" }, "/usr/bin:/bin")
  local seen: mut {string:boolean} = {}
  for _, path in ipairs(given) do
    assert(seen[path] ~= true, path .. " twice")
    seen[path] = true
  end
  assert(given[1] == "/bin/sh" and given[2] == "/bin/cat")
end
