-- type declarations for cosmo.repl
-- GENERATED from cosmopolitan's definitions.lua by _types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

local record repl
  --- Starts an interactive read-eval-print-loop (REPL) on standard input
  --- and output, with line editing, history, and tab completion. Each
  --- input line is evaluated as an expression (printing its results) or
  --- as a statement. The loop runs until end of input (Ctrl-D). Takes no
  --- arguments and returns nothing.
  start: function()
end

return repl
