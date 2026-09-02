#!/usr/bin/env cosmic
-- The owner rule at the WRITE: `new --repo` and `set --repo` refuse a
-- slug under a foreign owner before it lands, so stale data stops
-- entering the board, and accept it when the spec — the one being
-- filed, or the one the item already has — names it under
-- `## Access`. The same rule read back at the ready bar, for a value
-- written before it existed, is in `_work/gitgate_test.tl`; this is
-- the sibling `_work/gitgraph_test.tl`'s file cap sends the graph
-- verbs' half to.

local check = require("cosmic.check")
local fs = require("cosmic.fs")
local fixture = require("_work.fixture")
local gitspec = require("_work.gitspec")
local graph = require("_work.gitgraph")
local owner = require("_work.gitowner")
local store = require("_work.store")

local ACCESS_SPEC < const > = fixture.READY_SPEC
.. "## Access\n- whilp/cosmopolitan (the fork the diff deliberately targets)\n"

--- A board that reads its origin as `cosmic-lua/cosmic`, with one
--- placed root to file under.
local function github_board(name: string): store.Store, string
  local s = fixture.init_shared("write-" .. name)
  fixture.github_origin(s, "cosmic-lua/cosmic")
  local root = fixture.root_with_leaf(s)
  return s, root
end

--- The ids on a board, for the set difference a `new` is read from.
local function ids(s: store.Store): {string: boolean}
  local out: {string: boolean} = {}
  for _, i in ipairs(check.must(store.list(s))) do
    out[i.id] = true
  end
  return out
end

--- Capture what a verb prints, so a test can pin its verdict line.
local function capture(f: function(): integer): integer, string
  local lines: {string} = {}
  local real = _G.print
  _G.print = function(...: any)
    local parts: {string} = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    lines[#lines + 1] = table.concat(parts, "\t")
  end
  local ok, result = pcall(f)
  _G.print = real
  if not ok then
    error(result, 0)
  end
  -- cast: pcall erases the callee's return type; f is typed to return integer
  return result as integer, table.concat(lines, "\n")
end

-- The board's owner is read from the origin's https form.
local function test_board_owner_is_the_origins_owner()
  local s = github_board("owner")
  assert(owner.board_owner(s) == "cosmic-lua", "got: "
    .. tostring(owner.board_owner(s)))
end

-- `new --repo` under a foreign owner is refused with the value and the
-- repair, and nothing is filed; the same owner as the board lands.
local function test_new_refuses_a_foreign_owner_repo()
  local s, root = github_board("new")
  local before = ids(s)
  local code, out = capture(function(): integer
      return graph.cmd_new(s, "a fork-side slice", root, nil, "whilp/cosmopolitan")
    end)
  assert(code ~= 0, "a foreign owner is refused")
  assert(out:find("REFUSED: repo: whilp/cosmopolitan", 1, true)
    and out:find("--repo cosmic-lua/cosmopolitan", 1, true),
    "the verdict names the value and the repair: " .. out)
  for id in pairs(ids(s)) do
    assert(before[id], "and nothing was filed: " .. id)
  end
  assert(graph.cmd_new(s, "a fork-side slice", root, nil,
      "cosmic-lua/cosmopolitan") == 0, "the board's own owner lands")
end

-- A `--spec-file` naming the slug under `## Access` is the escape at
-- file time: the item lands with the foreign repo, and its spec says why.
local function test_new_accepts_a_foreign_owner_the_spec_declares()
  local s, root = github_board("new-declared")
  local before = ids(s)
  assert(graph.cmd_new(s, "a fork-side slice", root, ACCESS_SPEC,
      "whilp/cosmopolitan") == 0, "a declared cross-owner repo lands")
  local filed: string = nil
  for id in pairs(ids(s)) do
    if not before[id] then filed = id end
  end
  assert(filed ~= nil and check.must(store.load(s, filed)).repo
    == "whilp/cosmopolitan", "with the field as given")
end

-- `set --repo` asks the same rule of the item's CURRENT spec: refused
-- bare, accepted once the spec names the slug.
local function test_set_refuses_a_foreign_owner_repo_until_declared()
  local s, root = github_board("set")
  local leaf = fixture.file_item(s, "a slice", root)
  local code, out = capture(function(): integer
      return graph.cmd_set(s, leaf, nil, "whilp/cosmopolitan", nil)
    end)
  assert(code ~= 0, "a foreign owner is refused")
  assert(out:find(("gitboard set %s --repo cosmic-lua/cosmopolitan")
      :format(leaf:sub(1, 8)), 1, true),
    "the verdict names the repair: " .. out)
  assert(check.must(store.load(s, leaf)).repo == "", "and nothing was written")
  local path = fs.join(fixture.tmpdir, "write-set-access.md")
  assert(fs.write(path, ACCESS_SPEC))
  assert(gitspec.cmd_spec(s, leaf, path) == 0)
  assert(graph.cmd_set(s, leaf, nil, "whilp/cosmopolitan", nil) == 0,
    "declared under the item's own spec, the field is accepted")
  assert(check.must(store.load(s, leaf)).repo == "whilp/cosmopolitan")
end

-- Local-only boards have no owner and the write is never refused —
-- which is also why every existing fixture is unchanged.
local function test_a_local_only_board_writes_any_repo()
  local s = fixture.init_state_repo("write-local")
  local root = fixture.file_item(s, "an outcome", "")
  assert(graph.cmd_new(s, "a slice", root, nil, "whilp/cosmopolitan") == 0,
    "no origin, no owner, no refusal")
end
