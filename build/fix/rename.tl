--- `cosmic fix --rename Old=new`: renames a module's member, or a field of a record a module declares, at its declaration
--- and at each place `cosmic uses` finds ([`cosmic.doc`]'s [`Doc.uses`]): a read or a call through the module, an alias of
--- it, or a value the checker typed, and each link to it in a comment or a Markdown file. The rest of the run is the fix it
--- is part of, over the files written where it names no paths, which lays them out and builds them, so a place left
--- there fails that build at its line.
---
--- An edit is made only where it names one place. On a line of code that is a `.old` or `:old` after a name: the only one
--- of the line, or each one after a name that the file binds to the module by `require`, or after the member's own
--- record. A line with more than one and none of those is left as it was and told. Once those are written, a key of a
--- table literal or a write that the checker refuses because the record has no field of the old name is renamed too.
local Clock = require("cosmic.clock")
local Doc = require("cosmic.doc")
local Fs = require("cosmic.fs")
local Lexer = require("lang.lexer")
local Pipeline = require("build.pipeline")
local Sqlite = require("cosmic.sqlite")
local build_paths = require("build.paths")
local String = require("cosmic.string")
local clock = require("build.clock")
local logger = require("build.logger")
local log = logger.log

local record Rename
  --- One edit: `length` bytes of a file at `offset` (from 1) become `text`.
  record Splice
    offset: integer
    length: integer
    text: string
  end

  --- What a rename did: each file written, each line left as it was and why (`a.tl:3: ...`), and how many places changed.
  record Done
    written: {string}
    left: {string}
    places: integer
  end
end

local type Splice = Rename.Splice

local KEYWORDS: mut {string: boolean} = {}
for word in ("and break do else elseif end false for function goto if in local nil not or repeat return then true " ..
    "until while"):gmatch("%S+") do
  KEYWORDS[word] = true
end

--- `old` and `new` of `Old=new`, where `new` is a name Lua takes and `old` is not empty.
function Rename.parse(given: string): (string, string) | (nil, string)
  local old, new = given:match("^([^=]+)=([^=]*)$")
  if old == nil or new == nil then
    return nil, "--rename takes Old=new (Money.format=render), not '" .. given .. "'"
  end
  if not new:match("^[%a_][%w_]*$") then
    return nil, "--rename: '" .. new .. "' is no name: write the new last name alone (render, not Money.render)"
  end
  if KEYWORDS[new] == true then
    return nil, "--rename: '" .. new .. "' is a keyword of Lua, so no name"
  end
  return old, new
end

--- The names `source` binds to `module` by `require`: `M` of `local M = require("money")` and of
--- `local type M = require("money")`.
local function aliases(source: string, module: string): mut {string: boolean}
  local out: mut {string: boolean} = {}
  for name, required in source:gmatch("local%s+([%a_][%w_]*)%s*=%s*require%s*%(?%s*[\"']([^\"']+)[\"']") do
    if required == module then out[name] = true end
  end
  for name, required in source:gmatch("local%s+type%s+([%a_][%w_]*)%s*=%s*require%s*%(?%s*[\"']([^\"']+)[\"']") do
    if required == module then out[name] = true end
  end
  return out
end

--- The splices of the code on line `y` of `tokens`: each `.old` or `:old` there, by the rule of the module's header.
--- @return string | nil Why the line was left, when it was
local function code_splices(tokens: Lexer.Tokens, y: integer, old: string, new: string, owners: {string: boolean},
                            out: mut {Splice}): string?
  local found: mut {integer} = {}
  local owned: mut {integer} = {}
  for i = 2, Lexer.count(tokens) do
    if Lexer.y(tokens, i) == y and Lexer.kind(tokens, i) == "identifier" and Lexer.text(tokens, i) == old then
      local before: string = Lexer.kind(tokens, i - 1)
      if before == "." or before == ":" then
        found[#found + 1] = i
        if i >= 3 and Lexer.kind(tokens, i - 2) == "identifier" and owners[Lexer.text(tokens, i - 2)] == true then
          owned[#owned + 1] = i
        end
      end
    end
  end
  local chosen: {integer} = if #found == 1 then found elseif #owned > 0 then owned else {} end
  if #chosen == 0 then
    if #found == 0 then return "no ." .. old .. " or :" .. old .. " here" end
    return String.counted(#found, "place") .. " name ." .. old .. " here, and none through the module: edit it by hand"
  end
  for _, i in ipairs(chosen) do
    local splice: Splice = { offset = Lexer.offset(tokens, i), length = #old, text = new }
    out[#out + 1] = splice
  end
  return nil
end

--- The splice of the declaration on line `y`: the first `old` there after a `.` or `:` (`function Money.format`), else
--- the first before a `:` (a field, `name: string`) or `=`.
local function declaration_splice(tokens: Lexer.Tokens, y: integer, old: string, new: string, out: mut {Splice}): string?
  local fallback: integer? = nil
  for i = 2, Lexer.count(tokens) do
    if Lexer.y(tokens, i) == y and Lexer.kind(tokens, i) == "identifier" and Lexer.text(tokens, i) == old then
      local before: string = Lexer.kind(tokens, i - 1)
      if before == "." or before == ":" then
        local splice: Splice = { offset = Lexer.offset(tokens, i), length = #old, text = new }
        out[#out + 1] = splice
        return nil
      end
      local after: string = if i < Lexer.count(tokens) then Lexer.kind(tokens, i + 1) else "" end
      if fallback == nil and (after == ":" or after == "=") then fallback = i end
    end
  end
  if fallback ~= nil then
    local splice: Splice = { offset = Lexer.offset(tokens, fallback), length = #old, text = new }
    out[#out + 1] = splice
    return nil
  end
  return "no declaration of " .. old .. " here"
end

--- The offset (from 1) at which line `y` of `source` starts, and the one at which it ends (its newline or the end).
local function line_span(source: string, y: integer): (integer, integer) | (nil, nil)
  local start = 1
  for _ = 2, y do
    local at = source:find("\n", start, true)
    if at == nil then return nil, nil end
    start = at + 1
  end
  local stop: integer = source:find("\n", start, true) or (#source + 1)
  return start, stop
end

--- The splices of each link on line `y` of `source`: a `` `...old` `` span whose text, with `:` read as `.`, is one of
--- `names`, the ways to write the member.
local function link_splices(source: string, y: integer, old: string, new: string, names: {string: boolean},
                            out: mut {Splice}): string?
  local start, stop = line_span(source, y)
  if start == nil then return "no such line" end
  local before = #out
  local at = start
  while at < stop do
    local open = source:find("`", at, true)
    if open == nil or open >= stop then break end
    local close = source:find("`", open + 1, true)
    if close == nil or close >= stop then break end
    local span = source:sub(open + 1, close - 1)
    local mark = span:sub(-#old - 1, -#old - 1)
    if #span > #old and span:sub(-#old) == old and (mark == "." or mark == ":") and
        names[span:sub(1, -#old - 2) .. "." .. old] == true then
      out[#out + 1] = { offset = close - #old, length = #old, text = new }
    end
    at = close + 1
  end
  if #out == before then return "no link to ." .. old .. " here" end
  return nil
end

--- `source` with each splice of `splices` made; they do not overlap.
local function spliced(source: string, splices: {Splice}): string
  local sorted: mut {Splice} = {}
  local seen: mut {integer: boolean} = {}
  for _, s in ipairs(splices) do
    if seen[s.offset] == nil then
      seen[s.offset] = true
      sorted[#sorted + 1] = s
    end
  end
  table.sort(sorted, function(a: Splice, b: Splice): boolean return a.offset < b.offset end)
  local parts: mut {string} = {}
  local at = 1
  for _, s in ipairs(sorted) do
    parts[#parts + 1] = source:sub(at, s.offset - 1)
    parts[#parts + 1] = s.text
    at = s.offset + s.length
  end
  parts[#parts + 1] = source:sub(at)
  return table.concat(parts)
end

--- The places of one file to rename: its lines of code, of links, and the declaration's line (0 for none).
local record Places
  code: mut {integer: boolean}
  links: mut {integer: boolean}
  mut declared: integer
end

--- The splices of the places `uses` does not see, after the first edits are written: each key of a table literal and
--- each write the checker now refuses because `record` (`Invoice.Line`) has no field `old`, in each Teal file of the
--- tree at `root` (its standing `own`) whose text names `old`. Checked over the build the run staged, with the texts as
--- they now stand.
local function refused_splices(root: string, own: boolean, record: string, old: string, new: string):
    ({string: {Splice}}) | (nil, string)
  local options, options_trouble = Pipeline.options(root, own)
  if options == nil then return nil, options_trouble end
  local db, open_trouble = Sqlite.open(build_paths.resolve(root).working)
  if db == nil then return nil, tostring(open_trouble) end
  local built, built_trouble = Pipeline.build(db, options)
  local _, _ = db:close()
  if built == nil then return nil, built_trouble end
  local build = built.build
  local word = "%f[%w_]" .. old .. "%f[^%w_]"
  local named: mut {string} = {}
  local texts: mut {string: string} = {}
  local files: mut {string: string} = {}
  for _, source in ipairs(built.index.sources) do
    if source.dialect == "tl" then
      local text, _ = Fs.read(root .. "/" .. source.filename)
      if text ~= nil and text:find(word) ~= nil then
        named[#named + 1] = source.module
        texts[source.module] = text
        files[source.module] = source.filename
        if text ~= source.text then local _ = build:replace(source.module, text) end
      end
    end
  end
  build:lower(named)
  local out: mut {string: {Splice}} = {}
  local owner = "`" .. record .. "`"
  local field = "`" .. old .. "`"
  for _, module in ipairs(named) do
    local result = build:result(module, true)
    local text = texts[module]!
    if result ~= nil then
      local splices: mut {Splice} = {}
      for _, problem in ipairs(result.errors) do
        if problem.msg:find(owner, 1, true) ~= nil and problem.msg:find(field, 1, true) ~= nil then
          -- A key names the field where the error is; a write's error is at its target (`l` of `l.name = x`), whose
          -- `.name` follows on the line.
          local at: integer? = nil
          if text:sub(problem.offset, problem.offset + #old - 1) == old then
            at = problem.offset
          else
            local dot = text:find("[.:]" .. old .. "%f[^%w_]", problem.offset)
            local newline = text:find("\n", problem.offset, true)
            if dot ~= nil and (newline == nil or dot < newline) then at = dot + 1 end
          end
          if at ~= nil then
            local splice: Splice = { offset = at, length = #old, text = new }
            splices[#splices + 1] = splice
          end
        end
      end
      if #splices > 0 then out[files[module]!] = splices end
    end
  end
  return out
end

--- Renames `old` (as `cosmic uses` takes it) to `new` in the tree at `root` (its standing `own`), from the last build's
--- uses; where `checking`, writes nothing and tells what it would change.
function Rename.run(root: string, own: boolean, old: string, new: string, checking: boolean): (Rename.Done) | (nil, string)
  local started = Clock.monotonic_ns()
  local docs = require("build.docs")
  -- A build of its own, as `cosmic uses` makes, though no build has been made here yet: the uses are its rows.
  local built, build_trouble = require("build.rebuild").here("fix", true)
  if not built then
    return nil, "the tree does not build, so its uses are not known: fix the build first" ..
      (if build_trouble ~= "" then ": " .. build_trouble else "" end)
  end
  local sources = docs.databases()
  local view, view_trouble = docs.view(sources.handles, sources.public)
  if view == nil then return nil, view_trouble end
  local entries, exact_trouble = Doc.exact(view, old)
  if entries == nil then return nil, tostring(exact_trouble) end
  local declared: mut {Doc.Entry} = {}
  for _, e in ipairs(entries) do
    if e.symbol ~= "" and e.file ~= "" then declared[#declared + 1] = e end
  end
  if #declared ~= 1 then
    local names: mut {string} = {}
    for _, e in ipairs(declared) do names[#names + 1] = e.module .. " " .. e.symbol end
    if #declared == 0 then
      return nil, "'" .. old .. "' names no member a file of the tree declares"
    end
    return nil, "'" .. old .. "' names " .. String.counted(#declared, "member") .. " (" .. table.concat(names, ", ") ..
      "): write it in full"
  end
  local entry = declared[1]
  local last = entry.symbol:match("([%a_][%w_]*)$") or entry.symbol
  if last == new then return nil, entry.symbol .. " is called " .. new .. " already" end
  local sibling = entry.module .. "." .. entry.symbol:sub(1, #entry.symbol - #last) .. new
  local taken, _ = Doc.exact(view, sibling)
  for _, e in ipairs(taken or {}) do
    if e.symbol ~= "" and e.file ~= "" then
      return nil, sibling .. " is declared already (" .. e.file .. ":" .. tostring(e.line) .. "): pick another name"
    end
  end
  local found, uses_trouble = Doc.uses(view, entry.module .. "." .. entry.symbol)
  if found == nil then return nil, tostring(uses_trouble) end
  local files: mut {string: Places} = {}
  local order: mut {string} = {}
  local function places(file: string): Places
    local p = files[file]
    if p == nil then
      p = { code = {}, links = {}, declared = 0 }
      files[file] = p
      order[#order + 1] = file
    end
    return p
  end
  places(entry.file).declared = entry.line
  for _, use in ipairs(found) do
    if use.module == entry.module and use.symbol == entry.symbol then
      local p = places(use.from_file)
      if use.link then p.links[use.line] = true else p.code[use.line] = true end
    end
  end
  table.sort(order)
  -- A use through the member's own record, in its file or another: `Money` of `Money.format`.
  local owner = entry.source_symbol:match("^([%a_][%w_]*)%.") or ""
  -- What a link to the member may write, before its last part: the module, the record, or an alias of the module.
  local rest = entry.symbol:sub(1, #entry.symbol - #last)
  local written: mut {string} = {}
  local left: mut {string} = {}
  local count = 0
  for _, file in ipairs(order) do
    local p = files[file]!
    local path = root .. "/" .. file
    local source, read_trouble = Fs.read(path)
    if source == nil then return nil, tostring(read_trouble) end
    local teal = file:match("%.tl$") ~= nil
    local tokens: Lexer.Tokens? = if teal then Lexer.lex(source, file).tokens else nil end
    local owners = aliases(source, entry.module)
    if owner ~= "" then owners[owner] = true end
    local splices: mut {Splice} = {}
    local function tell(y: integer, why: string?)
      if why ~= nil then
        local told = file .. ":" .. tostring(y) .. ": " .. why
        left[#left + 1] = told
      end
    end
    if p.declared > 0 and tokens ~= nil then
      tell(p.declared, declaration_splice(tokens, p.declared, last, new, splices))
    end
    local lines: mut {integer} = {}
    for y in pairs(p.code) do lines[#lines + 1] = y end
    table.sort(lines)
    for _, y in ipairs(lines) do
      if y ~= p.declared then
        if tokens ~= nil then
          tell(y, code_splices(tokens, y, last, new, owners, splices))
        else
          tell(y, "no Teal file: edit it by hand")
        end
      end
    end
    local linked: mut {integer} = {}
    for y in pairs(p.links) do linked[#linked + 1] = y end
    table.sort(linked)
    local names: mut {string: boolean} = {
      [entry.module .. "." .. entry.symbol] = true, [entry.symbol] = true, [entry.source_symbol] = true }
    for alias in pairs(owners) do names[alias .. "." .. rest .. last] = true end
    for _, y in ipairs(linked) do tell(y, link_splices(source, y, last, new, names, splices)) end
    if #splices > 0 then
      count = count + #splices
      if checking then
        log:say("fix: --rename would change " .. String.counted(#splices, "place") .. " in " .. file)
      else
        local ok, write_trouble = Fs.write(path, spliced(source, splices))
        if not ok then return nil, tostring(write_trouble) end
      end
      written[#written + 1] = file
    end
  end
  -- A key of a table literal or a write is no use, but once the declaration is renamed the checker refuses each one
  -- by the old name: those are renamed too.
  local record_name = entry.source_symbol:match("^(.+)%.[%a_][%w_]*$")
  if not checking and record_name ~= nil and #written > 0 then
    local more, more_trouble = refused_splices(root, own, record_name, last, new)
    if more == nil then
      log:say("fix: --rename: no keys nor writes looked for: " .. more_trouble)
    else
      local more_files: mut {string} = {}
      for file in pairs(more) do more_files[#more_files + 1] = file end
      table.sort(more_files)
      for _, file in ipairs(more_files) do
        local path = root .. "/" .. file
        local source, read_trouble = Fs.read(path)
        if source == nil then return nil, tostring(read_trouble) end
        local ok, write_trouble = Fs.write(path, spliced(source, more[file]!))
        if not ok then return nil, tostring(write_trouble) end
        count = count + #more[file]!
        local seen = false
        for _, w in ipairs(written) do
          if w == file then seen = true end
        end
        if not seen then written[#written + 1] = file end
      end
    end
  end
  for _, why in ipairs(left) do log:say("fix: --rename left " .. why) end
  log:say("fix: --rename " .. entry.module .. " " .. entry.symbol .. " to " .. new .. ": " ..
      String.counted(count, "place") .. " in " .. String.counted(#written, "file") ..
      (if #left > 0 then ", " .. String.counted(#left, "line") .. " left" else "" end) ..
      "; the build below names any place left, " .. clock.took(started))
  return { written = written, left = left, places = count }
end

return Rename
