--- Bootstrap-portable file writing for the build tooling.
---
--- _build's fetch/stage pipeline runs under the pinned BOOTSTRAP cosmic
--- binary (an older runtime) while the modules it requires are compiled
--- from the current tree, which targets the current cosmos pin. Anything
--- on this path must therefore survive BOTH runtimes. `cosmo.Barf`'s third
--- argument changed from a positional mode to an options table across the
--- 2026.07 error-convention release, which made `cosmic.io.barf` (now `cosmic.fs.write`) crash the
--- fetch step under the old bootstrap; writing through signature-stable
--- `cosmo.unix` primitives instead keeps the pipeline working no matter
--- which side of a binding change the hosting binary is on. Errors are
--- stringified with tostring, which renders both the old `unix.Errno`
--- userdata and the new error strings.
local unix = require("cosmo.unix")

--- Write data to a file (create or truncate), bootstrap-portably.
--- @param path string destination path
--- @param data string bytes to write
--- @param mode integer? file mode for a newly created file (default 0644)
--- @return boolean success
--- @return string? error
local function write_file(path: string, data: string, mode?: integer): boolean, string
  local fd, oerr = unix.open(path, unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC,
    mode or tonumber("644", 8))
  if not fd then
    return false, "open " .. path .. ": " .. tostring(oerr)
  end
  local off: integer = 1
  while off <= #data do
    local n, werr = unix.write(fd, string.sub(data, off))
    if not n or n <= 0 then
      unix.close(fd)
      return false, "write " .. path .. ": " .. tostring(werr)
    end
    off = off + math.tointeger(n)
  end
  unix.close(fd)
  return true
end

return {
  write_file = write_file,
}
