#!/usr/bin/env lua
--- Shell-free binary packing (#732): replaces the cosmic_bin recipe's
--- staging for-loops (mkdir/cp), the mtime clamp (find -exec touch),
--- and the cd + zip pipeline. Make remains the source of truth for
--- WHAT ships: it passes every file as an explicit --copy SRC DST pair
--- (relative destinations computed with patsubst, not shell suffix
--- stripping). This script owns HOW: stage, clamp, pack.
---
--- Pack policy (moved from the pack-cosmic define): the boot-critical
--- Lua — .lua/cosmic/* modules, main.lua and .args — is inflate()d on
--- EVERY invocation (29 inflate() calls at boot; whilp/cosmic#487), so
--- store it uncompressed to skip the decompress. The rest (tl.lua,
--- type declarations, docs, .tl source, skills) is large or lazy-loaded
--- and stays deflated. -X strips Unix extra fields (atime/mtime/uid/
--- gid): zip reading a staged file bumps its atime to pack time, which
--- leaked into local headers even with mtimes clamped (#733). Entry
--- mtimes stay as clamped DOS timestamps; mode bits live in the
--- central attrs and survive -X.

local child = require("cosmic.child")
local fs = require("cosmic.fs")
local fs_types = require("cosmic.fs.types")
local proc = require("cosmic.proc")

local function fail(msg: string): integer
  io.stderr:write("build-pack: " .. msg .. "\n")
  return 1
end

local function copy_file(src: string, dst: string): boolean, string
  local content, rerr = fs.read(src)
  if not content then
    return false, "read " .. src .. " failed: " .. (rerr or "unknown error")
  end
  local st = fs.stat(src)
  if not st then
    return false, "stat " .. src .. " failed"
  end
  -- cast: mixed-representation Stat
  local mode = (st as fs_types.Stat):mode() % 512
  fs.makedirs(fs.dirname(dst))
  local ok, werr = fs.write(dst, content, mode)
  if not ok then
    return false, "write " .. dst .. " failed: " .. (werr or "unknown error")
  end
  fs.chmod(dst, mode)
  return true
end

local function copy_tree(src: string, dst: string): boolean, string
  local dir0, derr = fs.opendir(src)
  if not dir0 then
    return false, "opendir " .. src .. " failed: " .. (derr or "unknown error")
  end
  local dh = dir0 as fs_types.Dir -- cast: record union after guard
  fs.makedirs(dst)
  while true do
    local name = dh:read()
    if not name then break end
    if name ~= "." and name ~= ".." then
      local s, d = fs.join(src, name), fs.join(dst, name)
      local st = fs.stat(s)
      if st and (st as fs_types.Stat):is_dir() then -- cast: mixed-representation Stat
        local ok, err = copy_tree(s, d)
        if not ok then return false, err end
      else
        local ok, err = copy_file(s, d)
        if not ok then return false, err end
      end
    end
  end
  return true
end

--- Clamp mtimes (and atimes) of everything under path — children
--- first, then the directory itself, so writes never re-bump a parent.
local function clamp(path: string, epoch: integer): boolean, string
  local st = fs.stat(path)
  if not st then
    return false, "stat " .. path .. " failed"
  end
  if (st as fs_types.Stat):is_dir() then -- cast: mixed-representation Stat
    local dir0, derr = fs.opendir(path)
    if not dir0 then
      return false, "opendir " .. path .. " failed: " .. (derr or "unknown error")
    end
    local dh = dir0 as fs_types.Dir -- cast: record union after guard
    while true do
      local name = dh:read()
      if not name then break end
      if name ~= "." and name ~= ".." then
        local ok, err = clamp(fs.join(path, name), epoch)
        if not ok then return false, err end
      end
    end
  end
  local ok, uerr = fs.utimensat(path, epoch, 0, epoch, 0)
  if not ok then
    return false, "utimensat " .. path .. " failed: " .. (uerr or "unknown error")
  end
  return true
end

local function zip_add(zip_bin: string, built: string, out: string,
    flags: string, entries: {string}): boolean, string
  local argv: {string} = {zip_bin, flags}
  table.insert(argv, out)
  for _, e in ipairs(entries) do
    table.insert(argv, e)
  end
  local result, serr = child.run(argv, {cwd = built})
  if not result then
    return false, "spawn " .. zip_bin .. " failed: " .. tostring(serr)
  end
  local r = result as child.Result -- cast: record union after guard
  if r.stderr and r.stderr ~= "" then
    io.stderr:write(r.stderr)
  end
  if not r.ok then
    return false, "zip " .. flags .. " failed (exit " .. tostring(r.code) .. ")"
  end
  return true
end

--- pack --out BIN --built DIR --epoch N --zip ZIP --base SRCBIN
---      [--copy SRC DST]... [--copytree SRC DST]...
local function main(...: string): integer
  local args = {...}
  local out, built, zip_bin, base: string, string, string, string
  local epoch = 0
  local copies: {{string, string}} = {}
  local trees: {{string, string}} = {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--out" then
      out = args[i + 1]; i = i + 2
    elseif a == "--built" then
      built = args[i + 1]; i = i + 2
    elseif a == "--epoch" then
      epoch = math.tointeger(tonumber(args[i + 1])) or 0; i = i + 2
    elseif a == "--zip" then
      zip_bin = args[i + 1]; i = i + 2
    elseif a == "--base" then
      base = args[i + 1]; i = i + 2
    elseif a == "--copy" then
      table.insert(copies, {args[i + 1], args[i + 2]}); i = i + 3
    elseif a == "--copytree" then
      table.insert(trees, {args[i + 1], args[i + 2]}); i = i + 3
    else
      return fail("unknown argument: " .. tostring(a))
    end
  end
  if not out or not built or not zip_bin or not base then
    return fail("usage: build-pack --out BIN --built DIR --epoch N --zip ZIP"
      .. " --base SRCBIN [--copy SRC DST]... [--copytree SRC DST]...")
  end

  fs.rmrf(built)
  for _, c in ipairs(copies) do
    local ok, err = copy_file(c[1], fs.join(built, c[2]))
    if not ok then return fail(err) end
  end
  for _, t in ipairs(trees) do
    local ok, err = copy_tree(t[1], fs.join(built, t[2]))
    if not ok then return fail(err) end
  end

  local ok, err = clamp(built, epoch)
  if not ok then return fail(err) end

  ok, err = copy_file(base, out)
  if not ok then return fail(err) end
  local exec_ok, cerr = fs.chmod(out, tonumber("755", 8) as integer) -- cast: octal is integral
  if not exec_ok then
    return fail("chmod " .. out .. " failed: " .. (cerr or "unknown error"))
  end

  -- cast: or fallback does not narrow
  local cwd = (fs.getcwd() or ".") as string
  -- the zip children run with cwd inside the staging tree, so both the
  -- archive path and the zip binary itself must be absolute
  local abs_out = out
  if out:sub(1, 1) ~= "/" then
    abs_out = fs.join(cwd, out)
  end
  if zip_bin:sub(1, 1) ~= "/" then
    zip_bin = fs.join(cwd, zip_bin)
  end
  ok, err = zip_add(zip_bin, built, abs_out, "-qr0X", {".lua/cosmic"})
  if not ok then return fail(err) end
  ok, err = zip_add(zip_bin, built, abs_out, "-qrX",
    {".lua", ".tl", ".docs", "sys", "skills", "-x", ".lua/cosmic/*"})
  if not ok then return fail(err) end
  ok, err = zip_add(zip_bin, built, abs_out, "-q0X", {"main.lua", ".args"})
  if not ok then return fail(err) end
  return 0
end

if proc.is_main() then
  os.exit(main(...))
end

return {main = main}
