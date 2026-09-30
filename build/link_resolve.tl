--- What a link names ([`build.links`]), from what a [`Context`] says of
--- the project: the resolution `cosmic fix` checks every link by, and
--- the build indexes each link by ([`build.link_index`]). Resolution
--- reads only through its context, so each of them hands it a world of
--- its own: `fix` the disk ([`on_disk`]) and the project's databases, the
--- build the disk and the projection it is writing. See [`build.links`]
--- for the order a target is resolved in.

local Fs = require("cosmic.fs")
local String = require("cosmic.string")
local link_text = require("build.link_text")

local record link_resolve
  --- A symbol a context names: its module and its `symbol` as
  --- `docs` holds it (`""` for the module's own row).
  record Symbol
    module: string
    symbol: string
    --- The file that declares it, from the root; nil or `""` when the
    --- context does not say.
    file: string | nil
  end

  --- What resolution reads beyond the file, so a test can hand it a
  --- world of its own.
  record Context
    --- The project's root, absolute.
    root: string
    --- "file" or "dir" for what is at the absolute `path`, or nil.
    kind: function(path: string): string | nil
    --- The text of the file at the absolute `path`, or nil.
    read: function(path: string): string | nil
    --- Each symbol `query` names (step 2). Nil and why when the
    --- databases cannot be read.
    symbols: function(query: string): {Symbol} | nil, string
    --- The symbols of `module` whose name is `member`.
    member: function(module: string, member: string): {Symbol} | nil, string
    --- The absolute `path` with every symbolic link in it followed, or
    --- nil when it cannot be.
    real: function(path: string): string | nil
    --- Why `symbols` cannot answer for the project's own code (it has
    --- no database yet), or nil when it can.
    unbuilt: function(): string | nil
  end

  --- Resolves links, remembering what it looked up.
  record Resolver
    context: Context
    kinds: {string: string}
    headings: {string: {string: boolean}}
    symbols: {string: {Symbol}}
    members: {string: {Symbol}}
    trouble: string | nil
    --- The root with its links followed, once asked.
    real_root: string | nil
    --- How many links named no symbol while `context.unbuilt` said
    --- the symbols were incomplete, and so were not reported.
    unchecked: integer
  end

  --- What one target resolved to, by `kind`:
  ---
  --- - "url": a URL, which is not checked;
  --- - "standard": a value of the Lua standard library (`name`);
  --- - "declared": a name the linking file declares (`name`, dotted);
  --- - "symbol": a symbol of `module` (`symbol` as `docs` holds it),
  ---   declared in `file` (`""` when the context does not say);
  --- - "file": a file or directory, `path` from the root;
  --- - "anchor": a heading of the file at `path`, or a line of one
  ---   (`anchor`, as written).
  record Target
    kind: string
    name: string
    module: string
    symbol: string
    path: string
    anchor: string
    file: string
  end
end

--- A resolver over `context`.
function link_resolve.resolver(context: link_resolve.Context): link_resolve.Resolver
  return { context = context, kinds = {}, headings = {}, symbols = {}, members = {},
           unchecked = 0 }
end

--- What `resolver`'s context says is at `path`, asked once.
local function kind_at(resolver: link_resolve.Resolver, path: string): string | nil
  local cached = resolver.kinds[path]
  if cached == nil then
    cached = resolver.context.kind(path) or ""
    resolver.kinds[path] = cached
  end
  return cached ~= "" and cached or nil
end

--- Whether the code point `code` is a pictograph or a mark that
--- joins or varies one: what GitHub leaves out of an anchor.
local function pictograph(code: integer): boolean
  return code >= 0x2190 and code <= 0x2BFF or code >= 0x1F000 and code <= 0x1FAFF or
    code >= 0xFE00 and code <= 0xFE0F or code == 0x200D or code == 0x20E3
end

--- A heading's anchor as GitHub makes it: lowercased, its punctuation
--- but `-` and `_` and its pictographs dropped, each space a `-`.
local function slug_of(heading: string): string
  local text = heading:gsub("%[([^%]]*)%]%b()", "%1")
  local out: {string} = {}
  if utf8.len(text) == nil then
    -- Not UTF-8: each byte past ASCII is kept as it is.
    for at = 1, #text do
      local c = text:sub(at, at)
      if c:byte() >= 128 or c:match("[%w_%-]") ~= nil then
        out[#out + 1] = c:lower()
      elseif c == " " then
        out[#out + 1] = "-"
      end
    end
    return table.concat(out)
  end
  for _, code in utf8.codes(text) do
    local c = utf8.char(code)
    if code >= 128 then
      if not pictograph(code) then out[#out + 1] = c end
    elseif c:match("[%w_%-]") ~= nil then
      out[#out + 1] = c:lower()
    elseif c == " " then
      out[#out + 1] = "-"
    end
  end
  return table.concat(out)
end

--- Every anchor Markdown `text` gives, GitHub's way: each heading's,
--- `#` or underlined, a repeated one's taking `-1`, `-2` and so on,
--- and each `<a id>` or `<a name>`.
local function anchors(text: string): {string: boolean}
  local out: {string: boolean} = {}
  local count: {string: integer} = {}
  local function heading(line: string)
    local slug = slug_of((line:gsub("%s+#+%s*$", "")))
    local seen = count[slug]
    if seen == nil then
      count[slug] = 0
      out[slug] = true
    else
      count[slug] = seen + 1
      out[slug .. "-" .. (seen + 1)] = true
    end
  end
  local previous: string | nil = nil
  for line in (link_text.without_fences(text) .. "\n"):gmatch("([^\n]*)\n") do
    local atx = line:match("^ ? ? ?#+%s+(.-)%s*$")
    if atx ~= nil then
      heading(atx)
      previous = nil
    elseif previous ~= nil and (line:match("^ ? ? ?=+%s*$") ~= nil or
        line:match("^ ? ? ?%-+%s*$") ~= nil) then
      heading(String.trim(previous))
      previous = nil
    else
      previous = line:match("%S") ~= nil and line or nil
    end
    for _, attribute in ipairs({ "id", "name" }) do
      for name in line:gmatch("<a%s[^>]-" .. attribute .. "%s*=%s*[\"']([^\"']+)[\"']") do
        out[name] = true
      end
    end
  end
  return out
end

--- Why `anchor` names nothing in the file at `path`, or nil when it
--- names a heading of it. A file other than Markdown takes only a line
--- anchor (`L12`, `L12-L20`).
local function anchor_problem(resolver: link_resolve.Resolver, path: string, anchor: string): string | nil
  if not String.ends_with(path, ".md") then
    if anchor:match("^L%d+$") ~= nil or anchor:match("^L%d+%-L%d+$") ~= nil then
      return nil
    end
    return "only a Markdown file's headings take an anchor"
  end
  local found = resolver.headings[path]
  if found == nil then
    local text = resolver.context.read(path)
    found = text ~= nil and anchors(text) or {}
    resolver.headings[path] = found
  end
  if found[anchor:lower()] or found[anchor] then
    return nil
  end
  return "no heading of " .. Fs.basename(path) .. " has the anchor #" .. anchor
end

--- `path` with each `.` and `..` taken out, or nil when it climbs past
--- the top.
local function normalized(path: string): string | nil
  local parts: {string} = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts == 0 then return nil end
      parts[#parts] = nil
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return "/" .. table.concat(parts, "/")
end

--- Whether `path` is `root` or under it.
local function within(path: string, root: string): boolean
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

--- The file or directory the path `target` names from the file at
--- `from`: relative to its directory, then to the root (and a path
--- that starts with `/` to the root alone). Nil and why when there is
--- none there: the reason the first place gives, of none, the root's
--- `o/` (the build's output), a place outside the root, or a link that
--- leads out of it.
local function located(resolver: link_resolve.Resolver, from: string, target: string): string | nil, string
  local root = resolver.context.root
  local bases: {string} = { root }
  if target:sub(1, 1) ~= "/" then
    table.insert(bases, 1, Fs.dirname(from))
  end
  local why: string | nil = nil
  for _, base in ipairs(bases) do
    local path = normalized(base .. "/" .. target)
    local reason: string | nil = nil
    local relative = path ~= nil and path:sub(#root + 2) or ""
    if path == nil or not within(path, root) then
      reason = "it lies outside the project's root"
    elseif relative == "o" or relative:sub(1, 2) == "o/" then
      -- Refused before it is looked at, so the build's output never
      -- enters what a projection is signed by ([`build.link_index`]).
      reason = "it is under o/, the build's output"
    elseif kind_at(resolver, path) ~= nil then
      if resolver.real_root == nil then
        resolver.real_root = resolver.context.real(root) or root
      end
      local real = resolver.context.real(path)
      if real == nil or not within(real, resolver.real_root) then
        reason = "a symbolic link leads it out of the project"
      else
        return path, ""
      end
    end
    if why == nil and reason ~= nil then why = reason end
  end
  return nil, why or "no declaration, symbol or file by that name"
end

--- `path` as the project's root sees it.
local function shown(resolver: link_resolve.Resolver, path: string): string
  local root = resolver.context.root
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

--- The symbols the context names `query` by, asked once.
local function symbols_named(resolver: link_resolve.Resolver, query: string): {link_resolve.Symbol}
  local cached = resolver.symbols[query]
  if cached == nil then
    local found, trouble = resolver.context.symbols(query)
    if found == nil then
      resolver.trouble = trouble
      found = {}
    end
    cached = found
    resolver.symbols[query] = cached
  end
  return cached
end

--- The members of `module` named `member`, asked once.
local function members_named(resolver: link_resolve.Resolver, module: string,
                             member: string): {link_resolve.Symbol}
  local key = module .. "\n" .. member
  local cached = resolver.members[key]
  if cached == nil then
    local found, trouble = resolver.context.member(module, member)
    if found == nil then
      resolver.trouble = trouble
      found = {}
    end
    cached = found
    resolver.members[key] = cached
  end
  return cached
end

--- A symbol spelled in full: its module, then its name with a
--- method's `:` read as `.`, joined by `.`; a module's own row is the
--- module alone.
function link_resolve.spelled(symbol: link_resolve.Symbol): string
  if symbol.symbol == "" then
    return symbol.module
  end
  return symbol.module .. "." .. symbol.symbol:gsub(":", ".")
end

--- Why `found` is not one answer: none, or more than one.
local function one_of(found: {string}, none: string): string | nil
  if #found == 1 then
    return nil
  end
  if #found == 0 then
    return none
  end
  table.sort(found)
  return "it names " .. #found .. ": " .. table.concat(found, ", ", 1, math.min(#found, 5)) ..
    (#found > 5 and ", ..." or "") .. "; link the one meant in full"
end

--- The Lua standard library's globals, as this program carries them:
--- not `io`, `os` or `debug`, which cosmic leaves out.
-- TODO: walk `_G` itself, so a global a runtime adds is found too, once
-- the checker takes a reference to `_G`: it fails an assertion in
-- vendor tl's `Err_at` (an error with no file).
local STANDARD <const>: {string: any} = {
  assert = assert, collectgarbage = collectgarbage, error = error,
  getmetatable = getmetatable, ipairs = ipairs, load = load, next = next, pairs = pairs,
  pcall = pcall, print = print, rawequal = rawequal, rawget = rawget, rawlen = rawlen,
  rawset = rawset, require = require, select = select, setmetatable = setmetatable,
  tonumber = tonumber, tostring = tostring, type = type, xpcall = xpcall,
  coroutine = coroutine, math = math, package = package,
  string = string, table = table, utf8 = utf8,
}

--- Whether the dotted `name` is a value of the Lua standard library
--- this program carries (`string.format`, `print`).
local function standard(name: string): boolean
  local value: any = STANDARD
  for part in name:gmatch("[^.]+") do
    if value is {any: any} then
      value = rawget(value, part)
    else
      return false
    end
  end
  return value ~= nil
end

--- `path`, a link's path, as the file it names is spelled: a query
--- (`?plain=1`) left off and each `%XX` escape read.
local function unescaped(path: string): string
  path = path:gsub("%?.*$", "")
  return (path:gsub("%%(%x%x)", function(hex: string): string
    return string.char(math.tointeger(tonumber(hex, 16)) or 0)
  end))
end

--- What `target`, linked from the file at the absolute path `from`,
--- resolves to; nil and why when it resolves to nothing or to more
--- than one thing. `declared` gives what that file declares, asked
--- only when the target could be a name. A `path_first` target, an
--- inline link's or a definition's, is a URL or a path first, as in
--- Markdown: a file it names wins over a name.
function link_resolve.resolve(resolver: link_resolve.Resolver, from: string, target: string,
                              declared: function(): link_text.Declared,
                              path_first: boolean): link_resolve.Target | nil, string
  local function made(kind: string, fields: {string: string}): link_resolve.Target
    return { kind = kind, name = fields.name or "", module = fields.module or "",
             symbol = fields.symbol or "", path = fields.path or "", anchor = fields.anchor or "",
             file = fields.file or "" }
  end
  if target:match("^https?://") ~= nil or target:match("^mailto:") ~= nil then
    return made("url", {})
  end
  local path, anchor = target:match("^([^#]*)#(.*)$")
  if path == nil then
    path = target
  end
  if path == "" then
    if anchor == nil or anchor == "" then
      return nil, "it is empty"
    end
    local problem = anchor_problem(resolver, from, anchor)
    if problem ~= nil then
      return nil, problem
    end
    return made("anchor", { path = shown(resolver, from), anchor = anchor })
  end
  local file, why = located(resolver, from, unescaped(path))
  local function in_file(at: string): link_resolve.Target | nil, string
    if anchor == nil or anchor == "" then
      return made("file", { path = shown(resolver, at) })
    end
    if kind_at(resolver, at) ~= "file" then return nil, "a directory has no headings" end
    local problem = anchor_problem(resolver, at, anchor)
    if problem ~= nil then
      return nil, problem
    end
    return made("anchor", { path = shown(resolver, at), anchor = anchor })
  end
  if file ~= nil and path_first then
    return in_file(file)
  end
  local found: {string} = {}
  local symbols: {string: link_resolve.Symbol} = {}
  local name = link_text.name_of(target)
  local bare = name ~= nil and name:find("[.:]") == nil
  if name ~= nil then
    local dotted = name:gsub(":", ".")
    local own = declared()
    if own.names[dotted] then
      return made("declared", { name = dotted })
    end
    if standard(dotted) then
      return made("standard", { name = dotted })
    end
    local first, rest = dotted:match("^([%a_][%w_]*)%.(.+)$")
    if first ~= nil and own.aliases[first] ~= nil then
      local module = own.aliases[first]
      local members = members_named(resolver, module, rest)
      local spelled: {string} = {}
      for _, member in ipairs(members) do spelled[#spelled + 1] = link_resolve.spelled(member) end
      local problem = one_of(spelled, module .. " has no " .. rest)
      if problem ~= nil then
        return nil, problem
      end
      return made("symbol", { module = members[1].module, symbol = members[1].symbol,
                               file = members[1].file })
    end
    -- A name alone is its own file's: another module's symbol is
    -- written in full, so a link does not start naming another thing
    -- when some module comes to document a name of its own.
    if bare then
      if file == nil then
        why = "a name alone links only to a declaration of its own file; " ..
          "write another module's symbol in full (`module.member`)"
      end
    else
      for _, symbol in ipairs(symbols_named(resolver, name)) do
        local full = link_resolve.spelled(symbol)
        found[#found + 1] = full
        symbols[full] = symbol
      end
    end
  end
  if file ~= nil then
    found[#found + 1] = "the file " .. shown(resolver, file)
  end
  -- A shortcut names a symbol; an inline link, a path first.
  if #found == 0 and name ~= nil and not bare and not path_first and resolver.context.unbuilt() ~= nil then
    resolver.unchecked = resolver.unchecked + 1
    return nil, ""
  end
  if #found > 1 and file ~= nil then
    table.sort(found)
    return nil, "it names " .. #found .. ": " .. table.concat(found, ", ") ..
      "; write ./" .. shown(resolver, file) .. " for the file, or the symbol in full"
  end
  local problem = one_of(found, why)
  if problem ~= nil then
    return nil, problem
  end
  if file ~= nil then
    return in_file(file)
  end
  local symbol = symbols[found[1]]
  return made("symbol", { module = symbol.module, symbol = symbol.symbol, file = symbol.file })
end

--- What the name or path `content` names as a link's code span would,
--- from the file at the absolute path `from`: a symbol, or a file of
--- the tree; nil for anything else -- a name the file declares, the
--- standard library, a directory, an anchor, what names nothing or more
--- than one thing. With `in_tree`, a symbol only when the file that
--- declares it is a file of the tree: what a Markdown file's definition
--- of a code-span label must name ([`build.links`]). A name no symbol
--- answers is not counted among those left unchecked
--- ([`Resolver.unchecked`]): it is asked, not linked.
function link_resolve.meant(resolver: link_resolve.Resolver, from: string, content: string,
                            declared: function(): link_text.Declared,
                            in_tree: boolean): link_resolve.Target | nil
  local unchecked = resolver.unchecked
  local target, _ = link_resolve.resolve(resolver, from, content, declared, false)
  resolver.unchecked = unchecked
  if target == nil then
    return nil
  end
  local root = resolver.context.root
  if target.kind == "symbol" then
    if not in_tree or target.file ~= "" and target.file:sub(1, 2) ~= "o/" and
        kind_at(resolver, root .. "/" .. target.file) == "file" then
      return target
    end
    return nil
  end
  if target.kind == "file" and kind_at(resolver, root .. "/" .. target.path) == "file" then
    return target
  end
  return nil
end

--- The extensions a file of the tree is named with: a span that ends
--- in one reads as a file's name, whatever symbol it also spells.
local FILE_EXTENSIONS <const>: {string: boolean} = {
  tl = true, lua = true, c = true, h = true, zig = true, md = true, sh = true, yml = true,
  yaml = true, json = true, txt = true, pin = true, tsv = true, py = true, toml = true,
}

--- Whether `content` is shaped as a path: the characters of one, and a
--- `/` or an extension.
local function path_shaped(content: string): boolean
  return content:match("^[%w_%-%./]+$") ~= nil and
    (content:find("/", 1, true) ~= nil or content:match("%.%a%w*$") ~= nil)
end

--- What a plain code span holding `content`, in the file at the
--- absolute path `from`, is to become a link to, by the rule `cosmic
--- fix` rewrites such a span by; nil to leave it as written.
---
--- A span is linked when its link would name exactly one thing and that
--- thing is what the span means:
---
--- - a name alone (no `.`), only when the file declares it at its top
---   level and nowhere else (`module_level`): a local, a parameter, a
---   loop's variable or a field by its own name may be what the span
---   means, and another module's symbol is written in full;
--- - a name in full (`module.member`, `Type.member`, `alias.member`
---   through a `require` of the file, a module's whole name) that names
---   one symbol of the project ([`docs.exact`]'s rule), or one member the
---   file declares;
--- - a path of a file of the tree, one with a `/` in it.
---
--- Left as written: a span that is neither a name nor a path (a command,
--- a flag, an assignment, a pattern); a name alone that is one plain
--- lowercase word (`path`, `run`), which reads as prose or a variable
--- as often as a declaration of its file; a file's name alone
--- (`vendor.tl`), which as often means the module a file of that name
--- holds, or another file of the name elsewhere; the standard library, a
--- directory, and what names nothing or more than one thing. `in_tree`
--- is `meant`'s.
function link_resolve.linkable(resolver: link_resolve.Resolver, from: string, content: string,
                               declared: function(): link_text.Declared,
                               module_level: function(): {string: boolean},
                               in_tree: boolean): link_resolve.Target | nil
  local name = link_text.name_of(content)
  if name == nil and not path_shaped(content) then
    return nil
  end
  if name ~= nil then
    local dotted = name:gsub(":", ".")
    local alone = dotted:find(".", 1, true) == nil
    -- TODO: link a plain lowercase word the file declares where the span
    -- says it is a name -- written as a call (`render()`) -- once
    -- link_text.plain_spans reads the words around a span: `render`
    -- in build/docs.tl stays as written with `docs`, which there means
    -- the table as often as the module.
    if alone and dotted:match("^[%l%d]+$") ~= nil then
      return nil
    end
    if declared().names[dotted] then
      if module_level()[dotted] then
        return { kind = "declared", name = dotted, module = "", symbol = "", path = "",
                 anchor = "", file = "" }
      end
      return nil
    end
    if alone then
      return nil
    end
  end
  local target = link_resolve.meant(resolver, from, content, declared, in_tree)
  if target == nil or content:find("/", 1, true) ~= nil then
    return target
  end
  -- A name in full may name a symbol; a file's name alone links nothing.
  if target.kind == "file" or FILE_EXTENSIONS[content:match("%.(%w+)$") or ""] then
    return nil
  end
  return target
end

--- A context over the project at `root` as it is on disk, its
--- symbols answered by `symbols` and `member`, and `unbuilt` saying
--- why they lack the project's own code, or nil.
function link_resolve.on_disk(root: string,
                              symbols: function(query: string): {link_resolve.Symbol} | nil, string,
                              member: function(module: string, member: string): {link_resolve.Symbol} | nil, string,
                              unbuilt: function(): string | nil): link_resolve.Context
  return {
    root = root,
    kind = function(path: string): string | nil
      local st, _ = Fs.stat(path)
      if st == nil then return nil end
      return st.kind == "dir" and "dir" or "file"
    end,
    read = function(path: string): string | nil
      local text, _ = Fs.read(path)
      return text
    end,
    real = function(path: string): string | nil
      local real, _ = Fs.absolute(path)
      return real
    end,
    unbuilt = unbuilt,
    symbols = symbols,
    member = member,
  }
end

--- Resolves links in the file at the absolute `path` as though it held
--- `text`: its own headings are read from it, not from the context.
function link_resolve.holds(resolver: link_resolve.Resolver, path: string, text: string)
  resolver.headings[path] = anchors(text)
end

return link_resolve
