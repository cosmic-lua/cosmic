#!/usr/bin/env cosmic
-- A session's identity is what the board's whole review distance rests
-- on, so the resolver is pinned three ways: an explicit name always
-- wins, an omitted one is DERIVED from the environment in a fixed
-- source order, and a session the environment cannot name stays
-- anonymous rather than borrowing a shared default. The note is what a
-- verb prints so a derived identity is visible; it speaks only for the
-- derived case.

local check = require("cosmic.check")
local env = require("cosmic.env")
local session = require("_work.session")

-- Both known sources cleared, so a test sees only what it sets. The
-- runner's own environment may carry CLAUDE_CODE_SESSION_ID.
local function clear()
  for _, name in ipairs(session.SOURCES) do
    local _ok, _err = env.unset(name)
  end
end

local function test_explicit_name_wins()
  clear()
  check.must(env.set("GITBOARD_SESSION", "from-env"))
  local who, source = session.resolve("typed-in")
  assert(who == "typed-in", "explicit wins: " .. who)
  assert(source == "flag", "source names the flag: " .. source)
  clear()
end
test_explicit_name_wins()

local function test_derives_when_omitted()
  clear()
  check.must(env.set("CLAUDE_CODE_SESSION_ID", "sess-abc123"))
  for _, given in ipairs({"", "   "}) do
    local who, source = session.resolve(given == "" and nil or given)
    assert(who == "sess-abc123", "derived from env: " .. who)
    assert(source == "CLAUDE_CODE_SESSION_ID", "source names it: " .. source)
  end
  clear()
end
test_derives_when_omitted()

local function test_source_order_is_fixed()
  clear()
  check.must(env.set("GITBOARD_SESSION", "explicit-runner"))
  check.must(env.set("CLAUDE_CODE_SESSION_ID", "fallback-id"))
  local who, source = session.resolve(nil)
  assert(who == "explicit-runner", "GITBOARD_SESSION is consulted first: " .. who)
  assert(source == "GITBOARD_SESSION", "source: " .. source)
  clear()
end
test_source_order_is_fixed()

local function test_unnamed_stays_anonymous()
  clear()
  local who, source = session.resolve(nil)
  assert(who == "", "no source names it, so it is anonymous: '" .. who .. "'")
  assert(source == "none", "source: " .. source)
  -- An explicit empty string is the same as omitting.
  local who2 = session.resolve("")
  assert(who2 == "", "an empty flag is not a name either: '" .. who2 .. "'")
  clear()
end
test_unnamed_stays_anonymous()

local function test_value_used_verbatim()
  clear()
  -- Surrounding whitespace is trimmed (a shell heredoc leaves some),
  -- but the id itself is never shortened into a prettier prefix.
  check.must(env.set("GITBOARD_SESSION", "  claude/wizardly-rubin-74byv9  "))
  local who = session.resolve(nil)
  assert(who == "claude/wizardly-rubin-74byv9", "trimmed, not shortened: " .. who)
  clear()
end
test_value_used_verbatim()

local function test_note_speaks_only_for_derivation()
  assert(session.note("sess-abc", "CLAUDE_CODE_SESSION_ID")
    == "session sess-abc (from CLAUDE_CODE_SESSION_ID)",
    "a derived identity is announced")
  assert(session.note("typed-in", "flag") == "",
    "an explicit name needs no note")
  assert(session.note("", "none") == "",
    "an anonymous session has nothing to announce")
end
test_note_speaks_only_for_derivation()
