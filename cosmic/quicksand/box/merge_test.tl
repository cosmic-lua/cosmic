#!/usr/bin/env cosmic
local m = require("cosmic.quicksand.box.merge")
local types = require("cosmic.quicksand.types")

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
  local ro = out.fs.ro
  assert(#ro == 3, "got: " .. tostring(#ro))
  assert(ro[1] == "/a" and ro[2] == "/b" and ro[3] == "/c", "order+dedupe wrong")
end
test_list_concat_dedupe()

local function test_list_first_seen_wins_ordering()
  -- Order preserved from left; duplicates from right dropped.
  local out = m.merge(
    {fs = {rw = {"/tmp", "/work"}}},
    {fs = {rw = {"/work", "/cache"}}})
  local rw = out.fs.rw
  assert(rw[1] == "/tmp" and rw[2] == "/work" and rw[3] == "/cache")
end
test_list_first_seen_wins_ordering()

local function test_map_per_key_later_wins()
  local out = m.merge(
    {net = {allow = {["a:80"] = {}, ["b:80"] = {type = "bearer", token = "x"}}}},
    {net = {allow = {["b:80"] = {}, ["c:80"] = {}}}})
  local allow = out.net.allow
  assert(allow["a:80"] ~= nil, "a:80 kept")
  assert(allow["b:80"] ~= nil, "b:80 kept")
  assert(allow["c:80"] ~= nil, "c:80 added")
  -- Later wins per key — b:80 should be the empty table, not the bearer one.
  local b = allow["b:80"]
  assert(b.type == nil, "b:80 should be overwritten, got type=" .. tostring(b.type))
end
test_map_per_key_later_wins()

local function test_env_set_and_keep()
  local out = m.merge(
    {env = {keep = {"PATH", "HOME"}, set = {FOO = "1"}}},
    {env = {keep = {"HOME", "TERM"}, set = {FOO = "2", BAR = "3"}}})
  local env = out.env
  local keep = env.keep
  assert(#keep == 3, "keep dedupe failed: " .. tostring(#keep))
  local s = env.set
  assert(s.FOO == "2", "later wins")
  assert(s.BAR == "3")
end
test_env_set_and_keep()

local function test_nested_proc_scalars()
  local out = m.merge(
    {proc = {uid = 1000, gid = 1000, no_new_privs = true}},
    {proc = {uid = 2000}})
  local p = out.proc
  assert(p.uid == 2000, "later wins")
  assert(p.gid == 1000, "gid preserved")
  assert(p.no_new_privs == true, "no_new_privs preserved")
end
test_nested_proc_scalars()

-- sys is a section like fs: scalars in it overlay per key.
local function test_nested_sys_scalars()
  local out = m.merge(
    {sys = {promises = "stdio rpath"}},
    {sys = {exec_promises = "stdio"}})
  local s = out.sys
  assert(s.promises == "stdio rpath", "promises preserved")
  assert(s.exec_promises == "stdio", "exec_promises overlay applied")
end
test_nested_sys_scalars()

local function test_nil_table_skipped()
  local a: types.BoxOptions = {hostname = "x"}
  local out = m.merge(a, nil, {cwd = "/y"})
  assert(out.hostname == "x")
  assert(out.cwd == "/y")
end
test_nil_table_skipped()

local function test_returns_fresh_table()
  local a: types.BoxOptions = {fs = {ro = {"/usr"}}}
  local out = m.merge(a)
  local ra = a.fs.ro
  local ro = out.fs.ro
  table.insert(ro, "/etc")
  assert(#ra == 1, "source list mutated: " .. tostring(#ra))
end
test_returns_fresh_table()

local function test_empty_merge()
  local out = m.merge()
  assert(type(out) == "table")
  -- A record with fields of differing types is not a valid map, so the
  -- emptiness check needs the map view the merge walk itself runs on.
  local as_map = out as {string: any} -- cast: record inspected as map
  assert(next(as_map) == nil, "empty merge should return empty table")
end
test_empty_merge()

-- Security-policy opt-outs are boolean `false`, and `a and a[k] or nil`
-- silently collapses that to nil. These three cases pin the fix.

local function test_scalar_false_survives_merge()
  local out = m.merge({pid_ns = false})
  assert(out.pid_ns == false, "got: " .. tostring(out.pid_ns))
end
test_scalar_false_survives_merge()

local function test_scalar_false_in_b_overrides_true_in_a()
  local out = m.merge(
    {net = {proxy_env = true}},
    {net = {proxy_env = false}})
  local net = out.net
  assert(net.proxy_env == false, "got: " .. tostring(net.proxy_env))
end
test_scalar_false_in_b_overrides_true_in_a()

local function test_scalar_false_in_a_survives_absent_b_key()
  local out = m.merge(
    {proc = {no_new_privs = false}},
    {proc = {uid = 1000}})
  local proc = out.proc
  assert(proc.no_new_privs == false, "got: " .. tostring(proc.no_new_privs))
  assert(proc.uid == 1000, "uid preserved")
end
test_scalar_false_in_a_survives_absent_b_key()

local function test_proc_keep_caps_merges_as_list()
  -- Regression: absent from the list schema, keep_caps fell into the
  -- recursive branch and merged BY INDEX — {CAP_A,CAP_B} over {CAP_C}
  -- yielded {CAP_C,CAP_B}, silently retaining a capability the overlay
  -- never granted. It concatenates and dedupes like every other list.
  local out = m.merge(
    {proc = {keep_caps = {"CAP_NET_BIND_SERVICE", "CAP_CHOWN"}}},
    {proc = {keep_caps = {"CAP_CHOWN", "CAP_SETUID"}}})
  local caps = out.proc.keep_caps
  assert(#caps == 3, "got: " .. tostring(#caps))
  assert(caps[1] == "CAP_NET_BIND_SERVICE" and caps[2] == "CAP_CHOWN"
    and caps[3] == "CAP_SETUID", "order+dedupe wrong for keep_caps")
end
test_proc_keep_caps_merges_as_list()

local function test_unknown_key_merges_as_scalar()
  -- Unknown keys merge as scalars, which is what makes a new policy
  -- field forward-compatible. BoxOptions cannot spell one, so the
  -- rule is reachable only the way an untyped caller reaches it.
  local a: {string: any} = {future_knob = "a"}
  local b: {string: any} = {future_knob = "b"}
  -- cast: forward-compat key BoxOptions does not declare
  local out = m.merge(a as types.BoxOptions, b as types.BoxOptions)
  local view = out as {string: any} -- cast: record inspected as map
  assert(view.future_knob == "b", "got: " .. tostring(view.future_knob))
end
test_unknown_key_merges_as_scalar()
