--- Examples for the cosmic.js module.
--- Demonstrates escaping a string for embedding inside a JavaScript
--- string literal, and the SafeJs type cosmic.template's html mode
--- binds a {{js ...}} interpolation through.

-- Example_escape_literal demonstrates escaping raw text for the
-- content of a JavaScript string literal — the caller still supplies
-- the surrounding quotes.
local function Example_escape_literal()
  local js = require("cosmic.js")
  local escaped = js.escape_literal([[say "hi"]])
  print('var msg = "' .. escaped .. '";')
  -- Output:
  -- var msg = "say \u0022hi\u0022";
end

-- Example_safe demonstrates the SafeJs wrapper cosmic.template's
-- {{js ...}} interpolations require: safe() escapes and wraps in one
-- call, and .raw is the escaped text ready to sit between quotes. The
-- closing tag's `<` is not left literal, so this stays safe even
-- nested inside a <script> block.
local function Example_safe()
  local js = require("cosmic.js")
  local out = js.safe("</script>")
  assert(not out.raw:match("<"), "expected no literal < in the escaped output")
  print(out.raw)
end

-- Example_trusted demonstrates the explicit hatch for content already
-- known to be a safe JavaScript literal body, such as a number
-- formatted by hand — wraps without escaping.
local function Example_trusted()
  local js = require("cosmic.js")
  local out = js.trusted("42")
  print(out.raw)
  -- Output:
  -- 42
end

-- Suppress unused warnings for examples
local _ = {Example_escape_literal, Example_safe, Example_trusted}
