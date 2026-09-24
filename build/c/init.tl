--- This tree's own C, checked against the review checklist's mechanical
--- items (`build.c.rules`) over the syntax tree clang prints of it
--- (`build.c.tree`). `cosmic fix` runs it over every C file it covers.
---
--- The tree comes from the pinned `bin/zig cc`, with the includes and
--- defines a core is built with, so a header resolves and a macro expands
--- the way the build sees it. They are written out here rather than read
--- from build.zig, which has no form a program can read them from; an
--- include or define this list drifts from shows up as a compile error,
--- and a compile error fails the check.

local Child = require("cosmic.child")
local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local gen_syscalls = require("build.gen_syscalls")
local layout = require("build.c.layout")
local rules = require("build.c.rules")
local tree = require("build.c.tree")

local record c
  --- What checking one file came to: its findings, or why it could not
  --- be checked.
  record Outcome
    file: string
    findings: {rules.Finding}
    trouble: string
  end
end

--- How many compilers run at once.
local parallel <const> = 8

--- How much of a dump is kept: curl's type-checking macros make
--- core/http.c's more than twice Child's default of 16 MiB, and a dump
--- that lost its beginning would be checked only from where it resumes.
local dump_limit <const> = 256 * 1024 * 1024

local crypto_include_dirs: {string} = {
  "include", "core", "drivers/builtin/include", "drivers/builtin/src",
  "dispatch", "utilities", "platform", "extras",
}

--- The compiler's command line for `file`. Includes are relative to the
--- root when the compiler runs there, so the tree's own headers are named
--- as its own (`core/guard.h`) and checked with the file.
local function command(root: string, file: string, cwd: string): {string}
  local prefix = cwd == root and "" or root .. "/"
  local out: {string} = {
    root .. "/bin/zig", "cc", "-E", "-o", "/dev/null", "-Xclang", "-ast-dump",
    "-fno-color-diagnostics", "-std=c11", "-Wno-unused-command-line-argument",
    "-DLUA_USE_POSIX", "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
    "-DTF_PSA_CRYPTO_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DMBEDTLS_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DCOSMIC_TARGET_ID=1", "-DCOSMIC_TARGET_NAME=\"check\"",
    "-DCOSMIC_CONFIGURATION_ID=1", "-DCOSMIC_CONFIGURATION_NAME=\"check\"",
    "-DCOSMIC_PORTABLE_REQUIRED_TARGET_MASK=UINT64_C(1)",
    "-DCOSMIC_PORTABLE_RELEASE_CONFIGURATION_ID=1",
  }
  for _, dir in ipairs({
    "core", "vendor/lua/src", "vendor/sqlite", "vendor/miniz", "vendor/mbedtls/include",
    "vendor/bzip2", "vendor/xz/src/liblzma/api", "vendor/cares/include", "vendor/curl/include",
    "vendor/yyjson/src",
  }) do
    out[#out + 1] = "-I" .. prefix .. dir
  end
  for _, dir in ipairs(crypto_include_dirs) do
    out[#out + 1] = "-I" .. prefix .. "vendor/mbedtls/tf-psa-crypto/" .. dir
  end
  out[#out + 1] = file
  return out
end

--- What is never C of this tree's own to check: the build's output, the
--- upstream sources and the records that patch them, and anything hidden.
local function skip(entry: string): boolean
  local first = entry:match("^([^/]+)") or entry
  if first == "o" or first == "vendor" or first == "patch" or first == "bin" then
    return true
  end
  return Fs.basename(entry):sub(1, 1) == "."
end

--- Every C file under `dir`, `.c` and `.h`, relative to it and sorted.
function c.sources(dir: string): {string} | nil, string
  local files, trouble = Fs.walk(dir, skip)
  if files == nil then return nil, trouble end
  local out: {string} = {}
  for _, file in ipairs(files) do
    if String.ends_with(file, ".c") or String.ends_with(file, ".h") then out[#out + 1] = file end
  end
  table.sort(out)
  return out
end

--- What core/syscalls.h under `root` declares each binding returns, or
--- nothing when there is no such header to read.
local function declared_in(root: string): {string: rules.Declared}
  local out: {string: rules.Declared} = {}
  local header, _ = Fs.read(root .. "/core/syscalls.h")
  if header == nil then return out end
  local found, _ = gen_syscalls.read(header)
  if found == nil then return out end
  for _, call in ipairs(found.calls) do
    out[call.name] = { count = #call.results, fallible = #call.results == 3,
                       effect = #call.results > 0 and call.results[1].kind == "boolean" }
  end
  return out
end

--- What checking `file` came to, and what it defines and refers to.
local function outcome(root: string, file: string, result: Child.Result, trouble: string,
                       declared: {string: rules.Declared}, limit: integer):
    c.Outcome, rules.Unit
  if result == nil then
    return { file = file, trouble = trouble }
  end
  if not result.ok then
    local err = tostring(result.stderr or "")
    return { file = file, trouble = "clang could not read it:\n" .. (err:gsub("\n+$", "")) }
  end
  if result.truncated then
    return { file = file, trouble = "its syntax tree is larger than " .. limit ..
      " bytes, the most that is read of one" }
  end
  local decls = tree.parse(tostring(result.stdout or ""), root)
  return { file = file, findings = rules.check(decls, file, declared) },
    rules.unit(decls, file, declared)
end

--- Whether `files` are every C file under `cwd` that compiles on its
--- own: only then is what refers to a function across files all known.
local function whole(cwd: string, files: {string}): boolean
  local all = c.sources(cwd)
  if all == nil then return false end
  local named: {string: boolean} = {}
  for _, file in ipairs(files) do
    while file:sub(1, 2) == "./" do file = file:sub(3) end
    named[file] = true
  end
  for _, file in ipairs(all) do
    if String.ends_with(file, ".c") and not named[file] then return false end
  end
  return true
end

--- Checks every one of `files`, paths relative to `cwd` (by default
--- `root`, cosmic's own tree), a few compilers at a time. The outcomes
--- come back in the order of `files`. A header two of them include is
--- checked with each, and what is found in it is reported once. When
--- `files` are every C file under `cwd`, a function no file but its own
--- refers to ("single-file") is found too, with the file defining it,
--- as long as every one of them could be read. `limit` is the most bytes
--- of one file's syntax tree that are read, by default `dump_limit`; a
--- file whose tree is larger is refused rather than half checked.
function c.check(root: string, files: {string}, cwd?: string, limit?: integer):
    {c.Outcome}
  cwd = cwd or root
  local declared = declared_in(root)
  local outcomes: {c.Outcome} = {}
  local units: {integer: rules.Unit} = {}
  local running: {Child.Handle} = {}
  local which: {Child.Handle: integer} = {}
  local next_file = 1
  while next_file <= #files or #running > 0 do
    while next_file <= #files and #running < parallel do
      local handle, trouble = Child.start(command(root, files[next_file], cwd), {
        cwd = cwd, stdout = "capture", stderr = "capture", capture_limit = limit or dump_limit,
      })
      if handle == nil then
        outcomes[next_file] = { file = files[next_file], trouble = trouble }
      else
        running[#running + 1] = handle
        which[handle] = next_file
      end
      next_file = next_file + 1
    end
    if #running > 0 then
      local done, trouble = Child.wait_any(running, 120000)
      if done == nil then
        for _, handle in ipairs(running) do
          local _, _ = handle:close()
          outcomes[which[handle]] = { file = files[which[handle]], trouble = trouble }
        end
        running = {}
      else
        local result, wait_trouble = done:wait()
        outcomes[which[done]], units[which[done]] = outcome(root, files[which[done]], result,
          wait_trouble, declared, limit or dump_limit)
        local still: {Child.Handle} = {}
        for _, handle in ipairs(running) do
          if handle ~= done then still[#still + 1] = handle end
        end
        running = still
      end
    end
  end
  if whole(cwd, files) then
    local every: {rules.Unit} = {}
    local by_file: {string: c.Outcome} = {}
    for i = 1, #files do
      if units[i] ~= nil then every[#every + 1] = units[i] end
      by_file[outcomes[i].file] = outcomes[i]
    end
    -- A file that could not be read refers to what is not known: its
    -- own trouble is the finding, rather than guesses about the rest.
    local known = #every == #files
    for _, f in ipairs(known and rules.single_file(every) or {}) do
      for _, u in ipairs(every) do
        local o = by_file[u.file]
        if u.defines[f.within] ~= nil and o.findings ~= nil then
          o.findings[#o.findings + 1] = f
        end
      end
    end
  end
  local seen: {string: boolean} = {}
  for _, o in ipairs(outcomes) do
    if o.findings ~= nil then
      local kept: {rules.Finding} = {}
      for _, f in ipairs(o.findings) do
        local key = f.file .. ":" .. f.line .. ":" .. f.rule
        if not seen[key] then
          seen[key] = true
          kept[#kept + 1] = f
        end
      end
      o.findings = kept
    end
  end
  return outcomes
end

--- `source`, a C file, in the layout `build.c.layout` holds; or nil and
--- why, when laying it out would change more than whitespace.
function c.laid_out(source: string): string | nil, string
  return layout.rendered(source)
end

return c
