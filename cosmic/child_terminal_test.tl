local Child = require("cosmic.child")

--- The start that gives a program a terminal takes it as all three of
--- the program's streams, and no stream or input of its own beside it.
local function test_start_on_terminal_takes_no_streams_of_its_own()
  for _, field in ipairs({ "stdin", "stdout", "stderr" }) do
    local opts: Child.Options = {}
    if field == "stdin" then
      opts.stdin = "null"
    elseif field == "stdout" then
      opts.stdout = "null"
    else
      opts.stderr = "null"
    end
    local ok, why = pcall(Child.start_on_terminal, { "/bin/true" }, opts, 9)
    assert(not ok and tostring(why):find("takes no stdin, stdout, stderr or input", 1, true), tostring(why))
  end
  local ok, why = pcall(Child.start_on_terminal, { "/bin/true" }, { input = "x" }, 9)
  assert(not ok and tostring(why):find("takes no stdin", 1, true), tostring(why))
end
