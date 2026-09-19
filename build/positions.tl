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
  --- One guidance catalog entry, found by a top-level function's own
  --- `guidance:` comment tag paired with a `return nil, ...` inside its
  --- body -- see `catalog_of`.
  record CatalogEntry
    symbol: string
    --- The static text of the returned message, when any of it is a
    --- literal (empty when the whole expression is dynamic, in which
    --- case the entry is never produced at all -- see `static_text`).
    message: string
    guidance: string
    line: integer
  end

  --- What a single parse of a `kind = "test"` module's source tells the
  --- importer: its own test names, whether it also returns its own
  --- value at the top level, and any guidance catalog entries its
  --- functions carry. Bundled into one record rather than returned as
  --- separate slots: `analyze`'s first return admits nil (source that
  --- fails to lex or parse), and a fallible return may declare at most
  --- two slots -- the extras ride on the value's record instead.
  record Analysis
    tests: {string}
    has_top_level_return: boolean
    catalog: {CatalogEntry}
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
    --- True only for a module `build.doctest` produced from a
    --- `doc/guides/*.md` file rather than read off disk as `.tl`
    --- source: `build.importer.compile` widens its warning discount for
    --- exactly this module, and only this one, to cover the one
    --- `print`-shadowing warning that generated shape always carries --
    --- see `discount_doctest_shadow_warnings`.
    generated: boolean
    key: string
    --- The compiled Lua, once `build.importer.compile` has it: made
    --- this run or read back from the cache under the same key.
    lua: string
  end
end

--- A `return nil, $MSG`-shaped statement's message expression, reduced
--- to whatever of it is a literal: a plain string leaf reads as its own
--- text, a `..` concatenation reads as both sides joined the same way,
--- and anything else (a call, a variable) contributes nothing. A
--- message built entirely from such a case (`return nil, describe(e)`)
--- reduces to `""`, which `catalog_of` treats as nothing to catalog --
--- there is no text a person's error could ever contain to match it
--- against.
local function static_text(node: ast.Node): string
  if node == nil then
    return ""
  end
  if node.kind == "string" then
    return node.conststr or ""
  end
  if node.kind == "op" and node.op ~= nil and node.op.op == ".." then
    return static_text(node.e1) .. static_text(node.e2)
  end
  return ""
end

--- The guidance text a function's own comments carry, or `""` when they
--- carry none. A `---` doc comment is an ordinary explanation until one
--- line starts with `guidance:` (leading `--`/`---` and one following
--- space stripped first); from there every remaining comment line joins
--- in, space-separated, as the guidance a matching error should show.
local function guidance_of(comments: {compiler.Comment}): string
  if comments == nil then
    return ""
  end
  local collecting = false
  local parts: {string} = {}
  for _, c in ipairs(comments) do
    local body = c.text:match("^%-%-%-?%s?(.*)$") or c.text
    if collecting then
      parts[#parts + 1] = body
    else
      local tail = body:match("^guidance:%s*(.*)$")
      if tail then
        collecting = true
        parts[#parts + 1] = tail
      end
    end
  end
  return table.concat(parts, " ")
end

--- A declared function's own name: a `local_function`'s name alone, or
--- a `record_function`'s owner and name joined by `:`/`.` the way it
--- was declared, e.g. `"Sqlite.run"`.
local function symbol_of(stmt: ast.Node): string
  local fn_name = stmt.name
  local tk = fn_name ~= nil and fn_name.tk or nil
  if stmt.kind == "local_function" then
    return tk or ""
  end
  local owner = stmt.fn_owner
  local owner_tk = owner ~= nil and owner.tk or nil
  local sep = stmt.is_method and ":" or "."
  return (owner_tk or "") .. sep .. (tk or "")
end

--- Every node under a function declared inside `body` -- a nested
--- `local function`, a method, or an anonymous `function` value -- so a
--- hit found there can be told from one in `body`'s own blocks.
--- `ast.find_all` walks the whole subtree and offers no way to stop at
--- a function boundary, so the boundary is drawn here instead.
local function nodes_under_inner_functions(body: ast.Node): {ast.Node: boolean}
  local inner: {ast.Node: boolean} = {}
  ast.walk(body, function(n: ast.Node)
    if n.kind == "local_function" or n.kind == "record_function"
       or n.kind == "global_function" or n.kind == "function" then
      ast.walk(n, function(under: ast.Node)
        inner[under] = true
      end)
    end
  end)
  return inner
end

--- Every honest-return failure inside `stmt`'s own body that carries
--- literal text, once `stmt`'s comments have already named guidance for
--- it: `return nil, ...` (a value) and `return false, ...` (an effect)
--- alike, `patterns` carrying one compiled pattern for each. Searches
--- the whole body, nested blocks included (an error return three `if`s
--- deep is exactly as cataloguable as a top-level one) -- but never
--- crosses into a function declared inside it, since that inner
--- function's own returns belong to ITS comments, found when the outer
--- walk reaches it directly, not to this one's.
local function catalog_in_body(body: ast.Node, patterns: {ast.Node},
    symbol: string, guidance: string): {positions.CatalogEntry}
  local out: {positions.CatalogEntry} = {}
  local inner = nodes_under_inner_functions(body)
  for _, pattern in ipairs(patterns) do
    for _, hit in ipairs(ast.find_all(body, pattern)) do
      local msg = hit.caps["_MSG"]
      local text = msg ~= nil and static_text(msg) or ""
      -- A handful of significant characters or better: enough to anchor
      -- an FTS match, so a mostly-interpolated message ("parameter " ..
      -- index .. ": " .. trouble, reduced to "parameter : ") is left
      -- out rather than shipped as a near-universal false match.
      if not inner[hit.node] and #(text:gsub("%A", "")) >= 6 then
        out[#out + 1] = { symbol = symbol, message = text, guidance = guidance,
          line = hit.node.y }
      end
    end
  end
  return out
end

--- Every guidance catalog entry a chunk's own top-level functions carry:
--- each `local_function`/`record_function` whose comments name guidance,
--- paired with the literal text of every honest-return failure its own
--- body returns. Top-level only, the same boundary `analysis_of`
--- already draws for test names -- a function nested inside another
--- statement is reached when THAT statement's own entry is walked,
--- never here.
local function catalog_of(built: compiler, parsed: ast.Parsed): {positions.CatalogEntry}, string
  local patterns: {ast.Node} = {}
  for _, source in ipairs({ "return nil, $MSG", "return false, $MSG" }) do
    local pattern, trouble = ast.compile_pattern(built, source)
    if pattern == nil then
      return {}, trouble
    end
    patterns[#patterns + 1] = pattern
  end
  local out: {positions.CatalogEntry} = {}
  for _, stmt in ipairs(parsed.node) do
    if stmt.kind == "local_function" or stmt.kind == "record_function" then
      local guidance = guidance_of(stmt.comments)
      if #guidance > 0 and stmt.body ~= nil then
        local symbol = symbol_of(stmt)
        for _, entry in ipairs(catalog_in_body(stmt.body, patterns, symbol, guidance)) do
          out[#out + 1] = entry
        end
      end
    end
  end
  return out, ""
end

--- The same facts, read off a chunk something else already parsed, so a
--- caller that needs the parse for another question too pays for it
--- once. `built` is needed only to compile the `return nil, $MSG`
--- pattern `catalog_of` matches against; a pattern-compile failure
--- (which nothing in this tree's own source should ever trigger) is
--- reported as an ordinary failure rather than silently dropping the
--- catalog.
function positions.analysis_of(built: compiler, parsed: ast.Parsed): positions.Analysis | nil, string
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
  local catalog, trouble = catalog_of(built, parsed)
  if trouble ~= "" then
    return nil, trouble
  end
  return { tests = names, has_top_level_return = has_return, catalog = catalog }, ""
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
  return positions.analysis_of(built, parsed)
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
