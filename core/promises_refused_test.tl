--- What `spawn`'s `promises` (core/process.h) refuses before anything
--- starts, as core/promises_child_test.tl holds a live child to the filter
--- they make: a promise no one keeps, and `nest` on a start that has no
--- root and pid namespace of its own to hold what it lets through. The
--- refusal is the argument check's, on every platform, and starts no
--- child, so it needs no sandbox.

local Test = require("cosmic.test")
local type raw_process = require("cosmic.internal.process")
local stand_in = require("build.stand_in")
-- Required, so the module whose loader is handed the raw table is of this
-- test's import closure, and the store has it to hand it from.
local type _ = require("cosmic.child")

--- Nothing is read beyond the closure: the stand-in is built in the
--- test's own directory and never started.
Test.policy{}

local type Searcher = function(string): any, any

--- The raw table the store's searcher hands `wrapper`'s loader.
local function raw_behind(wrapper: string): any
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher(wrapper)
    if type(loader) == "function" and type(extra) == "table" then return extra end
  end
  error(wrapper .. " is handed no raw table")
end

local process = raw_behind("cosmic.child") as raw_process -- cast: the table core/process.h declares

local function test_a_promise_no_one_keeps_is_refused_before_a_start(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  for _, bad in ipairs({ "inet", "" }) do
    local started = pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
      { promises = { bad } })
    assert(not started, bad .. " is no promise")
  end
  local numeric: any = { 1 }
  assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { promises = numeric as {string} }))
  local scalar: any = "fork"
  assert(not pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
    { promises = scalar as {string} }))
end

local function test_nest_is_a_promise_of_a_root_and_pid_namespace_of_its_own(tmp: string)
  local probe = assert(stand_in.build(tmp .. "/stand-in"))
  -- It lets signals reach any pid and files rest on mounts, which only a
  -- policy's root and pid namespace hold: no start without them keeps it.
  for _, sandbox in ipairs({ {}, { strict = true }, { unveil = { reads = { probe } } } }) do
    local sandboxed = sandbox as raw_process.Sandbox -- cast: each shape is a partial sandbox
    sandboxed.promises = { "nest" }
    local started, why = pcall(process.spawn, probe, { probe }, nil, nil, nil, nil, nil, false, nil,
      sandboxed)
    assert(not started and tostring(why):find("nest", 1, true), tostring(why))
  end
end
