#!/usr/bin/env lua
--- Shell-free recipe steps for the compile, copy, version-link, and
--- doc-index rules (#732): `compile` replaces the cat/if/redirect/
--- cmp/mv dance, `copy` replaces mkdir+cp, `link` replaces
--- mkdir+ln -sfn, `capture` replaces redirect+cmp/mv for scripts.
---
--- Runs under the PINNED bootstrap against its EMBEDDED stdlib only —
--- deliberately no tree requires, unlike every other build script: the
--- compile rule is what BUILDS the tree's .lua files, so a tree
--- dependency here is circular, and the recipes export LUA_PATH=";;"
--- so a caller's LUA_PATH cannot redirect the driver's own requires.
--- The bootstrap sha therefore covers this driver's entire runtime; a
--- bootstrap bump that breaks an embedded API fails the build loudly.
--- The driver's own .lua is compiled by a self-bootstrap exception
--- rule (see lib/build/cook.mk) — it cannot compile itself.

local child = require("cosmic.child")
local env = require("cosmic.env")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local proc = require("cosmic.proc")

local function fail(msg: string): integer
  io.stderr:write("build-recipe: " .. msg .. "\n")
  return 1
end

--- Run argv, pass stderr through, and write stdout to out only when
--- the content changed — preserving the old cmp/mv contract that an
--- unchanged result does not touch the output's mtime.
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

--- compile <flag_stamp> <bootstrap> <src> <out> [compiler flags...]
--- Reads the probed flag and sets the child's LUA_PATH (";;" for
--- strict compiles, $TREE_LUA_PATH otherwise; TL_PATH passes through
--- from the rule's export).
local function do_compile(args: {string}): integer
  local stamp, bootstrap, src, out = args[1], args[2], args[3], args[4]
  if not out then
    return fail("usage: compile <flag_stamp> <bootstrap> <src> <out> [flags...]")
  end
  -- cast: or fallback does not narrow
  local flag = ((fs.read(stamp) or "") as string):match("%S+")
  if flag ~= "--compile-strict" and flag ~= "--compile" then
    return fail("bad compile flag in " .. stamp .. ": " .. tostring(flag))
  end
  if flag == "--compile-strict" then
    env.set("LUA_PATH", ";;")
  else
    local tree = child_tree_lua_path()
    if not tree then
      return fail("TREE_LUA_PATH required for non-strict compiles")
    end
    env.set("LUA_PATH", tree)
  end

  local argv: {string} = {bootstrap}
  for i = 5, #args do
    table.insert(argv, args[i])
  end
  table.insert(argv, flag)
  table.insert(argv, src)
  return run_into(argv, out)
end

--- capture <bootstrap> <out> <script+args...> — run a script under the
--- bootstrap with LUA_PATH=$TREE_LUA_PATH and write its stdout to out
--- if changed (the doc-index rule's shape).
local function do_capture(args: {string}): integer
  local bootstrap, out = args[1], args[2]
  if not out or not args[3] then
    return fail("usage: capture <bootstrap> <out> <script> [args...]")
  end
  local tree = child_tree_lua_path()
  if not tree then
    return fail("TREE_LUA_PATH required for capture")
  end
  env.set("LUA_PATH", tree)
  local argv: {string} = {bootstrap}
  for i = 3, #args do
    table.insert(argv, args[i])
  end
  return run_into(argv, out)
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

local modes: {string: function({string}): integer} = {
  capture = do_capture,
  compile = do_compile,
  copy = do_copy,
  link = do_link,
}

local function main(...: string): integer
  local args = {...}
  local mode = table.remove(args, 1)
  local run_mode = mode and modes[mode]
  if not run_mode then
    return fail("usage: build-recipe capture|compile|copy|link ...")
  end
  return run_mode(args)
end

if proc.is_main() then
  os.exit(main(...))
end

return {main = main}
