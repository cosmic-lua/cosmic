#!/usr/bin/env cosmic
local m = require("cosmic.quicksand.box.merge")

local function test_scalar_later_wins()
  local out = m.merge({hostname = "a", cwd = "/x"}, {hostname = "b"})
  assert(out.hostname == "b", "got: " .. tostring(out.hostname))
  assert(out.cwd == "/x", "cwd preserved")
end
test_scalar_later_wins()

local function test_scalar_nil_is_noop()
  local out = m.merge({hostname = "a"}, {hostname = nil, cwd = "/x"})
  assert(out.hostname == "a")
  assert(out.cwd == "/x")
end
test_scalar_nil_is_noop()

local function test_list_concat_dedupe()
  local out = m.merge(
    {fs = {ro = {"/a", "/b"}}},
    {fs = {ro = {"/b", "/c"}}})
  local ro = (out.fs as {string: any}).ro as {string} -- cast: from any
  assert(#ro == 3, "got: " .. tostring(#ro))
  assert(ro[1] == "/a" and ro[2] == "/b" and ro[3] == "/c", "order+dedupe wrong")
end
test_list_concat_dedupe()

local function test_list_first_seen_wins_ordering()
  -- Order preserved from left; duplicates from right dropped.
  local out = m.merge(
    {fs = {rw = {"/tmp", "/work"}}},
    {fs = {rw = {"/work", "/cache"}}})
  local rw = (out.fs as {string: any}).rw as {string} -- cast: from any
  assert(rw[1] == "/tmp" and rw[2] == "/work" and rw[3] == "/cache")
end
test_list_first_seen_wins_ordering()

local function test_map_per_key_later_wins()
  local out = m.merge(
    {net = {allow = {["a:80"] = {}, ["b:80"] = {type = "bearer", token = "x"}}}},
    {net = {allow = {["b:80"] = {}, ["c:80"] = {}}}})
  local allow = (out.net as {string: any}).allow as {string: any} -- cast: from any
  assert(allow["a:80"] ~= nil, "a:80 kept")
  assert(allow["b:80"] ~= nil, "b:80 kept")
  assert(allow["c:80"] ~= nil, "c:80 added")
  -- Later wins per key — b:80 should be the empty table, not the bearer one.
  local b = allow["b:80"] as {string: any}
  assert(b.type == nil, "b:80 should be overwritten, got type=" .. tostring(b.type))
end
test_map_per_key_later_wins()

local function test_env_set_and_keep()
  local out = m.merge(
    {env = {keep = {"PATH", "HOME"}, set = {FOO = "1"}}},
    {env = {keep = {"HOME", "TERM"}, set = {FOO = "2", BAR = "3"}}})
  local env = out.env as {string: any}
  local keep = env.keep as {string}
  assert(#keep == 3, "keep dedupe failed: " .. tostring(#keep))
  local s = env.set as {string: string}
  assert(s.FOO == "2", "later wins")
  assert(s.BAR == "3")
end
test_env_set_and_keep()

local function test_nested_proc_scalars()
  local out = m.merge(
    {proc = {uid = 1000, gid = 1000, pledge = "stdio"}},
    {proc = {uid = 2000}})
  local p = out.proc as {string: any}
  assert(p.uid == 2000, "later wins")
  assert(p.gid == 1000, "gid preserved")
  assert(p.pledge == "stdio", "pledge preserved")
end
test_nested_proc_scalars()

local function test_nil_table_skipped()
  local a: {string: any} = {hostname = "x"}
  local out = m.merge(a, nil, {cwd = "/y"})
  assert(out.hostname == "x")
  assert(out.cwd == "/y")
end
test_nil_table_skipped()

local function test_returns_fresh_table()
  local a: {string: any} = {fs = {ro = {"/usr"}}}
  local out = m.merge(a)
  local ra = (a.fs as {string: any}).ro as {string}
  local ro = (out.fs as {string: any}).ro as {string}
  table.insert(ro, "/etc")
  assert(#ra == 1, "source list mutated: " .. tostring(#ra))
end
test_returns_fresh_table()

local function test_empty_merge()
  local out = m.merge()
  assert(type(out) == "table")
  assert(next(out) == nil, "empty merge should return empty table")
end
test_empty_merge()
