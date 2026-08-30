#!/usr/bin/env cosmic
-- Tests for the sqltext scan: the one question it answers is "is
-- there a second statement after a top-level `;`?", and the shapes
-- below are the ones a lexical scan gets wrong — semicolons inside
-- strings, comments, bracketed identifiers, and the single DDL shape
-- that embeds statements of its own, a CREATE TRIGGER body.

local sqltext = require("cosmic.sqlite.sqltext")

local multi = sqltext.has_multiple_statements

local function test_single_statements_pass()
  assert(not multi("SELECT 1"), "bare statement")
  assert(not multi("SELECT 1;"), "trailing semicolon is one statement")
  assert(not multi("SELECT 1; -- trailing comment"), "comment after semi")
  assert(not multi("SELECT 1; /* block */"), "block comment after semi")
  assert(not multi("SELECT ';'"), "semicolon in a string")
  assert(not multi("SELECT \"a;b\""), "semicolon in a quoted identifier")
  assert(not multi("SELECT [a;b] FROM t"), "semicolon in a bracket")
  assert(not multi("SELECT 1 -- ; not a statement\n+ 1"), "semi in line comment")
end

local function test_second_statements_are_caught()
  assert(multi("SELECT 1; SELECT 2"), "two statements")
  assert(multi("SELECT 1;;SELECT 2"), "double semicolon")
  assert(multi("SELECT 1; 'even a string'"), "a string is content too")
end

-- A CREATE TRIGGER body is ONE prepared statement whose semicolons
-- are internal: sqlite3_prepare compiles the whole trigger, so the
-- scan must not refuse it as multi-statement.
local TRIGGER = [[
CREATE TRIGGER trg AFTER INSERT ON t
BEGIN
  UPDATE t SET n = n + 1;
  INSERT INTO log VALUES (new.id);
END
]]

local function test_a_trigger_body_is_one_statement()
  assert(not multi(TRIGGER), "internal semicolons are not statements")
  assert(not multi(TRIGGER .. ";"), "trailing semicolon after END")
  assert(not multi("CREATE TEMP TRIGGER trg AFTER INSERT ON t " ..
      "BEGIN UPDATE t SET n = 1; END"), "TEMP between CREATE and TRIGGER")
  assert(not multi("create trigger trg after insert on t " ..
      "begin update t set n = 1; end"), "keywords in lower case")
  assert(not multi("CREATE TRIGGER trg AFTER INSERT ON t BEGIN " ..
      "UPDATE t SET n = CASE WHEN n > 0 THEN 1 ELSE 0 END; END"),
    "a CASE inside the body owns its own END")
  assert(not multi("CREATE /* c */ TRIGGER trg -- note\n AFTER INSERT ON t " ..
      "BEGIN UPDATE t SET n = 1; END"),
    "comments between the keywords do not split the arming sequence")
end

local function test_a_trigger_plus_more_is_still_caught()
  assert(multi(TRIGGER .. "; SELECT 1"), "statement after the trigger")
  assert(multi("SELECT 1; " .. TRIGGER), "statement before the trigger")
end

-- The recognizer arms only on the exact CREATE [TEMP] TRIGGER
-- sequence, and only a real keyword closes a body — identifiers that
-- merely contain the words, and quoted or bracketed spellings, never
-- count.
local function test_lookalikes_do_not_confuse_the_scan()
  assert(multi("CREATE TABLE trigger_log (a); SELECT 1"),
    "a trigger-shaped identifier does not arm")
  assert(multi("CREATE TABLE x (trigger int); SELECT 1"),
    "a column named trigger does not arm")
  assert(multi("SELECT CASE WHEN 1 THEN 2 ELSE 3 END; SELECT 1"),
    "CASE outside a trigger body owns no semicolons")
  assert(multi("CREATE TRIGGER trg AFTER INSERT ON t BEGIN " ..
      "UPDATE t SET x = \"end\"; UPDATE [end] SET y = 1; END; SELECT 1"),
    "a quoted or bracketed end never closes the body")
end

-- Ambiguity stays a refusal: a semicolon before the body opens is
-- top-level (it is not legal trigger SQL either way), so the scan
-- errs toward the safe answer.
local function test_a_semicolon_before_begin_counts()
  assert(multi("CREATE TRIGGER trg; SELECT 1"),
    "a semicolon between TRIGGER and BEGIN is top-level")
end

-- A body that never closes is the deliberate exception: the depth
-- never returns to zero, so the scan answers false whatever follows.
-- The property still holds because sqlite3_prepare refuses the
-- incomplete trigger outright — nothing runs, rather than a prefix
-- running silently — and this pins the division of labor on the
-- record.
local function test_an_unclosed_body_defers_to_prepare()
  assert(not multi("CREATE TRIGGER t AFTER INSERT ON x " ..
      "BEGIN SELECT 1; DROP TABLE users"),
    "past an unclosed BEGIN every semicolon reads as internal")
end
