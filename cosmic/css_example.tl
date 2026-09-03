--- Examples for the cosmic.css module.
--- Demonstrates escaping a string for interpolation into a CSS value,
--- and the SafeCss type cosmic.template's html mode binds a
--- {{css ...}} interpolation through.

-- Example_escape demonstrates the allowlist rule: every byte that is
-- not an ASCII letter or digit becomes a `\XX ` hex escape. This is
-- for a VALUE position or a quoted string body — it is not safe
-- inside url(...) or a selector, where CSS decodes the escape back to
-- the raw byte before a parser ever sees it (see cosmic/css.tl).
local function Example_escape()
  local css = require("cosmic.css")
  print(css.escape([[url("x")]]))
  -- Output:
  -- url\28 \22 x\22 \29
end

-- Example_safe demonstrates the SafeCss wrapper cosmic.template's
-- {{css ...}} interpolations require: safe() escapes and wraps in one
-- call, and .raw is the escaped value ready to sit inside a CSS
-- declaration.
local function Example_safe()
  local css = require("cosmic.css")
  local out = css.safe("red; background: url(evil)")
  print(out.raw)
  -- Output:
  -- red\3b \20 background\3a \20 url\28 evil\29
end

-- Example_trusted demonstrates the explicit hatch for a value already
-- known to be safe, such as a fixed color keyword — wraps without
-- escaping.
local function Example_trusted()
  local css = require("cosmic.css")
  local out = css.trusted("crimson")
  print(out.raw)
  -- Output:
  -- crimson
end

-- Suppress unused warnings for examples
local _ = {Example_escape, Example_safe, Example_trusted}
