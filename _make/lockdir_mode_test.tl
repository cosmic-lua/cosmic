#!/usr/bin/env cosmic
--- reads: _make/lockdir.tl
--- requires: mode-enforcement
--- Coverage for lockdir cases that depend on directory mode enforcement.
local fs = require("cosmic.fs")
local lockdir = require("_make.lockdir")

local tmpdir = os.getenv("TEST_TMPDIR") or "/tmp"

local function scratch(name: string): string
  local root = fs.join(tmpdir, "lockdir-" .. name)
  assert(fs.remove_all(root))
  assert(fs.make_dirs(root))
  return root
end

local function test_permission_denied_is_terminal()
  local root = scratch("mode-terminal")
  local token = "550e8400-e29b-41d4-a716-446655440000"

  local empty = fs.join(root, "empty")
  assert(fs.make_dir(empty))
  assert(fs.set_mode(root, fs.octal("500")))
  local absent_ok = lockdir.retire(empty, token)
  assert(fs.set_mode(root, fs.octal("700")))
  assert(absent_ok and fs.is_dir(empty), "absent token must not attempt rmdir")

  local eacces = fs.join(root, "ENOTEMPTY-lock")
  local owned = lockdir.try_acquire(eacces, "owner")
  assert(owned.state == "owned")
  assert(fs.set_mode(root, fs.octal("500")))
  local retired = lockdir.retire(eacces, owned.token)
  assert(fs.set_mode(root, fs.octal("700")))
  assert(not retired, "terminal EACCES is not ENOTEMPTY")
end

local function test_cleanup_error_is_not_contention()
  local root = scratch("ENOENT-cleanup")
  local path = fs.join(root, "writer.lock")
  assert(lockdir.try_acquire(path, "A").state == "owned")
  local original_move = fs.move
  local candidate = ""
  fs.move = function(src: string, dst: string): boolean, string
    local ok, err = original_move(src, dst)
    assert(not ok, "existing owner makes publication fail")
    candidate = src
    assert(fs.set_mode(candidate, fs.octal("500")))
    return ok, err
  end
  local called, got = pcall(lockdir.try_acquire, path, "B")
  fs.move = original_move
  assert(called and got.state == "error", "cleanup EACCES is not busy")
  assert(fs.is_dir(candidate), "reported cleanup error leaves only private candidate")
  assert(fs.set_mode(candidate, fs.octal("700")))
end
