--- What a program of the host needs beside its own file to start: the
--- loader and the shared libraries a dynamic one names, and the
--- interpreter a script's `#!` line names. A module that grants a host
--- program ([`cosmic.test`]'s `host`) is given these with it
--- ([`host_program.complete`]), each a host file like any it grants: its
--- worker has it at its own name, and its key holds it by its contents.
--- So a test that starts `/bin/cat` grants `/bin/cat` and needs nothing of
--- the profile "system", whose key holds every package the host has.
---
--- What a program opens once it runs is not found here: a library it
--- loads by name (`dlopen`: a name service, a locale, an iconv table), a
--- configuration file, another program it starts. A test whose program
--- needs one grants it too, or declares "system".
---
--- The libraries are the loader's own answer (`<loader> --list <program>`,
--- which glibc's and musl's both take, and which `ldd` runs), asked in the
--- process that keys the tests, not in a worker: that process starts the
--- loader a granted file names, unsandboxed, as the test it keys would
--- start the file. A loader that does not answer leaves the program with
--- its loader alone, and its test fails to start it. A program that is no
--- ELF file of 64 bits and little-endian names nothing.
---
--- Only an absolute path that is a file is given: a `#!` line naming a
--- directory or a relative path gives nothing. An `env` interpreter's
--- program is found on the PATH a sandboxed worker that declares PATH has
--- ([`build.test_sandbox`]'s `path`).
---
--- No digest of the harness holds this module ([`build.test_key`]'s
--- `harness_own`), and none needs to: all it decides is which host files a
--- module is given, and a key holds each of those by its path and contents.

local Child = require("cosmic.child")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local run, find, stat = Child.run, Proc.find, sys.stat

local record host_program
end

--- The most a `#!` line is read to, as the kernel reads it.
local SHEBANG_MAX <const> = 256

--- The most of a file's head read for its ELF header and program headers,
--- and the most a loader's name is.
local HEAD_MAX <const> = 65536
local NAME_MAX <const> = 4096

--- `count` bytes of the file at `path` from `offset`, fewer at its end; nil
--- where it cannot be read.
local function bytes_at(path: string, count: integer, offset: integer): string?
  local fd, _ = sys.open(path, sys.O_RDONLY)
  if fd == nil then return nil end
  local data, _ = sys.pread(fd, count, offset)
  local _, _ = sys.close(fd)
  return data
end

--- The loader a dynamic ELF file names (its PT_INTERP segment), `head` the
--- file's first bytes and `path` where the rest is: nil for a static one,
--- a file that is no 64-bit little-endian ELF, or one whose headers say
--- what the file does not hold.
local function loader_of(head: string, path: string): string?
  if #head < 64 or head:sub(1, 4) ~= "\127ELF" or head:byte(5) ~= 2 or head:byte(6) ~= 1 then
    return nil
  end
  local phoff = string.unpack("<i8", head, 33)
  local phentsize, phnum = string.unpack("<I2I2", head, 55)
  if phoff < 64 or phentsize < 56 then return nil end
  for i = 0, phnum - 1 do
    local at = phoff + i * phentsize + 1
    if at + 56 - 1 > #head then return nil end
    local kind = string.unpack("<I4", head, at)
    if kind == 3 then
      local offset = string.unpack("<i8", head, at + 8)
      local filesz = string.unpack("<i8", head, at + 32)
      if offset < 0 or filesz < 2 or filesz > NAME_MAX then return nil end
      local name = bytes_at(path, filesz, offset)
      if name == nil or #name ~= filesz then return nil end
      -- The segment ends with a NUL the name does not hold.
      return name:sub(1, filesz - 1)
    end
  end
  return nil
end

--- The files `loader --list path` says `path` loads, by the path each
--- resolved to: none where the loader does not answer.
local function libraries(loader: string, path: string): {string}
  local out: mut {string} = {}
  local result, _ = run({ loader, "--list", path },
    { stdout = "capture", stderr = "capture", env = {}, timeout_ns = 10 * 1000000000 })
  if result == nil or not result.ok then return out end
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local named = line:match("=>%s+(/%S+)") or line:match("^%s*(/%S+)%s+%(")
    if named ~= nil then out[#out + 1] = named end
  end
  return out
end

--- What the file at `path` names that it needs to start, itself left out:
--- a script's interpreter, and the program an `env` interpreter runs,
--- found on `search`; a dynamic program's loader and libraries.
local function named_by(path: string, search: string): {string}
  local out: mut {string} = {}
  local st, _ = stat(path)
  -- A file no one may run starts nothing.
  if st == nil or st.kind ~= "file" or st.mode & 0x49 == 0 then return out end
  local head = bytes_at(path, HEAD_MAX, 0)
  if head == nil then return out end
  local line = head:sub(1, SHEBANG_MAX):match("^#![ \t]*([^\n]*)")
  if line ~= nil then
    local words: mut {string} = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    local interpreter = words[1]
    if interpreter ~= nil then
      out[#out + 1] = interpreter
      if interpreter:match("/env$") ~= nil then
        local index = 2
        local word = words[index]
        while word ~= nil and (word:sub(1, 1) == "-" or word:match("^[%w_]+=") ~= nil) do
          index = index + 1
          word = words[index]
        end
        if word ~= nil then
          local found, _ = find(word, search)
          if found ~= nil then out[#out + 1] = found end
        end
      end
    end
    return out
  end
  local loader = loader_of(head, path)
  if loader ~= nil then
    out[#out + 1] = loader
    for _, library in ipairs(libraries(loader, path)) do out[#out + 1] = library end
  end
  return out
end

--- What each path was found to name, for the process: a run asks of the
--- same few programs for many modules.
local memo: mut {string:{string}} = {}

--- `host`, the host paths a module grants, with what each program among
--- them needs to start after them, and what those need in turn (a
--- script's interpreter is a program too), each once, in the order found.
--- `search` is the PATH an `env` interpreter's program is found on.
function host_program.complete(host: {string}, search: string): mut {string}
  local out: mut {string} = {}
  local seen: mut {string:boolean} = {}
  for _, path in ipairs(host) do
    if seen[path] ~= true then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  local next_path = 1
  while next_path <= #out do
    local path = assert(out[next_path], "a path within the list's length is there")
    next_path = next_path + 1
    local needs = memo[search .. "\0" .. path]
    if needs == nil then
      needs = named_by(path, search)
      memo[search .. "\0" .. path] = needs
    end
    for _, need in ipairs(needs) do
      local there, _ = stat(need)
      -- Only a file by an absolute path: nothing here gives a directory.
      if need:sub(1, 1) == "/" and there ~= nil and there.kind == "file" and seen[need] ~= true then
        seen[need] = true
        out[#out + 1] = need
      end
    end
  end
  return out
end

return host_program
