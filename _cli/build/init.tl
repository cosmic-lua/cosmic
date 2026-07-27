--- Shell-free recipe steps for the build's make rules: `compile`
--- replaces the cat/if/redirect/cmp/mv dance, `copy` replaces mkdir+cp,
--- `link` replaces mkdir+ln -sfn, `capture` and `tee` replace redirects
--- with cmp/mv or tee, plus list/remove/require-*/verdict.
---
--- Embedded in the cosmic binary behind the greedy `--build <mode>
--- <args>...` CLI flag. The build's make recipes exec the
--- PINNED bootstrap's copy (`$(bootstrap_cosmic) --build ...`), so
--- changes here reach the recipes only through a release + bootstrap
--- pin bump — an edit to this file cannot affect the build that
--- compiles it.
---
--- Requires the EMBEDDED stdlib only — deliberately no tree modules:
--- the compile rule is what BUILDS the tree's .lua files, so a tree
--- dependency here is circular, and the recipes export LUA_PATH=";;"
--- so a caller's LUA_PATH cannot redirect the driver's own requires.
--- The bootstrap sha therefore covers the driver's entire runtime; a
--- bootstrap bump that breaks an embedded API fails the build loudly.

local modes = require("_cli.build.steps")

local function verbs(): {string}
  local names: {string} = {}
  for name in pairs(modes) do
    names[#names + 1] = name
  end
  table.sort(names)
  return names
end

--- The vocabulary as one line, which is the point of it being closed.
--- @return string Comma-separated verb names
local function mode_names(): string
  return table.concat(verbs(), ", ")
end

local function recipe_fail(msg: string): integer
  io.stderr:write("cosmic -c: " .. msg .. "\n")
  return 1
end

--- Characters that mean something only to a shell. A recipe line is
--- split on whitespace and run as argv, so these would travel through
--- as literal argument bytes — a pipeline, a redirect, or a quoted
--- path would silently do something other than what it looks like.
--- Refusing them states the model at the first attempt rather than at
--- the first mysterious result.
local SHELL_CHARS < const > = ";|&<>`$(){}\\\"'\n"

--- @param line string A recipe line
--- @return string | nil The first shell character present, if any
local function shell_char(line: string): string | nil
  for i = 1, #SHELL_CHARS do
    local c = SHELL_CHARS:sub(i, i)
    if line:find(c, 1, true) then
      return c
    end
  end
  return nil
end

--- Run one recipe line: `cosmic -c '<line>'`.
---
--- This is the SHELL half of the driver (`SHELL := cosmic`, and make's
--- default `.SHELLFLAGS` is already `-c`). A line is whitespace-split
--- argv whose first word must name one of the modes above — no
--- quoting, no expansion, no pipes, no redirects. Two properties come
--- out of that: a recipe cannot be malformed by the data it carries,
--- and a build's whole capability surface is the modes table.
---
--- The trailing `;`: make does NOT use SHELL for a recipe line it
--- considers shell-free — it builds argv and execs directly (job.c's
--- fast path, taken whenever the line holds none of `#;"*?[]&|<>(){}$`^`
--- and does not start with a shell builtin). Lines in this vocabulary
--- are shell-free by construction, so without a metacharacter make
--- would exec them itself and cosmic would never see them: `rm -rf x`
--- in a generated rule would simply run. Generated recipes therefore
--- end in `;`, which forces the SHELL path, and this strips it. It is
--- the cheapest available sentinel and the only one that behaves
--- identically under a real shell — a leading `:` also forces the
--- path, but `sh` would discard the whole line.
--- @param line string The recipe line make passed
--- @return integer Exit code
--- Split and validate a recipe line without running it, so the caller
--- can fence the step (_cli.driver) before anything executes.
--- @param line string The recipe line make passed
--- @return string|nil The verb, nil when the line is blank or invalid
--- @return {string} The verb's arguments
--- @return string|nil Error message when the line is invalid
local function parse(line: string): string | nil, {string}, string | nil
  -- Strip ONE trailing sentinel. A `;` anywhere else is still refused
  -- below, so `copy a b ; touch evil` does not become two commands.
  line = line:gsub("%s*;%s*$", "")
  local bad = shell_char(line)
  if bad ~= nil then
    return nil, {}, "recipe lines are argv, not shell; found "
    .. string.format("%q", bad) .. " in: " .. line
  end
  local argv: {string} = {}
  for word in line:gmatch("%S+") do
    argv[#argv + 1] = word
  end
  -- make does not hand us blank lines, but a variable that expanded to
  -- nothing looks like one; doing nothing is what a shell would do.
  if #argv == 0 then
    return nil, {}, nil
  end
  local verb = table.remove(argv, 1)
  if not modes[verb] then
    return nil, {}, "unknown verb '" .. verb .. "'; a recipe may run: "
    .. mode_names()
  end
  return verb, argv, nil
end

--- Run an already-parsed verb.
--- @param verb string A name from the modes table
--- @param args {string} The verb's arguments
--- @return integer Exit code
local function dispatch(verb: string, args: {string}): integer
  local run_verb = modes[verb]
  if not run_verb then
    return recipe_fail("unknown verb '" .. verb .. "'")
  end
  return run_verb(args)
end

-- No `main`, and no script mode. Both belonged to `--build <mode>`, a
-- flag that went with the Makefile: a recipe reaches this vocabulary
-- through `cosmic -c '<line>'` and nothing else, which is what lets the
-- fence derive its grants from the line it is about to run.

return {
  parse = parse,
  dispatch = dispatch,
  verbs = verbs,
}
