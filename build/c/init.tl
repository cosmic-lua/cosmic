--- This tree's own C, checked against the review checklist's mechanical
--- items (`build.c.rules`) over the syntax tree clang prints of it
--- (`build.c.tree`). `cosmic fix` runs it over every C file it covers.
---
--- The tree comes from the pinned `bin/zig cc`, with the includes and
--- defines a core is built with, so a header resolves and a macro expands
--- the way the build sees it. They are written out here rather than read
--- from build.zig, which has no form a program can read them from; an
--- include or define this list drifts from shows up as a compile error,
--- and a compile error fails the check. It targets x86_64-linux-musl, the
--- core's first target and the one `COSMIC_TARGET_ID` names, on every
--- host, so a header is the pinned zig's own rather than the host's.
---
--- Each compiler is a process `build.filesystem_observations` knows as
--- declared: before it starts, the scripts and pins that name the one zig
--- `bin/zig` runs are read, and the environment, and after it, every
--- header its dependency file names outside that zig's own install, so a
--- test that checks C stands on what the compiler read. The compiler is
--- given only the environment `passed` names, each read here. An
--- override naming another zig or bootstrap cosmic is no declaration.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local sys = require("cosmic.sys")
local gen_syscalls = require("build.gen_syscalls")
local layout = require("build.c.layout")
local observations = require("build.filesystem_observations")
local rules = require("build.c.rules")
local tree = require("build.c.tree")
local Zig = require("build.zig")

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
--- Where the compiler looks for an included header, in its order: relative
--- to the root when the compiler runs there, so the tree's own headers are
--- named as its own (`core/guard.h`).
local function include_dirs(root: string, cwd: string): {string}
  local prefix = cwd == root and "" or root .. "/"
  local out: {string} = {}
  for _, dir in ipairs({
    "core", "vendor/lua/src", "vendor/sqlite", "vendor/miniz", "vendor/mbedtls/include",
    "vendor/bzip2", "vendor/xz/src/liblzma/api", "vendor/cares/include", "vendor/curl/include",
    "vendor/yyjson/src",
  }) do
    out[#out + 1] = prefix .. dir
  end
  for _, dir in ipairs(crypto_include_dirs) do
    out[#out + 1] = prefix .. "vendor/mbedtls/tf-psa-crypto/" .. dir
  end
  return out
end

local function command(root: string, file: string, cwd: string, depfile: string): {string}
  -- TODO: check the core for each of its targets, not the first alone:
  -- the code under `__APPLE__` (core/executable.c's, core/syscalls.c's)
  -- is checked on no host.
  local out: {string} = {
    root .. "/bin/zig", "cc", "-target", "x86_64-linux-musl", "-MD", "-MF", depfile,
    "-E", "-o", "/dev/null", "-Xclang", "-ast-dump",
    "-fno-color-diagnostics", "-std=c11", "-Wno-unused-command-line-argument",
    "-DLUA_USE_POSIX", "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
    "-DTF_PSA_CRYPTO_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DMBEDTLS_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DCOSMIC_TARGET_ID=1", "-DCOSMIC_TARGET_NAME=\"check\"",
    "-DCOSMIC_CONFIGURATION_ID=1", "-DCOSMIC_CONFIGURATION_NAME=\"check\"",
    "-DCOSMIC_PORTABLE_REQUIRED_TARGET_MASK=UINT64_C(1)",
    "-DCOSMIC_PORTABLE_RELEASE_CONFIGURATION_ID=1",
  }
  for _, dir in ipairs(include_dirs(root, cwd)) do
    out[#out + 1] = "-I" .. dir
  end
  out[#out + 1] = file
  return out
end

--- The environment a compiler is given, and all of it: what `bin/zig`,
--- `bin/cosmic-bootstrap`, the bootstrap cosmic and `build/zig.tl` read --
--- where the caches are, the overrides, and how to reach and trust a
--- download. Each is read one by one, so a key holds these and nothing
--- else of an environment that changes with every `cd`.
local passed <const> = {
  "PATH", "HOME", "XDG_CACHE_HOME", "TMPDIR",
  "COSMIC_ZIG", "COSMIC_ZIG_CACHE", "COSMIC_ZIG_GLOBAL_CACHE",
  "COSMIC_BOOTSTRAP", "COSMIC_BOOTSTRAP_ATTEMPTS", "COSMIC_BOOTSTRAP_VERIFY",
  "COSMIC_PORTABLE_CACHE",
  "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE",
  "http_proxy", "https_proxy", "no_proxy", "all_proxy",
  "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "ALL_PROXY",
}

--- The environment `passed` names, as this process has it.
local function environment(): {string:string}
  local out: {string:string} = {}
  for _, name in ipairs(passed) do
    local value = Env.get(name)
    if value ~= nil then out[name] = value end
  end
  return out
end

--- What names the one zig `bin/zig` runs, read so a key holds it: the
--- scripts and the pins. Answers the directory that zig is installed in,
--- or nil when an override names a zig or a bootstrap cosmic the pins do
--- not.
-- TODO: hash what the scripts run from the host -- `sh`, and the `sed`,
-- `wc` and `tr` `PATH` finds -- or run them from the pins too: a host
-- whose tools change keeps its verdicts.
local function toolchain(root: string): string | nil
  for _, name in ipairs({ "COSMIC_ZIG", "COSMIC_BOOTSTRAP" }) do
    local value = Env.get(name)
    if value ~= nil and value ~= "" then return nil end
  end
  for _, path in ipairs({ "bin/zig", "bin/cosmic-bootstrap", "bin/zig.pin", "build/zig.tl",
                          "ci/cosmic-driver.pin" }) do
    local _, _ = Fs.read(root .. "/" .. path)
  end
  local cache, _ = Fs.cache_path("zig")
  if cache == nil then return nil end
  local install, _ = Zig.pinned_install(root, cache)
  return install ~= nil and install.path or nil
end

--- The paths a dependency file names, its target's aside, with clang's
--- escapes undone: `\ ` a space, `\#` a `#`, `$$` a `$`, and a
--- backslash ending a line a continuation.
local function dependency_paths(text: string): {string}
  local out: {string} = {}
  local word: {string} = {}
  local function finish()
    if #word > 0 then out[#out + 1] = table.concat(word) end
    word = {}
  end
  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    local after = text:sub(i + 1, i + 1)
    if ch == "\\" and (after == " " or after == "#") then
      word[#word + 1] = after
      i = i + 2
    elseif ch == "\\" and after == "\n" then
      finish()
      i = i + 2
    elseif ch == "$" and after == "$" then
      word[#word + 1] = "$"
      i = i + 2
    elseif ch == " " or ch == "\t" or ch == "\n" or ch == "\r" then
      finish()
      i = i + 1
    else
      word[#word + 1] = ch
      i = i + 1
    end
  end
  finish()
  table.remove(out, 1)
  return out
end

--- Lists `dir` once in a check, but under `install`: a listing is how a
--- header that is not there, which the compiler looked for and passed
--- over, enters a key -- one added there later would be found first.
--- With `below`, every directory under it is listed too: an include
--- spelled with a directory (`mbedtls/md.h`) is looked for in each such
--- directory of each include directory, whose own listing does not change
--- when a file is added inside one.
local function list_once(dir: string, install: string | nil, listed: {string: boolean},
                         below?: boolean)
  if listed[dir] or (install ~= nil and Fs.within(dir, install)) then return end
  listed[dir] = true
  local entries, _ = sys.readdir(dir)
  if entries == nil or not below then return end
  for name, kind in pairs(entries) do
    local path = dir .. "/" .. name
    -- The compiler looks through a link to a directory as through the
    -- directory, so a listing follows one too.
    local followed = kind
    if kind == "link" then
      local st, _ = sys.stat(path)
      followed = st ~= nil and st.kind or "other"
    end
    if followed == "dir" then
      list_once(path, install, listed, true)
    end
  end
end

--- Reads every file a compiler's dependency file names, but those under
--- `install` (the pinned zig's own), so they are observed as read, and
--- lists the directory each is in. Whether there was a dependency file to
--- go by: a compiler that failed wrote none, and what it looked for is
--- not known.
local function read_dependencies(depfile: string, cwd: string, install: string | nil,
                                 listed: {string: boolean}): boolean
  local text, _ = Fs.read(depfile)
  if text == nil then return false end
  for _, path in ipairs(dependency_paths(text)) do
    if path:sub(1, 1) ~= "/" then path = cwd .. "/" .. path end
    if install == nil or not Fs.within(path, install) then
      local _, _ = Fs.read(path)
      list_once(Fs.dirname(path), install, listed)
    end
  end
  return true
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

--- What the binding headers under `root` (core/syscalls.h and
--- core/process.h) declare each binding returns; a header that is not
--- there declares nothing.
local function declared_in(root: string): {string: rules.Declared}
  local out: {string: rules.Declared} = {}
  for _, derivation in ipairs(gen_syscalls.targets) do
    local header, _ = Fs.read(root .. "/" .. derivation.target.header)
    local found: gen_syscalls.Declarations | nil = nil
    if header ~= nil then
      local read, _ = gen_syscalls.read(header)
      found = read
    end
    for _, call in ipairs(found ~= nil and found.calls or {}) do
      out[call.name] = { count = #call.results, fallible = #call.results == 3,
                         effect = #call.results > 0 and call.results[1].kind == "boolean" }
    end
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
  -- A tree that cannot be walked is not known to be whole: sharing goes
  -- unjudged, and every file named is still checked on its own.
  local all, _ = c.sources(cwd)
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
  local install = toolchain(root)
  local env = environment()
  local deps, deps_trouble = Fs.mkdtemp("cosmic-c-deps-")
  if deps == nil then
    for i, file in ipairs(files) do
      outcomes[i] = { file = file, trouble = "no directory for its dependency file: " .. deps_trouble }
    end
    return outcomes
  end
  -- Every directory a header could be found in, listed so one added
  -- where the compiler looked and found nothing enters the key.
  local listed: {string: boolean} = {}
  local function absolute(path: string): string
    return path:sub(1, 1) == "/" and path or cwd .. "/" .. path
  end
  for _, dir in ipairs(include_dirs(root, cwd)) do
    list_once(absolute(dir), install, listed, true)
  end
  for _, file in ipairs(files) do list_once(Fs.dirname(absolute(file)), install, listed) end
  local function depfile(i: integer): string return deps .. "/" .. tostring(i) .. ".d" end
  local function compile(): boolean
    local held = true
    while next_file <= #files or #running > 0 do
      while next_file <= #files and #running < parallel do
        local handle, trouble = Child.start(command(root, files[next_file], cwd,
          depfile(next_file)), {
          cwd = cwd, env = env, stdout = "capture", stderr = "capture",
          capture_limit = limit or dump_limit,
        })
        if handle == nil then
          outcomes[next_file] = { file = files[next_file], trouble = trouble }
          held = false
        else
          running[#running + 1] = handle
          which[handle] = next_file
        end
        next_file = next_file + 1
      end
      if #running > 0 then
        local done, trouble = Child.wait_any(running, 120000)
        if done == nil then
          if trouble == "" then trouble = "clang gave no answer in 120 seconds" end
          held = false
          for _, handle in ipairs(running) do
            local _, _ = handle:close()
            outcomes[which[handle]] = { file = files[which[handle]], trouble = trouble }
          end
          running = {}
        else
          local result, wait_trouble = done:wait()
          held = read_dependencies(depfile(which[done]), cwd, install, listed) and held
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
    return held
  end
  local compiled, trouble = pcall(function(): string
    if install ~= nil then
      observations.declared("bin/zig cc", compile)
    else
      local _ = compile()
    end
    return ""
  end)
  local _, _ = Fs.remove_tree(deps)
  if not compiled then error(trouble, 0) end
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
