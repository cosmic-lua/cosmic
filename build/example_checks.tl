--- The check that what `cosmic docs` shows as an example runs as shown.
--- An example runs in place, from its `_example.tl` file, where the file's
--- own `require` lines and the harness's variables are in scope; a reader
--- copies the rendered text alone. Here that text is wrapped as a
--- standalone chunk -- the `Example` table, the function, a call of it --
--- and compiled with the checker, so a missing `require` or a name only
--- the harness defines (`tmp`) is refused. Nothing is run: the function's
--- body already runs in place under `cosmic test`, and what differs when
--- it is copied is what a compile sees.
---
--- Each user guide's examples (`doc/guides`) are held the same way: a
--- block that opens an example must compile alone, unless it is only a
--- project's entry, which reads its `file=` companions through the
--- harness's `tmp` and is compiled with that one name in scope. That
--- exemption stays: the companions are the `file=` blocks the guide
--- shows, which the generated test writes into `tmp` before the entry
--- runs, so an entry that made its own directory would repeat each
--- file's text a second time, in code, beside the block that shows it;
--- doctest has no notion of a companion written into the current
--- directory instead.
local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local doctest = require("build.doctest")
local standalone = require("build.standalone")
local symbols = require("build.symbols")
local type compiler = require("build.compiler")

local record example_checks
end

--- What the checker says of `source` as the chunk `name`, one line each.
local function problems(built: compiler, env: compiler.Env, name: string,
                        source: string): {string}
  local code, result = built.gen(source, env, nil, "tl")
  local out: {string} = {}
  if result ~= nil then
    for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
      for _, e in ipairs(group or {}) do
        out[#out + 1] = name .. ": " .. e.msg .. " (line " .. e.y .. " of the text as shown)"
      end
    end
  end
  if code == nil and #out == 0 then
    out[1] = name .. ": the compiler refused it"
  end
  return out
end

--- A stored example source (`build.analyzer.ExampleEntry.source`: the
--- `require` lines it needs, the function) as a chunk that runs alone:
--- `local Example = {}` where the function begins, and a call of it.
--- Lines are kept, so a complaint's line is a line of the text shown,
--- less the one `local Example` takes at the function.
local function chunk(name: string, source: string): string
  -- The function's `function` starts a line: a match inside a comment
  -- or a string of a call carried above it is not the boundary.
  local at = source:find("^function Example%.") or source:find("\nfunction Example%.")
  if at ~= nil and source:sub(at, at) == "\n" then
    at = at + 1
  end
  local head = at ~= nil and source:sub(1, at - 1) or ""
  local rest = at ~= nil and source:sub(at) or source
  return head .. "local Example = {} " .. rest .. "\nExample." .. name .. "()\n"
end

--- Every public example's rendered source, compiled as it is copied.
--- @param env the checker's environment: `require` of a module the
---   examples name is answered from it
local function examples(db: Sqlite.Handle, built: compiler,
                                 env: compiler.Env): {string}
  local rows, trouble = Sqlite.text_rows(db,
    "SELECT file, line, name, source FROM examples WHERE " ..
    symbols.public_only("module", true) .. " ORDER BY file, line")
  if rows == nil then
    return { "reading the examples: " .. trouble }
  end
  local out: {string} = {}
  for _, row in ipairs(rows) do
    local where = row[1] .. ":" .. row[2] .. ": example " .. row[3]
    for _, line in ipairs(problems(built, env, where, chunk(row[3], row[4]))) do
      out[#out + 1] = line
    end
  end
  return out
end

--- One guide's examples, each compiled alone (`file` is the guide's
--- path, named in a complaint). One with `file=` companions is a
--- project's entry, whose code reads them through `tmp`: it compiles
--- with `tmp` a string in scope, and a name it needs beyond that is
--- still refused.
local function guide(text: string, file: string, built: compiler,
                              env: compiler.Env): {string}
  local entries, trouble = doctest.entries(text)
  if entries == nil then
    return { file .. ": " .. trouble }
  end
  local out: {string} = {}
  for _, entry in ipairs(entries) do
    local source = entry.source
    if entry.companions then
      source = 'local tmp: string = ""\nlocal _ = tmp\n' .. source
    end
    local where = file .. ":" .. entry.line .. ": example"
    for _, line in ipairs(problems(built, env, where, source .. "\n")) do
      out[#out + 1] = line
    end
  end
  return out
end

--- Both of the above over the tree at `root`: the projection `db`'s
--- examples and each of `guides` (default `symbols.guides`, read from
--- `doc/guides/<name>.md`).
--- @param built a compiler, its own: the check points it at this binary's sources
function example_checks.run(db: Sqlite.Handle, root: string, built: compiler,
                            guides?: {string}): {string}
  local env, env_trouble = standalone.environment(built)
  if env == nil then
    return { env_trouble }
  end
  local out = examples(db, built, env)
  for _, name in ipairs(guides or symbols.guides) do
    local file = "doc/guides/" .. name .. ".md"
    local text, read_trouble = Fs.read(root .. "/" .. file)
    if text == nil then
      out[#out + 1] = read_trouble
    else
      for _, line in ipairs(guide(text, file, built, env)) do
        out[#out + 1] = line
      end
    end
  end
  return out
end

return example_checks
