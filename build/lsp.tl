--- `cosmic lsp`: a Language Server Protocol server for Teal, so an editor
--- shows what `cosmic fix` and `cosmic test` would refuse as it is typed.
---
--- It serves one editor over standard input and output, or, with
--- `--listen [host:]port` or `--socket <path>`, each editor that connects
--- (a session of its own per connection) until SIGINT or SIGTERM. Messages
--- are JSON-RPC 2.0 framed by a `Content-Length` header, as the protocol's
--- base layer says.
---
--- What it answers:
---
--- - Diagnostics, published as a document is opened, changed or saved:
---   the checker's syntax and type errors and its warnings, which a build
---   refuses as it refuses errors, each with [`teal.replacement`]'s hint,
---   and what else a build refuses of a module: a `global`, a test that
---   returns a value, and in cosmic's own tree its contracts and its stub
---   ([`compilation.generate`]).
---   The text is checked in memory, as the editor holds it, after the
---   rewrite a build makes of it first ([`build.shape_specs`]), so a
---   column is the document's own. A `require` is answered as a build
---   names modules: from an open document first, then the file below the
---   workspace's root (`a/b.d.tl`, `a/b.tl`, `a/b/init.tl`, then a template),
---   then the binary's own `cosmic.*` modules, so a project's modules need
---   no build.
--- - Hover: the docs of the symbol under the cursor, from the binary's own
---   docs and the project's last build, as `cosmic docs`. A name whose
---   first part is a local bound to a `require` is looked up in the module
---   required: [`Fs.read`], with `local Fs = require("cosmic.fs")`, is
---   [`cosmic.fs.read`].
--- - Formatting: the whole document as `cosmic fix` writes it.
---
--- Where the editor takes a registration of the files to watch, the
--- server registers every `.tl` and `.tmpl` file at `initialized`, and
--- checks each open document again when one changes on disk.
---
--- Positions are UTF-16, the protocol's default, or UTF-8 where the
--- client offers it (`general.positionEncodings`). A line ends at "\r\n",
--- "\n" or a lone "\r".
---
--- Over standard input and output it exits 0 after `shutdown`, at `exit`
--- or the stream's end, and 1 at an `exit` or an end that comes without
--- `shutdown`, or a stream that breaks. A listener exits 0 when SIGINT or
--- SIGTERM stops it, closing every connection still open, and 1 when it
--- cannot listen. A socket file that a listener which crashed left, one
--- nothing listens at, is removed before listening at its path. A
--- command line it refuses exits 2.
---
--- Its `spec` (build/verb_spec.tl) is `bare`: standard output is the
--- protocol's. Complaints go to standard error as `cosmic: lsp: ...`.

local Cli = require("cosmic.cli")
local Clock = require("cosmic.clock")
local Flags = require("cosmic.flags")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Net = require("cosmic.net")
local Shape = require("cosmic.shape")
local Sqlite = require("cosmic.sqlite")
local Store = require("cosmic.store")
local Stream = require("cosmic.stream")
local Template = require("cosmic.template")
local Url = require("cosmic.url")
local analyzer = require("build.analyzer")
local ast = require("build.ast")
local bare = require("build.bare")
local compilation = require("build.compilation")
local docs = require("build.docs")
local globals = require("build.globals")
local plural = require("build.plural")
local receivers = require("build.receivers")
local shape_specs = require("build.shape_specs")
local stub = require("build.stub")
local teal = require("build.teal")
local tree = require("build.tree")
local verb_spec = require("build.verb_spec")
local type compiler = require("build.compiler")
local type build_module = require("build.module")

local record lsp
  --- The verb's registration: see build/verb_spec.tl.
  spec: verb_spec.Spec

  --- A document the editor holds open.
  record Document
    uri: string
    text: string
    --- The name the checker knows it by: its path below the root, or its
    --- absolute path when it is not below it.
    name: string
  end

  --- What a session is given beyond its root: what a test stands in for.
  record Options
    --- Where complaints go, without their newline: standard error when nil.
    err?: function(line: string)
    --- The databases docs are read from: [`Store.databases()`] when nil.
    store?: {Sqlite.Handle}
  end

  --- A project module the checker was served: the file it was read from
  --- and the text it held then, before any rewrite.
  record Served
    file: string
    text: string
  end

  --- One editor's session: what it opened and what it was told.
  record Session
    --- The workspace's root, which a `require` is answered below.
    root: string
    --- "utf-16" or "utf-8": what a position's character counts.
    encoding: string
    initialized: boolean
    shut_down: boolean
    --- Set at `exit`: the exit status the session ends with.
    exit: integer | nil
    documents: {string:Document}
    --- Where complaints go, without their newline.
    err: function(line: string)
    built: compiler | nil
    env: compiler.Env | nil
    --- The types the checker reports of the document it checks, which
    --- [`build.contracts`] reads.
    typed: receivers.State | nil
    --- Whether the root is cosmic's own tree, which a build holds to its
    --- contracts and its stubs as well.
    own_tree: boolean
    --- Whether the editor takes a registration of the files to watch.
    watch: boolean
    --- The globals a fresh environment has, so a check drops those an
    --- earlier text declared.
    base_globals: {string:boolean}
    --- Each project module the checker was served, by name. Its type is
    --- kept between checks until one of them reads otherwise now.
    served: {string:Served}
    store: {Sqlite.Handle} | nil
    view: docs.View | nil
    --- Why the docs could not be read, once they were tried.
    view_trouble: string | nil
    --- The docs databases the session opened itself, closed as it ends.
    opened: {Sqlite.Handle}
  end

  --- A reader of framed messages.
  record Frames
    --- The next message's body: nil and "" at the end between messages,
    --- nil and why for a stream that ends inside one or holds a header
    --- the protocol does not.
    next: function(Frames): string | nil, string
    --- The next message's body when the bytes read already hold all of
    --- it, without reading; nil otherwise, with nothing taken.
    buffered: function(Frames): string | nil
  end
end

--- The most header bytes ahead of a body.
local MAX_HEADER <const> = 8192
--- The largest message body taken, in bytes.
local MAX_BODY <const> = 64 * 1024 * 1024

-- JSON-RPC's and the protocol's error codes.
local PARSE_ERROR <const> = -32700
local INVALID_REQUEST <const> = -32600
local METHOD_NOT_FOUND <const> = -32601
local INVALID_PARAMS <const> = -32602
local INTERNAL_ERROR <const> = -32603
local NOT_INITIALIZED <const> = -32002
local REQUEST_FAILED <const> = -32803

-- What the server reads of the messages it is sent, each checked by its
-- shape before it is read.

--- A message's envelope: `id` and `params` are read by what the method
--- says they are.
local record Message
  method: string | nil
  id: any
  params: any
end

local MESSAGE <const> = Shape.record({
  method = Shape.optional(Shape.string),
  id = Shape.optional(Shape.any),
  params = Shape.optional(Shape.any),
})

local record Position
  line: integer
  character: integer
end

local record DocumentIdentifier
  uri: string
  text: string | nil
end

local record ContentChange
  text: string
end

--- The params of every `textDocument/` method read.
local record DocumentParams
  textDocument: DocumentIdentifier
  position: Position | nil
  contentChanges: {ContentChange} | nil
end

local DOCUMENT_PARAMS <const> = Shape.record_of("DocumentParams")

local record WorkspaceFolder
  uri: string
end

local record General
  positionEncodings: {string} | nil
end

local record DynamicRegistration
  dynamicRegistration: boolean | nil
end

local record WorkspaceCapabilities
  didChangeWatchedFiles: DynamicRegistration | nil
end

local record ClientCapabilities
  general: General | nil
  workspace: WorkspaceCapabilities | nil
end

local record InitializeParams
  rootUri: string | nil
  rootPath: string | nil
  workspaceFolders: {WorkspaceFolder} | nil
  capabilities: ClientCapabilities | nil
end

local INITIALIZE_PARAMS <const> = Shape.record_of("InitializeParams")

-- What the server sends, encoded as it is.

local record SaveOptions
  includeText: boolean
end

local record SyncOptions
  openClose: boolean
  change: integer
  save: SaveOptions
end

local record ServerCapabilities
  positionEncoding: string
  textDocumentSync: SyncOptions
  hoverProvider: boolean
  documentFormattingProvider: boolean
end

local record ServerInfo
  name: string
end

local record InitializeResult
  capabilities: ServerCapabilities
  serverInfo: ServerInfo
end

--- A range: its `start` and its `end`, a name no record field can have.
local type Range = {string: Position}

local record Diagnostic
  range: Range
  severity: integer
  source: string
  message: string
  code: string | nil
end

local record MarkupContent
  kind: string
  value: string
end

local record Hover
  contents: MarkupContent
end

local record TextEdit
  range: Range
  newText: string
end

local record ResponseError
  code: integer
  message: string
end

local record Watcher
  globPattern: string
end

local record WatchOptions
  watchers: {Watcher}
end

local record Registration
  id: string
  method: string
  registerOptions: WatchOptions
end

local record RegistrationParams
  registrations: {Registration}
end

--- The id of the one request the server makes, which registers the
--- files it watches: its answer is read as any response is, and dropped.
local WATCH_REQUEST <const> = 1

--- `body` with its header, as one message on the wire.
function lsp.frame(body: string): string
  return "Content-Length: " .. tostring(#body) .. "\r\n\r\n" .. body
end

--- What a reader of frames has read and not yet answered.
local record FrameState
  buffer: string
  ended: boolean
end

--- A message's header: where it ends (the byte its blank line starts at)
--- and the length of the body after it.
local record Header
  finish: integer
  length: integer
end

local function too_long(): string
  return "a header longer than " .. plural.count(MAX_HEADER, "byte")
end

--- The header `buffer` begins with: nil and "" while the bytes of its end
--- have not all come, nil and why for one the protocol refuses.
local function header_of(buffer: string): Header | nil, string
  local finish = buffer:find("\r\n\r\n", 1, true)
  if finish == nil then
    if #buffer > MAX_HEADER then return nil, too_long() end
    return nil, ""
  end
  if finish - 1 > MAX_HEADER then return nil, too_long() end
  local length: integer | nil = nil
  for line in buffer:sub(1, finish - 1):gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name == nil then
      return nil, "a header line with no name: " .. line
    end
    if name:lower() == "content-length" then
      length = nil
      if value:match("^%d+$") ~= nil then length = math.tointeger(tonumber(value)) end
      if length == nil then
        return nil, "a Content-Length that is no length: " .. value
      end
    end
  end
  if length == nil then
    return nil, "a message with no Content-Length"
  end
  if length > MAX_BODY then
    return nil, "a message of " .. plural.count(length, "byte") .. ", over the " ..
      plural.count(MAX_BODY, "byte") .. " taken"
  end
  return { finish = finish, length = length }, ""
end

--- The messages `read` gives, one body at a time ([`lsp.Frames`]):
--- `read` answers the next chunk of the stream, as a [`Stream.Reader`]'s
--- `read` does.
function lsp.frames_of(read: function(): string | nil, string): lsp.Frames
  local held: FrameState = { buffer = "", ended = false }
  --- The next chunk `read` gives: nil and "" at its end, nil and why
  --- where it breaks.
  local function more(): string | nil, string
    if held.ended then return nil, "" end
    local chunk, trouble = read()
    if chunk == nil then
      held.ended = true
      return nil, trouble
    end
    return chunk, ""
  end
  --- The next message's header, read until its end is in the buffer:
  --- nil and "" at the stream's end between messages.
  local function read_header(): Header | nil, string
    while true do
      local found, trouble = header_of(held.buffer)
      if found ~= nil then return found, "" end
      if trouble ~= "" then return nil, trouble end
      local chunk, why = more()
      if chunk == nil then
        if why ~= "" then return nil, why end
        if held.buffer:match("^%s*$") ~= nil then return nil, "" end
        return nil, "the stream ended inside a header"
      end
      held.buffer = held.buffer .. chunk
    end
  end
  return {
    next = function(_self: lsp.Frames): string | nil, string
      local header, trouble = read_header()
      if header == nil then return nil, trouble end
      -- The body's chunks are joined once, not one at a time: a body of
      -- many chunks would be copied once for each.
      local parts: {string} = { held.buffer:sub(header.finish + 4) }
      local have = #parts[1]
      while have < header.length do
        local chunk, why = more()
        if chunk == nil then
          if why ~= "" then return nil, why end
          return nil, "the stream ended inside a message"
        end
        parts[#parts + 1] = chunk
        have = have + #chunk
      end
      local joined = table.concat(parts)
      held.buffer = joined:sub(header.length + 1)
      return joined:sub(1, header.length), ""
    end,
    buffered = function(_self: lsp.Frames): string | nil
      local header, _ = header_of(held.buffer)
      if header == nil then return nil end
      local start = header.finish + 4
      if #held.buffer - start + 1 < header.length then return nil end
      local body = held.buffer:sub(start, start + header.length - 1)
      held.buffer = held.buffer:sub(start + header.length)
      return body
    end,
  }
end

--- The messages `reader` holds, one body at a time ([`lsp.Frames`]).
function lsp.frames(reader: Stream.Reader): lsp.Frames
  return lsp.frames_of(function(): string | nil, string return reader:read() end)
end

--- The path a `file:` URI names, or nil for another scheme.
local function path_of(uri: string): string | nil
  local rest = uri:match("^file://[^/]*(/.*)$")
  if rest == nil then return nil end
  local path, _ = Url.unescape(rest)
  return path
end

--- `path` below `root`, or nil when it is not below it.
local function below(path: string, root: string): string | nil
  local prefix = root
  if prefix:sub(-1) ~= "/" then prefix = prefix .. "/" end
  if path:sub(1, #prefix) == prefix then return path:sub(#prefix + 1) end
  return nil
end

--- A text's lines as the protocol counts them: where each starts (a
--- byte, from 1) and what it holds, without its end, which is "\r\n",
--- "\n" or a lone "\r".
local record Lines
  starts: {integer}
  texts: {string}
end

local function lines_of(text: string): Lines
  local starts: {integer} = {}
  local texts: {string} = {}
  local at = 1
  while true do
    local stop = text:find("[\r\n]", at)
    starts[#starts + 1] = at
    if stop == nil then
      texts[#texts + 1] = text:sub(at)
      return { starts = starts, texts = texts }
    end
    texts[#texts + 1] = text:sub(at, stop - 1)
    at = stop + 1
    if text:sub(stop, stop + 1) == "\r\n" then at = stop + 2 end
  end
end

--- How many units of `encoding` the bytes of `line` before byte `x` (from
--- 1) take: the protocol's character of that column, from 0.
local function character_of(line: string, x: integer, encoding: string): integer
  local before = line:sub(1, x - 1)
  if encoding == "utf-8" then return #before end
  local units = 0
  for _, code in utf8.codes(before, true) do
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return units
end

--- The byte (from 1) at the protocol's `character` of `line`, or one past
--- the line's end for a character past it.
local function byte_of(line: string, character: integer, encoding: string): integer
  if encoding == "utf-8" then return math.min(character, #line) + 1 end
  local units = 0
  for at, code in utf8.codes(line, true) do
    if units >= character then return at end
    units = units + 1
    if code >= 0x10000 then units = units + 1 end
  end
  return #line + 1
end

--- The protocol's position of byte `offset` (from 1) of the text `lines`
--- holds; a byte of a line's end is past the line's last character.
local function position(lines: Lines, offset: integer, encoding: string): Position
  local low, high = 1, #lines.starts
  while low < high do
    local middle = (low + high + 1) // 2
    if lines.starts[middle] <= offset then low = middle else high = middle - 1 end
  end
  local line = lines.texts[low]
  local x = math.min(math.max(offset - lines.starts[low] + 1, 1), #line + 1)
  return { line = low - 1, character = character_of(line, x, encoding) }
end

--- The range from `start` to `finish`.
local function range(start: Position, finish: Position): Range
  return { ["start"] = start, ["end"] = finish }
end

--- Where each line of `text` starts as the checker counts lines, which is
--- at "\n" alone: its columns are bytes.
local function checker_starts(text: string): {integer}
  local out: {integer} = { 1 }
  local at = text:find("\n", 1, true)
  while at ~= nil do
    out[#out + 1] = at + 1
    at = text:find("\n", at + 1, true)
  end
  return out
end

--- The byte of the document's own text at byte `offset` of it as
--- spliced (`splices`, the last first, as [`shape_specs.splices`] answers
--- them). A byte a splice put in is the byte the splice follows.
local function unspliced(splices: {shape_specs.Splice}, offset: integer): integer
  local shift = 0
  for i = #splices, 1, -1 do
    local splice = splices[i]
    local first = splice.at + shift + 1
    if offset < first then break end
    if offset < first + #splice.text then return splice.at end
    shift = shift + #splice.text
  end
  return offset - shift
end

--- The import path a build gives the file `name` below the root:
--- `a/b.tl`, `a/b.d.tl` and `a/b/init.tl` are all `a.b`.
local function module_of(name: string): string
  local stem = name:gsub("%.d%.tl$", "")
  if stem == name then stem = name:gsub("/init%.tl$", "") end
  if stem == name then stem = name:gsub("%.tl$", "") end
  return (stem:gsub("/", "."))
end

--- The files a build reads the module `name` from, the first that is
--- there taken: a declaration ahead of a source, a directory's `init.tl`,
--- then a template. A file under `static/` or a `testdata/` directory is
--- no module.
local function candidates(name: string): {string}
  local stem = name:gsub("%.", "/")
  local none: {string} = {}
  if stem:match("^static/") ~= nil or stem:match("^testdata/") ~= nil or
      stem:find("/testdata/", 1, true) ~= nil then
    return none
  end
  return { stem .. ".d.tl", stem .. ".tl", stem .. "/init.tl", stem .. ".tmpl", stem .. "/init.tmpl" }
end

--- A new session, before `initialize`, answering below `root`.
function lsp.new(root: string, options?: lsp.Options): lsp.Session
  local given: lsp.Options = options or {}
  return {
    root = root,
    encoding = "utf-16",
    initialized = false,
    shut_down = false,
    exit = nil,
    documents = {},
    err = given.err or bare.err,
    built = nil,
    env = nil,
    typed = nil,
    own_tree = false,
    watch = false,
    base_globals = {},
    served = {},
    store = given.store,
    view = nil,
    view_trouble = nil,
    opened = {},
  }
end

--- What the checker reads for a module: its text, then a close.
local record Handle
  text: string
  read: function(Handle, what: string): string
  close: function(Handle): boolean
end

local function handle_of(text: string): Handle
  return {
    text = text,
    read = function(self: Handle, _what: string): string return self.text end,
    close = function(_self: Handle): boolean return true end,
  }
end

--- The project module `name` as a build finds it below the session's
--- root: the first of its [`candidates`] that is an open document or a
--- file. Nil when none is.
local function project_module(session: lsp.Session, name: string): lsp.Served | nil
  local open: {string:string} = {}
  for _, document in pairs(session.documents) do open[document.name] = document.text end
  for _, file in ipairs(candidates(name)) do
    local text = open[file]
    if text == nil then
      local read, _ = Fs.read(session.root .. "/" .. file)
      text = read
    end
    if text ~= nil then return { file = file, text = text } end
  end
  return nil
end

--- What the checker reads of the project module `found`, named `name`:
--- the file name it reads it under and the text. A template is its Teal,
--- under a name that ends in `tl`, the only one the checker takes, and
--- nil where it does not compile; a source is as a build rewrites it. A
--- rewrite that fails leaves the source as it is: the module's refusal is
--- its own, not the document's.
local function served_text(session: lsp.Session, name: string, found: lsp.Served): lsp.Served | nil
  if found.file:match("%.tmpl$") ~= nil then
    local compiled, _ = Template.compile(found.text, found.file)
    if compiled == nil then return nil end
    return { file = found.file .. ".tl", text = compiled }
  end
  local built, env = session.built, session.env
  if built == nil or env == nil then return found end
  local ok, resolved, _ = pcall(shape_specs.resolve, built, env, found.file, name, found.text)
  if ok and resolved ~= nil then return { file = found.file, text = resolved } end
  return found
end

--- The session's checker and its environment, made on first use.
local function checker(session: lsp.Session): compiler, compiler.Env
  -- TODO: a document's first check checks every project module it
  -- reaches from its source, which for cosmic's own build/lsp.tl takes
  -- about 25 seconds; a module unchanged since the last build could be
  -- read as the stub that build made of it (build/stub.tl), which waits
  -- on a session finding a project module's stub by its source.
  local built, env = session.built, session.env
  if built ~= nil and env ~= nil then return built, env end
  local loaded = assert(teal.load())
  loaded.search_module = function(name: string, _search_all: boolean): string | nil, any
    local found = project_module(session, name)
    if found ~= nil then
      local reading = served_text(session, name, found)
      if reading == nil then return nil, nil end
      session.served[name] = found
      return reading.file, handle_of(reading.text)
    end
    local standard = teal.standard_text(name)
    if standard == nil then return nil, nil end
    return name:gsub("%.", "/") .. ".tl", handle_of(standard.text)
  end
  local made, env_trouble = loaded.new_env({
    defaults = { feat_lax = "off", gen_compat = "off", gen_target = "5.4" },
  })
  if made == nil then error(env_trouble, 0) end
  teal.strip(made)
  for name in pairs(made.globals) do session.base_globals[name] = true end
  session.typed = receivers.install(made)
  local own, _ = tree.is_own(session.root)
  session.own_tree = own == true
  session.built, session.env = loaded, made
  return loaded, made
end

--- Readies `env` for a check: drops the globals an earlier text declared,
--- which would be declared twice, and the project modules served before
--- when one of them now reads otherwise (an open document, or the file,
--- changed, or one shadows another), all of them, since one that requires
--- the changed one may change with it. A module whose global was dropped
--- is checked again too, to declare it again: the served modules are
--- dropped whenever an earlier check declared a global, the document's
--- own or a module's. The `cosmic.*` modules stay, which is most of what
--- a check costs.
local function refresh(session: lsp.Session, env: compiler.Env)
  local stale = false
  for name in pairs(env.globals) do
    if session.base_globals[name] ~= true then
      env.globals[name] = nil
      stale = true
    end
  end
  for name, was in pairs(session.served) do
    if stale then break end
    local now = project_module(session, name)
    if now == nil or now.file ~= was.file or now.text ~= was.text then
      stale = true
      break
    end
  end
  if not stale then return end
  for name in pairs(session.served) do
    env.modules[name] = nil
    env.module_filenames[name] = nil
  end
  session.served = {}
end

--- The kind a build gives the file `name` below the root, as the
--- `inputs` view of build/analysis_schema.tl names it: a declaration, a
--- test, an example, a program's `cmd/<name>/main.tl`, or a module.
local function kind_of(name: string): string
  if name:match("%.d%.tl$") ~= nil then return "decl" end
  if name:match("_test%.tl$") ~= nil then return "test" end
  if name:match("_example%.tl$") ~= nil then return "example" end
  if name:match("^cmd/[^/]+/main%.tl$") ~= nil then return "main" end
  return "module"
end

--- What a build refuses beyond the checker's errors: where, in the
--- checker's lines and columns, and why.
local record Refusal
  line: integer
  column: integer
  message: string
end

--- The number `digits` spell.
local function number_of(digits: string): integer
  local value = math.tointeger(tonumber(digits))
  if value == nil then return 1 end
  return value
end

--- The refusal `said`, as a build words one (`file:line:column: why`,
--- `file:line: why` or `file: why`), at the place it names: the first
--- line, or its first column, where it names none.
local function refusal_of(said: string): Refusal
  local y, x, why = said:match("^[^:\n]*:(%d+):(%d+): (.*)$")
  if y ~= nil and x ~= nil and why ~= nil then
    return { line = number_of(y), column = number_of(x), message = why }
  end
  local line, rest = said:match("^[^:\n]*:(%d+): (.*)$")
  if line ~= nil and rest ~= nil then
    return { line = number_of(line), column = 1, message = rest }
  end
  return { line = 1, column = 1, message = said:match("^[^:\n]*: (.*)$") or said }
end

--- The refusals `said` holds, one a line, as [`compilation.generate`]
--- joins its contracts' ([`refusal_of`]): what a build prints, put where
--- it says, since it answers them in no other shape.
local function refusals_of(said: string): {Refusal}
  local out: {Refusal} = {}
  for line in said:gmatch("[^\n]+") do out[#out + 1] = refusal_of(line) end
  return out
end

--- The line of the top-level `return` of `parsed`, or 1 where it has none.
local function return_line(parsed: ast.Parsed): integer
  for _, statement in ipairs(parsed.node) do
    if statement.kind == "return" then return statement.y end
  end
  return 1
end

--- The plan a build makes of `document` ([`compilation.collect`]), from
--- a parse of it, and what a build refuses that the parse tells: a
--- `global` ([`compilation.global_refusal`]), a test that returns a value
--- or an example that returns none ([`compilation.refusal`]), a
--- [`Test.policy`] the build does not take. No plan for a text that does
--- not parse, whose errors the checker reports, or whose analysis is
--- refused.
local function plan_of(built: compiler, document: lsp.Document): build_module.Plan | nil, {Refusal}
  local refusals: {Refusal} = {}
  local parsed, _ = ast.parse(built, document.text, document.name)
  if parsed == nil then return nil, refusals end
  for _, place in ipairs(globals.found(parsed)) do
    refusals[#refusals + 1] = refusal_of(compilation.global_refusal(document.name .. ":" ..
        tostring(place.line) .. ":" .. tostring(place.column)))
  end
  local analysis, trouble = analyzer.analysis_of(built, parsed, document.text)
  if analysis == nil then
    refusals[#refusals + 1] = refusal_of(trouble)
    return nil, refusals
  end
  local kind = kind_of(document.name)
  local tests: {string} = {}
  if kind == "test" then
    tests = analysis.tests
  elseif kind == "example" then
    for _, example in ipairs(analysis.examples) do tests[#tests + 1] = example.name end
  end
  -- A source that returns nothing has no stub ([`build.derivation`]).
  local made: stub.Made | nil = nil
  if analysis.has_top_level_return then made = stub.made(parsed) end
  local plan: build_module.Plan = {
    path = module_of(document.name),
    file = document.name,
    kind = kind,
    source = document.text,
    source_hash = "",
    requires = {},
    tests = tests,
    inputs = analysis.inputs,
    has_top_level_return = analysis.has_top_level_return,
    generated = false,
    key = nil,
    graph_key = nil,
    lua = nil,
    stub = made,
  }
  local refused = compilation.refusal(plan)
  if refused ~= nil then
    local at = refusal_of(refused)
    at.line = return_line(parsed)
    refusals[#refusals + 1] = at
  end
  return plan, refusals
end

--- What one check of a document found: the errors of the document
--- itself, and the text and splices they are positioned in.
local record Checked
  errors: {compiler.Error}
  --- What a build refuses beyond the checker's errors.
  refusals: {Refusal}
  --- The text as checked, after the build's rewrite.
  text: string
  splices: {shape_specs.Splice}
  refused: {string:boolean}
end

--- The checker's reading of a text [`compilation.generate`] refused for
--- the checker's errors, which it hands its renderer.
local record Rendered
  result: compiler.Result | nil
end

--- Checks `document` in `env`, as a build checks it.
local function check(session: lsp.Session, built: compiler, env: compiler.Env,
                     document: lsp.Document): Checked
  -- TODO: a build also refuses a `require` that reaches into a closed
  -- directory, or into build/ or a test in cosmic's own tree
  -- (build/positions.tl), which wants every module the root holds: it
  -- waits on a session listing the root's modules as a build stages them.
  local none: {shape_specs.Splice} = {}
  local found: {compiler.Error} = {}
  local plan, refusals = plan_of(built, document)
  -- A build refuses a test that returns a value, or an example that
  -- returns none, before it checks it ([`compilation.refusal`]).
  if plan ~= nil and compilation.refusal(plan) ~= nil then
    return { errors = found, refusals = refusals, text = document.text, splices = none, refused = {} }
  end
  local resolution = shape_specs.splices(built, env, document.name, module_of(document.name),
    document.text)
  if resolution.refusal ~= "" then
    local refused = refusal_of(resolution.refusal)
    refused.line = resolution.line
    refusals[#refusals + 1] = refused
    return { errors = found, refusals = refusals, text = document.text, splices = none, refused = {} }
  end
  local splices = resolution.splices
  local text = shape_specs.spliced(document.text, splices)
  local result: compiler.Result | nil = nil
  if plan == nil or plan.kind == "decl" then
    result = built.check_string(text, env, document.name, "tl")
  else
    -- Compiled as a build compiles it, which drops the warnings a build
    -- discounts and refuses what a build refuses beyond the checker's
    -- errors: in cosmic's own tree its stub and its contracts, and Lua's
    -- refusal of the code. The checker's reading of a text it refuses is
    -- what it hands the renderer. The type it records of the module is
    -- put back: an open document is read through `search_module`.
    local rendered: Rendered = { result = nil }
    local kept = env.modules[plan.path]
    local made, trouble = compilation.generate(plan, built, env, assert(session.typed),
      session.own_tree, true, function(_file: string, _source: string, checked: compiler.Result): string
        rendered.result = checked
        return ""
      end)
    env.modules[plan.path] = kept
    result = rendered.result
    if made == nil and result == nil then
      for _, refusal in ipairs(refusals_of(trouble)) do refusals[#refusals + 1] = refusal end
    end
  end
  if result == nil then
    return { errors = found, refusals = refusals, text = text, splices = splices, refused = {} }
  end
  -- A text with a syntax error has no warnings, nor a list of them: the
  -- list of lists ends there.
  for _, group in ipairs({ result.syntax_errors, result.type_errors, result.warnings }) do
    for _, e in ipairs(group) do found[#found + 1] = e end
  end
  return { errors = found, refusals = refusals, text = text, splices = splices,
    refused = teal.refused_type_requires(document.name, text, result) }
end

--- The diagnostics of `document`, each encoded.
local function diagnose(session: lsp.Session, document: lsp.Document): {string}
  local built, env = checker(session)
  refresh(session, env)
  -- What the check adds to `loaded` is dropped after it, its results'
  -- trees with it: a module's type stays in `modules`, which is what a
  -- later check reads, and a text read again is checked again.
  local order = env.loaded_order
  local before = #order
  local ok, outcome = pcall(check, session, built, env, document)
  for i = #order, before + 1, -1 do
    local name = order[i]
    if name ~= nil then env.loaded[name] = nil end
    order[i] = nil
  end
  if not ok then error(tostring(outcome), 0) end
  local checked: Checked = outcome
  local lines = lines_of(document.text)
  local starts = checker_starts(checked.text)
  local out: {string} = {}
  --- The diagnostic `message` at the checker's line `y` and column `x`.
  local function add(y: integer, x: integer, message: string, code: string | nil)
    local line = math.min(math.max(y, 1), #starts)
    local at = math.min(starts[line] + math.max(x, 1) - 1, #checked.text + 1)
    local offset = unspliced(checked.splices, at)
    local word = document.text:match("^[%w_]+", offset) or ""
    local diagnostic: Diagnostic = {
      range = range(position(lines, offset, session.encoding),
        position(lines, offset + math.max(#word, 1), session.encoding)),
      -- A build refuses a warning as it does an error.
      severity = 1,
      source = "cosmic",
      message = message,
      code = code,
    }
    out[#out + 1] = assert(Json.encode(diagnostic))
  end
  for _, refusal in ipairs(checked.refusals) do
    add(refusal.line, refusal.column, refusal.message, nil)
  end
  for _, e in ipairs(checked.errors) do
    local instead = teal.replacement(e, checked.text, document.name, checked.refused)
    local message = e.msg
    if instead ~= nil then message = message .. " -- " .. instead end
    local code: string | nil = e.code
    if code == nil then code = e.tag end
    add(e.y, e.x, message, code)
  end
  return out
end

--- The notification that publishes `diagnostics`, each encoded, for `uri`.
local function publication(uri: string, diagnostics: {string}): string
  return '{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":' ..
    Json.quote(uri) .. ',"diagnostics":[' .. table.concat(diagnostics, ",") .. "]}}"
end

--- The document `params` names, opened as `text` when it is given.
local function document_of(session: lsp.Session, params: DocumentParams, text?: string): lsp.Document | nil
  local uri = params.textDocument.uri
  local document = session.documents[uri]
  if document == nil and text ~= nil then
    local path = path_of(uri) or uri
    document = { uri = uri, text = text, name = below(path, session.root) or path }
    session.documents[uri] = document
  elseif document ~= nil and text ~= nil then
    document.text = text
  end
  return document
end

--- The docs view, read once.
local function view_of(session: lsp.Session): docs.View | nil
  if session.view ~= nil or session.view_trouble ~= nil then return session.view end
  local sources = docs.databases(session.store or Store.databases(), session.root)
  session.opened = sources.opened
  local view, trouble = docs.view(sources.handles, sources.public)
  session.view = view
  session.view_trouble = trouble
  if view == nil then session.err("cosmic: lsp: no docs: " .. trouble) end
  return view
end

--- The dotted name under byte `x` of `line`, up to the end of the word
--- the cursor is in: [`Fs.read`] with the cursor anywhere in `Fs`'s `read`.
local function name_at(line: string, x: integer): string | nil
  local first = x
  while first > 1 do
    if line:sub(first - 1, first - 1):match("[%w_%.]") == nil then break end
    first = first - 1
  end
  local last = x
  while last <= #line do
    if line:sub(last, last):match("[%w_]") == nil then break end
    last = last + 1
  end
  local name = line:sub(first, last - 1):gsub("^%.+", "")
  if name:match("^[%a_]") == nil then return nil end
  return name
end

--- `name` with its first part read as the module a `require` in `text`
--- bound to it: [`Fs.read`] as [`cosmic.fs.read`]. Nil when no `require` did.
local function resolved(text: string, name: string): string | nil
  local head, rest = name:match("^([%a_][%w_]*)(.*)$")
  for alias, module in text:gmatch("local%s+([%a_][%w_]*)%s*=%s*require%s*%(?%s*[\"']([%w_%.]+)[\"']") do
    if alias == head then return module .. rest end
  end
  return nil
end

--- The hover for `params`, or nil when nothing is documented there.
local function hover(session: lsp.Session, params: DocumentParams): Hover | nil
  local document = document_of(session, params)
  local where = params.position
  if document == nil or where == nil then return nil end
  local line = lines_of(document.text).texts[where.line + 1] or ""
  local name = name_at(line, byte_of(line, where.character, session.encoding))
  if name == nil then return nil end
  local view = view_of(session)
  if view == nil then return nil end
  local queries: {string} = {}
  local through = resolved(document.text, name)
  if through ~= nil then queries[#queries + 1] = through end
  queries[#queries + 1] = name
  for _, query in ipairs(queries) do
    local found, _ = docs.exact(view, query)
    local entry: docs.Entry | nil = nil
    if found ~= nil then entry = found[1] end
    if entry ~= nil then
      local title = entry.module
      if entry.symbol ~= "" then title = title .. "." .. entry.symbol end
      local parts: {string} = { "**" .. title .. "**" }
      if entry.signature ~= "" then
        parts[#parts + 1] = "```teal\n" .. entry.signature .. "\n```"
      end
      if entry.text ~= "" then parts[#parts + 1] = entry.text end
      return { contents = { kind = "markdown", value = table.concat(parts, "\n\n") } }
    end
  end
  return nil
end

--- The edits that format `params`' document, encoded, or nil and why
--- there are none.
local function formatting(session: lsp.Session, params: DocumentParams): string | nil, string
  local document = document_of(session, params)
  if document == nil then return nil, "no such document is open" end
  local built = checker(session)
  local fixed, trouble = require("build.fix").source(built, document.text, document.name)
  if fixed == nil then return nil, trouble end
  if fixed.source == document.text then return "[]", "" end
  local lines = lines_of(document.text)
  local edit: TextEdit = {
    range = range({ line = 0, character = 0 }, position(lines, #document.text + 1, session.encoding)),
    newText = fixed.source,
  }
  return "[" .. assert(Json.encode(edit)) .. "]", ""
end

--- The workspace's root `params` names, if any.
local function root_of(params: InitializeParams): string | nil
  local uri = params.rootUri
  local folders = params.workspaceFolders
  if uri == nil and folders ~= nil and folders[1] ~= nil then uri = folders[1].uri end
  local path = params.rootPath
  if uri ~= nil then path = path_of(uri) end
  if path == nil or path == "" then return nil end
  return (path:gsub("(.)/+$", "%1"))
end

--- The answer to `initialize`.
local function initialize(session: lsp.Session, params: InitializeParams): InitializeResult
  session.root = root_of(params) or session.root
  local capabilities = params.capabilities
  local general: General | nil = nil
  if capabilities ~= nil then general = capabilities.general end
  local offered: {string} = {}
  if general ~= nil then offered = general.positionEncodings or offered end
  for _, name in ipairs(offered) do
    if name == "utf-8" then session.encoding = "utf-8" end
  end
  local workspace: WorkspaceCapabilities | nil = nil
  if capabilities ~= nil then workspace = capabilities.workspace end
  local watched: DynamicRegistration | nil = nil
  if workspace ~= nil then watched = workspace.didChangeWatchedFiles end
  session.watch = watched ~= nil and watched.dynamicRegistration == true
  session.initialized = true
  return {
    capabilities = {
      positionEncoding = session.encoding,
      textDocumentSync = { openClose = true, change = 1, save = { includeText = false } },
      hoverProvider = true,
      documentFormattingProvider = true,
    },
    serverInfo = { name = "cosmic" },
  }
end

--- The request that registers the files the server watches: every
--- module a `require` may read ([`candidates`]).
local function watch_request(): string
  local params: RegistrationParams = { registrations = { {
    id = "cosmic.watch",
    method = "workspace/didChangeWatchedFiles",
    registerOptions = { watchers = { { globPattern = "**/*.tl" }, { globPattern = "**/*.tmpl" } } },
  } } }
  return '{"jsonrpc":"2.0","id":' .. tostring(WATCH_REQUEST) ..
    ',"method":"client/registerCapability","params":' .. assert(Json.encode(params)) .. "}"
end

--- A publication of each open document's diagnostics: a document may
--- require the one saved, or the file changed on disk.
local function republished(session: lsp.Session): {string}
  local out: {string} = {}
  for _, document in pairs(session.documents) do
    out[#out + 1] = publication(document.uri, diagnose(session, document))
  end
  return out
end

--- The response to the request `id` (encoded) answering `result` (encoded).
local function response(id: string, result: string): string
  return '{"jsonrpc":"2.0","id":' .. id .. ',"result":' .. result .. "}"
end

--- The response to the request `id` (encoded) failing with `code`.
local function failure(id: string, code: integer, why: string): string
  local said: ResponseError = { code = code, message = why }
  return '{"jsonrpc":"2.0","id":' .. id .. ',"error":' .. assert(Json.encode(said)) .. "}"
end

--- The `id` of `message`, encoded: "null" for a notification.
local function id_of(message: Message): string
  local id, _ = Json.encode(message.id)
  return id or "null"
end

--- What `message` asks: each message to send in answer, encoded, in
--- order, a request's response among them.
local function handle(session: lsp.Session, message: Message): {string}
  local out: {string} = {}
  local method = message.method
  local id = id_of(message)
  local is_request = id ~= "null"
  if method == nil then
    -- A response to a request this server never makes.
    if not is_request then
      out[#out + 1] = failure("null", INVALID_REQUEST, "a message with no method")
    end
    return out
  end
  if method == "exit" then
    session.exit = 1
    if session.shut_down then session.exit = 0 end
    return out
  end
  if not session.initialized and method ~= "initialize" then
    if is_request then out[#out + 1] = failure(id, NOT_INITIALIZED, "initialize first") end
    return out
  end
  if session.shut_down then
    if is_request then out[#out + 1] = failure(id, INVALID_REQUEST, "the server is shut down") end
    return out
  end
  if method == "initialize" then
    local params, trouble = INITIALIZE_PARAMS:into(message.params)
    if session.initialized then
      out[#out + 1] = failure(id, INVALID_REQUEST, "initialize was already sent")
    elseif params == nil then
      out[#out + 1] = failure(id, INVALID_PARAMS, "initialize: " .. trouble)
    else
      out[#out + 1] = response(id, (assert(Json.encode(initialize(session, params)))))
    end
    return out
  end
  if method == "shutdown" then
    session.shut_down = true
    out[#out + 1] = response(id, "null")
    return out
  end
  if method == "initialized" then
    if session.watch then out[#out + 1] = watch_request() end
    return out
  end
  if method == "workspace/didChangeWatchedFiles" then
    return republished(session)
  end
  if method:sub(1, #"textDocument/") ~= "textDocument/" then
    if is_request then out[#out + 1] = failure(id, METHOD_NOT_FOUND, "no method " .. method) end
    return out
  end
  local params, trouble = DOCUMENT_PARAMS:into(message.params)
  if params == nil then
    if is_request then out[#out + 1] = failure(id, INVALID_PARAMS, method .. ": " .. trouble) end
    return out
  end
  if method == "textDocument/didOpen" then
    local document = document_of(session, params, params.textDocument.text)
    if document ~= nil then
      out[#out + 1] = publication(document.uri, diagnose(session, document))
    end
  elseif method == "textDocument/didChange" then
    -- The server asked for whole texts, so the last is the document.
    local none: {ContentChange} = {}
    local changes = params.contentChanges or none
    local last = changes[#changes]
    if last ~= nil then
      local document = document_of(session, params, last.text)
      if document ~= nil then
        out[#out + 1] = publication(document.uri, diagnose(session, document))
      end
    end
  elseif method == "textDocument/didSave" then
    for _, published in ipairs(republished(session)) do out[#out + 1] = published end
  elseif method == "textDocument/didClose" then
    local document = document_of(session, params)
    if document ~= nil then
      session.documents[document.uri] = nil
      local cleared: {string} = {}
      out[#out + 1] = publication(document.uri, cleared)
    end
  elseif method == "textDocument/hover" then
    local found = hover(session, params)
    local result = "null"
    if found ~= nil then result = assert(Json.encode(found)) end
    out[#out + 1] = response(id, result)
  elseif method == "textDocument/formatting" then
    local edits, why = formatting(session, params)
    if edits == nil then
      out[#out + 1] = failure(id, REQUEST_FAILED, why)
    else
      out[#out + 1] = response(id, edits)
    end
  elseif is_request then
    out[#out + 1] = failure(id, METHOD_NOT_FOUND, "no method " .. method)
  end
  return out
end

--- The message `body` holds: nil and its answer where it is not JSON
--- (-32700) or not a message (-32600).
local function message_of(body: string): Message | nil, string
  local decoded, trouble = Json.decode(body)
  if decoded == nil and trouble ~= "" then
    return nil, failure("null", PARSE_ERROR, trouble)
  end
  local message, invalid: Message | nil, string = Shape.into(decoded, MESSAGE)
  if message == nil then
    return nil, failure("null", INVALID_REQUEST, "not a message: " .. invalid)
  end
  return message, ""
end

--- The messages to send in answer to the message `body`, encoded.
local function answers(session: lsp.Session, body: string): {string}
  local message, refusal = message_of(body)
  if message == nil then return { refusal } end
  -- A fault answering one message fails that message, not the session.
  local ok, handled = pcall(handle, session, message)
  if ok then return handled end
  session.err("cosmic: lsp: " .. tostring(handled))
  local id = id_of(message)
  if id == "null" then return {} end
  return { failure(id, INTERNAL_ERROR, tostring(handled)) }
end

--- The document the message `body` sends a whole new text of, or nil
--- when it is no `textDocument/didChange`.
local function changed_uri(body: string): string | nil
  local message, _ = message_of(body)
  if message == nil or message.method ~= "textDocument/didChange" then return nil end
  local params, _ = DOCUMENT_PARAMS:into(message.params)
  if params == nil then return nil end
  return params.textDocument.uri
end

--- A message [`lsp.serve`] read ahead and has yet to answer.
local record Ahead
  body: string | nil
end

--- The next message to answer: the one read ahead, else the next of
--- `frames`.
local function next_body(frames: lsp.Frames, ahead: Ahead): string | nil, string
  local body = ahead.body
  if body ~= nil then
    ahead.body = nil
    return body, ""
  end
  return frames:next()
end

--- `body`, or, when it changes a document and the bytes read already hold
--- more changes of the same document right after it, the last of them:
--- each holds the whole text, so only the last is checked. What is read
--- past them waits in `ahead`.
local function latest(frames: lsp.Frames, ahead: Ahead, body: string): string
  local uri = changed_uri(body)
  if uri == nil then return body end
  local last = body
  while true do
    local after = frames:buffered()
    if after == nil then return last end
    if changed_uri(after) ~= uri then
      ahead.body = after
      return last
    end
    last = after
  end
end

--- [`lsp.serve`]'s loop: its exit status.
local function served(session: lsp.Session, frames: lsp.Frames,
                      write: function(text: string): boolean, string): integer
  local ahead: Ahead = { body = nil }
  while true do
    local exit = session.exit
    if exit ~= nil then return exit end
    local body, trouble = next_body(frames, ahead)
    if body == nil then
      if trouble ~= "" then
        session.err("cosmic: lsp: " .. trouble)
        return 1
      end
      if session.shut_down then return 0 end
      return 1
    end
    for _, answer in ipairs(answers(session, latest(frames, ahead, body))) do
      local sent, why = write(lsp.frame(answer))
      if not sent then
        session.err("cosmic: lsp: " .. why)
        return 1
      end
    end
  end
end

--- Serves `session` the messages `reader` holds, writing each answer
--- through `write`, until `exit` or the end of the stream, then closes
--- the docs databases the session opened. Answers the exit status: 0
--- after `shutdown`, at `exit` or the stream's end, and 1 at an `exit` or
--- an end with no `shutdown` before it, a stream that breaks or a write
--- that fails.
function lsp.serve(session: lsp.Session, reader: Stream.Reader,
                   write: function(text: string): boolean, string): integer
  local code = served(session, lsp.frames(reader), write)
  for _, db in ipairs(session.opened) do
    local _, _ = db:close()
  end
  session.opened = {}
  return code
end

local spec = Cli.verbs["lsp"].spec or {}

local usage = "cosmic lsp [--stdio] [--listen [host:]port] [--socket path]"

--- Whether `host` is a numeric IPv4 address, four decimal octets.
local function ipv4(host: string): boolean
  if host:match("^%d+%.%d+%.%d+%.%d+$") == nil then return false end
  for octet in host:gmatch("%d+") do
    local value = math.tointeger(tonumber(octet))
    if #octet > 3 or value == nil or value > 255 then return false end
  end
  return true
end

--- Whether `host` is a numeric IPv6 address: eight groups of up to four
--- hex digits, a run of them written `::` once at most, the last two an
--- IPv4 address where one ends it.
local function ipv6(host: string): boolean
  local text = host
  local groups = 0
  local tail = text:match(":(%d+%.%d+%.%d+%.%d+)$")
  if tail ~= nil then
    if not ipv4(tail) then return false end
    text = text:sub(1, #text - #tail) .. "0:0"
  end
  local first, last = text:find("::", 1, true)
  if first ~= nil and text:find("::", last, true) ~= nil then return false end
  local parts: {string} = {}
  if first ~= nil then
    parts = { text:sub(1, first - 1), text:sub(last + 1) }
  else
    parts = { text }
  end
  for _, part in ipairs(parts) do
    if part ~= "" then
      for group in (part .. ":"):gmatch("([^:]*):") do
        if group:match("^%x%x?%x?%x?$") == nil then return false end
        groups = groups + 1
      end
    end
  end
  if first ~= nil then return groups < 8 end
  return groups == 8
end

--- The address `--listen` names: `port` alone is the loopback's, and a
--- host is a numeric IPv4 address or an IPv6 one in brackets.
local function listen_address(word: string): Net.Address | nil
  local host, port = word:match("^%[(.+)%]:(%d+)$")
  if host ~= nil and not ipv6(host) then return nil end
  if host == nil then
    host, port = word:match("^([^:]+):(%d+)$")
    if host ~= nil and not ipv4(host) then return nil end
  end
  if host == nil then host, port = "127.0.0.1", word:match("^(%d+)$") end
  if port == nil then return nil end
  local number = math.tointeger(tonumber(port))
  if number == nil or number > 65535 then return nil end
  return Net.tcp(host, number)
end

--- Whether `address` is reached only from this host.
local function loopback(address: Net.Address): boolean
  if address.kind == "unix" then return true end
  local host = address.host or ""
  return host:match("^127%.") ~= nil or host == "::1"
end

--- Where `address` listens, as a person reads it.
local function named(address: Net.Address): string
  if address.kind == "unix" then return address.path or "" end
  local host = address.host or ""
  if host:find(":", 1, true) ~= nil then host = "[" .. host .. "]" end
  return host .. ":" .. tostring(address.port)
end

--- The connections a listener has open, closed as it stops.
local record Open
  conns: {Net.Conn: boolean}
  stopping: boolean
end

--- How long a connection has to end once the server stops, after its
--- close: a session in a check ends the check first.
local GRACE_NS <const> = Clock.seconds(5)

--- Serves each editor that connects at `listeners`, a session of its own
--- below `root` each, until SIGINT or SIGTERM. Answers the exit code.
local function listen(root: string, listeners: {Net.Address}): integer
  local open: Open = { conns = {}, stopping = false }
  local ok, trouble = Net.serve({
    listeners = listeners,
    serve = function(conn: Net.Conn)
      open.conns[conn] = true
      local session = lsp.new(root, {
        -- A connection the stop closes ends its session, which has no
        -- complaint to make of it.
        err = function(line: string)
          if not open.stopping then bare.err(line) end
        end,
        store = nil,
      })
      local _ = lsp.serve(session, conn, function(text: string): boolean, string
        return conn:write(text)
      end)
      open.conns[conn] = nil
    end,
    limits = nil,
    timeout_ns = nil,
    grace_ns = GRACE_NS,
    on_ready = function(addresses: {Net.Address}, _server: Net.Server)
      for _, address in ipairs(addresses) do
        bare.err("cosmic: lsp: listening at " .. named(address))
        if not loopback(address) then
          bare.err("cosmic: lsp: warning: " .. named(address) .. " is reached from beyond this " ..
              "host, and any client there reads the files below the root it names, unasked " ..
              "who it is")
        end
      end
    end,
    -- An editor holds its connection open and idle while it runs: the
    -- stop closes every one, or none would end.
    on_stop = function(_server: Net.Server)
      open.stopping = true
      local conns: {Net.Conn} = {}
      for conn in pairs(open.conns) do conns[#conns + 1] = conn end
      for _, conn in ipairs(conns) do
        local _, _ = conn:close()
      end
    end,
    on_error = nil,
  })
  if not ok then
    bare.err("cosmic: lsp: " .. trouble)
    return bare.failed
  end
  return bare.ok
end

--- Removes the socket file at `path` that a listener which did not close,
--- one that crashed, left behind: a socket nothing listens at, where a
--- connect fails. Anything else at `path`, a socket a server
--- listens at or a file of another kind, is left for the listen to refuse.
local function clear_stale(path: string)
  -- A link, to a socket or to anything else, is left alone.
  local link, _ = Fs.readlink(path)
  if link ~= nil then return end
  local st, _ = Fs.stat(path)
  if st == nil or st.kind ~= "socket" then return end
  local conn, _ = Net.connect(Net.unix(path), { timeout_ns = Clock.seconds(1) })
  if conn ~= nil then
    local _, _ = conn:close()
    return
  end
  -- TODO: remove the file only where the connect is refused, not where a
  -- live listener's backlog is full, which fails a connect at once too:
  -- that waits on Net.connect answering why it failed in a shape of its
  -- own, an errno, rather than in words.
  local _, _ = Fs.remove(path)
end

--- Runs the command line `argv`, `lsp` at slot 1, and answers the exit
--- code.
local function run(argv: {integer:string}): integer
  local complain = bare.complainer("lsp", bare.err)
  local parsed, trouble = Flags.parse(argv, 2, spec)
  if parsed == nil then
    complain(trouble .. "; " .. usage)
    return bare.refused
  end
  if #parsed.words > 0 then
    complain("takes no words, given " .. parsed.words[1] .. "; " .. usage)
    return bare.refused
  end
  local none: {string} = {}
  local listeners: {Net.Address} = {}
  for _, word in ipairs(parsed.all["--listen"] or none) do
    local address = listen_address(word)
    if address == nil then
      complain("--listen takes [host:]port, a numeric IPv4 host or an IPv6 one in brackets, given " ..
          word)
      return bare.refused
    end
    listeners[#listeners + 1] = address
  end
  for _, path in ipairs(parsed.all["--socket"] or none) do
    listeners[#listeners + 1] = Net.unix(path)
  end
  if parsed.set["--stdio"] == true and #listeners > 0 then
    complain("--stdio serves one editor, and takes no --listen or --socket; " .. usage)
    return bare.refused
  end
  local root, root_trouble = Fs.absolute(".")
  if root == nil then
    complain(root_trouble)
    return bare.failed
  end
  if #listeners == 0 then
    return lsp.serve(lsp.new(root), Stream.from_fd(0), bare.out)
  end
  for _, path in ipairs(parsed.all["--socket"] or none) do clear_stale(path) end
  return listen(root, listeners)
end

lsp.spec = {
  name = "lsp",
  run = run,
  bare = true,
  fresh = nil,
  recheck_on_refusal = nil,
  summarizes_failure = nil,
  program_slot = nil,
  takes = "where to listen",
  exits = "`lsp` speaks the Language Server Protocol on its standard output and " ..
    "exits 0 after `shutdown`, at `exit` or the stream's end, 1 at an `exit` or an end " ..
    "with no `shutdown` before it or a stream that breaks; listening, it exits 0 when " ..
    "SIGINT or SIGTERM stops it and 1 when it cannot listen; 2 for a command line it refuses",
  passthrough = "it serves until its editor exits, which a case of the verb list cannot be",
  guide = "none: an editor starts it, not a person",
  tests = { "build.lsp_test", "build.lsp_tool_test" },
}

return lsp
