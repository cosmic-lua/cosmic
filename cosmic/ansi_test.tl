--- Tests for cosmic.ansi.
local ansi = require("cosmic.ansi")
local env = require("cosmic.env")

local ESC = string.char(27)

local function test_color_wraps_with_fg_close()
  assert(ansi.red("x") == ESC .. "[31mx" .. ESC .. "[39m",
    "got: " .. ansi.red("x"):gsub(ESC, "\\e"))
  assert(ansi.color("x", "bright_cyan") == ESC .. "[96mx" .. ESC .. "[39m")
end
test_color_wraps_with_fg_close()

local function test_bg_wraps_with_bg_close()
  assert(ansi.bg("x", "red") == ESC .. "[41mx" .. ESC .. "[49m")
  assert(ansi.bg("x", "bright_white") == ESC .. "[107mx" .. ESC .. "[49m")
end
test_bg_wraps_with_bg_close()

local function test_attr_uses_specific_off_codes()
  assert(ansi.bold("x") == ESC .. "[1mx" .. ESC .. "[22m")
  assert(ansi.underline("x") == ESC .. "[4mx" .. ESC .. "[24m")
  assert(ansi.attr("x", "strikethrough") == ESC .. "[9mx" .. ESC .. "[29m")
end
test_attr_uses_specific_off_codes()

local function test_styles_compose_when_nested()
  -- The inner color close (39) must not end the outer bold, so the
  -- trailing text after the nested section stays bold.
  local nested = ansi.bold(ansi.red("err") .. " detail")
  assert(nested == ESC .. "[1m" .. ESC .. "[31merr" .. ESC .. "[39m"
    .. " detail" .. ESC .. "[22m",
    "got: " .. nested:gsub(ESC, "\\e"))
end
test_styles_compose_when_nested()

local function test_convenience_functions_match_generic_forms()
  assert(ansi.green("x") == ansi.color("x", "green"))
  assert(ansi.yellow("x") == ansi.color("x", "yellow"))
  assert(ansi.blue("x") == ansi.color("x", "blue"))
  assert(ansi.magenta("x") == ansi.color("x", "magenta"))
  assert(ansi.cyan("x") == ansi.color("x", "cyan"))
  assert(ansi.dim("x") == ansi.attr("x", "dim"))
end
test_convenience_functions_match_generic_forms()

local function test_strip_removes_all_sgr()
  local styled = ansi.bold(ansi.bg(ansi.red("a"), "blue") .. "b") .. "c"
  assert(ansi.strip(styled) == "abc", "got: " .. ansi.strip(styled))
  assert(ansi.strip("plain") == "plain")
  assert(ansi.strip(ansi.reset) == "")
  -- multi-parameter sequences are SGR too
  assert(ansi.strip(ESC .. "[1;31mx" .. ESC .. "[0m") == "x")
end
test_strip_removes_all_sgr()

local function test_strip_leaves_non_sgr_escapes()
  local cursor_up = ESC .. "[2A"
  assert(ansi.strip(cursor_up .. "x") == cursor_up .. "x")
end
test_strip_leaves_non_sgr_escapes()

local function test_strip_requires_csi_bracket()
  -- ESC without the "[" is not an SGR sequence and must pass through,
  -- even though the pattern's "[0-9;]*" would trivially match zero times.
  assert(ansi.strip(ESC .. "m") == ESC .. "m")
  assert(ansi.strip(ESC .. "0m") == ESC .. "0m")
end
test_strip_requires_csi_bracket()

local function test_reset_constant()
  assert(ansi.reset == ESC .. "[0m")
end
test_reset_constant()

local function test_enabled_honors_no_color()
  local saved = env.get("NO_COLOR")
  assert(env.set("NO_COLOR", "1"))
  assert(ansi.is_enabled(1) == false, "NO_COLOR should disable color")
  assert(ansi.is_enabled() == false)
  if saved then
    assert(env.set("NO_COLOR", saved))
  else
    assert(env.unset("NO_COLOR"))
  end
end
test_enabled_honors_no_color()

local function test_enabled_honors_dumb_term()
  local saved_no_color = env.get("NO_COLOR")
  local saved_term = env.get("TERM")
  assert(env.unset("NO_COLOR"))
  assert(env.set("TERM", "dumb"))
  assert(ansi.is_enabled(1) == false, "TERM=dumb should disable color")
  if saved_term then
    assert(env.set("TERM", saved_term))
  else
    assert(env.unset("TERM"))
  end
  if saved_no_color then
    assert(env.set("NO_COLOR", saved_no_color))
  end
end
test_enabled_honors_dumb_term()

local function test_enabled_requires_a_tty()
  -- Under the test runner stdout is a pipe, so with the env vetoes
  -- cleared the tty check decides — and must say false.
  local saved_no_color = env.get("NO_COLOR")
  local saved_term = env.get("TERM")
  assert(env.unset("NO_COLOR"))
  assert(env.unset("TERM"))
  assert(ansi.is_enabled(1) == false, "pipe misdetected as tty")
  if saved_term then
    assert(env.set("TERM", saved_term))
  end
  if saved_no_color then
    assert(env.set("NO_COLOR", saved_no_color))
  end
end
test_enabled_requires_a_tty()
