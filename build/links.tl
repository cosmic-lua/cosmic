--- Links in comments and Markdown, and whether each one resolves:
--- what `cosmic fix` holds Teal, C, Zig and Markdown to, in any
--- project. A link is what CommonMark would show as one; anything else
--- is prose, and never fails.
---
--- A link takes one of three forms, as Markdown and rustdoc write them:
---
--- - `` [`x`] ``, a shortcut, whose target is `x`;
--- - `[text][label]` (or `[text][]`, or `[label]` alone), whose target
---   a `[label]: target` line gives, in the same comment block (a run
---   of comments on consecutive lines) or, in Markdown, anywhere in the
---   file. A label may be a code span, and then `` [`x`] `` is this
---   form, not a shortcut;
--- - `[text](target)`, inline, whose target is a URL or a path: no
---   space (but inside `<>`), none of `+*^$[]{}|\()`, and a `%` only in
---   a `%XX` escape, with at most a quoted title after it.
---
--- Prose, never checked: a name in backticks alone (`` `x` ``); a
--- reference whose label nothing defines (`[i][j]`, `[%a_][%w_]*`), as
--- CommonMark shows it as written; brackets in any other shape
--- (`[options]`); a footnote (`[^1]`); a code span (which ends with its
--- paragraph), a fenced block, and a Teal long comment (`--[[ ]]`,
--- code set aside). A `[` right after a word, a `]`, a `)` or a `%`
--- opens an index or a pattern, never a link. A URL (`http://`,
--- `https://`, `mailto:`) is not checked.
---
--- A shortcut's target resolves, in order, to:
---
--- 1. a name the file itself declares: a local, a function, a
---    parameter, a record's field or member (`Rec.field`), an enum's
---    value; and `alias.member` where `local alias = require("m")`,
---    which is `m`'s member `member`; or a value of the Lua standard
---    library this program carries (`string.format`, `print`; not
---    `io`, `os` or `debug`, which cosmic leaves out);
--- 2. for a name with a `.` or a `:` ([`Fs.read`], [`cosmic.fs`]), a symbol
---    the project's databases know, by the rule `cosmic docs <word>`
---    answers an exact query with ([`docs.exact`], a type's member
---    through an alias included), or a module's member written in full
---    ([`cosmic.fs.read`]). A name alone names no symbol of another
---    module: it links to a declaration of its own file, the standard
---    library or a file, and another module's symbol is written in
---    full, so that a link does not come to name another thing when
---    some module documents a name of its own;
--- 3. a file or directory of the tree, relative to the linking file's
---    directory and then to the project's root (a leading `/`: the root
---    alone), inside the root once links are followed and not under
---    the root's `o/` (a stale build directory an older tool wrote). An `#anchor` must name a
---    Markdown file's heading, `#` or underlined, or an `<a id>` or
---    `<a name>`, as GitHub makes anchors; `#anchor` alone names the
---    linking file's own. A `?query` is left off and `%XX` read.
---
--- A name the file declares wins outright, so a local shadows a symbol
--- of the same name. Past that, a shortcut must match exactly one
--- symbol or file: one that matches two symbols, or a symbol and a
--- file, fails and lists what it matched, each spelled in full (a file
--- as `./path`), so the link can name the one it means. An inline
--- link's or a definition's target is a path first, as in Markdown: a
--- file it names wins, and only a target that names no file is a name.
---
--- Where the project has no database of its own yet
--- ([`Context.unbuilt`]), a shortcut that resolves to nothing is counted
--- rather than failed: its symbol may be one the build would record.
---
--- `cosmic fix` also makes links of plain code spans (`rewrite`): a
--- `` `x` `` whose `x` is a name in full naming one symbol, a file of
--- the tree, or a top-level declaration of its own file becomes
--- `` [`x`] ``, by the
--- rule [`link_resolve.linkable`] gives, and `fix --check` fails on each
--- it would make. A Markdown file also gets the definitions GitHub
--- needs to show such a link, in a block at its end; a definition
--- whose label is a code span must name the file the label names, or
--- the file that declares its symbol.
---
--- The parse is [`build.link_text`]'s, C's, Zig's and Markdown's text
--- [`build.link_files`]', and the resolution [`build.link_resolve`]'s,
--- which the build shares to index each link ([`build.link_index`]);
--- this module answers symbols from the project's databases.

local Fs = require("cosmic.fs")
local Sqlite = require("cosmic.sqlite")
local docs = require("build.docs")
local link_resolve = require("build.link_resolve")
local link_text = require("build.link_text")
local symbol_index = require("build.symbol_index")
local symbols = require("build.symbols")
local String = require("cosmic.string")

local record links
  --- What a file declares, for resolution where a comment on a line
  --- stands (`at`) and for linking a plain span (`module_level`,
  --- [`link_resolve.linkable`]); `parsed` false for Teal that does not
  --- parse.
  record Known
    at: function(line: integer): link_text.Declared
    module_level: {string: boolean}
    parsed: boolean
    --- What every line sees ([`link_text.Declarations`]'s `everywhere`), where the reader keeps it.
    everywhere?: {string: boolean}
  end

  --- What `check` and `rewrite` read of a Teal file, taken from a
  --- parse the caller already has (`facts`): good for `source` alone.
  record Facts
    source: string
    blocks: {link_text.Block}
    known: Known
  end

  --- What `rewrite` made of a file: its new text, and each span it linked
  --- as `file:line: link: ...`, the file as named.
  record Rewritten
    mut source: string
    mut linked: mut {string}
    --- Whether a Markdown file's block of definitions changes.
    mut redefined: boolean
  end

  --- How [`links.check`] and [`links.rewrite`] read a file named `name`, of `kind`
  --- ([`build.link_files.kind_of`]): its comments in blocks, and what it
  --- declares. Teal is read off the new grammar's tree
  --- ([`build.syntax_links`]).
  record Reader
    blocks: function(kind: string, source: string, name: string): {link_text.Block}
    declarations: function(kind: string, source: string, name: string): Known
  end

  check: function(reader: Reader, resolver: link_resolve.Resolver, file: string, absolute: string, kind: string,
                  source: string, facts?: Facts): {string}
  rewrite: function(reader: Reader, resolver: link_resolve.Resolver, file: string, absolute: string, kind: string,
                    source: string, facts?: Facts): Rewritten
end

local type Known = links.Known
local type Rewritten = links.Rewritten

--- The path from the directory `from` to `to`, both from the root.
local function relative_path(from: string, to: string): string
  local from_parts: mut {string} = {}
  for part in from:gmatch("[^/]+") do from_parts[#from_parts + 1] = part end
  local to_parts: mut {string} = {}
  for part in to:gmatch("[^/]+") do to_parts[#to_parts + 1] = part end
  local common = 0
  while common < #from_parts and common < #to_parts - 1 and
      from_parts[common + 1] == to_parts[common + 1] do
    common = common + 1
  end
  local out: mut {string} = {}
  for _ = common + 1, #from_parts do out[#out + 1] = ".." end
  for index = common + 1, #to_parts do out[#out + 1] = to_parts[index] end
  return table.concat(out, "/")
end

--- The file from the root that a link to `target` names: the file
--- itself, or the one that declares its symbol.
local function file_of(target: link_resolve.Target): string
  return target.kind == "symbol" and target.file or target.path
end

--- What is wrong with `link`, a definition in the file at the absolute
--- path `absolute`, when its label is one code span naming a symbol or
--- a file ([`link_resolve.meant`]): the label decides what the link names,
--- so its target must be the file the label names or the one that
--- declares its symbol. Nil when it is, and for any other definition,
--- whose target is checked as a path.
local function misdefined(resolver: link_resolve.Resolver, absolute: string, link: link_text.Link,
                          declared: function(): link_text.Declared): string?
  local named = link_text.shortcut_target(link.label or "")
  if named == nil or link.target:match("^%a[%w+.-]*:") ~= nil then
    return nil
  end
  local meant = link_resolve.meant(resolver, absolute, named, declared, true)
  if meant == nil then
    return nil
  end
  local expected = file_of(meant)
  local got, _ = link_resolve.resolve(resolver, absolute, link.target, declared, true)
  if got ~= nil and got.kind == "file" and got.path == expected then
    return nil
  end
  local what = if meant.kind == "symbol" then "declared in " else "the file " end
  return "the definition of " .. named .. " names " .. link.target .. ", but " .. named ..
    " is " .. what .. expected
end

--- What is wrong with the links of `source`, a file of `kind` at the absolute path `absolute`, each as
--- `file:line: link: ...` with `file` as it was named, the file read by `reader`. Nothing when it holds no link, or every
--- link resolves to one thing.
function links.check(reader: links.Reader, resolver: link_resolve.Resolver, file: string, absolute: string,
                     kind: string, source: string, facts?: links.Facts): {string}
  if facts ~= nil and facts.source ~= source then
    facts = nil
  end
  local out: mut {string} = {}
  if not link_text.may_link(source) then
    return out
  end
  if kind == "markdown" then
    link_resolve.holds(resolver, absolute, source)
  end
  -- What the file declares, once a link asked for it.
  local own: mut {Known} = {}
  if facts ~= nil and facts.known ~= nil then own[1] = facts.known end
  local blocks = facts ~= nil and facts.blocks or reader.blocks(kind, source, file)
  for _, link in ipairs(link_text.in_blocks(blocks)) do
    local function declared(): link_text.Declared
      local found: Known = own[1] or reader.declarations(kind, source, file)
      own[1] = found
      return found.at(link.line)
    end
    local wrong = link.form == "definition" and misdefined(resolver, absolute, link, declared) or nil
    if wrong ~= nil then
      out[#out + 1] = file .. ":" .. link.line .. ": link: " .. wrong
    -- A reference's target is checked where its definition is.
    elseif link.form ~= "reference" then
      local target, problem = link_resolve.resolve(resolver, absolute, link.target, declared,
        link.form ~= "shortcut")
      -- No problem named: a symbol not checked ([`Context.unbuilt`]).
      if target == nil and problem ~= "" then
        out[#out + 1] = file .. ":" .. link.line .. ": link: " .. link.target ..
          " does not resolve (" .. problem .. ")"
      end
    end
  end
  return out
end

--- A block of definitions `fix` writes at the end of a Markdown file,
--- one line each: `` [`x`]: path ``.
local definition_line = "^%[(`+[^`]+`+)%]:[ \t]+(%S+)[ \t]*$"

--- `text`, a Markdown file, split before the block of definitions at
--- its end (`definition_line`, each label a code span), trailing blank
--- lines and all; the block is "" when there is none.
local function split_definitions(text: string): string, string
  local lines: mut {string} = {}
  for line in String.lines(text) do lines[#lines + 1] = line end
  if lines[#lines] == "" then lines[#lines] = nil end
  local last = #lines
  while last > 0 and lines[last]:match("^%s*$") ~= nil do last = last - 1 end
  local first = last + 1
  while first > 1 and lines[first - 1]:match(definition_line) ~= nil do first = first - 1 end
  if first > last or (first > 1 and lines[first - 1]:match("^%s*$") == nil) then
    return text, ""
  end
  return table.concat(lines, "\n", 1, first - 1), table.concat(lines, "\n", first, last)
end

--- `source`, a file of `kind` at the absolute path `absolute`, with each
--- plain code span [`link_resolve.linkable`] names a target for made a
--- shortcut link (`` `x` `` to `` [`x`] ``); the rule is that
--- function's, and [`link_text.plain_spans`] says which spans could be one.
--- A span whose label a definition in its block already holds, or, in
--- Markdown, whose label two spans would give different targets, stays
--- as written. Teal that does not parse is left as it is.
---
--- GitHub shows a shortcut with no definition as the text it is, so a
--- Markdown file also gets a block of definitions at its end, sorted,
--- one for each label of a code span its shortcuts use that names a
--- symbol or a file of the tree ([`link_resolve.meant`]): the path, from
--- the file's directory, of the file the label names or of the one that
--- declares its symbol. That block is rewritten whole each time: a
--- definition no link uses goes, and one that names another file than
--- its label is set right.
function links.rewrite(reader: links.Reader, resolver: link_resolve.Resolver, file: string, absolute: string,
                       kind: string, source: string, facts?: links.Facts): Rewritten
  local out: Rewritten = { source = source, linked = {}, redefined = false }
  if source:find("`", 1, true) == nil then
    return out
  end
  if facts ~= nil and facts.source ~= source then
    facts = nil
  end
  -- What the file declares is read once a span could name something.
  local held: mut {Known} = {}
  if facts ~= nil and facts.known ~= nil then held[1] = facts.known end
  local function known(): Known
    local found = held[1]
    if found == nil then
      found = reader.declarations(kind, source, file)
      held[1] = found
    end
    return found
  end
  local function module_level(): {string: boolean} return known().module_level end
  local markdown = kind == "markdown"
  local body, managed = source, ""
  if markdown then
    body, managed = split_definitions(source)
  end
  -- Each bracket to put in, by the byte it goes before.
  local inserts: mut {integer: string} = {}
  local by_label: mut {string: {{integer}}} = {}
  local label_target: mut {string: string} = {}
  local refused: mut {string: boolean} = {}
  local blocks = facts ~= nil and facts.blocks or reader.blocks(kind, body, file)
  for _, block in ipairs(blocks) do
    local defined: mut {string: boolean} = {}
    if block.text:find("]:", 1, true) ~= nil then
      for _, link in ipairs(link_text.parse(block.text)) do
        if link.form == "definition" then defined[link_text.label_key(link.label or "")] = true end
      end
    end
    local starts = block.starts or {}
    local spans = link_text.plain_spans(block.text)
    local block_lines: mut {string} = {}
    if kind == "c" and #spans > 0 then
      for line in String.lines(block.text) do block_lines[#block_lines + 1] = line end
    end
    for _, span in ipairs(spans) do
      local key = link_text.label_key(span.written)
      local at = if (starts[span.line] or 0) > 0 then starts[span.line] + span.column - 1 else 0 end
      -- A C header's `---` and `--` lines are the Teal declaration of
      -- its bindings ([`build.gen_syscalls`]): their names are that
      -- declaration's, not the header's, so their spans stay as written.
      local teal_in_c = kind == "c" and (block_lines[span.line] or ""):match("^%s*%-%-") ~= nil
      if not defined[key] and not teal_in_c and at > 0 and
          body:sub(at, at + #span.written - 1) == span.written then
        local function declared(): link_text.Declared
          return known().at(block.line + span.line - 1)
        end
        local target = link_resolve.linkable(resolver, absolute, span.content, declared, module_level,
          markdown)
        if target ~= nil then
          local said = target.kind == "declared" and target.name or
            target.kind == "file" and target.path or
            link_resolve.spelled({ module = target.module, symbol = target.symbol })
          if label_target[key] ~= nil and label_target[key] ~= said then
            refused[key] = true
          end
          label_target[key] = said
          by_label[key] = by_label[key] or {}
          table.insert(by_label[key], { at, at + #span.written })
          inserts[at] = "["
          inserts[at + #span.written] = "]"
          out.linked[#out.linked + 1] = file .. ":" .. (block.line + span.line - 1) ..
            ": link: " .. span.written .. " would link to " .. said
        end
      end
    end
  end
  -- Teal that does not parse is left as it is.
  if held[1] ~= nil and not held[1].parsed then
    return { source = source, linked = {}, redefined = false }
  end
  if markdown then
    for key in pairs(refused) do
      for _, pair in ipairs(by_label[key]) do
        inserts[pair[1]] = nil
        inserts[pair[2]] = nil
      end
    end
    local kept: mut {string} = {}
    for _, line in ipairs(out.linked) do
      local written = line:match(": link: (`+[^`]+`+) would link to ")
      if written == nil or not refused[link_text.label_key(written)] then kept[#kept + 1] = line end
    end
    out.linked = kept
  end
  local positions: mut {integer} = {}
  for at in pairs(inserts) do positions[#positions + 1] = at end
  table.sort(positions)
  local pieces: mut {string} = {}
  local from = 1
  for _, at in ipairs(positions) do
    pieces[#pieces + 1] = body:sub(from, at - 1)
    pieces[#pieces + 1] = inserts[at]
    from = at
  end
  pieces[#pieces + 1] = body:sub(from)
  local linked = table.concat(pieces)
  if not markdown then
    out.source = linked
    return out
  end

  -- The definitions the shortcuts of the linked text need. One of the
  -- block's own whose label names nothing `meant` answers is another's
  -- to set right, and is kept while a link uses it.
  local root = resolver.context.root
  local here = Fs.dirname(absolute):sub(#root + 2)
  local wanted: mut {string: string} = {}
  local labels: mut {string: string} = {}
  local human: mut {string: boolean} = {}
  local had: mut {string: link_text.Link} = {}
  for _, link in ipairs(link_text.parse(managed)) do
    if link.form == "definition" then had[link_text.label_key(link.label or "")] = link end
  end
  local shortcuts: mut {link_text.Link} = {}
  for _, link in ipairs(link_text.parse(linked)) do
    if link.form == "definition" then
      human[link_text.label_key(link.label or "")] = true
    elseif link.form == "shortcut" then
      shortcuts[#shortcuts + 1] = link
    end
  end
  for _, link in ipairs(shortcuts) do
    local key = link_text.label_key(link.text)
    if not human[key] and labels[key] == nil then
      local function declared(): link_text.Declared return known().at(link.line) end
      local meant = link_resolve.meant(resolver, absolute, link.target, declared, true)
      if meant ~= nil then
        labels[key] = link.text
        wanted[key] = relative_path(here, file_of(meant))
      elseif had[key] ~= nil then
        labels[key] = had[key].label
        wanted[key] = had[key].target
      end
    end
  end
  local keys: mut {string} = {}
  for key in pairs(wanted) do keys[#keys + 1] = key end
  table.sort(keys)
  local lines: mut {string} = {}
  for _, key in ipairs(keys) do
    lines[#lines + 1] = "[" .. labels[key] .. "]: " .. wanted[key]
  end
  local block = table.concat(lines, "\n")
  if block == managed and linked == body then
    return out
  end
  if block == "" then
    out.source = managed == "" and linked or (linked:gsub("%s+$", "") .. "\n")
  else
    out.source = linked:gsub("%s+$", "") .. "\n\n" .. block .. "\n"
  end
  out.redefined = block ~= managed
  return out
end

--- The rows of `view` that `cosmic docs` shows, each from the database
--- that owns its module, held in memory.
local function index_of(view: docs.View): symbol_index.Index?, string
  local out = symbol_index.new()
  for module in pairs(view.owners) do symbol_index.module(out, module) end
  for index, db in ipairs(view.databases) do
    local tables, tables_trouble = Sqlite.text_rows(db,
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'docs'")
    if tables == nil then return nil, tables_trouble end
    if #tables > 0 then
      -- Every row, as [`build.docs`] reads a type an alias stands for
      -- in any; only those shown, of the database that owns the
      -- module, answer a name.
      local rows, trouble = Sqlite.text_rows(db,
        "SELECT d.module, d.symbol, d.source_symbol, d.file, d.kind, d.signature, d.exported, " ..
          "d.id, " .. symbols.shown_docs("d", view.public[index] == true) .. " FROM docs d " ..
          "ORDER BY d.module, d.id")
      if rows == nil then return nil, trouble end
      for _, row in ipairs(rows) do
        symbol_index.add(out, { module = row:text(1), symbol = row:text(2), source_symbol = row:text(3),
          file = row:text(4), kind = row:text(5), signature = row:text(6), exported = row:text(7) == "1",
          shown = row:text(9) == "1" and view.owners[row:text(1)] == index, database = index,
          id = math.tointeger(tonumber(row:text(8))) or 0 })
      end
    end
    local bound, bound_trouble = symbol_index.add_bound(out, db, "")
    if not bound then return nil, bound_trouble end
  end
  return out, ""
end

--- A context over the project at `root` as it is on disk, with symbols
--- from the view `open` gives, opened the first time a link asks for
--- one: a file with no link to a symbol reads no database. `unbuilt`
--- says why the view lacks the project's own code, or nil. A name is
--- answered from the view's rows held in memory ([`build.symbol_index`]).
function links.context(root: string, open: function(): docs.View?, string,
                       unbuilt: function(): string?): link_resolve.Context
  -- The index once built, or why it could not be; neither until asked.
  local ready_index: mut {symbol_index.Index} = {}
  local failure: mut {string} = {}
  local function ready(): symbol_index.Index?, string
    if ready_index[1] ~= nil then return ready_index[1], "" end
    if failure[1] ~= nil then return nil, failure[1] end
    local opened, why = open()
    if opened == nil then
      failure[1] = why
      return nil, why
    end
    local indexed, index_trouble = index_of(opened)
    if indexed == nil then
      failure[1] = index_trouble
      return nil, index_trouble
    end
    ready_index[1] = indexed
    return indexed, ""
  end
  local function named(query: string): {link_resolve.Symbol}?, string
    local index, why = ready()
    if index == nil then return nil, why end
    return symbol_index.named(index, query), ""
  end
  local function member(module: string, name: string): {link_resolve.Symbol}?, string
    local index, why = ready()
    if index == nil then return nil, why end
    return symbol_index.member(index, module, name), ""
  end
  return link_resolve.on_disk(root, named, member, unbuilt)
end

return links
