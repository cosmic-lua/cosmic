--- The recipe steps themselves: one function per verb.
---
--- Split out of _cli.build when the vocabulary outgrew the 500-line
--- cap. The dispatcher next door owns the vocabulary (which names
--- exist, how a line is parsed); this file owns what each name does.
---
--- Requires the EMBEDDED stdlib only — deliberately no tree modules:
--- the compile step is what BUILDS the tree's .lua files, so a tree
--- dependency here is circular, and the recipes export LUA_PATH=";;"
--- so a caller's LUA_PATH cannot redirect the driver's own requires.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")

local function fail(msg: string): integer
  io.stderr:write("--build: " .. msg .. "\n")
  return 1
end

--- Run argv, pass stderr through, and write stdout to out only when
--- the content changed, so an unchanged result does not touch the
--- output's mtime.
local function run_into(argv: {string}, out: string): integer
  local result, serr = child.run(argv)
  if not result then
    return fail("spawn " .. argv[1] .. " failed: " .. tostring(serr))
  end
  local r = result as child.Result -- cast: record union after guard
  if r.stderr and r.stderr ~= "" then
    io.stderr:write(r.stderr)
  end
  if not r.ok then
    return r.code or 1
  end
  local existing = fs.read(out)
  if existing == r.stdout then
    return 0
  end
  fs.makedirs(fs.dirname(out))
  local ok, werr = fs.write(out, r.stdout)
  if not ok then
    return fail("write " .. out .. " failed: " .. (werr or "unknown error"))
  end
  return 0
end

local function child_tree_lua_path(): string
  local tree = os.getenv("TREE_LUA_PATH")
  if not tree or tree == "" then
    return nil
  end
  return tree
end

--- compile <bootstrap> <src> <out> [compiler flags...]
--- Always a STRICT compile: --compile-strict type checks and then
--- generates from that same checked AST, so nothing ships that did not
--- typecheck, under LUA_PATH=";;" so output cannot depend on parallel
--- build order. TL_PATH passes through from the rule's export.
---
--- Compiles are unconditionally strict, with no flag-stamp argument to
--- probe: a driver that falls back to a non-strict, order-dependent
--- compile when the stamp says the flag is unavailable is a place where
--- a stale input degrades silently.
local function do_compile(args: {string}): integer
  local bootstrap, src, out = args[1], args[2], args[3]
  if not out then
    return fail("usage: compile <bootstrap> <src> <out> [flags...]"
      .. " [--deps <path>...]")
  end
  env.set("LUA_PATH", ";;")
  local argv: {string} = {bootstrap}
  for i = 4, #args do
    -- Everything after --deps is an INPUT, named so the derived fence
    -- can grant it, and never forwarded to the child. Forwarding was a
    -- silent disaster the first time it was written: a bare path lands
    -- as the child's first positional, getopt stops parsing there, and
    -- `cosmic --include-dir . util.tl --compile-strict main.tl` RUNS
    -- util.tl as a script and writes its empty stdout as main.lua. The
    -- compile "passes" having checked nothing -- the shape,
    -- where an argv ambiguity makes a gate report a pass it never ran.
    if args[i] == "--deps" then
      break
    end
    table.insert(argv, args[i])
  end
  table.insert(argv, "--compile-strict")
  table.insert(argv, src)
  return run_into(argv, out)
end

--- capture <bootstrap> <out> <script+args...> — run a script under the
--- bootstrap and write its stdout to out if changed (the doc-index
--- rule's shape). The child sees LUA_PATH=$TREE_LUA_PATH when the rule
--- exports one; otherwise it inherits the recipe's ";;" (embedded).
local function do_capture(args: {string}): integer
  local bootstrap, out = args[1], args[2]
  if not out or not args[3] then
    return fail("usage: capture <bootstrap> <out> <script> [args...]")
  end
  local tree = child_tree_lua_path()
  if tree then
    env.set("LUA_PATH", tree)
  end
  local argv: {string} = {bootstrap}
  for i = 3, #args do
    table.insert(argv, args[i])
  end
  return run_into(argv, out)
end

--- tee <out> <cmd...> — run a command, print its stdout AND write it to
--- out (the summary rules' `| tee $@` shape, pipefail semantics: the
--- child's exit code propagates after the file is written).
local function do_tee(args: {string}): integer
  local out = args[1]
  if not out or not args[2] then
    return fail("usage: tee <out> <cmd> [args...]")
  end
  local argv: {string} = {}
  for i = 2, #args do
    table.insert(argv, args[i])
  end
  local result, serr = child.run(argv)
  if not result then
    return fail("spawn " .. argv[1] .. " failed: " .. tostring(serr))
  end
  local r = result as child.Result -- cast: record union after guard
  if r.stderr and r.stderr ~= "" then
    io.stderr:write(r.stderr)
  end
  io.write(r.stdout)
  fs.makedirs(fs.dirname(out))
  local ok, werr = fs.write(out, r.stdout)
  if not ok then
    return fail("write " .. out .. " failed: " .. (werr or "unknown error"))
  end
  if not r.ok then
    return r.code or 1
  end
  return 0
end

--- list <out> <items...> — write items one per line, only if changed
--- (the lint file-list stamp's printf + cmp/mv shape).
local function do_list(args: {string}): integer
  local out = args[1]
  if not out then
    return fail("usage: list <out> [items...]")
  end
  local parts: {string} = {}
  for i = 2, #args do
    table.insert(parts, args[i])
  end
  local content = table.concat(parts, "\n") .. "\n"
  local existing = fs.read(out)
  if existing == content then
    return 0
  end
  fs.makedirs(fs.dirname(out))
  local ok, werr = fs.write(out, content)
  if not ok then
    return fail("write " .. out .. " failed: " .. (werr or "unknown error"))
  end
  return 0
end

--- test <out> <cmd> [args...] — run one test file, writing the
--- `<out>.got`/`.out`/`.err` contract testrun already owns, and then
--- **always succeed**.
---
--- That last part is the whole point, and it is a decision rather than
--- an oversight. `--test` propagates its child's exit code, so a rule
--- shaped `cosmic --test …` fails when the test fails: under `make`
--- that stops the build at the first failing test, and — worse — a
--- test that means to SKIP exits 2, which is indistinguishable from a
--- failure to make. The graph's job is to record what happened; the
--- report step grades it, where 0/2/other already mean pass/skip/fail.
--- So the verb writes the result and returns 0, every test in a run
--- gets to run, and skip semantics survive the trip through make.
---
--- A step that could not record a result at all (unwritable output) is
--- still a failure: that is the graph breaking, not a test failing.
local function do_test(args: {string}): integer
  local out = args[1]
  if not out or not args[2] then
    return fail("usage: test <out> <cmd> [args...]")
  end
  local argv: {string} = {}
  for i = 2, #args do
    -- Same contract as compile: --deps names inputs for the fence and
    -- is never handed to the child. A test that read arg[1] would
    -- otherwise find its own dependency list there.
    if args[i] == "--deps" then
      break
    end
    argv[#argv + 1] = args[i]
  end
  -- The test fence, behavioural half: point TMP at a scratch directory
  -- beside this step's own output, so testrun's mkdtemp lands there and
  -- the test's TEST_TMPDIR is inside its own unit rather than in a
  -- shared /tmp. Two things follow, and the first matters more than the
  -- second: tests stop being able to collide with each other through
  -- the temp directory at all, on every platform, whether or not a
  -- kernel is enforcing anything; and the derived fence's write grant
  -- (this step's output directory) already covers it, so the kernel
  -- half needs no extra rule.
  --
  -- ABSOLUTE, because `out` is a path relative to the project root and
  -- TEST_TMPDIR outlives the cwd it was written against: a test that
  -- chdirs — or that spawns a child with `cwd = TEST_TMPDIR` and
  -- compares the result to it — resolves a relative one against
  -- somewhere else and gets a different directory, or a mismatch it
  -- reports as its own bug.
  local scratch = fs.abspath(out .. ".tmp.d")
  env.set("TMP", scratch)
  fs.makedirs(scratch)
  local testrun = require("cosmic.testrun")
  testrun.run(argv, out)
  if not fs.isfile(out .. ".got") then
    return fail("test " .. out .. ": no result recorded")
  end
  return 0
end

--- require-marker <marker> <dir> — fail unless some file under dir
--- contains marker as a plain substring (the enforce lane's tripwire:
--- grep -rqs replacement).
local function do_require_marker(args: {string}): integer
  local marker, dir = args[1], args[2]
  if not dir then
    return fail("usage: require-marker <marker> <dir>")
  end
  local function scan(d: string): boolean
    local dir0 = fs.opendir(d)
    if not dir0 then return false end
    local dh = dir0 as fs_types.Dir -- cast: record union after guard
    while true do
      local name = dh:read()
      if not name then break end
      if name ~= "." and name ~= ".." then
        local p = fs.join(d, name)
        local st = fs.stat(p)
        if st and (st as fs_types.Stat):is_dir() then -- cast: mixed-representation Stat
          if scan(p) then return true end
        else
          local content = fs.read(p)
          if content and string.find(content, marker, 1, true) then
            return true
          end
        end
      end
    end
    return false
  end
  if scan(dir) then
    return 0
  end
  return fail("no file under " .. dir .. " contains '" .. marker .. "'")
end

--- require-elf <file> — fail unless file starts with the ELF magic
--- (the assimilation checks' `printf '\177ELF' | cmp` process
--- substitution).
local function do_require_elf(args: {string}): integer
  local path = args[1]
  if not path then
    return fail("usage: require-elf <file>")
  end
  local content = fs.read(path)
  if not content or string.sub(content, 1, 4) ~= "\127ELF" then
    return fail(path .. " is not a native ELF — assimilation failed"
      .. " (sandboxed rules need a native ELF, no loader grants)")
  end
  return 0
end

--- remove <paths...> — rm -f: delete files, ignoring missing ones.
local function do_remove(args: {string}): integer
  for _, p in ipairs(args) do
    fs.unlink(p)
  end
  return 0
end

--- verdict <o_dir> <stages...> — the ci grading loop: print each
--- stage's summary in a log group, grade it by summary text AND the
--- per-stage ci-ok exit marker (a stage failing after writing a clean
--- summary must still fail), and end with the verdict line.
local function do_verdict(args: {string}): integer
  local o_dir = args[1]
  if not o_dir or not args[2] then
    return fail("usage: verdict <o_dir> <stages...>")
  end
  local failed: {string} = {}
  for i = 2, #args do
    local s = args[i]
    io.write("::group::" .. s .. "\n")
    local summary = fs.read(fs.join(o_dir, s .. "-summary.txt"))
    if summary then
      io.write(summary)
      if string.match(summary, "[1-9]%d* failed") then
        table.insert(failed, s)
      elseif not fs.stat(fs.join(o_dir, "ci-ok-" .. s)) then
        table.insert(failed, s .. " (exit)")
      end
    else
      io.write(s .. ": no summary produced\n")
      table.insert(failed, s)
    end
    io.write("::endgroup::\n")
  end
  if #failed > 0 then
    io.write("ci: FAIL (" .. table.concat(failed, " ") .. ")\n")
    return 1
  end
  io.write("ci: PASS\n")
  return 0
end

--- copy <src> <dst> — mkdir -p + cp, preserving the permission bits.
local function do_copy(args: {string}): integer
  local src, dst = args[1], args[2]
  if not dst then
    return fail("usage: copy <src> <dst>")
  end
  local content, rerr = fs.read(src)
  if not content then
    return fail("read " .. src .. " failed: " .. (rerr or "unknown error"))
  end
  local st = fs.stat(src)
  if not st then
    return fail("stat " .. src .. " failed")
  end
  -- cast: mixed-representation Stat
  local mode = (st as fs_types.Stat):mode() % 512 -- permission bits (0777)
  fs.makedirs(fs.dirname(dst))
  local ok, werr = fs.write(dst, content, mode)
  if not ok then
    return fail("write " .. dst .. " failed: " .. (werr or "unknown error"))
  end
  fs.chmod(dst, mode) -- write's mode only applies on create
  return 0
end

--- link <target> <linkpath> — mkdir -p + ln -sfn.
local function do_link(args: {string}): integer
  local target, linkpath = args[1], args[2]
  if not linkpath then
    return fail("usage: link <target> <linkpath>")
  end
  fs.makedirs(fs.dirname(linkpath))
  fs.unlink(linkpath)
  local ok, lerr = fs.symlink(target, linkpath)
  if not ok then
    return fail("symlink " .. linkpath .. " -> " .. target .. " failed: "
      .. (lerr or "unknown error"))
  end
  return 0
end

--- The one door out of the vocabulary: `exec <program> [args...]`.
---
--- It resolves ONLY to bytes already under the build root — a pinned
--- dependency staged into `o/`, a binary this build produced — and
--- never to a PATH lookup. A bare `exec cc` becomes `<cwd>/cc`, which
--- is not under the root, so it is refused rather than silently
--- picking up whatever the host has installed. That is what makes the
--- build's external surface enumerable: pins declare the bytes, fetch
--- obtains them, exec runs them, and nothing else runs at all.
---
--- The root is `$COSMIC_EXEC_ROOT`, else `o` beneath the current
--- directory (make runs recipes at the project root).
--- @param args {string} Program path, then its arguments
--- @return integer The program's exit code, or 1 on refusal
local function do_exec(args: {string}): integer
  local program = args[1]
  if not program then
    return fail("usage: exec <program> [args...]")
  end
  -- REALPATH, not abspath, on both sides. abspath normalizes `..` and
  -- so refuses a path that climbs out lexically, but it does not follow
  -- symlinks -- and the kernel does, at spawn. So `o/tool -> /bin/sh`
  -- had an abspath under the root, passed the prefix test, and ran the
  -- host binary: the design's "exec resolves only to pinned bytes under
  -- o/, never PATH" was a stronger claim than the check enforced.
  -- Verified before the fix with `ln -sf /bin/echo o/tool`.
  --
  -- Resolving the ROOT too matters when the build directory is itself
  -- reached through a link (a worktree under a symlinked home), or the
  -- prefix comparison comes out false for two spellings of one path.
  -- The relative `o/bootstrap/lua -> cosmic` link bin/make creates
  -- still resolves inside the root, so it keeps working.
  local root_named = fs.abspath(env.get("COSMIC_EXEC_ROOT", "o"))
  local root = (fs.realpath(root_named) or root_named) as string -- cast: scalar fallback
  local named = fs.abspath(program)
  -- Falling back to the lexical path when realpath fails keeps the
  -- ROOT check first, so a bare `sh` still reports "never PATH" rather
  -- than "no such file" -- the more useful answer for the mistake it
  -- actually is. Nothing escapes through the fallback: realpath only
  -- fails for a path that does not resolve, and `isfile` below rejects
  -- those (a dangling link included).
  local abs = (fs.realpath(named) or named) as string -- cast: scalar fallback
  -- Prefix match on a separator boundary, so a sibling `o-other/` next
  -- to `o/` cannot pass for being inside it.
  if abs ~= root and abs:sub(1, #root + 1) ~= root .. "/" then
    return fail("exec " .. program .. ": resolves to " .. abs ..
      ", which is not under the build root " .. root
      .. "; a recipe may only exec pinned or built bytes, never PATH")
  end
  if not fs.isfile(abs) then
    return fail("exec " .. program .. ": no such file (" .. abs .. ")")
  end
  local argv: {string} = {abs}
  for i = 2, #args do
    argv[#argv + 1] = args[i]
  end
  -- "inherit" so the program streams as it runs, like every other
  -- recipe step.
  local h, serr = child.spawn(argv, {stdout = "inherit", stderr = "inherit"})
  if not (h is child.Handle) then
    return fail("exec " .. program .. ": " .. (serr or "unknown error"))
  end
  -- cast: Teal's narrowing does not survive the early-exit guard above
  local res, werr = (h as child.Handle):wait()
  if not (res is child.Result) then
    return fail("exec " .. program .. ": " .. (werr or "unknown error"))
  end
  return res.code or 1
end

local modes: {string: function({string}): integer} = {
  capture = do_capture,
  compile = do_compile,
  copy = do_copy,
  exec = do_exec,
  link = do_link,
  list = do_list,
  remove = do_remove,
  ["require-elf"] = do_require_elf,
  ["require-marker"] = do_require_marker,
  tee = do_tee,
  test = do_test,
  verdict = do_verdict,
}

return modes
