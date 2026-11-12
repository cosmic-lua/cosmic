--- This tree's own C, checked against the review checklist's mechanical
--- items ([`build.c.rules`]) over the syntax tree clang prints of it
--- ([`build.c.tree`]). `cosmic fix` runs it over every C file it covers.
---
--- The tree comes from the pinned zig's `cc`, with the includes and
--- defines a core is built with, so a header resolves and a macro expands
--- the way the build sees it. They are written out here rather than read
--- from build.zig, which has no form a program can read them from; an
--- include or define this list drifts from shows up as a compile error,
--- and a compile error fails the check. It targets x86_64-linux-musl, the
--- core's first target and the one `COSMIC_TARGET_ID` names, on every
--- host, so a header is the pinned zig's own rather than the host's.
---
--- The code a preprocessor branch keeps differs with the target and the
--- configuration, so a file is also dumped under each of the other
--- `variants` -- the core's other targets, and the checked core's
--- defines -- when it can differ: when its text, or the text of a header
--- of the tree it includes, names a macro that tells them apart
--- ([`sensitive`]). A finding says which variants reported it.
---
--- A compile starts the pinned zig itself where it is installed
--- (`compiler`), and [`bin/zig`], which fetches it, where it is not.
--- Each compiler starts under build.confine's `declaring`, given what it
--- runs from and what it compiles, plus the system's paths:
---
--- - only where [`bin/zig`] runs the compile, the scripts and pins that
---   name the one zig it runs, and the bootstrap cosmic that runs
---   build/zig.tl;
--- - that zig's own install, its library unpatched: patch/zig-lib/'s
---   records touch only `zig build`;
--- - the include directories and each file's own;
--- - a directory of the check's own for caches (the cores the bootstrap
---   cosmic's launcher extracts among them, [`c.own_caches`]) and
---   dependency files.
---
--- In a test's sandboxed worker, the sandbox every process it starts
--- inherits holds the compiler, as the test's [`Test.policy`] declares. In
--- an unsandboxed worker the compiler gets a root of its own holding
--- those paths alone, where the kernel gives one. Where the kernel gives
--- none, it runs unconfined. Either way its test's verdict stands on
--- what the test declared.
---
--- The compiler is given only the environment `passed` names. An
--- override naming another zig or bootstrap cosmic declares nothing:
--- its compilers start as any process a test starts does.

local Child = require("cosmic.child")
local Env = require("cosmic.env")
local Fs = require("cosmic.fs")
local Poll = require("cosmic.poll")
local String = require("cosmic.string")
local gen_syscalls = require("build.gen_syscalls")
local confine = require("build.confine")
local layout = require("build.c.layout")
local link_files = require("build.link_files")
local rules = require("build.c.rules")
local tree = require("build.c.tree")
local Zig = require("build.zig")
local plural = require("build.plural")
local Clock = require("cosmic.clock")
local Sqlite = require("cosmic.sqlite")
local check_memo = require("build.check_memo")
local inputs = require("build.c.inputs")

local record c
  --- What checking one file came to: its findings, or why it could not
  --- be checked.
  record Outcome
    file: string
    mut findings?: mut {rules.Finding}
    mut trouble?: string
    --- The names of the variants it was checked under, in order.
    variants?: mut {string}
  end

  --- One way the core is built, as far as its C can tell: the compiler's
  --- target and the defines the build gives it.
  record Variant
    name: string
    target: string
    defines: {string}
    --- The macros whose appearance in a file's tree lets it differ from the first variant's.
    tells: {string}
  end

  --- One compile: the file, by index, and the variant, by index.
  record Job
    file: integer
    variant: integer
  end

  mut variants: {c.Variant}
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

--- Where the compiler looks for an included header, in its order. The
--- paths are relative to the root when the compiler runs there, so the
--- tree's own headers are named as its own ([`core/guard.h`]).
local function include_dirs(root: string, cwd: string): {string}
  local prefix = if cwd == root then "" else root .. "/" end
  local out: mut {string} = {}
  for _, dir in ipairs({
      "core", "vendor/lua/src", "vendor/sqlite", "vendor/miniz", "vendor/mbedtls/include",
      "vendor/bzip2", "vendor/xz/src/liblzma/api", "vendor/cares/include", "vendor/curl/include",
      "vendor/yyjson/src", "vendor/zstd/lib", "vendor/expat/lib",
  }) do
    out[#out + 1] = prefix .. dir
  end
  for _, dir in ipairs(crypto_include_dirs) do
    out[#out + 1] = prefix .. "vendor/mbedtls/tf-psa-crypto/" .. dir
  end
  return out
end

--- The macros that tell a target from the first (the compiler's own, and
--- the id and name the build defines), and the checked core from a
--- release one: a file whose tree names none of them cannot differ.
local target_tells <const>: {string} = {
  "__APPLE__", "__MACH__", "__linux__", "__aarch64__", "__arm64__", "__x86_64__",
  "__amd64__", "__NR_", "COSMIC_TARGET",
}
local checked_tells <const>: {string} = {
  "COSMIC_CHECKED", "COSMIC_CONFIGURATION", "LUAI_ASSERT", "LUA_USE_APICHECK",
}

--- The defines the checked core adds to its own C (build.zig's
--- `checked_flags`, `lua_checks`).
local checked_defines <const>: {string} = {
  "-DCOSMIC_TARGET_ID=1", "-DCOSMIC_TARGET_NAME=\"x86_64-linux-musl\"",
  "-DCOSMIC_CHECKED", "-DLUAI_ASSERT", "-DLUA_USE_APICHECK",
  "-DCOSMIC_CONFIGURATION_ID=2", "-DCOSMIC_CONFIGURATION_NAME=\"sanitized\"",
}

--- The ways the core is built whose C can differ, as build.zig's
--- `targets` and `sanitized_configuration` have them, written out here
--- like the includes (build/c/variants_test.tl holds them to build.zig's).
--- The first is what every file is dumped under; the others only when
--- [`sensitive`] says its tree can differ. The checked core is built for
--- the host's target, which is any of the three; it is checked on the
--- first, whose branches the other targets' checked cores share but for
--- what the target variants already show.
c.variants = {
  { name = "x86_64-linux-musl", target = "x86_64-linux-musl", defines = {
    "-DCOSMIC_TARGET_ID=1", "-DCOSMIC_TARGET_NAME=\"x86_64-linux-musl\"",
    "-DCOSMIC_CONFIGURATION_ID=1", "-DCOSMIC_CONFIGURATION_NAME=\"release\"" },
    tells = target_tells },
  { name = "aarch64-linux-musl", target = "aarch64-linux-musl", defines = {
    "-DCOSMIC_TARGET_ID=2", "-DCOSMIC_TARGET_NAME=\"aarch64-linux-musl\"",
    "-DCOSMIC_CONFIGURATION_ID=1", "-DCOSMIC_CONFIGURATION_NAME=\"release\"" },
    tells = target_tells },
  { name = "aarch64-macos", target = "aarch64-macos", defines = {
    "-DCOSMIC_TARGET_ID=3", "-DCOSMIC_TARGET_NAME=\"aarch64-macos\"",
    "-DCOSMIC_CONFIGURATION_ID=1", "-DCOSMIC_CONFIGURATION_NAME=\"release\"" },
    tells = target_tells },
  { name = "x86_64-linux-musl checked", target = "x86_64-linux-musl", defines = checked_defines, tells = checked_tells },
}

--- The compiler's command line for `file` under `variant`, `zig` the
--- program that runs it ([`compiler`]).
local function command(root: string, zig: string, file: string, cwd: string, variant: c.Variant): {string}
  local out: mut {string} = {
    zig, "cc", "-target", variant.target,
    "-E", "-o", "/dev/null", "-Xclang", "-ast-dump",
    "-fno-color-diagnostics", "-std=c11", "-Wno-unused-command-line-argument",
    "-DLUA_USE_POSIX", "-DMINIZ_NO_ZLIB_COMPATIBLE_NAMES",
    "-DTF_PSA_CRYPTO_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DMBEDTLS_CONFIG_FILE=\"mbedtls_cosmic_config.h\"",
    "-DCOSMIC_PORTABLE_REQUIRED_TARGET_MASK=UINT64_C(1)",
    "-DCOSMIC_PORTABLE_RELEASE_CONFIGURATION_ID=1",
  }
  for _, define in ipairs(variant.defines) do out[#out + 1] = define end
  for _, dir in ipairs(include_dirs(root, cwd)) do
    out[#out + 1] = "-I" .. dir
  end
  out[#out + 1] = file
  return out
end

--- The environment a compiler is given, and all of it: what [`bin/zig`],
--- [`bin/cosmic-bootstrap`], the bootstrap cosmic and [`build/zig.tl`] read --
--- where the caches are, the overrides, and how to reach and trust a
--- download, and nothing else of an environment that changes with
--- every `cd`.
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
  local out: mut {string:string} = {}
  for _, name in ipairs(passed) do
    local value = Env.get(name)
    if value ~= nil then out[name] = value end
  end
  return out
end

--- Where a standalone run keeps the compiles it checked
--- ([`build.standalone`]), which bin/zig's run of build/zig.tl reads and
--- writes, as [`Fs.cache_dir`] vouches for it, or nil where it vouches for
--- none. Withheld, every compile runs build/zig.tl checked afresh: about
--- 0.8 s on the release ci/cosmic-driver.pin names, so a check of a few
--- files under each variant took seconds more than its compiles.
local function standalone_compiles(variables: {string:string}): string?
  local dir, _ = Fs.cache_dir("standalone", { environment = variables })
  return dir
end

--- The bootstrap cosmic whose sha256 is `digest` (the pin's third line), where `variables` caches it
--- ([`bin/cosmic-bootstrap`]'s `cosmic-<sha256>`), fetched first where it is not cached yet (a cleared cache, a new
--- pin): a confined compiler, given the cache to read and no network, could not fetch it, and every check would fail
--- with the fetch's error. The fetch is bin/cosmic-bootstrap's own (`--raw-path`), run unconfined with `variables`;
--- bin/cosmic has run it already wherever it started the check, so this is a run that did not. Answers its path, or nil
--- and why where it is not there after.
function c.bootstrap_cosmic(root: string, variables: {string:string}, digest: string): string?, string
  local function cached(): string?
    local dir, _ = Fs.cache_dir("bootstrap", { environment = variables, make = false })
    if dir == nil then return nil end
    local path = dir .. "/cosmic-" .. digest
    local st, _ = Fs.stat(path)
    if st == nil then return nil end
    return path
  end
  local found = cached()
  if found ~= nil then return found, "" end
  local result, trouble = Child.run({ root .. "/bin/cosmic-bootstrap", "--raw-path" }, {
    env = variables, stdout = "capture", stderr = "capture", timeout_ns = Clock.seconds(600),
  })
  found = cached()
  if found ~= nil then return found, "" end
  local said = trouble
  if result ~= nil then said = ((result.stderr or ""):gsub("%s+$", "")) end
  local why = "the bootstrap cosmic ci/cosmic-driver.pin names is not cached, and bin/cosmic-bootstrap could not fetch it"
  if said ~= "" then why = why .. ": " .. said end
  return nil, why
end

--- What a compiler runs from, where [`bin/zig`] finds it by the pins: the
--- pinned zig's install, where `variables` locates it, the directory it is
--- installed in and the list of what outside the tree the compiler runs
--- from; and the sha256 of the bootstrap cosmic [`bin/cosmic-bootstrap`] runs
--- build/zig.tl on (the pin's third line), which it runs from too once
--- [`c.bootstrap_cosmic`] has it, or nil where the pin names none. The cores
--- its launcher extracts are the check's own ([`c.own_caches`]). Nil and an
--- empty list where an override names a zig or a bootstrap cosmic the pins
--- do not.
---
--- Where [`bin/zig`] runs the compile (`compiler`), the host programs the
--- scripts run (`sh`, the `dirname`, `sed`, `wc`
--- and `tr` that `PATH` finds, and the launcher's `uname` and `stat`)
--- come only from the sandbox: the system's paths, the tree's and the
--- test's own. A test's sandboxed worker is given the system's paths only
--- where its module declares `system`, and its key holds what they hold,
--- walked ([`declared_key.system_identity`]). A compiler confined in an
--- unsandboxed worker is given them as every confined process is. A
--- `PATH` directory outside those is not there for it.
local function toolchain(root: string, variables: {string:string}, direct: boolean):
    string?, mut {string}, string?
  -- A compile that starts the pinned zig itself runs no bootstrap cosmic,
  -- so one named in its place changes nothing of it.
  for _, name in ipairs(if direct then { "COSMIC_ZIG" } else { "COSMIC_ZIG", "COSMIC_BOOTSTRAP" } end) do
    local value = variables[name]
    if value ~= nil and value ~= "" then return nil, {}, nil end
  end
  local pin, _ = Fs.read(root .. "/ci/cosmic-driver.pin")
  local cache, _ = Fs.cache_dir("zig", { environment = variables, make = false })
  if cache == nil then return nil, {}, nil end
  local install, _ = Zig.pinned_install(root, cache)
  if install == nil then return nil, {}, nil end
  local digest = (pin or ""):match("^[^\n]*\n[^\n]*\n(%x+)")
  return install.path, { install.path }, digest
end

--- The program a compile starts, and whether it is zig itself: the zig
--- COSMIC_ZIG names in `variables`, else the pinned zig where `variables`
--- locates its install and it is there. A compile then starts no script,
--- no bootstrap cosmic and no program of the host's: the `sh`, `sed`,
--- `dirname`, `sha256sum` and the rest that [`bin/zig`], the script it
--- hands to and a launcher start before zig do not run. Where the pinned
--- zig is not installed yet it is [`bin/zig`], which fetches it.
local function compiler(root: string, variables: {string:string}): string, boolean
  local named = variables["COSMIC_ZIG"]
  if named ~= nil and named ~= "" then return named, true end
  local cache, _ = Fs.cache_dir("zig", { environment = variables, make = false })
  local install: Zig.Install? = nil
  if cache ~= nil then install, _ = Zig.pinned_install(root, cache) end
  if install ~= nil then
    local zig = install.path .. "/zig"
    local there, _ = Fs.exists(zig)
    if there == true then return zig, true end
  end
  return root .. "/bin/zig", false
end

--- `env`, a compiler's environment, with every cache it writes in `deps`, the check's own directory, which its
--- confinement lets it write. zig's: `-E` keeps nothing a later compile finds there, and a cache shared with every build
--- is no path to give a confined compiler. And the cores the bootstrap cosmic's launcher extracts (COSMIC_PORTABLE_CACHE),
--- as a sandboxed worker is given cores of its own (build/test_sandbox.tl's `own_cores`): the host's, which a compiler
--- confined in an unsandboxed worker could only read, fail every such check where they hold no core for the bootstrap
--- cosmic yet (a fresh or cleared cache, a new pin: the launcher cannot create its staging entry), and a core another
--- program extracted there would be run in its place. A check that compiles extracts the core afresh, a copy and a hash
--- of it; one the memo answers starts no launcher.
function c.own_caches(env: {string:string}, deps: string): {string:string}
  local out: mut {string:string} = {}
  for name, value in pairs(env) do out[name] = value end
  out["COSMIC_ZIG_CACHE"] = deps .. "/zig-project"
  out["COSMIC_ZIG_GLOBAL_CACHE"] = deps .. "/zig-global"
  -- What zig itself reads, as [`bin/zig`] names them to it
  -- ([`Zig.passthrough_environment`]), for a compile that starts zig
  -- without it ([`compiler`]).
  out["ZIG_LOCAL_CACHE_DIR"] = deps .. "/zig-project"
  out["ZIG_GLOBAL_CACHE_DIR"] = deps .. "/zig-global"
  out["COSMIC_PORTABLE_CACHE"] = deps .. "/cores"
  return out
end

--- Every C file under `dir`, `.c` and `.h`, relative to it and sorted:
--- what a walk for links finds of cosmic's own C ([`link_files.checked`]).
function c.sources(dir: string): {string}?, string
  local files, trouble = link_files.walk(dir)
  if files == nil then return nil, trouble end
  local out: mut {string} = {}
  for _, file in ipairs(files) do
    if link_files.checked(file, true) == "c" then out[#out + 1] = file end
  end
  return out, ""
end

--- What the binding headers under `root` (core/syscalls.h and
--- core/process.h) declare each binding returns; a header that is not
--- there declares nothing.
local function declared_in(root: string): {string: rules.Declared}
  local out: mut {string: rules.Declared} = {}
  for _, derivation in ipairs(gen_syscalls.targets) do
    local header, _ = Fs.read(root .. "/" .. derivation.target.header)
    local found: gen_syscalls.Declarations? = nil -- declared: member_missing
    if header ~= nil then
      local read, _ = gen_syscalls.read(header)
      found = read
    end
    for _, call in ipairs(found ~= nil and found.calls or {}) do -- checked: literal_needs_type
      local descriptors: mut {integer} = {}
      for i, parameter in ipairs(call.parameters) do
        if gen_syscalls.descriptor(parameter) then
          descriptors[#descriptors + 1] = i
        end
      end
      out[call.name] = { count = #call.results, fallible = #call.results == 3,
        effect = #call.results > 0 and call.results[1].kind == "boolean",
        descriptors = descriptors }
    end
  end
  return out
end

--- What a memo keeps of a compile's outcome: the findings, and what the unit defines and refers to.
local function encoded(findings: {rules.Finding}, unit: rules.Unit): string
  local rows: mut {{string}} = {}
  for _, f in ipairs(findings) do
    rows[#rows + 1] = { "F", f.file, tostring(f.line), f.rule, f.within, f.message }
  end
  local names: mut {string} = {}
  for name in pairs(unit.defines) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean return a < b end)
  for _, name in ipairs(names) do
    local place = unit.defines[name] or { file = "", line = 0 }
    rows[#rows + 1] = { "D", name, place.file, tostring(place.line) }
  end
  local referred: mut {string} = {}
  for name in pairs(unit.refers) do referred[#referred + 1] = name end
  table.sort(referred, function(a: string, b: string): boolean return a < b end)
  for _, name in ipairs(referred) do
    rows[#rows + 1] = { "R", name }
  end
  return check_memo.encode(rows)
end

--- Field `i` of a row a memo kept.
local function field(fields: {string}, i: integer): string
  return fields[i] or ""
end

--- The findings and unit of `file` that `text` encodes ([`encoded`]), or nil where it does not read.
local function decoded(file: string, text: string): mut {rules.Finding}?, rules.Unit?
  local findings: mut {rules.Finding} = {}
  local unit: rules.Unit = { file = file, defines = {}, refers = {} }
  for _, fields in ipairs(check_memo.decode(text)) do
    local kind = fields[1]
    if kind == "F" and #fields == 6 and math.tointeger(tonumber(field(fields, 3))) ~= nil then
      findings[#findings + 1] = { file = field(fields, 2), line = math.tointeger(tonumber(field(fields, 3))) or 0,
        rule = field(fields, 4), within = field(fields, 5), message = field(fields, 6) }
    elseif kind == "D" and #fields == 4 and math.tointeger(tonumber(field(fields, 4))) ~= nil then
      unit.defines[field(fields, 2)] = { file = field(fields, 3), line = math.tointeger(tonumber(field(fields, 4))) or 0 }
    elseif kind == "R" and #fields == 2 then
      unit.refers[field(fields, 2)] = true
    else
      return nil, nil
    end
  end
  return findings, unit
end

--- What `declared` says as text, in an order that does not change: a part of what a compile's outcome is made of.
local function declared_text(declared: {string: rules.Declared}): string
  local names: mut {string} = {}
  for name in pairs(declared) do names[#names + 1] = name end
  table.sort(names, function(a: string, b: string): boolean return a < b end)
  local parts: mut {string} = {}
  for _, name in ipairs(names) do
    local d = declared[name] or { count = 0, fallible = false, effect = false, descriptors = {} }
    local at: mut {string} = {}
    for _, position in ipairs(d.descriptors) do at[#at + 1] = tostring(position) end
    parts[#parts + 1] = name .. " " .. tostring(d.count) .. " " .. tostring(d.fallible) .. " " .. tostring(d.effect) ..
      " " .. table.concat(at, ",")
  end
  return table.concat(parts, "\n")
end

--- What checking `file` came to, and what it defines and refers to.
local function outcome(root: string, file: string, result: Child.Result?, trouble: string,
                       declared: {string: rules.Declared}, limit: integer):
    c.Outcome, rules.Unit?
  if result == nil then
    return { file = file, trouble = trouble }, nil
  end
  if not result.ok then
    local err = tostring(result.stderr or "")
    return { file = file, trouble = "clang could not read it:\n" .. (err:gsub("\n+$", "")) }, nil
  end
  if result.truncated then
    return { file = file, trouble = "its syntax tree is larger than " .. plural.count(limit, "byte") ..
        ", the most that is read of one" }, nil
  end
  local decls = tree.parse(tostring(result.stdout or ""), root)
  local unreadable = rules.unreadable(decls)
  if unreadable ~= nil then return { file = file, trouble = unreadable }, nil end
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
  local named: mut {string: boolean} = {}
  for _, file in ipairs(files) do
    while file:sub(1, 2) == "./" do file = file:sub(3) end
    named[file] = true
  end
  for _, file in ipairs(all) do
    if String.ends_with(file, ".c") and named[file] ~= true then return false end
  end
  return true
end

--- Element `position` of `list`, a position the caller's own loop or count keeps within it.
local function nth<T>(list: {T}, position: integer): T
  return (assert(list[position], "a position is within the list"))
end

--- The value kept under `key` in `map`, a key this file set before it reads it.
local function held_in<K, V>(map: {K: V}, key: K): V
  return (assert(map[key], "the key was set before it is read"))
end

--- Whether the tree of `file` (a path relative to `cwd`) can differ under
--- `variant` from the first's: its text, or that of a header of the tree it
--- includes, names one of the variant's `tells`. A header is found as the compiler finds one of the
--- tree's own, beside the including file or in core/; one it cannot read is
--- taken to differ. `memo` keeps what each path answered.
local function sensitive(root: string, cwd: string, file: string, variant: c.Variant,
                         memo: mut {string: boolean}): boolean
  local function visit(path: string, stack: mut {string: boolean}): boolean
    local remembered = memo[path]
    if remembered ~= nil then return remembered end
    if stack[path] == true then return false end
    stack[path] = true
    local text, _ = Fs.read(path)
    local found = text == nil
    if text ~= nil then
      for _, name in ipairs(variant.tells) do
        if text:find(name, 1, true) then
          found = true
          break
        end
      end
    end
    if not found and text ~= nil then
      for name in ("\n" .. text):gmatch('\n%s*#%s*include%s*"([^"\n]+)"') do
        for _, dir in ipairs({ Fs.dirname(path), root .. "/core" }) do
          local header = dir .. "/" .. name
          local present, _ = Fs.exists(header)
          if present == true then
            if visit(header, stack) then found = true end
            break
          end
        end
        if found then break end
      end
    end
    stack[path] = nil
    -- A header met inside a cycle is not final until the cycle's start is.
    if found or next(stack) == nil then memo[path] = found end
    return found
  end
  return visit(if file:sub(1, 1) == "/" then file else cwd .. "/" .. file end, {})
end

--- Checks every one of `files`, paths relative to `cwd` (by default
--- `root`, cosmic's own tree), a few compilers at a time. The outcomes
--- come back in the order of `files`. A header two of them include is
--- checked with each, and what is found in it is reported once. When
--- `files` are every C file under `cwd`, a function no file but its own
--- refers to ("single-file") is found too, with the file defining it,
--- as long as every one of them could be read. `limit` is the most bytes
--- of one file's syntax tree that are read, by default `dump_limit`; a
--- file whose tree is larger is refused rather than half checked. With `store`, a database for [`build.check_memo`],
--- a compile whose inputs have not changed ([`build.c.inputs`]) is not run again: what the checks made of its tree is
--- read from the memo, and one that is made is kept there. A run over every C file drops the rows it did not use.
function c.check(root: string, files: {string}, cwd?: string, limit?: integer, store?: Sqlite.Handle):
    {c.Outcome}
  cwd = cwd or root
  local declared = declared_in(root)
  local outcomes: mut {c.Outcome} = {}
  local units: mut {integer: rules.Unit} = {}
  local which: mut {Child.Handle: integer} = {}
  -- One compile per file under the first variant, and one per file under
  -- each of the others the file's tree can differ in.
  local jobs: mut {c.Job} = {}
  local ran: mut {integer: {integer}} = {}
  local memo: mut {integer: {string: boolean}} = {}
  for i, _ in ipairs(files) do
    ran[i] = { 1 }
    jobs[#jobs + 1] = { file = i, variant = 1 }
  end
  for v = 2, #c.variants do
    memo[v] = {}
    for i, file in ipairs(files) do
      if sensitive(root, cwd, file, nth(c.variants, v), held_in(memo, v)) then -- checked: view_as_mut
        local used = held_in(ran, i)
        used[#used + 1] = v -- checked: view_written
        jobs[#jobs + 1] = { file = i, variant = v }
      end
    end
  end
  local results: mut {integer: c.Outcome} = {}
  local env = environment()
  local zig, direct = compiler(root, env)
  local install, runs_from, bootstrap_digest = toolchain(root, env, direct)
  local made_deps, deps_trouble = Fs.mkdtemp("cosmic-c-deps-")
  if made_deps == nil then
    for i, file in ipairs(files) do
      outcomes[i] = { file = file, trouble = "no directory for its compiler's caches: " .. deps_trouble }
    end
    return outcomes
  end
  local deps: string = made_deps
  env = c.own_caches(env, deps)
  local function absolute(path: string): string
    return if path:sub(1, 1) == "/" then path else cwd .. "/" .. path end
  end
  local dirs: mut {string} = {}
  for _, dir in ipairs(include_dirs(root, cwd)) do dirs[#dirs + 1] = absolute(dir) end
  -- The key each compile's outcome is kept under, for those whose inputs can be known and that the memo lacks; those it
  -- holds are answered here.
  local keys: mut {integer: string} = {}
  local stored = false
  if store ~= nil and install ~= nil then
    local prepared, _ = check_memo.prepare(store, "c")
    stored = prepared
  end
  if store ~= nil and stored then
    local salt = check_memo.salt(root, { "build/c/init.tl", "build/c/rules.tl", "build/c/tree.tl", "build/c/inputs.tl",
      "build/check_memo.tl", "build/gen_syscalls.tl", "build/plural.tl" }, "c 1")
    local context = root .. "\0" .. cwd .. "\0" .. tostring(limit or dump_limit) .. "\0" .. declared_text(declared)
    local readers: mut {integer: inputs.Reader} = {}
    for j, job in ipairs(jobs) do
      local file = assert(files[job.file])
      local words = command(root, zig, file, cwd, assert(c.variants[job.variant]))
      local reader = readers[job.variant]
      if reader == nil then
        reader = inputs.reader(dirs, words)
        readers[job.variant] = reader
      end
      local read = inputs.key(reader, absolute(file), words, assert(install))
      if read ~= nil then
        local key = check_memo.key(salt, "c", context .. "\0" .. read)
        local text = check_memo.get(store, "c", key)
        local findings, unit: mut {rules.Finding}?, rules.Unit?
        if text ~= nil then
          findings, unit = decoded(file, text)
        end
        if findings ~= nil and unit ~= nil then
          results[j] = { file = file, findings = findings }
          units[j] = unit
        else
          keys[j] = key
        end
      end
    end
  end
  local function compile()
    local running: mut {Child.Handle} = {}
    local next_job = 1
    while next_job <= #jobs or #running > 0 do
      while next_job <= #jobs and #running < parallel do
        local job = nth(jobs, next_job)
        -- A compile the memo answered is not run.
        if results[next_job] == nil then
          local handle, trouble = Child.start(
            command(root, zig, nth(files, job.file), cwd, nth(c.variants, job.variant)), {
              cwd = cwd, env = env, stdout = "capture", stderr = "capture",
              capture_limit = limit or dump_limit,
            })
          if handle == nil then
            results[next_job] = { file = nth(files, job.file), trouble = trouble }
          else
            running[#running + 1] = handle
            which[handle] = next_job
          end
        end
        next_job = next_job + 1
      end
      if #running > 0 then
        local done, trouble = Child.wait_any(running, Clock.seconds(120))
        if done == nil then
          if trouble == Poll.TIMEOUT then trouble = "clang gave no answer in 120 seconds" end
          for _, handle in ipairs(running) do
            local _, _ = handle:close()
            local stopped = held_in(which, handle)
            results[stopped] = { file = nth(files, nth(jobs, stopped).file), trouble = trouble }
          end
          running = {}
        else
          local result, wait_trouble = done:wait()
          local finished = held_in(which, done)
          local job = nth(jobs, finished)
          local made, unit = outcome(root, nth(files, job.file), result,
            wait_trouble, declared, limit or dump_limit)
          results[finished] = made
          if unit ~= nil then units[finished] = unit end
          local made_findings = made.findings
          local made_key = keys[finished]
          -- A compile that made findings made a unit too.
          if store ~= nil and made_key ~= nil and made_findings ~= nil and unit ~= nil then
            check_memo.put(store, "c", made_key, encoded(made_findings, unit))
          end
          local still: mut {Child.Handle} = {}
          for _, handle in ipairs(running) do
            if handle ~= done then still[#still + 1] = handle end
          end
          running = still
        end
      end
    end
  end
  local compiled, trouble = pcall(function(): string
    if install == nil then
      compile()
      return ""
    end
    -- The bootstrap cosmic, fetched now where it is not cached, and only
    -- where a compile the memo did not answer is left to run: a compile
    -- that cannot run is told why, and an answered one keeps its answer.
    local unanswered: mut {integer} = {}
    for j in ipairs(jobs) do
      if results[j] == nil then unanswered[#unanswered + 1] = j end
    end
    if #unanswered == 0 then return "" end
    if bootstrap_digest ~= nil and not direct then
      local variables: mut {string:string} = {}
      for name, value in pairs(env) do variables[name] = value end
      -- One try: where a fetch fails here, a person runs bin/cosmic, which tries again.
      if variables["COSMIC_BOOTSTRAP_ATTEMPTS"] == nil then
        variables["COSMIC_BOOTSTRAP_ATTEMPTS"] = "1"
      end
      local bootstrap, why = c.bootstrap_cosmic(root, variables, bootstrap_digest)
      if bootstrap == nil then
        for _, j in ipairs(unanswered) do
          results[j] = { file = nth(files, nth(jobs, j).file), trouble = why }
        end
        return ""
      end
      runs_from[#runs_from + 1] = bootstrap
    end
    -- What the compiler is given beside what it runs from: the tree's
    -- pieces of the toolchain, the include directories, and each file's
    -- own directory, where a header beside it is found.
    local reads: mut {string} = {}
    local seen: mut {string: boolean} = {}
    local function give(path: string)
      if seen[path] ~= true then
        seen[path] = true
        reads[#reads + 1] = path
      end
    end
    -- The scripts and pins only where [`bin/zig`] runs the compile.
    if not direct then
      for _, path in ipairs({ "bin/zig", "bin/cosmic-bootstrap", "bin/zig.pin", "build/zig.tl",
          "ci/cosmic-driver.pin", "ci/bootstrap-files.txt" }) do
        give(root .. "/" .. path)
      end
    end
    for _, path in ipairs(runs_from) do give(path) end
    for _, dir in ipairs(include_dirs(root, cwd)) do give(absolute(dir)) end
    for _, file in ipairs(files) do give(Fs.dirname(absolute(file))) end
    local writes: mut {string} = { deps }
    local kept = if direct then nil else standalone_compiles(env) end
    if kept ~= nil then writes[#writes + 1] = kept end
    confine.declaring({ reads = reads, writes = writes }, compile)
    return ""
  end)
  local _, _ = Fs.remove_tree(deps)
  local is_whole = whole(cwd, files)
  if store ~= nil and stored then
    -- Only a run over every file may say which rows are no longer wanted.
    if is_whole and compiled then
      check_memo.finish(store, "c")
    else
      local _, _ = Sqlite.run(store, "COMMIT")
    end
  end
  if not compiled then error(trouble, 0) end
  -- A file's outcome is the first variant's, with the findings of the
  -- others added; a variant that could not be read fails the file, named
  -- when it is not the first. Only the first variant's tree is shared
  -- across files (below): the others are partial, and which functions a
  -- file refers to is the first's to say.
  -- TODO: share a function across files under every variant's units, not
  -- the first's: a function only a macOS-only (or checked-only) file refers
  -- to is read as referred to by none in the first variant, and a header
  -- function only the other variants' files refer to is not flagged. This
  -- waits on rules.single_file taking one unit per variant and file.
  local first_unit: mut {integer: rules.Unit} = {}
  local at: mut {string: rules.Finding} = {}
  for i, file in ipairs(files) do
    local variants: mut {string} = {}
    local findings: mut {rules.Finding} = {}
    local out: c.Outcome = { file = file, variants = variants }
    outcomes[i] = out
    for _, v in ipairs(held_in(ran, i)) do
      local job = 0
      for j, candidate in ipairs(jobs) do
        if candidate.file == i and candidate.variant == v then
          job = j
          break
        end
      end
      local result = held_in(results, job)
      local name = nth(c.variants, v).name
      variants[#variants + 1] = name
      local reported = result.findings
      if reported == nil then
        out.findings = nil
        out.trouble = (if v == 1 then "" else name .. ": " end) .. assert(result.trouble)
        break
      end
      if v == 1 then
        out.findings = findings
        local first = units[job]
        if first ~= nil then first_unit[i] = first end
      end
      for _, f in ipairs(reported) do
        local key = f.file .. ":" .. tostring(f.line) .. ":" .. f.rule .. ":" .. f.within
        local same = at[key]
        if same == nil then
          f.variants = { name }
          at[key] = f
          findings[#findings + 1] = f
        else
          local named = assert(same.variants)
          named[#named + 1] = name
        end
      end
    end
    -- A file whose first variant could not be read has no findings to
    -- keep from the others.
    if out.trouble ~= nil then out.findings = nil end
  end
  if is_whole then
    local every: mut {rules.Unit} = {}
    local by_file: mut {string: c.Outcome} = {}
    for i = 1, #files do
      local unit = first_unit[i]
      if unit ~= nil then every[#every + 1] = unit end
      local own = nth(outcomes, i)
      by_file[own.file] = own
    end
    -- A file that could not be read refers to what is not known: its
    -- own trouble is the finding, rather than guesses about the rest.
    local known = #every == #files
    for _, f in ipairs(if known then rules.single_file(every) else {} end) do -- checked: literal_needs_type
      for _, u in ipairs(every) do
        local o = by_file[u.file]
        if o ~= nil and u.defines[f.within] ~= nil then
          local findings = o.findings
          if findings ~= nil then
            f.variants = { nth(c.variants, 1).name }
            findings[#findings + 1] = f
          end
        end
      end
    end
  end
  local seen: mut {string: boolean} = {}
  for _, o in ipairs(outcomes) do
    local o_findings = o.findings
    if o_findings ~= nil then
      local kept: mut {rules.Finding} = {}
      for _, f in ipairs(o_findings) do
        local key = f.file .. ":" .. tostring(f.line) .. ":" .. f.rule
        if seen[key] ~= true then
          seen[key] = true
          kept[#kept + 1] = f
        end
      end
      o.findings = kept
    end
  end
  return outcomes
end

--- `source`, a C file, in the layout [`build.c.layout`] holds; or nil and
--- why, when laying it out would change more than whitespace.
function c.laid_out(source: string): string?, string
  return layout.rendered(source)
end

return c
