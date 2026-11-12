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
--- process that keys the tests, not in a worker. A program that is no ELF
--- file of this machine's word size and byte order names nothing.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local Proc = require("cosmic.proc")
local sys = require("cosmic.sys")

local run, read, find, stat = Child.run, Fs.read, Proc.find, sys.stat

local record host_program
end

--- The most a `#!` line is read to, as the kernel reads it.
local SHEBANG_MAX <const> = 256

--- The loader a dynamic ELF file `data` names (its PT_INTERP segment), or
--- nil for a static one, a file that is no 64-bit little-endian ELF, or
--- one cut short.
local function loader_of(data: string): string?
  if #data < 64 or data:sub(1, 4) ~= "\127ELF" or data:byte(5) ~= 2 or data:byte(6) ~= 1 then
    return nil
  end
  local phoff = string.unpack("<I8", data, 33)
  local phentsize, phnum = string.unpack("<I2I2", data, 55)
  for i = 0, phnum - 1 do
    local at = phoff + i * phentsize + 1
    if at + 56 - 1 > #data then return nil end
    local kind = string.unpack("<I4", data, at)
    if kind == 3 then
      local offset, _, _, filesz = string.unpack("<I8I8I8I8", data, at + 8)
      if offset + filesz > #data or filesz < 2 then return nil end
      -- The segment ends with a NUL the name does not hold.
      return data:sub(offset + 1, offset + filesz - 1)
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
  local data, _ = read(path)
  if data == nil then return out end
  local line = data:sub(1, SHEBANG_MAX):match("^#![ \t]*([^\n]*)")
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
  local loader = loader_of(data)
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
      if seen[need] ~= true then
        seen[need] = true
        out[#out + 1] = need
      end
    end
  end
  return out
end

return host_program
