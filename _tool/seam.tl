--- The compile seam of D29's runner mode: read a test file and, when
--- its shape is runner (top-level `test_*` definitions, none
--- self-called), append the toolchain-generated tail so the checker
--- checks what runs and the chunk runs what is defined.
---
--- The tail is `os.exit(require("cosmic.test").main({...}))`, one
--- entry per case in source order. `os.exit`, not a bare `return`:
--- the script host discards a chunk's return value (measured — a
--- script of `return 3` exits 0), so a returned summary could never
--- reach `_tool/testrun.tl`, which reads the child's exit. The exit
--- sits at a process boundary in generated source the tree never
--- contains, so fmt, lint, and the file's reader never meet it.
---
--- Appending changes no line number: the tail joins after the
--- source's final newline, so checker diagnostics and tracebacks
--- keep pointing at the real lines. Every other shape — legacy
--- (self-called), mixed (the lint's to refuse), empty, or a
--- non-test path — passes through byte-identical.

local discover = require("_tool.discover")
local fs = require("cosmic.fs")

--- What the seam hands back: the source to feed the toolchain, and
--- the discovery verdict the caller may report on.
local record Augmented
  source: string
  mode: discover.Mode
end

--- Split content into lines the way discover expects.
local function lines_of(content: string): {string}
  local out: {string} = {}
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    out[#out + 1] = line
  end
  return out
end

--- The generated tail for an ordered case list.
--- @param cases {discover.Case} The cases, in source order
--- @return string The tail text, newline-terminated
local function tail_of(cases: {discover.Case}): string
  local parts: {string} = {}
  for _, c in ipairs(cases) do
    parts[#parts + 1] = ("  {name = %q, fn = %s},"):format(c.name, c.name)
  end
  return "os.exit(require(\"cosmic.test\").main({\n"
  .. table.concat(parts, "\n") .. "\n}))\n"
end

--- Read `path` and append the runner tail when its shape calls for
--- one. Anything that is not a runner-mode `*_test.tl` comes back
--- byte-identical.
--- @param path string The source path
--- @return Augmented | nil The source and the discovery verdict
--- @return string Error when the file cannot be read
local function augment(path: string): Augmented | nil, string
  local content, err = fs.read(path)
  if content == nil then
    return nil, err
  end
  if not path:find("_test%.tl$") then
    return {source = content, mode = "empty"}
  end
  local d = discover.discover(path, content, lines_of(content))
  if d.mode ~= "runner" then
    return {source = content, mode = d.mode}
  end
  local src = content
  if src:sub(-1) ~= "\n" then
    src = src .. "\n"
  end
  return {source = src .. tail_of(d.cases), mode = "runner"}
end

local record SeamModule
  type Augmented = Augmented
  augment: function(path: string): Augmented | nil, string
end

local M: SeamModule = {
  augment = augment,
}

return M
