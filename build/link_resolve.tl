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
    file?: string
    --- What it is, as `docs` holds it (`"module"`, `"function"`), and
    --- its name as its file declares it (`source_symbol`); nil where
    --- the context does not say.
    kind?: string
    source?: string
  end

  --- What resolution reads beyond the file, so a test can hand it a
  --- world of its own.
  record Context
    --- The project's root, absolute.
    root: string
    --- "file" or "dir" for what is at the absolute `path`, or nil.
    mut kind: function(path: string): string?
    --- The text of the file at the absolute `path`, or nil.
    read: function(path: string): string?
    --- Each symbol `query` names (step 2). Nil and why when the
    --- databases cannot be read.
    symbols: function(query: string): {Symbol}?, string
    --- The symbols of `module` whose name is `member`.
    member: function(module: string, member: string): {Symbol}?, string
    --- The absolute `path` with every symbolic link in it followed, or
    --- nil when it cannot be.
    real: function(path: string): string?
    --- Why `symbols` cannot answer for the project's own code (it has
    --- no database yet), or nil when it can.
    unbuilt: function(): string?
    --- Whether the build made for this resolution refused `module`, so
    --- what `symbols` holds of it is an earlier build's, which says
    --- nothing of its members now. Asked once `symbols` or `member` has
    --- answered. Nil where no build was made.
    mut refused?: function(module: string): boolean
    --- Whether the tree ignores the path `relative` to the root, which
    --- `kind` then answers nil for: no fresh checkout has it.
    mut ignored?: function(relative: string): boolean
    --- Why what `symbols` and `member` hold is an earlier build's than
    --- the tree's, as a clause (`"the build refused typed.tl"`), so a
    --- module new since then is one they know nothing of; nil where it
    --- is the tree's. Asked once either has answered.
    mut stale?: function(): string?
    --- The files of the tree named `basename`, each from the root: what
    --- a path that names no file may have meant. Nil where the context
    --- cannot list them.
    mut named_files?: function(basename: string): {string}
  end

  --- Resolves links, remembering what it looked up.
  record Resolver
    context: Context
    kinds: mut {string: string}
    headings: mut {string: {string: boolean}}
    symbols: mut {string: {Symbol}}
    members: mut {string: {Symbol}}
    mut trouble?: string
    --- The root with its links followed, once asked.
    mut real_root?: string
    --- How many links named no symbol while `context.unbuilt` said
    --- the symbols were incomplete, and so were not reported.
    mut unchecked: integer
  end

  --- What one target resolved to, by `kind`:
  ---
  --- - "url": a URL, which is not checked;
  --- - "standard": a value this program's globals hold (`name`);
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
local function kind_at(resolver: link_resolve.Resolver, path: string): string?
  local cached = resolver.kinds[path]
  if cached == nil then
    cached = resolver.context.kind(path) or ""
    resolver.kinds[path] = cached
  end
  return if cached ~= "" then cached else nil end
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
  local out: mut {string} = {}
  if utf8.len(text) == nil then
    -- Not UTF-8: each byte past ASCII is kept as it is.
    for at = 1, #text do
      local c = text:sub(at, at)
      if String.byte_at(c, 1) >= 128 or c:match("[%w_%-]") ~= nil then
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
function link_resolve.anchors(text: string): {string: boolean}
  local out: mut {string: boolean} = {}
  local count: mut {string: integer} = {}
  local function heading(line: string)
    local slug = slug_of((line:gsub("%s+#+%s*$", "")))
    local seen = count[slug]
    if seen == nil then
      count[slug] = 0
      out[slug] = true
    else
      count[slug] = seen + 1
      out[slug .. "-" .. tostring((seen + 1))] = true
    end
  end
  local previous: string? = nil
  for line in String.lines(link_text.without_code(text)) do
    local atx = line:match("^ ? ? ?#+%s+(.-)%s*$")
    if atx ~= nil then
      heading(atx)
      previous = nil
    elseif previous ~= nil and (line:match("^ ? ? ?=+%s*$") ~= nil or
        line:match("^ ? ? ?%-+%s*$") ~= nil) then
      heading(String.trim(previous))
      previous = nil
    else
      previous = if line:match("%S") ~= nil then line else nil end
    end
    for _, attribute in ipairs({ "id", "name" }) do
      for name in line:gmatch("<a%s[^>]-" .. attribute .. "%s*=%s*[\"']([^\"']+)[\"']") do
        out[name] = true
      end
    end
  end
  return out
end

--- The anchors of the headings of the file at `path`, read once: none for a file the
--- context cannot read.
local function headings_of(resolver: link_resolve.Resolver, path: string): {string: boolean}
  local cached = resolver.headings[path]
  if cached ~= nil then
    return cached
  end
  local text = resolver.context.read(path)
  local read = if text ~= nil then link_resolve.anchors(text) else {} end -- checked: literal_needs_type
  resolver.headings[path] = read
  return read
end

--- Why `anchor` names nothing in the file at `path`, or nil when it
--- names a heading of it. A file other than Markdown takes only a line
--- anchor (`L12`, `L12-L20`).
local function anchor_problem(resolver: link_resolve.Resolver, path: string, anchor: string): string?
  if not String.ends_with(path, ".md") then
    if anchor:match("^L%d+$") ~= nil or anchor:match("^L%d+%-L%d+$") ~= nil then
      return nil
    end
    return "only a Markdown file's headings take an anchor"
  end
  local found = headings_of(resolver, path)
  if found[anchor:lower()] == true or found[anchor] == true then
    return nil
  end
  return "no heading of " .. Fs.basename(path) .. " has the anchor #" .. anchor
end

--- `path` with each `.` and `..` taken out, or nil when it climbs past
--- the top.
local function normalized(path: string): string?
  local parts: mut {string} = {}
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
  return path == root or String.starts_with(path, root .. "/")
end

--- The file or directory the path `target` names from the file at
--- `from`: relative to its directory, then to the root (and a path
--- that starts with `/` to the root alone). Nil and why when there is
--- none there: the reason the first place gives, of none, the root's
--- `o/` (a stale build directory an older tool wrote), a `.git` (git's
--- metadata), a path the tree ignores ([`Context.ignored`]), a place
--- outside the root, or a link that leads out of it. Only the first
--- place can be outside: `../x` from `doc/` is `x`, absent, whatever
--- `../x` from the root is. A path with a `/` that is nowhere it was
--- looked for says where that was; any other may be a name as well, and
--- gets the reason a name does.
local function located(resolver: link_resolve.Resolver, from: string, target: string): string?, string
  local root = resolver.context.root
  local ignores = resolver.context.ignored
  local bases: mut {string} = { root }
  if target:sub(1, 1) ~= "/" then
    table.insert(bases, 1, Fs.dirname(from))
  end
  local why: string? = nil
  local absent: mut {string} = {}
  for index, base in ipairs(bases) do
    local path = normalized(base .. "/" .. target)
    local reason: string? = nil
    local relative = if path ~= nil then path:sub(#root + 2) else "" end
    if path == nil or not within(path, root) then
      if index == 1 then reason = "it lies outside the project's root" end
    elseif relative == "o" or relative:sub(1, 2) == "o/" then
      -- Refused before it is looked at, so a stale build's output
      -- never enters what a projection is signed by ([`build.link_index`]).
      reason = "it is under o/, a stale build directory"
    elseif ("/" .. relative .. "/"):find("/.git/", 1, true) then
      -- Git's own metadata, not the project's: in a worktree `.git` is a
      -- file, so a path through it resolves in one checkout and not
      -- another. Refused before it is looked at, as `o/` is.
      reason = "it is under .git, git's own metadata"
    elseif ignores ~= nil and ignores(relative) then
      reason = if ("/" .. relative .. "/"):find("/node_modules/", 1, true) ~= nil then
        "it is under node_modules/, absent from a fresh checkout: link the source that names the package, or write " ..
          "it as code text" else
        "it is ignored (.gitignore), so absent from a fresh checkout: link the source or rule that makes it, or " ..
          "write it as code text" end
    elseif kind_at(resolver, path) ~= nil then
      local real_root = resolver.real_root or resolver.context.real(root) or root
      resolver.real_root = real_root
      local real = resolver.context.real(path)
      if real == nil or not within(real, real_root) then
        reason = "a symbolic link leads it out of the project"
      else
        return path, ""
      end
    elseif absent[#absent] ~= relative then
      absent[#absent + 1] = relative
    end
    if why == nil and reason ~= nil then why = reason end
  end
  if why == nil and #absent > 0 and target:find("/", 1, true) ~= nil then
    why = "no file at " .. table.concat(absent, " or ")
  end
  return nil, why or "no declaration, symbol or file by that name"
end

--- `path`, from the root, as a link from the file at `from` spells it:
--- relative to `from`'s directory.
local function relative_from(resolver: link_resolve.Resolver, from: string, path: string): string
  local root = resolver.context.root
  local here: mut {string} = {}
  for part in Fs.dirname(from):sub(#root + 2):gmatch("[^/]+") do here[#here + 1] = part end
  local there: mut {string} = {}
  for part in path:gmatch("[^/]+") do there[#there + 1] = part end
  local shared = 0
  while shared < #here and shared < #there - 1 and here[shared + 1] == there[shared + 1] do
    shared = shared + 1
  end
  local out: mut {string} = {}
  for _ = shared + 1, #here do out[#out + 1] = ".." end
  for at, part in ipairs(there) do
    if at > shared then out[#out + 1] = part end
  end
  return table.concat(out, "/")
end

--- Whether `content` is shaped as a path: the characters of one, and a
--- `/` or an extension.
local function path_shaped(content: string): boolean
  return content:match("^[%w_%-%./]+$") ~= nil and
    (content:find("/", 1, true) ~= nil or content:match("%.%a%w*$") ~= nil)
end

--- What a path `target`, linked from the file at `from` and naming no
--- file, may have meant: `"; <path> has that name: link it as <link>"`
--- where exactly one file of the tree has its last part's name
--- ([`Context.named_files`]), else `""`.
local function elsewhere(resolver: link_resolve.Resolver, from: string, target: string): string
  local listed = resolver.context.named_files
  local basename = target:match("([^/]+)$")
  if listed == nil or basename == nil or basename == "." or basename == ".." then return "" end
  local named = listed(basename)
  if #named ~= 1 then return "" end
  return "; " .. named[1] .. " has that name: link it as " .. relative_from(resolver, from, named[1])
end

--- `path` as the project's root sees it.
local function shown(resolver: link_resolve.Resolver, path: string): string
  local root = resolver.context.root
  if String.starts_with(path, root .. "/") then
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
local function one_of(found: mut {string}, none: string): string?
  if #found == 1 then
    return nil
  end
  if #found == 0 then
    return none
  end
  table.sort(found)
  return "it names " .. tostring(#found) .. ": " .. table.concat(found, ", ", 1, math.min(#found, 5)) ..
    (if #found > 5 then ", ..." else "" end) .. "; link the one meant in full"
end

--- Whether the dotted `name` is a value the running tool's globals
--- hold (`string.format`, `print`, `warn`), read from `_G` as it is
--- now: a project checked by one version of cosmic resolves against
--- that version's globals, not those of the one its programs run on.
--- Each step is a `rawget`, so a name the core refuses (`io`,
--- `dofile`), which only its metatable answers, does not resolve. Nor
--- does a step back into `_G` (`_G._G.print`) or into
--- `package.loaded` or `package.preload`, which hold what this process
--- happened to load, and `_G` again.
local function standard(name: string): boolean
  local globals: any = _G -- checked: unchecked_binding
  local package_table: any = package -- checked: any_use
  local value: any = globals
  local steps = 0
  for part in name:gmatch("[^.]+") do
    steps = steps + 1
    if value is {any: any} then -- declared: key_type
      if rawequal(value, package_table) and (part == "loaded" or part == "preload") then
        return false
      end
      value = rawget(value, part)
      if steps > 1 and rawequal(value, globals) then
        return false
      end
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

--- What [`link_resolve.resolve`] makes a target from: the fields a kind of target has, the rest empty.
local record TargetFields
  name?: string
  module?: string
  symbol?: string
  path?: string
  anchor?: string
  file?: string
end

--- Why a name in full `dotted` names nothing known, where the build made for this resolution refused the module it is
--- of ([`Context.refused`]): that module is `dotted`'s longest prefix that is a module of the tree, its file `p.tl` or
--- `p/init.tl` there, or that the build refused. A module that built answers for its own members even under a parent
--- that did not, whether or not an earlier build knew it. Nil where it built, or where no build was made.
local function refused_prefix(resolver: link_resolve.Resolver, dotted: string): string?
  local refused = resolver.context.refused
  if refused == nil then return nil end
  local root = resolver.context.root
  local module = dotted
  while true do
    if refused(module) then
      return module .. " did not build, so its symbols are unknown; fix it first"
    end
    local path = root .. "/" .. (module:gsub("%.", "/"))
    if kind_at(resolver, path .. ".tl") == "file" or kind_at(resolver, path .. "/init.tl") == "file" then
      return nil
    end
    local shorter = module:match("^(.+)%.[^.]+$")
    if shorter == nil then return nil end
    module = shorter
  end
end

--- The file of the tree that holds the module `module`, from the root: `p.tl` or `p/init.tl`; nil where neither is.
local function module_file(resolver: link_resolve.Resolver, module: string): string?
  local path = (module:gsub("%.", "/"))
  for _, file in ipairs({ path .. ".tl", path .. "/init.tl" }) do
    if kind_at(resolver, resolver.context.root .. "/" .. file) == "file" then return file end
  end
  return nil
end

--- The longest prefix of the dotted `name` that is a module of the tree ([`module_file`]), or nil.
local function tree_module(resolver: link_resolve.Resolver, name: string): string?
  local module = name
  while true do
    if module_file(resolver, module) ~= nil then return module end
    local shorter = module:match("^(.+)%.[^.]+$")
    if shorter == nil then return nil end
    module = shorter
  end
end

--- Why a name of the module `module`, a module of the tree, names nothing where what the symbols hold is an earlier
--- build's ([`Context.stale`]) and that build has no row of the module: it is new since, and the name may be one it
--- declares. A module the earlier build holds answers as it did then, a name it lacks failing for its own reason.
local function stale_for(resolver: link_resolve.Resolver, module: string?): string?
  -- TODO: a module changed since the earlier build answers as it was then, so a name added to it fails as naming
  -- nothing; say it is not known yet once the context can compare a file with what that build read of it.
  local stale = resolver.context.stale
  if stale == nil or module == nil then return nil end
  local why = stale()
  if why == nil then return nil end
  -- Asked by the module's name, the symbols answer its own row or first row, and any symbol of another module that
  -- ends in that name.
  for _, symbol in ipairs(symbols_named(resolver, module)) do
    if symbol.module == module then return nil end
  end
  return "not known yet: " .. module .. " is new since the last build, which links are checked against while " ..
    why .. "; fix that first"
end

--- `symbol` as a link spells it alone, other than as [`link_resolve.spelled`] does, or nil where the context names no
--- other: a module's own row by its file, `./<file>`; any other by its module and its name as its file declares it,
--- where that names `symbol` and nothing else.
local function respelled(resolver: link_resolve.Resolver, symbol: link_resolve.Symbol, spelled: string): string?
  if symbol.symbol == "" then
    local file = symbol.file
    if file ~= nil and file ~= "" then return "./" .. file end
    return nil
  end
  local source = symbol.source
  if source == nil or source == "" then return nil end
  local other = symbol.module .. "." .. source:gsub(":", ".")
  if other == spelled then return nil end
  local found = symbols_named(resolver, other)
  local only = found[1]
  if #found == 1 and only ~= nil and only.module == symbol.module and only.symbol == symbol.symbol then
    return other
  end
  return nil
end

--- Why the symbols `candidates`, more than one, are not one answer to the name `written`, where spelling one in full
--- would not tell it from the rest: two spell alike, or one is spelled as written. Each is named by its kind and file,
--- with how a link spells it alone where one can. Nil where each has a spelling of its own, which [`one_of`] says.
local function alike(resolver: link_resolve.Resolver, written: string, candidates: {link_resolve.Symbol}): string?
  if #candidates < 2 then return nil end
  local count: mut {string: integer} = {}
  local clash = false
  for _, symbol in ipairs(candidates) do
    local spelled = link_resolve.spelled(symbol)
    local times = (count[spelled] or 0) + 1
    count[spelled] = times
    if times > 1 or spelled == written then clash = true end
  end
  if not clash then return nil end
  local each: mut {string} = {}
  local first = link_resolve.spelled((assert(candidates[1], "two candidates at least")))
  local same = true
  for _, symbol in ipairs(candidates) do
    local spelled = link_resolve.spelled(symbol)
    if spelled ~= first then same = false end
    local kind = if symbol.symbol == "" then "module" else symbol.kind or "symbol" end
    local file = symbol.file
    local said = "the " .. kind .. " " .. spelled .. (if file ~= nil and file ~= "" then " (" .. file .. ")" else "" end)
    local other = if count[spelled] == 1 and spelled ~= written then spelled
      else respelled(resolver, symbol, spelled) end
    each[#each + 1] = said .. (if other ~= nil then ", write " .. other else ", spelled no other way" end)
  end
  table.sort(each)
  return "it names " .. tostring(#candidates) .. (if same then " spelled alike: " else ": " end) ..
    table.concat(each, "; ", 1, math.min(#each, 5)) .. (if #each > 5 then "; ..." else "" end)
end

--- What `target`, linked from the file at the absolute path `from`,
--- resolves to; nil and why when it resolves to nothing or to more
--- than one thing. `declared` gives what that file declares where the
--- link is ([`link_text.Declarations`]), asked only when the target
--- could be a name. A `path_first` target, an inline link's or a
--- definition's, is a URL or a path first, as in Markdown: a file it
--- names wins over a name.
function link_resolve.resolve(resolver: link_resolve.Resolver, from: string, target: string,
                              declared: function(): link_text.Declared,
                              path_first: boolean): link_resolve.Target?, string
  local function made(kind: string, fields: TargetFields): link_resolve.Target
    return { kind = kind, name = fields.name or "", module = fields.module or "",
      symbol = fields.symbol or "", path = fields.path or "", anchor = fields.anchor or "",
      file = fields.file or "" }
  end
  if target:match("^https?://") ~= nil or target:match("^mailto:") ~= nil then
    return made("url", {}), ""
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
    return made("anchor", { path = shown(resolver, from), anchor = anchor }), ""
  end
  local file, why = located(resolver, from, unescaped(path))
  local function in_file(at: string): link_resolve.Target?, string
    if anchor == nil or anchor == "" then
      return made("file", { path = shown(resolver, at) }), ""
    end
    if kind_at(resolver, at) ~= "file" then return nil, "a directory has no headings" end
    local problem = anchor_problem(resolver, at, anchor)
    if problem ~= nil then
      return nil, problem
    end
    return made("anchor", { path = shown(resolver, at), anchor = anchor }), ""
  end
  if file ~= nil and path_first then
    return in_file(file)
  end
  local found: mut {string} = {}
  local symbols: mut {string: link_resolve.Symbol} = {}
  local candidates: mut {link_resolve.Symbol} = {}
  local name = link_text.name_of(target)
  local bare = name ~= nil and name:find("[.:]") == nil
  if name ~= nil then
    local dotted = name:gsub(":", ".")
    local own = declared()
    if own.names[dotted] == true then
      return made("declared", { name = dotted }), ""
    end
    -- A global comes before a symbol, so one a later core adds shadows a symbol of its name.
    if standard(dotted) then
      return made("standard", { name = dotted }), ""
    end
    local first, rest = dotted:match("^([%a_][%w_]*)%.(.+)$")
    local module = if first ~= nil then own.aliases[first] else nil end
    if module ~= nil and rest ~= nil then
      local members = members_named(resolver, module, rest)
      local not_built = refused_prefix(resolver, module)
      if #members == 0 and not_built ~= nil then
        return nil, not_built
      end
      -- Unbuilt, the members of a module the symbols do not know yet
      -- (the project's own) may be ones the build would record, as for
      -- a name in full below; a known module's (the standard library's)
      -- are all there, so a member it lacks still fails.
      if #members == 0 and not path_first and resolver.context.unbuilt() ~= nil and
          #symbols_named(resolver, module) == 0 then
        resolver.unchecked = resolver.unchecked + 1
        return nil, ""
      end
      local provisional = if #members == 0 then stale_for(resolver, tree_module(resolver, module)) else nil end
      if provisional ~= nil then
        return nil, provisional
      end
      local spelled: mut {string} = {}
      for _, member in ipairs(members) do spelled[#spelled + 1] = link_resolve.spelled(member) end
      local problem = alike(resolver, dotted, members) or one_of(spelled, module .. " has no " .. rest)
      if problem ~= nil then
        return nil, problem
      end
      -- [`one_of`] found no fault, so `spelled`, one to a member, holds exactly one.
      local member = assert(members[1], "one member was spelled")
      return made("symbol", { module = member.module, symbol = member.symbol,
        file = member.file }), ""
    end
    -- A name alone is its own file's: another module's symbol is
    -- written in full, so a link does not start naming another thing
    -- when some module comes to document a name of its own.
    if bare then
      local held_in = if file == nil then module_file(resolver, dotted) else nil end
      if held_in ~= nil then
        -- The module's name is already in full: only its file is left to link.
        why = "a name alone links only to a declaration of its own file, and " .. dotted ..
          " is a module: link its file `" .. held_in .. "`"
      elseif file == nil then
        why = "a name alone links only to a declaration of its own file; " ..
          "write another module's symbol in full (`module.member`)"
      end
    else
      for _, symbol in ipairs(symbols_named(resolver, name)) do
        local full = link_resolve.spelled(symbol)
        found[#found + 1] = full
        symbols[full] = symbol
        candidates[#candidates + 1] = symbol
      end
    end
  end
  if file ~= nil then
    found[#found + 1] = "the file " .. shown(resolver, file)
  end
  -- A module the build refused is said so whether or not the symbols are complete.
  if #found == 0 and name ~= nil and not bare then
    local not_built = refused_prefix(resolver, (name:gsub(":", ".")))
    if not_built ~= nil then
      return nil, not_built
    end
  end
  -- A shortcut names a symbol; an inline link, a path first.
  if #found == 0 and name ~= nil and not bare and not path_first and resolver.context.unbuilt() ~= nil then
    resolver.unchecked = resolver.unchecked + 1
    return nil, ""
  end
  if #found == 0 and name ~= nil and not bare then
    local dotted = name:gsub(":", ".")
    local provisional = stale_for(resolver, tree_module(resolver, dotted))
    if provisional ~= nil then
      return nil, provisional
    end
    local held_in = module_file(resolver, dotted)
    if held_in ~= nil then
      return nil, dotted .. " is a module of the tree with no doc comment, so docs knows nothing of it: give " ..
        held_in .. " a leading `---`, or link the file `" .. held_in .. "`"
    end
  end
  if #found > 1 and file ~= nil then
    table.sort(found)
    return nil, "it names " .. tostring(#found) .. ": " .. table.concat(found, ", ") ..
      "; write ./" .. shown(resolver, file) .. " for the file, or the symbol in full"
  end
  if #found > 1 and name ~= nil then
    local problem = alike(resolver, (name:gsub(":", ".")), candidates)
    if problem ~= nil then
      return nil, problem
    end
  end
  if #found == 0 and file == nil and path_shaped(unescaped(path)) then
    why = why .. elsewhere(resolver, from, unescaped(path))
  end
  local problem = one_of(found, why)
  if problem ~= nil then
    return nil, problem
  end
  if file ~= nil then
    return in_file(file)
  end
  -- [`one_of`] found no fault and no file is named, so `found` holds one symbol's spelling.
  local symbol = assert(symbols[assert(found[1], "one symbol was found")], "a spelling found is one of the symbols")
  return made("symbol", { module = symbol.module, symbol = symbol.symbol, file = symbol.file }), ""
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
                            in_tree: boolean): link_resolve.Target?
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
--- a flag, an assignment, a pattern, a call with arguments); a name
--- alone that is one plain lowercase word (`path`, `run`), which reads
--- as prose or a variable as often as a declaration of its file, unless
--- it is written as a call (`run()`), which says it is the function; a
--- file's name alone (`vendor.tl`), which as often means the module a
--- file of that name holds, or another file of the name elsewhere; the
--- standard library, a directory, and what names nothing or more than
--- one thing. `in_tree` is `meant`'s.
function link_resolve.linkable(resolver: link_resolve.Resolver, from: string, content: string,
                               declared: function(): link_text.Declared,
                               module_level: function(): {string: boolean},
                               in_tree: boolean): link_resolve.Target?
  local name = link_text.name_of(content)
  if name == nil and not path_shaped(content) then
    return nil
  end
  if name ~= nil then
    local dotted = name:gsub(":", ".")
    local alone = dotted:find(".", 1, true) == nil
    if alone and dotted:match("^[%l%d]+$") ~= nil and content:sub(-2) ~= "()" then
      return nil
    end
    if declared().names[dotted] == true then
      if module_level()[dotted] == true then
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
  if target.kind == "file" or FILE_EXTENSIONS[content:match("%.(%w+)$") or ""] == true then
    return nil
  end
  return target
end

--- A context over the project at `root` as it is on disk, its
--- symbols answered by `symbols` and `member`, and `unbuilt` saying
--- why they lack the project's own code, or nil.
function link_resolve.on_disk(root: string,
                              symbols: function(query: string): {link_resolve.Symbol}?, string,
                              member: function(module: string, member: string): {link_resolve.Symbol}?, string,
                              unbuilt: function(): string?): link_resolve.Context
  return {
    root = root,
    kind = function(path: string): string?
      local st, _ = Fs.stat(path)
      if st == nil then return nil end
      return if st.kind == "dir" then "dir" else "file" end
    end,
    read = function(path: string): string?
      local text, _ = Fs.read(path)
      return text
    end,
    real = function(path: string): string?
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
  resolver.headings[path] = link_resolve.anchors(text)
end

return link_resolve
