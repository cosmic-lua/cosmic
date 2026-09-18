--- Position is the manifest: whether a file can be reached from outside
--- its own directory is a question of where it sits, not of its name.
---
--- A directory that holds its own `init.tl` is a module in its own
--- right, the ordinary way Lua already resolves `require("a.b")` to
--- `a/b/init.tl`, and every other file directly inside that directory
--- is a sibling, reachable only from a file that itself sits inside it.
--- A flat file with no such directory around it has no sibling to
--- protect and is public by construction. This generalizes the
--- reservation `build.importer` makes for the whole `cosmic` directory
--- to every directory in the tree.
---
--- The `Module` shape lives here, not in `build.importer`, so this
--- check can be a plain function of a module list without the two
--- files requiring one another.

local type compiler = require("build.compiler")
local ast = require("build.ast")

local record positions
  --- What a single parse of a `kind = "test"` module's source tells the
  --- importer: its own test names and whether it also returns its own
  --- value at the top level. Bundled into one record rather than
  --- returned as separate slots: `analyze`'s first return admits nil
  --- (source that fails to lex or parse), and a fallible return may
  --- declare at most two slots -- the extras ride on the value's
  --- record instead.
  record Analysis
    tests: {string}
    has_top_level_return: boolean
  end

  record Module
    path: string
    file: string
    kind: string
    source: string
    source_hash: string
    requires: {string}
    tests: {string}
    has_top_level_return: boolean
    key: string
    lua: string
    bytecode: string
  end
end

--- Both facts an importer needs from a `kind = "test"` module's source,
--- from one parse: the name of every top-level `local function test_*`,
--- in the order they appear, and whether the chunk also has a genuine
--- top-level (chunk-level) `return` statement -- the two are read
--- together off the same parsed chunk's own top-level statement array
--- so the source is never parsed twice for the two questions.
---
--- A test name is any direct element of that array (never a recursive
--- walk) whose kind is `"local_function"` and whose declared name
--- matches `^test_`. An indented one lives inside some OTHER
--- statement's own body, not the chunk's own array part, so it is
--- never reached here; a source SAMPLE held as a string literal is
--- never parsed as a statement at all, so there is no bracket-tracking
--- left to get wrong.
---
--- A genuine top-level return is any direct element of that same array
--- whose kind is `"return"`. Lua requires a `return` to be the last
--- statement of the block it sits in, so a module that type-checks at
--- all can only have one as its own chunk's final statement -- never
--- one a nested `if`, loop, or function body left behind, since those
--- parse as children of that inner block's own "statements" node,
--- never as an element of the chunk's own array.
---
--- An ordinary snake_case identifier or call starting with the six
--- letters `return` (`return_code = 1`, `return_value(x)`) parses to
--- an `"assignment"` or `"op"` node, never `"return"` -- there is no
--- text boundary to get wrong the way a pattern match over raw source
--- has to draw one by hand.
--- @param built compiler The loaded compiler capsule (`build.teal.load()`)
--- @param source string
--- @param name string Filename for parse diagnostics
--- @return Analysis | nil Every top-level test name plus the top-level-return fact
--- @return string Error message when `source` fails to lex or parse
function positions.analyze(built: compiler, source: string,
                           name: string): positions.Analysis | nil, string
  local parsed, trouble = ast.parse(built, source, name)
  if parsed == nil then
    return nil, trouble
  end
  local names: {string} = {}
  local has_return = false
  for _, stmt in ipairs(parsed.node) do
    if stmt.kind == "local_function" then
      local fn_name = stmt.name
      local tk = fn_name ~= nil and fn_name.tk or nil
      if tk ~= nil and tk:match("^test_") ~= nil then
        names[#names + 1] = tk
      end
    elseif stmt.kind == "return" then
      has_return = true
    end
  end
  return { tests = names, has_top_level_return = has_return }, ""
end

--- The file's own name, with no directory in front of it.
local function basename(file: string): string
  return file:match("([^/]+)$") or file
end

--- The directory a file sits in, or "" when it sits at the tree's root.
local function dirname(file: string): string
  return file:match("^(.*)/[^/]+$") or ""
end

--- Whether every require in `modules` respects sibling privacy, and if
--- not, which one and why.
--- @param modules every module the tree holds, with its requires
function positions.check(modules: {positions.Module}): boolean, string
  local by_path: {string:positions.Module} = {}
  local private_dirs: {string:boolean} = {}
  for _, m in ipairs(modules) do
    by_path[m.path] = m
    if basename(m.file) == "init.tl" then
      local dir = dirname(m.file)
      if dir ~= "" then
        private_dirs[dir] = true
      end
    end
  end
  for _, m in ipairs(modules) do
    for _, name in ipairs(m.requires) do
      local other = by_path[name]
      if other ~= nil then
        local dir = dirname(other.file)
        if private_dirs[dir] and other.file ~= dir .. "/init.tl" then
          local inside = m.file:sub(1, #dir + 1) == dir .. "/"
          if not inside then
            return false, m.file .. ": " .. name .. " is private to " ..
              dir .. "/; only a file inside it may import it"
          end
        end
      end
    end
  end
  return true, ""
end

return positions
