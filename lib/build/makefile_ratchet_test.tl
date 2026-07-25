#!/usr/bin/env cosmic
-- The no-shell and host-grant ratchets (#756 items 1/2), split from
-- makefile_test so neither file fights the 500-line cap. Consumes the
-- same pre-generated make fixtures via TEST_DIR.

local check = require("cosmic.check")
local fs = require("cosmic.fs")

local TEST_DIR = os.getenv("TEST_DIR")

local function read_database(): string
  local filepath = fs.join(TEST_DIR, "database.out")
  local text = check.must(fs.read(filepath), "failed to read " .. filepath)
  return (text:gsub("exit:%d+%s*$", ""))
end

-- #756 item 2: the no-shell default and its two ratchets. The database
-- fixture renders target-specific variables as "<owner>: VAR := value"
-- lines and pattern-specific ones as a "<pattern> :" header followed by
-- "# VAR := value" comment lines (blank line ends the block); the
-- parser below reads both shapes plus the uncommented global.
local record VarOverrides
  global: string
  owners: {string: string}
end

--- @param db string The database.out fixture text
--- @param var string Variable name as a Lua pattern (e.g. "%.UNVEIL")
--- @return VarOverrides Global value and per-owner override values
local function parse_var_overrides(db: string, var: string): VarOverrides
  local owners: {string: string} = {}
  local global_value: string = nil
  local pattern: string = nil
  for line in (db .. "\n"):gmatch("([^\n]*)\n") do
    local header = line:match("^(%S+) :$")
    if header then
      pattern = header
    elseif line == "" then
      pattern = nil
    else
      local owner, value = line:match("^([^#%s][^:]*): " .. var .. " := (.*)$")
      if owner then
        owners[owner] = value:match("^(.-)%s*$")
      elseif pattern then
        local pvalue = line:match("^# " .. var .. " := (.*)$")
        if pvalue then
          owners[pattern] = pvalue:match("^(.-)%s*$")
        end
      end
      local gvalue = line:match("^" .. var .. " := (.*)$")
      if gvalue then
        global_value = gvalue:match("^(.-)%s*$")
      end
    end
  end
  return {global = global_value, owners = owners}
end

local poison_shell < const > = "/dev/null/enoshell"
local real_shell < const > = "/bin/bash"

-- The complete set of rules allowed a real shell. Growing this list is
-- a design decision (#756 item 2): a new entry needs a "Shell
-- exception" comment at the rule stating why the recipe cannot be a
-- shell-free argv line (or a driver/CLI conversion instead).
local real_shell_allowed: {string} = {
  "doc-publish", -- SOURCE_SHA guard + git publishing
  "env-probe", -- shows the env a recipe shell sees
  "env-probe-clamped", -- .ENV canary probe (#756 item 5)
  "o/bin/ape", -- APE loader extraction IS the stub flow
  "o/ci-selftest-launder-summary.txt", -- deliberately laundering fixture
  "o/cosmic/version.lua", -- git describe interpolation
  "o/lib/build/make/ci-launder.out", -- nested-make fixture
  "o/lib/build/make/database.out", -- nested-make fixture
  "o/lib/build/make/dry-run.out", -- nested-make fixture
  "o/lib/build/make/env-clamp.out", -- nested-make fixture
  "o/lib/build/make/only-database.out", -- nested-make fixture
  "o/sandbox-canary/probe.got", -- out-of-grant write attempt
  "perf-bin", -- COSMO_LUA guard
  "regen-types", -- dev regen loop
  "sandbox-canary", -- verdict branching
}

-- test: the global SHELL is poisoned, every real-shell override is on
-- the allowlist above, and every allowlist entry still exists (a stale
-- entry means the exception was retired — remove it here too).
local function test_no_shell_default_ratchet()
  local db = read_database()
  local sh = parse_var_overrides(db, "SHELL")
  assert(sh.global == poison_shell,
    "global SHELL must be the poison, got: " .. tostring(sh.global))
  local allowed: {string: boolean} = {}
  for _, owner in ipairs(real_shell_allowed) do
    allowed[owner] = true
  end
  local problems: {string} = {}
  for owner, value in pairs(sh.owners) do
    if value ~= poison_shell then
      if not allowed[owner] then
        problems[#problems + 1] = owner .. " overrides SHELL to " .. value ..
        " but is not on the exception allowlist"
      elseif value ~= real_shell then
        problems[#problems + 1] = owner .. " overrides SHELL to unexpected " .. value
      end
    end
  end
  for _, owner in ipairs(real_shell_allowed) do
    local value = sh.owners[owner]
    if not value or value == poison_shell then
      problems[#problems + 1] = owner ..
      " is allowlisted but carries no real-shell override (stale entry)"
    end
  end
  assert(#problems == 0,
    "shell-exception ratchet:\n  " .. table.concat(problems, "\n  "))
end
test_no_shell_default_ratchet()

-- The complete set of rules whose .UNVEIL carries the host-exec grant
-- set ($(unveil_hostx), marker rx:/usr). Same ratchet contract: a new
-- carrier is a design decision, not a default (#756 items 2/4).
local hostx_marker < const > = "rx:/usr"
local hostx_allowed: {string} = {
  "doc-publish", -- unveil_run (git, network)
  "o/%.tl.benchmark.got", -- unveil_run test lane
  "o/%.tl.example.got", -- unveil_test lane
  "o/%.tl.test.got", -- unveil_test lane
  "o/coverage/%.tl.test.got", -- unveil_test lane
  "o/coverage/lib/build/help_test.tl.test.got", -- unveil_test + Makefile
  "o/coverage/lib/cosmic/teal_config_test.tl.test.got", -- unveil_test + tlconfig
  "o/coverage/lib/cosmic/tty_test.tl.test.got", -- unveil_test + pty devs
  "o/lib/build/help_test.tl.test.got", -- unveil_test + Makefile
  "o/lib/cosmic/teal_config_test.tl.test.got", -- unveil_test + tlconfig
  "o/lib/cosmic/tty_test.tl.test.got", -- unveil_test + pty devs
  "o/sandbox-canary/probe.got", -- canary needs its shell
  "perf", -- unveil_test lane
  "perf-baseline", -- unveil_test lane
  "perf-bin", -- unveil_test lane
  "perf-compare", -- unveil_test lane
  "perf-selfcheck", -- unveil_test lane
}

-- test: the global .UNVEIL carries no host-exec grants, and the set of
-- rules that do is exactly the allowlist above, both directions.
local function test_hostx_ratchet()
  local db = read_database()
  local uv = parse_var_overrides(db, "%.UNVEIL")
  assert(uv.global, "expected a global .UNVEIL in the database")
  assert(not uv.global:find(hostx_marker, 1, true),
    "global .UNVEIL must not carry the host-exec set, got: " .. uv.global)
  local allowed: {string: boolean} = {}
  for _, owner in ipairs(hostx_allowed) do
    allowed[owner] = true
  end
  local problems: {string} = {}
  for owner, value in pairs(uv.owners) do
    if value:find(hostx_marker, 1, true) and not allowed[owner] then
      problems[#problems + 1] = owner .. " carries " .. hostx_marker ..
      " but is not on the hostx allowlist"
    end
  end
  for _, owner in ipairs(hostx_allowed) do
    local value = uv.owners[owner]
    if not value or not value:find(hostx_marker, 1, true) then
      problems[#problems + 1] = owner ..
      " is allowlisted for hostx but carries no " .. hostx_marker ..
      " grant (stale entry)"
    end
  end
  assert(#problems == 0,
    "hostx ratchet:\n  " .. table.concat(problems, "\n  "))
end
test_hostx_ratchet()

-- The complete set of rule families enforced under real Landlock, and
-- the rules that deliberately opt out (#729, whose family-by-family
-- flip landed in #739/#740/#742/#743/#745).
--
-- Losing enforcement is SILENT: drop a `.SANDBOXED := 1` and every
-- grant set is still a superset of what the recipe needs, so nothing
-- fails and CI stays green — the build just stops enforcing. Nothing
-- else in the tree notices, which is what makes this a ratchet rather
-- than documentation. The canary (#716/#724) proves the MECHANISM
-- works; this proves it is still switched on where it was switched on.
local sandboxed_enforced: {string} = {
  "o/%.format.got", -- format checks (#742)
  "o/%.lint.got", -- lint (#740)
  "o/%.lua", -- compile family (#739)
  "o/%.teal.got", -- type checks (#742)
  "o/%.tl.example.got", -- examples (#745)
  "o/%.tl.test.got", -- test lane (#743)
  "o/%/.fetched", -- fetch (#740)
  "o/%/.staged", -- stage (#740)
  "o/benchmark-summary.txt", -- reporter summary (#740)
  "o/coverage/%.tl.test.got", -- coverage test lane (#743)
  "o/example-summary.txt", -- reporter summary (#740)
  "o/format-summary.txt", -- reporter summary (#740)
  "o/lint-summary.txt", -- reporter summary (#740)
  "o/sandbox-canary/probe.got", -- the canary itself (#716/#724)
  "o/teal-summary.txt", -- reporter summary (#740)
}

-- Opting out is a design decision with a reason recorded at the rule.
-- The benchmark family is deliberately absent from BOTH lists: it keeps
-- annotations without enforcement because no CI lane runs benchmarks,
-- and enforcing grants nothing exercises is not a falsifiable gate. It
-- flips when a lane runs it.
local sandboxed_exempt: {string} = {
  "o/cosmic/version.lua", -- reads .git; silent-fallback hazard
  "o/coverage/lib/cosmic/quicksand/box/run_test.tl.test.got",
  "o/coverage/lib/cosmic/quicksand/netns_test.tl.test.got",
  "o/coverage/lib/cosmic/quicksand/proxy_test.tl.test.got",
  "o/enforce/lib/cosmic/landlock_test.tl.test.got", -- self-sandboxing lane
  "o/enforce/lib/cosmic/pledge_test.tl.test.got", -- self-sandboxing lane
  "o/enforce/lib/cosmic/unveil_test.tl.test.got", -- self-sandboxing lane
  "o/lib/cosmic/quicksand/box/run_test.tl.test.got", -- unshare: no promise
  "o/lib/cosmic/quicksand/netns_example.tl.example.got",
  "o/lib/cosmic/quicksand/netns_test.tl.test.got",
  "o/lib/cosmic/quicksand/proxy_example.tl.example.got",
  "o/lib/cosmic/quicksand/proxy_test.tl.test.got",
}

--- Compare a set of owners against an allowlist in both directions.
--- @param actual {string: boolean} Owners observed in the database
--- @param allowed {string} The declared allowlist
--- @param label string What the value means, for the failure message
--- @param problems {string} Accumulator for failures
local function diff_owners(actual: {string: boolean}, allowed: {string},
                           label: string, problems: {string})
  local declared: {string: boolean} = {}
  for _, owner in ipairs(allowed) do
    declared[owner] = true
  end
  for owner in pairs(actual) do
    if not declared[owner] then
      problems[#problems + 1] = owner .. " is " .. label ..
      " but is not on the list"
    end
  end
  for _, owner in ipairs(allowed) do
    if not actual[owner] then
      problems[#problems + 1] = owner .. " is listed as " .. label ..
      " but no longer is (stale entry, or enforcement was lost)"
    end
  end
end

-- test: the enforced and exempt sets are exactly the lists above.
local function test_sandboxed_ratchet()
  local db = read_database()
  local sb = parse_var_overrides(db, "%.SANDBOXED")
  local ones: {string: boolean} = {}
  local zeros: {string: boolean} = {}
  for owner, value in pairs(sb.owners) do
    if value == "1" then
      ones[owner] = true
    elseif value == "0" then
      zeros[owner] = true
    end
  end
  assert(next(ones) ~= nil, "expected some enforced rules in the database")
  local problems: {string} = {}
  diff_owners(ones, sandboxed_enforced, "sandbox-enforced", problems)
  diff_owners(zeros, sandboxed_exempt, "sandbox-exempt", problems)
  assert(#problems == 0,
    ".SANDBOXED ratchet:\n  " .. table.concat(problems, "\n  "))
end
test_sandboxed_ratchet()

-- Static no-shell gate (#756 cleanup): the poisoned SHELL only trips
-- when a rule RUNS, and cold rules can sit broken unnoticed (the
-- since-retired stage1 broke at the #759 flip and was found days later
-- in #760 — exactly the class this catches). Scan every recipe in
-- the database dump: a rule not on the shell-exception allowlist must
-- carry no shell syntax in its recipe text. The dump is UNEXPANDED, so
-- a $(var) hiding metacharacters still needs the runtime poison — this
-- catches the quoted-literal class statically, before first run.
local function test_recipes_without_exception_are_shell_free()
  local db = read_database()
  local allowed: {string: boolean} = {}
  for _, owner in ipairs(real_shell_allowed) do
    allowed[owner] = true
  end
  local problems: {string} = {}
  local owner: string = nil
  local in_recipe = false
  for line in (db .. "\n"):gmatch("([^\n]*)\n") do
    if in_recipe and line:sub(1, 1) ~= "\t" then
      in_recipe = false
    end
    if in_recipe then
      -- $$ reaches the shell as a live $; flag it before stripping the
      -- make-side syntax ($(...) refs and $<-style automatics), whose
      -- <>|() are make's, not the shell's
      local bad = line:find("%$%$")
      if not bad then
        local stripped = line
        repeat
          local next_pass, n = stripped:gsub("%$%b()", "")
          stripped = next_pass
        until n == 0
        stripped = stripped:gsub("%$[<@*^?%%+|]", "")
        bad = stripped:find("[\"'|;&<>`]")
      end
      if bad and owner and not allowed[owner] then
        problems[#problems + 1] = owner .. ": " .. line:sub(2, 120)
      end
    elseif line:find("# Not a target", 1, true) then
      owner = nil
    elseif line:find("recipe to execute", 1, true) then
      in_recipe = true
    else
      local target = line:match("^([^#%s][^:]*):")
      if target then
        owner = target
      end
    end
  end
  assert(#problems == 0,
    "shell syntax in recipes without a shell exception:\n  " ..
    table.concat(problems, "\n  "))
end
test_recipes_without_exception_are_shell_free()
