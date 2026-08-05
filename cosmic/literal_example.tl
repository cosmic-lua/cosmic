--- Examples for the cosmic.literal module.
--- Reading a Teal or Lua file as DATA: one `return { … }` of literals,
--- lexed and matched, never loaded and never called. This is what makes
--- a config file that cannot do anything — no `os.execute`, no
--- `require`, no reading the environment — because the grammar admits
--- values and nothing else.

-- Example_parse demonstrates reading a literal table, including
-- nested tables and ["key"] entries.
local function Example_parse()
  local literal = require("cosmic.literal")
  local raw = literal.parse([[
return {
  name = "app",
  port = 8080,
  debug = false,
  limits = {["*"] = {rate = 10}},
}
]], {file = "config.tl"})
  local cfg = raw as {string: any} -- cast: the reader returns a plain table
  print(cfg.name, cfg.port, cfg.debug)
  -- Output:
  -- app	8080	false
end

-- Example_refuses_code demonstrates the property worth having: a file
-- that tries to compute is refused by name, with the line it happened
-- on. dofile() would have run it.
local function Example_refuses_code()
  local literal = require("cosmic.literal")
  local cfg, err = literal.parse(
    'return {home = os.getenv("HOME")}\n', {file = "config.tl"})
  print(cfg)
  print(err)
  -- Output:
  -- nil
  -- config.tl:1: a literal holds literals only; found 'os' (no variables, calls or concatenation)
end

-- Example_noun demonstrates naming the file kind in errors, which is
-- how `cosmic --make` makes the same grammar complain about "a pin".
local function Example_noun()
  local literal = require("cosmic.literal")
  local _, err = literal.parse("return 1\n", {file = "dep_pin.tl", noun = "pin"})
  print(err)
  -- Output:
  -- dep_pin.tl: a pin must return a table literal
end

-- Suppress unused warnings for examples
local _ = {Example_parse, Example_refuses_code, Example_noun}
