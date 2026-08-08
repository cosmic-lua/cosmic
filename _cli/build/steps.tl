--- The recipe steps themselves: one function per verb.
---
--- Split out of _cli.build when the vocabulary outgrew the 500-line
--- cap. The dispatcher next door owns the vocabulary (which names
--- exist, how a line is parsed); this file owns what each name does —
--- except the three that do real work per source (`compile`,
--- `capture`, `record`), which live in `_cli.build.work` with the
--- content-keyed skip that lets them not do it.
---
--- Requires the EMBEDDED stdlib only — deliberately no tree modules:
--- the compile step is what BUILDS the tree's .lua files, so a tree
--- dependency here is circular, and the recipes export LUA_PATH=";;"
--- so a caller's LUA_PATH cannot redirect the driver's own requires.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local records = require("_tool.records")
local work = require("_cli.build.work")

--- The one prefix a recipe step's failure wears, matching its siblings
--- in `_cli/build/init.tl` and `_cli/driver.tl`, so a failed step is
--- attributed to the surface that ran it rather than to a flag.
local function fail(msg: string): integer
  io.stderr:write("cosmic -c: " .. msg .. "\n")
  return 1
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
  local r, rerr = child.run(argv)
  if not r then
    return fail("start " .. argv[1] .. " failed: " .. tostring(rerr or "start failed"))
  end
  if r.stderr and r.stderr ~= "" then
    io.stderr:write(r.stderr)
  end
  io.write(r.stdout)
  local _ok, _err = fs.make_dirs(fs.dirname(out))
  local ok, werr = fs.write(out, r.stdout)
  if not ok then
    return fail("write " .. out .. " failed: " .. (werr or "unknown error"))
  end
  if not r.ok then
    return r.code or 1
  end
  return 0
end

--- write-list <out> <items...> — write items one per line, only if changed
--- (the lint file-list stamp's printf + cmp/mv shape).
local function do_write_list(args: {string}): integer
  local out = args[1]
  if not out then
    return fail("usage: write-list <out> [items...]")
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
  local _ok, _err = fs.make_dirs(fs.dirname(out))
  local ok, werr = fs.write(out, content)
  if not ok then
    return fail("write " .. out .. " failed: " .. (werr or "unknown error"))
  end
  return 0
end

--- assert-marker <marker> <dir> — fail unless some file under dir
--- contains marker as a plain substring (the enforce lane's tripwire:
--- grep -rqs replacement).
local function do_assert_marker(args: {string}): integer
  local marker, dir = args[1], args[2]
  if not dir then
    return fail("usage: assert-marker <marker> <dir>")
  end
  local function scan(d: string): boolean
    local dir0 = fs.open_dir(d)
    if not dir0 then return false end
    local dh = dir0
    while true do
      local name = dh:read()
      if not name then break end
      if name ~= "." and name ~= ".." then
        local p = fs.join(d, name)
        local st = fs.stat(p)
        if st and (st as fs.Stat):is_dir() then -- cast: record union after guard
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

--- assert-elf <file> — fail unless file starts with the ELF magic
--- (the assimilation checks' `printf '\177ELF' | cmp` process
--- substitution).
local function do_assert_elf(args: {string}): integer
  local path = args[1]
  if not path then
    return fail("usage: assert-elf <file>")
  end
  local content = fs.read(path)
  if not content or string.sub(content, 1, 4) ~= "\127ELF" then
    return fail(path .. " is not a native ELF — assimilation failed"
      .. " (sandboxed rules need a native ELF, no loader grants)")
  end
  return 0
end

--- remove <paths...> — rm -f: delete files, ignoring MISSING ones.
---
--- Only missing ones. Swallowing every error made "cannot unlink"
--- indistinguishable from "already gone", so a rule that could not
--- clear its output reported success and the next step ran against the
--- file it meant to replace.
local function do_remove(args: {string}): integer
  for _, p in ipairs(args) do
    -- Attempt the unlink, and only ask what went wrong when it fails.
    -- Guarding it with `fs.is_present` skipped DANGLING symlinks: exists
    -- follows the link, so one whose target is gone reads as "already
    -- gone" and was never unlinked -- and `link` makes symlinks, so a
    -- rule clearing a stale one silently kept it. `islink` is the second
    -- question because exists cannot see it either.
    local ok, uerr = fs.remove(p)
    if not ok and (fs.is_present(p) or fs.is_link(p)) then
      return fail("remove " .. p .. ": " .. (uerr or "unknown error"))
    end
  end
  return 0
end

--- verdict <o_dir> <stages...> — the ci grading loop: print each
--- stage's summary in a log group, grade it by the summary's own counts
--- AND the per-stage ci-ok exit marker (a stage failing after writing a
--- clean summary must still fail), and end with the verdict line.
---
--- The counts come from `_tool.records`, which OWNS the summary's
--- grammar: prose-matching `"[1-9]%d* failed"` made this a second
--- reader of a format with one writer, and it would have kept grading
--- yesterday's wording -- silently, in the direction of PASS.
---
--- The verb stays rather than retiring with its in-tree consumer:
--- `SHELL := cosmic` is a general contract, and grading a set of
--- stages is what an external makefile's `ci` needs. Cosmic's own `ci`
--- is a `--make` verb because it also decides WHICH stages run.
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
      local seen, bad = records.parse_counts(summary)
      if seen ~= nil and bad > 0 then
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
  local ci_ok = #failed == 0
  io.write(records.format_verdict("ci", ci_ok,
      ci_ok and "" or table.concat(failed, " ")) .. "\n")
  return records.exit_code(ci_ok)
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
  local mode = st:mode() % 512 -- permission bits (0777)
  local _ok, _err = fs.make_dirs(fs.dirname(dst))
  local ok, werr = fs.write(dst, content, mode)
  if not ok then
    return fail("write " .. dst .. " failed: " .. (werr or "unknown error"))
  end
  local _ok, _err = fs.set_mode(dst, mode) -- write's mode only applies on create
  return 0
end

--- link <target> <linkpath> — mkdir -p + ln -sfn.
local function do_link(args: {string}): integer
  local target, linkpath = args[1], args[2]
  if not linkpath then
    return fail("usage: link <target> <linkpath>")
  end
  local _ok, _err = fs.make_dirs(fs.dirname(linkpath))
  local _ok, _err = fs.remove(linkpath)
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
  -- REALPATH, not abspath, on both sides: abspath normalizes `..` but
  -- does not follow symlinks, and the kernel does at spawn. So
  -- `o/tool -> /bin/sh` had an abspath under the root, passed the
  -- prefix test, and ran the host binary. Resolving the ROOT too
  -- matters when the build directory is itself reached through a link.
  -- A relative symlink inside `o/` still resolves inside it, so the
  -- staging links a build makes keep working.
  local root_named = fs.absolute_path(env.get_or("COSMIC_EXEC_ROOT", "o"))
  local root = (fs.resolve(root_named) or root_named) as string -- cast: scalar fallback
  local named = fs.absolute_path(program)
  -- Falling back to the lexical path when realpath fails keeps the
  -- ROOT check first, so a bare `sh` still reports "never PATH" rather
  -- than "no such file" -- the more useful answer for the mistake it
  -- actually is. Nothing escapes through the fallback: realpath only
  -- fails for a path that does not resolve, and `isfile` below rejects
  -- those (a dangling link included).
  local abs = (fs.resolve(named) or named) as string -- cast: scalar fallback
  -- Prefix match on a separator boundary, so a sibling `o-other/` next
  -- to `o/` cannot pass for being inside it.
  if abs ~= root and abs:sub(1, #root + 1) ~= root .. "/" then
    return fail("exec " .. program .. ": resolves to " .. abs ..
      ", which is not under the build root " .. root
      .. "; a recipe may only exec pinned or built bytes, never PATH")
  end
  if not fs.is_file(abs) then
    return fail("exec " .. program .. ": no such file (" .. abs .. ")")
  end
  local argv: {string} = {abs}
  for i = 2, #args do
    argv[#argv + 1] = args[i]
  end
  -- "inherit" so the program streams as it runs, like every other
  -- recipe step.
  local h, serr = child.start(argv, {stdout = "inherit", stderr = "inherit"})
  if not (h is child.Handle) then
    return fail("exec " .. program .. ": " .. (serr or "unknown error"))
  end
  local res, werr = h:wait()
  if not (res is child.Result) then
    return fail("exec " .. program .. ": " .. (werr or "unknown error"))
  end
  return res.code or 1
end

--- The closed vocabulary, and every name says what the step DOES.
---
--- Three were renamed together, because each was borrowing a word that
--- already means something else here:
---
---   test        -> record       it records a result and always exits
---                               0; grading is `--report`'s job, and
---                               `--make test` is the verb that grades.
---                               A step called `test` that cannot fail
---                               a test is the worst of the three.
---   list        -> write-list   it WRITES its arguments to a file; it
---                               does not list anything.
---   require-*   -> assert-*     `require` is Lua's module loader, and
---                               these load nothing. They assert.
local modes: {string: function({string}): integer} = {
  ["assert-elf"] = do_assert_elf,
  ["assert-marker"] = do_assert_marker,
  capture = work.capture,
  compile = work.compile,
  copy = do_copy,
  exec = do_exec,
  link = do_link,
  record = work.record,
  remove = do_remove,
  tee = do_tee,
  verdict = do_verdict,
  ["write-list"] = do_write_list,
}

return modes
