#!/usr/bin/env cosmic
-- The `cast-justify` rule. An `as` cast passes either by matching an
-- allowlisted kind in `_build/casts_kinds.tl` or by carrying a
-- `-- cast: <reason>`. The reason is looked for over the cast's whole
-- extent, because the convention places it beside the `as` and a cast
-- whose expression wraps carries that `as` below the line the
-- diagnostic anchors at.

local cast_lint = require("_cli.cast_lint")
local check = require("cosmic.check")
local style = require("_tool.lint")

local type Diagnostic = style.Diagnostic

--- Run the rule over `lines` as `lint_file` does, at a path no
--- allowlisted kind's `where` reaches.
local function diagnose(lines: {string}): {Diagnostic}
  return cast_lint.check_cast_justification("cosmic/other/file.tl",
    table.concat(lines, "\n") .. "\n", lines)
end

-- A cast whose expression wraps: the `as` -- and so the reason an
-- author writes beside it -- is on line 4, while the diagnostic
-- anchors at line 2 where the expression starts.
local WRAPPED < const >: {string} = {
  "local reply: {string: any} = {}",
  "local x = {status = reply.status, headers = {},",
  "  body = reply.body}",
  "  as {string: string}",
}

--- `WRAPPED` with `trailer` appended to its `as` line.
--- @param trailer string Text to append, `""` for none
--- @return {string}
local function wrapped_with(trailer: string): {string}
  local out: {string} = {}
  for i, line in ipairs(WRAPPED) do
    out[i] = line
  end
  out[#out] = out[#out] .. trailer
  return out
end

-- A cast that structurally matches an allowlisted kind in
-- `_build/casts_kinds.tl` needs no `-- cast:` comment at all: the
-- "userdata boundary" kind's pattern (`$X as $T:..`) scoped to
-- `cosmic/fs/ops.tl` claims this site on shape alone.
local function test_cast_justify_allowlisted_kind_passes()
  local lines = {"local info: any = {}", "local x = info as any"}
  local diags = cast_lint.check_cast_justification("cosmic/fs/ops.tl",
    table.concat(lines, "\n") .. "\n", lines)
  check.equal(#diags, 0, "an allowlisted cast needs no comment")
end

-- The same cast, in a file no kind's `where` reaches, still needs its
-- comment: the allowlist narrows what is exempt, it does not widen
-- what is allowed.
local function test_cast_justify_unmatched_cast_fails()
  local diags = diagnose({"local info: any = {}", "local x = info as any"})
  check.equal(#diags, 1, "an uncommented cast still fails")
  check.equal(diags[1].rule, "cast-justify")
end

local function test_cast_justify_trailing_reason_passes()
  local diags = diagnose({
      "local info: any = {}",
      "local x = info as any -- cast: the probe's whole point",
    })
  check.equal(#diags, 0, "a trailing reason justifies a single-line cast")
end

local function test_cast_justify_reason_on_the_line_above_passes()
  local diags = diagnose({
      "local info: any = {}",
      "-- cast: 90 columns will not fit this one",
      "local x = info as any",
    })
  check.equal(#diags, 0, "the line above justifies a single-line cast")
end

-- The defect this file's span lookup exists for: the reason trails the
-- `as` on line 4, three lines below the anchor.
local function test_cast_justify_multi_line_reason_on_the_as_line_passes()
  local diags = diagnose(wrapped_with(" -- cast: a fabricated response"))
  check.equal(#diags, 0, "the reason beside the `as` justifies the cast")
end

local function test_cast_justify_multi_line_reason_above_the_start_passes()
  local above: {string} = {}
  for _, line in ipairs(wrapped_with("")) do
    if #above == 1 then
      above[2] = "-- cast: 90 columns will not fit this one"
    end
    above[#above + 1] = line
  end
  check.equal(#diagnose(above), 0,
    "the line above the expression still justifies a wrapped cast")
end

-- The guard still refuses: no reason anywhere in the span, and the
-- diagnostic anchors where it always did, at the expression's start.
local function test_cast_justify_multi_line_without_a_reason_fails()
  local diags = diagnose(wrapped_with(""))
  check.equal(#diags, 1, "a wrapped cast with no reason is unjustified")
  check.equal(diags[1].rule, "cast-justify")
  check.equal(diags[1].line, 2, "the anchor is the expression's first line")
end

-- A bare marker with nothing after it justifies nothing, on the `as`
-- line of a wrapped cast as anywhere else.
local function test_cast_justify_multi_line_bare_marker_fails()
  local diags = diagnose(wrapped_with(" -- cast:"))
  check.equal(#diags, 1, "a reasonless `-- cast:` justifies nothing")
end
