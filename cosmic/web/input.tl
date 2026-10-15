--- Reads what a request carries -- its query, an urlencoded form body, a
--- JSON body -- and binds it to a [`cosmic.shape`] spec, collecting the
--- error of every field. [`Web.route_typed`] calls these before a handler
--- runs; a handler on a plain route calls them itself.
---
---     local record Signup
---       email: string
---       age: integer | nil
---       news: boolean
---     end
---     local SIGNUP <const> = Shape.record_of("Signup")
---
---     local form, bad = Input.form_into(req, SIGNUP, { secret = { "password" } })
---     if form == nil then
---       return render(req, bad)   -- bad.errors lists every field at once
---     end
---
--- A failure is data, an [`Input.Invalid`]: a status, a one-line message,
--- every [`Input.FieldError`], and the values submitted. The statuses are
--- those of the whole package: 400 for input that cannot be decoded (a bad
--- percent-escape, malformed JSON or multipart), 413 for a body over its limit, 415 for
--- a wrong Content-Type, and 422 for a value that decodes but fails its
--- spec.
---
--- A form, a query and a path carry text, so the binder coerces by the
--- spec; the rules are fixed here:
---
--- - A scalar takes the last value sent for its name, so a hidden `0`
---   before a checkbox's `1` works. [`Input.Options.repeated`] = "error"
---   refuses a repeat.
--- - `integer` is optional sign and digits, spaces and tabs trimmed, and
---   fits an integer; no hex, no `1e3`, no `1.0`. `number` is digits with
---   an optional fraction and exponent, finite. `boolean` is `true on 1
---   yes` or `false off 0 no ""`, in any case. `one_of` compares text, or
---   the listed number or boolean read as its own kind.
--- - An absent `boolean` is false, since an unchecked box sends nothing;
---   `optional(boolean)` makes it nil. A value of `""` is nil for an
---   optional field of any kind but `string`, and "required" for a
---   required one but `string` and `boolean`.
--- - A `list` takes every value of its name, in the order sent, each read
---   as the list's element; none is the empty list. An element's error is
---   named `tags.0`, counted from 0 as a JSON Pointer counts.
--- - A nested record reads `parent.child`, up to three levels below the
---   top; an optional one is nil unless some name starts with `parent.`.
---   A `map`, and a `list` of records or lists, cannot be carried by a
---   form: [`Input.check_spec`] refuses them.
--- - A string with a NUL is refused. A name the spec does not list is
---   ignored, so `is_admin=1` binds nothing; only a `strict_record`
---   refuses one, except `csrf_token`.
---
--- `csrf_token` is exempt from a `strict_record` only at the top level, and
--- a list element's name (`tags.0`) is not checked for strictness. A `one_of`
--- that lists `""` never binds from text: an empty value is "required" (or
--- nil if optional) before the list is consulted.
---
--- A JSON body goes through [`Shape.into`] unchanged, so only its first
--- failure is reported. A JSON client should read an error's `pointer`, not
--- its `field`: the dotted `field` is ambiguous for a key that holds a `.`.

local Codec = require("cosmic.codec")
local Fs = require("cosmic.fs")
local Json = require("cosmic.json")
local Multipart = require("cosmic.http.multipart")
local Poll = require("cosmic.poll")
local Rand = require("cosmic.rand")
local Request = require("cosmic.web.request")
local Shape = require("cosmic.shape")
local Stream = require("cosmic.stream")
local String = require("cosmic.string")
local Types = require("cosmic.web.types")
local Url = require("cosmic.url")

local record Input
  --- One refused field: see [`Types.FieldError`].
  type FieldError = Types.FieldError
  --- Input that was refused: see [`Types.Invalid`].
  type Invalid = Types.Invalid
  --- What the readers and binders take: see [`Types.InputOptions`].
  type Options = Types.InputOptions

  --- A Content-Type read by [`Input.media_type`].
  record MediaType
    --- The lowercase `type/subtype`; "" when the request sent no
    --- Content-Type.
    essence: string
    --- The parameters by lowercase name, a quoted value unquoted.
    params: {string:string}
  end

  --- The urlencoded body once decoded, kept on the request by
  --- [`Input.form`] so that a middleware and the handler share one decode.
  FORM: Types.Key<Url.Query>
  --- The JSON body once decoded, kept the same way by [`Input.json`].
  JSON: Types.Key<any>
  --- The body limit when `max_bytes` is not given, 64 KiB.
  DEFAULT_MAX: integer
  --- The body limit of [`Input.multipart`] when `max_bytes` is not given,
  --- 16 MiB.
  DEFAULT_MULTIPART_MAX: integer

  --- A file part of a multipart body, spooled to disk.
  record Upload
    --- The name of the form field it came in.
    field: string
    --- The client's filename cut to its last path component: to show a
    --- person, never to name a file or build a path.
    filename: string
    --- The Content-Type the client claimed ("text/plain" when it sent none):
    --- a claim, not a fact about the bytes, to be checked before it is
    --- served back as the file's type.
    content_type: string
    --- How many bytes the file holds.
    size: integer
    --- Where the bytes are: a file of this process's user, mode 0600, under a
    --- random name. It is removed when the request ends, so a handler that
    --- keeps the file moves it ([`Fs.rename`]) first.
    path: string
  end

  --- A multipart body, read.
  record Multipart
    --- The text parts, as a urlencoded form's pairs are, in the order sent.
    fields: Url.Query
    --- The file parts by field name, in the order sent. A file input left
    --- blank (an empty filename and no bytes) is not here.
    files: {string:{Input.Upload}}
    --- How many bytes the body held.
    size: integer
    --- Removes the spooled files (and the directory made for them), now
    --- rather than when the request ends. It is safe to call twice and
    --- when a file is gone.
    discard: function(Multipart)
  end
end

Input.FORM = Request.key("input.form")
Input.JSON = Request.key("input.json")

--- The multipart body once read, kept on the request so that a middleware,
--- [`Input.form`] and the handler share one read and one set of files.
local MULTIPART <const>: Types.Key<Types.Parsed<Input.Multipart>> = Request.key("input.multipart")

--- The largest body read unless told: a form or a JSON document, not an
--- upload.
local DEFAULT_MAX <const> = 64 * 1024
Input.DEFAULT_MAX = DEFAULT_MAX

local DEFAULT_MULTIPART_MAX <const> = 16 * 1024 * 1024
Input.DEFAULT_MULTIPART_MAX = DEFAULT_MULTIPART_MAX

local DEFAULT_FILE_MAX <const> = 8 * 1024 * 1024
local DEFAULT_FIELD_MAX <const> = 1024 * 1024
local DEFAULT_FILES <const> = 10
local DEFAULT_PARTS <const> = 100

--- What a body read that passed its limit leaves on the request as
--- `body_failure`, in the words of the server's own for the same fault.
local OVER_LIMIT <const> = "http: the body is longer than limits.body_bytes"

--- The deepest nesting of records below the top one a form can carry.
local MAX_DEPTH <const> = 3

--- The names the web layer itself consumes, which a strict record
--- accepts.
local RESERVED <const>: {string:boolean} = { csrf_token = true }

local function stop(status: integer, source: string, field: string, code: string, message: string,
                    pointer?: string): Types.Invalid
  return { status = status, message = message, errors = {
    { source = source, field = field, code = code, message = message, pointer = pointer },
  } }
end

--- The line that stands for `errors`: the first, and how many more.
local function summary(errors: {Types.FieldError}): string
  local first = errors[1]
  local line = first.field ~= "" and (first.field .. ": " .. first.message) or first.message
  if #errors > 1 then line = line .. (" (and %d more)"):format(#errors - 1) end
  return line
end

local function invalid(status: integer, errors: {Types.FieldError}, submitted?: Url.Query): Types.Invalid
  return { status = status, message = summary(errors), errors = errors, submitted = submitted }
end

--- A copy of `q` without the names in `secret`.
local function without(q: Url.Query, secret: {string} | nil): Url.Query
  local hidden: {string:boolean} = {}
  for _, name in ipairs(secret or {}) do hidden[name] = true end
  local out: Url.Query = { pairs = {}, by_name = {} }
  for _, pair in ipairs(q.pairs) do
    if not hidden[pair.name] then
      out.pairs[#out.pairs + 1] = { name = pair.name, value = pair.value }
      local list = out.by_name[pair.name]
      if list == nil then
        list = {}
        out.by_name[pair.name] = list
      end
      list[#list + 1] = pair.value
    end
  end
  return out
end

--- `text` without the whitespace at either end, found by scanning from the
--- ends: a pattern's `^%s*(.-)%s*$` costs the square of a run of spaces.
local function trim(text: string): string
  local first = text:find("[^%s]")
  if first == nil then return "" end
  local last = #text
  while text:sub(last, last):find("^%s") do last = last - 1 end
  return text:sub(first, last)
end

--- Parses the Content-Type header of `req`.
--- @param req Types.Request The request
--- @return Input.MediaType The media type and its parameters; `essence` is "" when none was sent
function Input.media_type(req: Types.Request): Input.MediaType
  local value = req.headers["content-type"]
  if value == nil then return { essence = "", params = {} } end
  local head, rest = value:match("^([^;]*)(.*)$")
  local params: {string:string} = {}
  local pos = 1
  while true do
    local from, to, name = rest:find("^;[ \t]*([%w!#$%%&'*+.^_`|~-]+)=", pos)
    if from == nil then break end
    pos = to + 1
    local text: string
    if rest:sub(pos, pos) == '"' then
      local parts: {string} = {}
      pos = pos + 1
      while pos <= #rest do
        local c = rest:sub(pos, pos)
        if c == "\\" then
          parts[#parts + 1] = rest:sub(pos + 1, pos + 1)
          pos = pos + 2
        elseif c == '"' then
          pos = pos + 1
          break
        else
          parts[#parts + 1] = c
          pos = pos + 1
        end
      end
      text = table.concat(parts)
      local _, blanks = rest:find("^[ \t]*", math.min(pos, #rest + 1))
      pos = blanks + 1
    else
      local token = rest:match("^[^;]*", pos)
      pos = pos + #token
      text = trim(token)
    end
    params[name:lower()] = text
  end
  return { essence = (trim(head):lower()), params = params }
end

--- Whether the request has a body: a chunked one always does.
local function has_body(req: Types.Request): boolean
  local length = req.raw.length
  return length == nil or length > 0
end

--- Whether the charset parameter is absent or UTF-8.
local function utf8_charset(params: {string:string}): boolean
  local charset = params["charset"]
  return charset == nil or charset:lower() == "utf-8"
end

--- The 415 for a body of another type than `kind` ("form", "json" or "multipart"), or
--- nil when it is that type, in UTF-8 or no charset.
local function wrong_type(req: Types.Request, kind: string): Types.Invalid | nil
  local type_ = Input.media_type(req)
  local media, params = type_.essence, type_.params
  if kind == "multipart" then
    if media == "multipart/form-data" then return nil end
    return stop(415, "body", "", "content_type", media == "" and
        "the body needs a Content-Type of multipart/form-data" or
        ("a Content-Type of multipart/form-data is needed, not " .. media))
  end
  local good: boolean
  if kind == "form" then
    good = media == "application/x-www-form-urlencoded"
  else
    good = media == "application/json" or (media:find("^application/[^/;]+%+json$") ~= nil)
  end
  if good and utf8_charset(params) then return nil end
  local wanted = kind == "form" and "application/x-www-form-urlencoded" or "application/json"
  if good then
    return stop(415, "body", "", "content_type",
      ("a charset of utf-8 is needed, not %s, for %s"):format(params["charset"], media))
  end
  return stop(415, "body", "", "content_type", media == "" and
      ("the body needs a Content-Type of " .. wanted) or
      ("a Content-Type of " .. wanted .. " is needed, not " .. media))
end

--- The status and code a failed body read has.
-- TODO: once cosmic.http.server reports why a body read failed as a kind,
-- not only a message, read that in place of the server's words.
local function read_failed(why: string): Types.Invalid
  if why == OVER_LIMIT or why:find("longer than limits.body_bytes", 1, true) then
    return stop(413, "body", "", "too_large", "the body is too large")
  elseif why == Poll.TIMEOUT then
    return stop(408, "body", "", "malformed", "the body came too slowly")
  end
  return stop(400, "body", "", "malformed", (why:gsub("^http: ", "")))
end

--- The body of `req` as text, read at most `limit` bytes, kept on the
--- request, and put back for a later reader; nil and why when the body is
--- the wrong kind, too long or unreadable.
local function body_text(req: Types.Request, kind: string, opts: Types.InputOptions | nil
): string | nil, Types.Invalid
  local limit = opts and opts.max_bytes or DEFAULT_MAX
  if has_body(req) then
    local wrong = wrong_type(req, kind)
    if wrong ~= nil then return nil, wrong end
  end
  local length = req.raw.length
  if length ~= nil and length > limit then
    return nil, stop(413, "body", "", "too_large",
      ("the body is over the limit, max_bytes = %d"):format(limit))
  end
  local cached = req.body_text
  local data: string
  if cached ~= nil then
    data = cached
  else
    if req.body_failure ~= nil then return nil, read_failed(req.body_failure) end
    local read, why = Stream.read_all(Stream.limit(req.raw.body, limit + 1))
    if read == nil then
      req.body_failure = why
      return nil, read_failed(why)
    end
    data = read
    if #data <= limit then
      req.body_text = data
      req.raw.body = Stream.from_string(data)
    else
      -- The stream is spent past the limit: a later reader, whatever its
      -- limit, must not take the truncated bytes for the body.
      req.body_failure = OVER_LIMIT
    end
  end
  if #data > limit then
    return nil, stop(413, "body", "", "too_large",
      ("the body is over the limit, max_bytes = %d"):format(limit))
  end
  if not utf8.len(data) then
    return nil, stop(400, "body", "", "utf8", "the body is not valid UTF-8")
  end
  return data
end

--- Bytes read from the body, and from a part, at a time.
local CHUNK <const> = 16384

--- `name`, a client's text, fit for a message: plain bytes and short.
local function shown(name: string): string
  local plain = name:sub(1, 40):gsub("[^%w _.%-]", "?")
  return plain .. (#name > 40 and "..." or "")
end

--- The status and code a failed read of a multipart body has: the
--- parser's own reasons are the client's malformed body, any other is the
--- body source's (see [`read_failed`]).
local function multipart_failed(why: string, limit: integer): Types.Invalid
  if why == OVER_LIMIT then
    return stop(413, "body", "", "too_large", ("the body is over the limit, max_bytes = %d"):format(limit))
  end
  if why:find("^multipart: ") then return stop(400, "body", "", "malformed", why) end
  return read_failed(why)
end

--- The charset a part's Content-Type names, lowercase; "" for none.
local function part_charset(content_type: string): string
  return content_type:lower():match(";%s*charset%s*=%s*\"?([^\";%s]*)") or ""
end

--- A Reader over `source` that fails with [`OVER_LIMIT`] when it would pass
--- `limit` bytes, and the count of the bytes it passed so far.
local function counted(source: Stream.Reader, limit: integer): Stream.Reader, function(): integer
  local passed = { total = 0 }
  local reader: Stream.Reader = {
    read = function(_self: Stream.Reader, max?: integer): string | nil, string
      local chunk, why = source:read(math.min(max or CHUNK, limit + 1 - passed.total))
      if chunk == nil then return nil, why end
      passed.total = passed.total + #chunk
      if passed.total > limit then return nil, OVER_LIMIT end
      return chunk, ""
    end,
    close = function(_self: Stream.Reader): boolean, string return true, "" end,
  }
  return reader, function(): integer return passed.total end
end

--- The file an upload is being written to, where the closer of a killed
--- task can reach it.
local record Spool
  writer?: Stream.FileWriter
end

--- What a multipart read has spooled so far: the uploads kept, and the
--- private directory made for them when the caller named none.
local record Spooled
  kept: {Input.Upload}
  made?: string
end

--- The value of a `<close>` variable: only its `__close` matters.
local record Unwinding
  metamethod __close: function(Unwinding)
end

--- The multipart body of `req`, at most `limit` bytes, read once and kept.
--- The text parts are held in memory, each file part is spooled to disk
--- as it arrives, and a part over its cap ends the read at once: memory
--- is bounded by the parser's buffer and the text parts' caps, not by the
--- body.
local function read_multipart(req: Types.Request, limit: integer, opts: Types.InputOptions | nil
): Types.Parsed<Input.Multipart>
  local cached = req:get(MULTIPART)
  if cached ~= nil then
    if cached.value ~= nil and cached.value.size > limit then
      return { invalid = stop(413, "body", "", "too_large",
        ("the body is over the limit, max_bytes = %d"):format(limit)) }
    end
    return cached
  end
  local function remember(result: Types.Parsed<Input.Multipart>): Types.Parsed<Input.Multipart>
    req:set(MULTIPART, result)
    return result
  end
  local wrong = wrong_type(req, "multipart")
  if wrong ~= nil then return remember({ invalid = wrong }) end
  local header = (req.headers["content-type"] or ""):lower()
  local _, named = header:gsub(";%s*boundary%s*=", "")
  local boundary = Input.media_type(req).params["boundary"]
  if boundary == nil or named ~= 1 then
    return remember({ invalid = stop(400, "body", "", "malformed",
      "the Content-Type needs exactly one boundary") })
  end
  local length = req.raw.length
  if length ~= nil and length > limit then
    -- Not kept: nothing is read yet, and a reader with a higher limit may
    -- still take the body.
    return { invalid = stop(413, "body", "", "too_large",
      ("the body is over the limit, max_bytes = %d"):format(limit)) }
  end
  if req.body_failure ~= nil then return { invalid = read_failed(req.body_failure) } end

  local max_file = opts and opts.max_file_bytes or DEFAULT_FILE_MAX
  local max_field = opts and opts.max_field_bytes or DEFAULT_FIELD_MAX
  local max_files = opts and opts.max_files or DEFAULT_FILES
  local max_parts = opts and opts.max_parts or DEFAULT_PARTS
  local dir = opts and opts.dir
  -- TODO: a sweeper for the orphans a crash leaves in `opts.dir` (an
  -- `Input.sweep_uploads(dir, older_than_ns)` for a lifespan hook), once an
  -- app keeps uploads in a directory of its own that outlives a request; a
  -- private directory under the temp directory is the system's to clean.
  local spooled: Spooled = { kept = {} }
  local fields: Url.Query = { pairs = {}, by_name = {} }
  local files: {string:{Input.Upload}} = {}
  local m: Input.Multipart = { fields = fields, files = files, size = 0 }
  m.discard = function(_self: Input.Multipart)
    for _, upload in ipairs(spooled.kept) do
      local _, _ = Fs.remove(upload.path)
    end
    spooled.kept = {}
    if spooled.made ~= nil then
      local _, _ = Fs.remove_tree(spooled.made)
      spooled.made = nil
    end
  end
  -- A task killed while it waits for the body (a client that went away)
  -- runs no code after the wait, only its pending closes: they remove what
  -- is spooled so far.
  local settled = false
  local spooling: Spool = {}
  local unwinding_mt: metatable<Unwinding> = { __close = function()
    if settled then return end
    local writer = spooling.writer
    if writer ~= nil then
      local _, _ = writer:abort()
    end
    m:discard()
  end }
  local _unwinding <close>: Unwinding = setmetatable({}, unwinding_mt)
  -- The body is spent from here, whatever the outcome: a later reader of
  -- the bytes is told so, not given an empty body.
  local source, total = counted(req.raw.body, limit)
  if req.body_text == nil then req.body_failure = "http: the multipart body was already read" end
  local function stop_with(invalid_: Types.Invalid): Types.Parsed<Input.Multipart>
    m:discard()
    return remember({ invalid = invalid_ })
  end
  local function storage_failed(why: string): Types.Parsed<Input.Multipart>
    m:discard()
    error("input: cannot store an upload: " .. why, 0)
  end

  local reader, bad = Multipart.reader(source, { boundary = boundary, max_parts = max_parts + 1 })
  if reader == nil then return stop_with(stop(400, "body", "", "malformed", bad)) end
  local parts = 0
  while true do
    local part, why = reader:next_part()
    if part == nil then
      if why ~= "" then return stop_with(multipart_failed(why, limit)) end
      break
    end
    parts = parts + 1
    if parts > max_parts then
      return stop_with(stop(413, "body", "", "too_many", ("the body has more than %s"):format(String.counted(max_parts, "part"))))
    end
    if part.filename ~= nil then
      if #spooled.kept >= max_files then
        return stop_with(stop(413, "body", "", "too_many", ("the body has more than %s"):format(String.counted(max_files, "file"))))
      end
      -- The first bytes decide whether this is a file: a browser's blank
      -- file input is a part with no filename and no bytes, which keeps
      -- nothing and makes no directory.
      local first, fwhy = part.body:read(CHUNK)
      if first == nil and fwhy ~= "" then return stop_with(multipart_failed(fwhy, limit)) end
      if first ~= nil or part.filename ~= "" then
        local into: string
        if dir == nil then
          local made_dir, trouble = Fs.mkdtemp("cosmic-upload-")
          if made_dir == nil then return storage_failed(trouble) end
          spooled.made = made_dir
          dir = made_dir
          into = made_dir
        else
          into = dir
        end
        local path = into .. "/" .. Codec.hex((assert(Rand.entropy(16))))
        local writer, trouble = Stream.create(path, 384)
        if writer == nil then return storage_failed(trouble) end
        spooling.writer = writer
        local size = 0
        local verdict, detail = "ok", ""
        local chunk: string | nil = first
        local rwhy = ""
        while chunk ~= nil do
          size = size + #chunk
          if size > max_file then
            verdict = "over"
            break
          end
          local wrote, wwhy = writer:write(chunk)
          if not wrote then
            verdict, detail = "disk", wwhy
            break
          end
          chunk, rwhy = part.body:read(CHUNK)
        end
        if verdict == "ok" and rwhy ~= "" then verdict, detail = "source", rwhy end
        if verdict == "ok" then
          local closed, cwhy = writer:close()
          if not closed then verdict, detail = "disk", cwhy end
        else
          local _, _ = writer:abort()
        end
        spooling.writer = nil
        if verdict == "disk" then return storage_failed(detail) end
        if verdict == "source" then return stop_with(multipart_failed(detail, limit)) end
        if verdict == "over" then
          return stop_with(stop(413, "body", "", "too_large",
            ("the file %s is over the limit, max_file_bytes = %d"):format(shown(part.name), max_file)))
        end
        local upload: Input.Upload = { field = part.name, filename = part.filename,
          content_type = part.content_type, size = size, path = path }
        spooled.kept[#spooled.kept + 1] = upload
        local list = files[part.name]
        if list == nil then
          list = {}
          files[part.name] = list
        end
        list[#list + 1] = upload
      end
    else
      local pieces: {string} = {}
      local size = 0
      while true do
        local chunk, rwhy = part.body:read(CHUNK)
        if chunk == nil then
          if rwhy ~= "" then return stop_with(multipart_failed(rwhy, limit)) end
          break
        end
        size = size + #chunk
        if size > max_field then
          return stop_with(stop(413, "body", "", "too_large",
            ("the field %s is over the limit, max_field_bytes = %d"):format(shown(part.name), max_field)))
        end
        pieces[#pieces + 1] = chunk
      end
      local value = table.concat(pieces)
      local charset = part_charset(part.content_type)
      if charset == "iso-8859-1" or charset == "latin1" then
        value = value:gsub("[\128-\255]", function(c: string): string return utf8.char(c:byte()) end)
      elseif charset ~= "" and charset ~= "utf-8" and charset ~= "us-ascii" then
        return stop_with(stop(415, "body", "", "content_type",
          ("the field %s is in a charset other than UTF-8 and ISO-8859-1"):format(shown(part.name))))
      elseif not utf8.len(value) then
        return stop_with(stop(400, "body", "", "utf8", ("the field %s is not valid UTF-8"):format(shown(part.name))))
      end
      fields.pairs[#fields.pairs + 1] = { name = part.name, value = value }
      local list = fields.by_name[part.name]
      if list == nil then
        list = {}
        fields.by_name[part.name] = list
      end
      list[#list + 1] = value
    end
  end
  local _, _ = reader:close()
  settled = true
  m.size = total()
  if #spooled.kept > 0 or spooled.made ~= nil then
    -- The app closes a request's bodies when the handler has returned: the
    -- files go with them.
    -- TODO: once the app can run a hook after the reply is written, remove
    -- the files there, so a handler may answer with a stream over an upload.
    local cleanup: Stream.Reader = {
      read = function(_self: Stream.Reader, _max?: integer): string | nil, string return nil, "" end,
      close = function(_self: Stream.Reader): boolean, string
        m:discard()
        return true, ""
      end,
    }
    req.bodies[#req.bodies + 1] = cleanup
  end
  return remember({ value = m })
end

--- The query string of `req`, decoded. A query is not read leniently.
--- Without `opts` the decode is kept on the request and shared with
--- [`Types.Request.query`].
--- @param req Types.Request The request
--- @param opts Url.QueryOptions | nil What [`Url.decode_query`] takes
--- @return Types.Parsed<Url.Query> The query, or status 400
function Input.query(req: Types.Request, opts?: Url.QueryOptions): Types.Parsed<Url.Query>
  local q, why: Url.Query | nil, string
  if opts == nil then
    q, why = req:query()
  else
    q, why = Url.decode_query(req.query_string, opts)
  end
  if q == nil then return { invalid = stop(400, "query", "", "malformed", why) } end
  return { value = q }
end

--- The urlencoded body of `req`, decoded, with a Content-Type of
--- `application/x-www-form-urlencoded` (charset UTF-8 or none) and at most
--- `opts.max_bytes` (64 KiB). The body is read once: the decode is kept
--- under [`Input.FORM`], the bytes in `req:bytes()` and `req.raw.body`, so
--- a middleware and a handler both read it. A request with no body is an
--- empty form.
--- @param req Types.Request The request
--- @param opts Types.InputOptions | nil The limit
--- @return Types.Parsed<Url.Query> The form, or status 400, 408, 413 or 415
function Input.form(req: Types.Request, opts?: Types.InputOptions): Types.Parsed<Url.Query>
  if has_body(req) and Input.media_type(req).essence == "multipart/form-data" then
    local seen = req:get(Input.FORM)
    if seen ~= nil then return { value = seen } end
    local got = read_multipart(req, opts and opts.max_bytes or DEFAULT_MAX, opts)
    if got.invalid ~= nil then return { invalid = got.invalid } end
    local fields = assert(got.value).fields
    req:set(Input.FORM, fields)
    return { value = fields }
  end
  local text, bad = body_text(req, "form", opts)
  if text == nil then return { invalid = bad } end
  local cached = req:get(Input.FORM)
  if cached ~= nil then return { value = cached } end
  local q, why = Url.decode_query(text)
  if q == nil then return { invalid = stop(400, "form", "", "malformed", why) } end
  req:set(Input.FORM, q)
  return { value = q }
end

--- The multipart body of `req` (`multipart/form-data`), read once and kept
--- on the request, at most `opts.max_bytes` (16 MiB): the text
--- parts as a form's pairs, each file part spooled to a file of its own as
--- it arrives, so memory holds the parser's buffer and the text parts, not
--- the upload. The files go when the handler returns (the app closes the
--- request's bodies) or at [`Input.Multipart.discard`]; a handler that keeps
--- one moves it first. Nothing the client sent names a file.
---
--- Refused: 415 for another Content-Type; 400 for a body that is not
--- well-formed multipart (a missing, repeated or bad boundary, a part
--- without a name, a header or filename the parser refuses, a text part
--- that is not UTF-8, a body that ends early); 413 over `max_bytes`, a file
--- over `max_file_bytes` (8 MiB), a text part over `max_field_bytes`
--- (1 MiB), more than `max_files` (10) files or `max_parts` (100) parts;
--- 408 for a body that came too slowly. A text part in ISO-8859-1 is
--- converted; another charset is 415. The body is spent by the read:
--- `req:bytes()` afterward fails, unless it was read first.
---
--- The server's own `limits.body_bytes` (1 MiB) comes first: it answers 413
--- to a body above it before any handler runs, so `max_bytes` above it
--- changes nothing until [`Web.serve`] is given a higher `limits.body_bytes`,
--- which it applies to every route.
---
--- A body read past a limit is spent: a reader with a higher limit after a
--- lower one that passed it (an [`Input.form`] before this, on a body with no
--- Content-Length) is refused 413 naming the earlier limit. A body whose
--- Content-Length is over a limit is refused without being read, so a later
--- reader with a higher limit still takes it.
--- @param req Types.Request The request
--- @param opts Types.InputOptions | nil The limits and `dir`
--- @return Types.Parsed<Input.Multipart> The parts, or why not
-- TODO: let a route raise the server's limit for its own uploads, once
-- `ServeSpec.body_limit` exists (the TODO at `Server.Limits.body_bytes` in
-- cosmic/http/server.tl); until then a large upload raises `limits.body_bytes`
-- for the whole server.
function Input.multipart(req: Types.Request, opts?: Types.InputOptions): Types.Parsed<Input.Multipart>
  return read_multipart(req, opts and opts.max_bytes or DEFAULT_MULTIPART_MAX, opts)
end

--- The JSON body of `req`, decoded by [`Json.decode`] with `null` read as
--- [`Json.null`] (which [`Shape.into`] counts as missing) and nesting
--- limited to 32. The Content-Type is `application/json` or
--- `application/*+json`, charset UTF-8 or none: a cross-site HTML form
--- cannot send one, so a JSON endpoint that insists on it is out of reach
--- of a form post. The body is read once and kept as [`Input.form`]'s is,
--- the decode under [`Input.JSON`].
--- @param req Types.Request The request
--- @param opts Types.InputOptions | nil The limit
--- @return Types.Parsed<any> The value, or status 400, 408, 413, 415, or 422 for an empty body
function Input.json(req: Types.Request, opts?: Types.InputOptions): Types.Parsed<any>
  local text, bad = body_text(req, "json", opts)
  if text == nil then return { invalid = bad } end
  local cached = req:get(Input.JSON)
  if cached ~= nil then return { value = cached } end
  if text == "" then
    return { invalid = stop(422, "body", "", "required", "a JSON body is required", "") }
  end
  local value, why = Json.decode(text, { null_value = Json.null, max_depth = 32 })
  if value == nil then
    return { invalid = stop(400, "body", "", "json", why ~= "" and why or "the body is not JSON") }
  end
  req:set(Input.JSON, value)
  return { value = value }
end

local ints <const> = "^[+-]?%d+$"

--- `text` without leading and trailing spaces and tabs.
local function trimmed(text: string): string
  local first = text:find("[^ \t]")
  if first == nil then return "" end
  local last = #text
  while text:byte(last) == 32 or text:byte(last) == 9 do last = last - 1 end
  return text:sub(first, last)
end

--- The integer `text` spells, or nil.
local function parse_integer(text: string): integer | nil
  local s = trimmed(text)
  if not s:find(ints) then return nil end
  local sign, digits = s:match("^([+-]?)(%d+)$")
  digits = digits:gsub("^0+", "")
  local top = sign == "-" and "9223372036854775808" or "9223372036854775807"
  if #digits > #top or (#digits == #top and digits > top) then return nil end
  return math.tointeger(tonumber(s))
end

--- The finite number `text` spells, or nil.
local function parse_number(text: string): number | nil
  local s = trimmed(text)
  local body = s:gsub("^[+-]", "", 1)
  local mantissa, exponent = body:match("^([%d.]+)[eE]([+-]?%d+)$")
  if mantissa == nil then mantissa = body end
  if not (mantissa:find("^%d+$") or mantissa:find("^%d*%.%d+$")) then return nil end
  if exponent ~= nil and #exponent:gsub("^[+-]", "") > 6 then return nil end
  local n = tonumber(s)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
  return n
end

local TRUE <const>: {string:boolean} = { ["true"] = true, on = true, ["1"] = true, yes = true }
local FALSE <const>: {string:boolean} = { ["false"] = true, off = true, ["0"] = true, no = true, [""] = true }

local function parse_boolean(text: string): boolean | nil
  local s = text:lower()
  if TRUE[s] then return true end
  if FALSE[s] then return false end
  return nil
end

--- Where a binder is, and what it found.
local record Walk
  q: Url.Query
  source: string
  repeated: boolean
  errors: {Types.FieldError}
end

local function refuse(w: Walk, field: string, code: string, message: string)
  w.errors[#w.errors + 1] = { source = w.source, field = field, code = code, message = message }
end

local function listed(spec: Shape.Spec): string
  local parts: {string} = {}
  for i, v in ipairs(assert(spec.values)) do parts[i] = tostring(v) end
  return table.concat(parts, ", ")
end

--- The value `text` spells for the scalar `spec`, or nil with the error
--- recorded.
local function coerce(w: Walk, field: string, spec: Shape.Spec, text: string): any
  local kind = spec.kind
  if kind == "string" or kind == "any" then
    if text:find("\0", 1, true) then
      refuse(w, field, "type", "must not contain a NUL byte")
      return nil
    end
    return text
  elseif kind == "integer" then
    local n = parse_integer(text)
    if n == nil then refuse(w, field, "integer", "must be a whole number") end
    return n
  elseif kind == "number" then
    local n = parse_number(text)
    if n == nil then refuse(w, field, "number", "must be a number") end
    return n
  elseif kind == "boolean" then
    local b = parse_boolean(text)
    if b == nil then
      refuse(w, field, "boolean", "must be true or false")
      return nil
    end
    return b
  elseif kind == "one_of" then
    for _, want in ipairs(assert(spec.values)) do
      if want is string then
        if text == want then return want end
      elseif want is boolean then
        if parse_boolean(text) == want then return want end
      elseif want is integer then
        if parse_integer(text) == want then return want end
      else
        if parse_number(text) == want then return want end
      end
    end
    refuse(w, field, "one_of", "must be one of " .. listed(spec))
    return nil
  end
  error(("input: %s cannot be read from text, at %q"):format(kind, field), 0)
end

--- The value of the scalar `field`, given the text sent for it or nil.
local function scalar(w: Walk, field: string, spec: Shape.Spec, text: string | nil): any
  local kind = spec.kind
  if text == nil or (text == "" and kind ~= "string" and kind ~= "any") then
    if spec.optional then return nil end
    if kind == "boolean" then return false end
    refuse(w, field, "required", "is required")
    return nil
  end
  return coerce(w, field, spec, text)
end

local bind_record: function(w: Walk, prefix: string, spec: Shape.Spec, depth: integer): {string:any}

--- Whether some name starts with `prefix` and a dot.
local function nested_present(q: Url.Query, prefix: string): boolean
  local head = prefix .. "."
  for name in pairs(q.by_name) do
    if name:sub(1, #head) == head then return true end
  end
  return false
end

local function bind_list(w: Walk, field: string, spec: Shape.Spec): any
  local values = w.q.by_name[field]
  if values == nil then
    if spec.optional then return nil end
    return Json.array({})
  end
  local out: {any} = {}
  local of = assert(spec.of)
  for i, text in ipairs(values) do
    out[i] = scalar(w, field .. "." .. (i - 1), of, text)
  end
  return Json.array(out)
end

local function bind_node(w: Walk, field: string, spec: Shape.Spec, depth: integer): any
  local kind = spec.kind
  if kind == "record" then
    if spec.optional and not nested_present(w.q, field) then return nil end
    return bind_record(w, field, spec, depth + 1)
  elseif kind == "list" then
    return bind_list(w, field, spec)
  elseif kind == "map" then
    error(("input: %s is a map, which text cannot carry: see Input.check_spec"):format(field), 0)
  end
  local values = w.q.by_name[field]
  if values ~= nil and #values > 1 and w.repeated then
    refuse(w, field, "repeated", "was sent more than once")
    return nil
  end
  return scalar(w, field, spec, values and values[#values])
end

--- The first component of `name` after `prefix` and a dot, or nil where
--- `name` is not below `prefix`.
local function component(name: string, prefix: string): string | nil
  local rest = name
  if prefix ~= "" then
    local head = prefix .. "."
    if name:sub(1, #head) ~= head then return nil end
    rest = name:sub(#head + 1)
  end
  return (rest:match("^([^.]*)"))
end

bind_record = function(w: Walk, prefix: string, spec: Shape.Spec, depth: integer): {string:any}
  local fields, names = assert(spec.fields), assert(spec.names)
  if spec.strict then
    local unknown: {string} = {}
    local seen: {string:boolean} = {}
    for name in pairs(w.q.by_name) do
      local part = component(name, prefix)
      if part ~= nil and fields[part] == nil and not (prefix == "" and RESERVED[part]) and not seen[name] then
        seen[name] = true
        unknown[#unknown + 1] = name
      end
    end
    table.sort(unknown)
    for _, name in ipairs(unknown) do refuse(w, name, "unknown", "is not a known field") end
  end
  local out: {string:any} = {}
  for _, name in ipairs(names) do
    local field = prefix == "" and name or (prefix .. "." .. name)
    out[name] = bind_node(w, field, fields[name], depth)
  end
  return out
end

--- The scalar kinds [`coerce`] reads from text.
local SCALARS <const>: {string:boolean} = {
  string = true, any = true, integer = true, number = true, boolean = true, one_of = true,
}

--- Why `spec` cannot be carried by `source`, or "" when it can.
local function check_node(spec: Shape.Spec, field: string, source: string, depth: integer): string
  local kind = spec.kind
  local at = field == "" and "the spec" or ("field " .. field)
  if not (SCALARS[kind] or kind == "map" or kind == "record" or kind == "list") then
    return ("input: %s of a %s is of kind %s, which text cannot carry"):format(at, source, tostring(kind))
  end
  if kind == "map" then
    return ("input: %s of a %s is a map, which text cannot carry"):format(at, source)
  elseif kind == "record" then
    if source == "path" and field ~= "" then
      return ("input: %s of a path is a record: a path holds strings, integers, booleans and one_of"):format(at)
    end
    if depth > MAX_DEPTH + 1 then
      return ("input: %s of a %s nests records deeper than %d"):format(at, source, MAX_DEPTH)
    end
    local fields = assert(spec.fields)
    for _, name in ipairs(assert(spec.names)) do
      local trouble = check_node(fields[name], field == "" and name or (field .. "." .. name), source, depth + 1)
      if trouble ~= "" then return trouble end
    end
  elseif kind == "list" then
    local of = assert(spec.of).kind
    if source == "path" then
      return ("input: %s of a path is a list: a path holds one value per name"):format(at)
    end
    if of == "list" or of == "record" or of == "map" then
      return ("input: %s of a %s is a list of %ss, which text cannot carry"):format(at, source, of)
    end
    if not SCALARS[of] then
      return ("input: %s of a %s is a list of kind %s, which text cannot carry"):format(at, source, tostring(of))
    end
  elseif source == "path" and (kind == "number" or kind == "any" or spec.optional) then
    return ("input: %s of a path must be a string, integer, boolean or one_of, and present"):format(at)
  end
  return ""
end

--- Raises, naming the field, unless `spec` is one a `source` can carry: a
--- record of strings, integers, numbers, booleans, `one_of`, lists of
--- those, and records of the same nested three deep. A `map`, a list of
--- records and a spec of another kind cannot be read from text; a path holds only a string, integer,
--- boolean or `one_of` per name, none optional. A "body" (JSON) carries
--- any spec. [`Web.route_typed`] calls it when a route is registered, so a
--- spec text cannot satisfy fails at startup.
--- @param spec Shape.Spec The spec
--- @param source string "path", "query", "form" or "body"
function Input.check_spec(spec: Shape.Spec, source: string)
  if source ~= "path" and source ~= "query" and source ~= "form" and source ~= "body" then
    error(("input: %q is not a source: path, query, form or body"):format(tostring(source)), 2)
  end
  if source == "body" then return end
  if spec.kind ~= "record" then
    error(("input: a %s binds to a record, not a %s"):format(source, spec.kind), 2)
  end
  local trouble = check_node(spec, "", source, 1)
  if trouble ~= "" then error(trouble, 2) end
end

--- The JSON Pointer `pointer`, as a dotted field name: `/a/0/b` is `a.0.b`.
local function dotted(pointer: string): string
  if pointer == "" then return "" end
  local parts: {string} = {}
  for part in pointer:sub(2):gmatch("[^/]*") do
    parts[#parts + 1] = (part:gsub("~1", "/"):gsub("~0", "~"))
  end
  return table.concat(parts, ".")
end

--- Splits the message of [`Shape.into`], `pointer "/a/b": expected
--- integer, got string`, into its pointer and the rest. A message in
--- another form has no pointer.
local function split_failure(message: string): string, string
  if message:sub(1, 9) ~= 'pointer "' then return "", message end
  local i = 10
  while i <= #message do
    local c = message:sub(i, i)
    if c == "\\" then
      i = i + 2
    elseif c == '"' then
      break
    else
      i = i + 1
    end
  end
  local pointer, trouble = Json.decode(message:sub(9, i))
  local rest = message:sub(i + 1):gsub("^: ", "")
  if not pointer is string or trouble ~= "" then return "", message end
  return pointer, rest
end

--- The code a [`Shape.into`] failure `reason` stands for.
local function failure_code(reason: string): string
  if reason:find("^unknown key") then return "unknown" end
  if reason:find("got nothing$") or reason:find("got null$") then return "required" end
  local wanted = reason:match("^expected (%a+)")
  if wanted == "integer" or wanted == "number" or wanted == "boolean" then return wanted end
  if reason:find("^expected one of") then return "one_of" end
  return "type"
end

--- Binds the decoded `value` to `spec` with [`Shape.into`], as the answer
--- or the one error it reports.
local function bind_json<T>(value: any, spec: Shape.Spec): Types.Parsed<T>
  -- TODO: once cosmic.shape reports a failing path as steps, read them in
  -- place of splitting the message, and collect every failure of a JSON
  -- body as a form's are.
  local out, why: T | nil, string = Shape.into(value, spec)
  if out == nil then
    local pointer, reason = split_failure(why)
    return { invalid = invalid(422, { { source = "body", field = dotted(pointer), code = failure_code(reason),
      message = reason, pointer = pointer } }) }
  end
  return { value = out }
end

local function with_source(opts: Types.InputOptions | nil, source: string): Types.InputOptions
  local out: Types.InputOptions = {}
  if opts ~= nil then
    out.max_bytes, out.secret, out.repeated = opts.max_bytes, opts.secret, opts.repeated
  end
  out.source = source
  return out
end

--- Binds the text of `q` to `spec`, a record, coercing by the rules in the
--- module's description and collecting every field's error. The answer's
--- type is the caller's annotation, as [`Shape.into`]'s is; the tree is
--- checked by [`Shape.into`] last, so what comes back is what it makes.
--- `opts.source` ("form" by default) is what each error's `source` says.
--- @param q Url.Query The pairs
--- @param spec Shape.Spec A record
--- @param opts Types.InputOptions | nil `source`, `repeated`, `secret`
--- @return Types.Parsed<T> The record, or status 422 and every error
function Input.bind_strings<T>(q: Url.Query, spec: Shape.Spec, opts?: Types.InputOptions): Types.Parsed<T>
  if spec.kind ~= "record" then
    error(("input: bind_strings binds a record, not a %s"):format(tostring(spec.kind)), 2)
  end
  local w: Walk = { q = q, source = opts and opts.source or "form", errors = {},
    repeated = opts ~= nil and opts.repeated == "error" }
  local tree = bind_record(w, "", spec, 0)
  if #w.errors > 0 then
    return { invalid = invalid(422, w.errors, without(q, opts and opts.secret)) }
  end
  local out, why: T | nil, string = Shape.into(tree, spec)
  if out == nil then
    -- A tree the binder built that Shape refuses is the binder's bug; the
    -- client is told what Shape said.
    local pointer, reason = split_failure(why)
    return { invalid = invalid(422, { { source = w.source, field = dotted(pointer), code = "type",
      message = reason } }, without(q, opts and opts.secret)) }
  end
  return { value = out }
end

--- The query of `req` bound to `typed` by [`Input.bind_strings`], with
--- `source` "query". A failure to decode is 400, a value that fails the
--- spec 422.
--- @param req Types.Request The request
--- @param typed Shape.Typed<T> The record and its spec
--- @param opts Types.InputOptions | nil `repeated`, `secret`
--- @return Types.Parsed<T> The record, or why not
function Input.query_into<T>(req: Types.Request, typed: Shape.Typed<T>, opts?: Types.InputOptions): Types.Parsed<T>
  local read = Input.query(req)
  if read.invalid ~= nil then return { invalid = read.invalid } end
  local out: Types.Parsed<T> = Input.bind_strings(assert(read.value), typed.spec, with_source(opts, "query"))
  return out
end

--- The urlencoded body of `req` read by [`Input.form`] and bound to
--- `typed` by [`Input.bind_strings`]. 400, 408, 413 or 415 for a body that
--- cannot be read, 422 for a value that fails the spec.
--- @param req Types.Request The request
--- @param typed Shape.Typed<T> The record and its spec
--- @param opts Types.InputOptions | nil `max_bytes`, `repeated`, `secret`
--- @return Types.Parsed<T> The record, or why not
function Input.form_into<T>(req: Types.Request, typed: Shape.Typed<T>, opts?: Types.InputOptions): Types.Parsed<T>
  local read = Input.form(req, opts)
  if read.invalid ~= nil then return { invalid = read.invalid } end
  local out: Types.Parsed<T> = Input.bind_strings(assert(read.value), typed.spec, with_source(opts, "form"))
  return out
end

--- The text parts of the multipart body of `req`, read by
--- [`Input.multipart`], bound to `typed` by [`Input.bind_strings`] as a
--- form's fields are, with the same errors; the files are in
--- `Input.multipart(req).value.files`. The statuses are
--- [`Input.multipart`]'s, and 422 for a value that fails the spec.
--- @param req Types.Request The request
--- @param typed Shape.Typed<T> The record and its spec
--- @param opts Types.InputOptions | nil The limits, `repeated`, `secret`
--- @return Types.Parsed<T> The record, or why not
function Input.multipart_into<T>(req: Types.Request, typed: Shape.Typed<T>, opts?: Types.InputOptions): Types.Parsed<T>
  local read = Input.multipart(req, opts)
  if read.invalid ~= nil then return { invalid = read.invalid } end
  local out: Types.Parsed<T> = Input.bind_strings(assert(read.value).fields, typed.spec, with_source(opts, "form"))
  return out
end

--- The JSON body of `req` read by [`Input.json`] and checked against
--- `typed` by [`Shape.into`], whose first failure is the one error: its
--- `pointer` is the JSON Pointer of the failing value and its `field` the
--- same dotted (`/items/0/name` is `items.0.name`).
--- @param req Types.Request The request
--- @param typed Shape.Typed<T> The record and its spec
--- @param opts Types.InputOptions | nil The limit
--- @return Types.Parsed<T> The record, or why not
function Input.json_into<T>(req: Types.Request, typed: Shape.Typed<T>, opts?: Types.InputOptions): Types.Parsed<T>
  local read = Input.json(req, opts)
  if read.invalid ~= nil then return { invalid = read.invalid } end
  local out: Types.Parsed<T> = bind_json(read.value, typed.spec)
  return out
end

--- The path parameters of `req` (`req.params`, text) bound to `typed` by
--- [`Input.bind_strings`], with `source` "path".
--- @param req Types.Request The request
--- @param typed Shape.Typed<T> The record and its spec
--- @param opts Types.InputOptions | nil `secret`
--- @return Types.Parsed<T> The record, or status 422
function Input.path_into<T>(req: Types.Request, typed: Shape.Typed<T>, opts?: Types.InputOptions): Types.Parsed<T>
  local names: {string} = {}
  for name in pairs(req.params) do names[#names + 1] = name end
  table.sort(names)
  local q: Url.Query = { pairs = {}, by_name = {} }
  for _, name in ipairs(names) do
    local value = req.params[name]
    q.pairs[#q.pairs + 1] = { name = name, value = value }
    q.by_name[name] = { value }
  end
  local out: Types.Parsed<T> = Input.bind_strings(q, typed.spec, with_source(opts, "path"))
  return out
end

--- An [`Input.Invalid`] of status 422 with the one error `message` on
--- `field`, over the form already read by [`Input.form`] (or without
--- values where none was), for a fault no spec can catch, such as an
--- email already taken, so that the handler re-renders by the same path.
--- @param req Types.Request The request
--- @param field string The field
--- @param message string What to tell the person
--- @param opts Types.InputOptions | nil `secret`
--- @return Types.Invalid The refusal
function Input.fail(req: Types.Request, field: string, message: string, opts?: Types.InputOptions): Types.Invalid
  local q = req:get(Input.FORM)
  local errors: {Types.FieldError} = { { source = "form", field = field, code = "invalid", message = message } }
  return invalid(422, errors, q ~= nil and without(q, opts and opts.secret) or nil)
end

--- The messages of `bad` by field, several joined with "; ", for a
--- form to show beside each input. A field with none is absent.
--- @param bad Types.Invalid The refusal
--- @return {string:string} The message of each field
function Input.errors_by_field(bad: Types.Invalid): {string:string}
  local joined: {string:string} = {}
  for _, e in ipairs(bad.errors) do
    local before = joined[e.field]
    joined[e.field] = before ~= nil and (before .. "; " .. e.message) or e.message
  end
  return joined
end

--- The last value submitted for `name` in `bad`, "" when none was or
--- the name is secret.
--- @param bad Types.Invalid The refusal
--- @param name string The field
--- @return string The value, to put back in the input
function Input.value(bad: Types.Invalid, name: string): string
  if bad.submitted == nil then return "" end
  return Url.query_last(bad.submitted, name) or ""
end

return Input
