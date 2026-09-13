# Recipes

end-to-end patterns composing several `cosmic.*` modules. each recipe is a
complete script shape — adapt names and drop pieces you don't need.

## CLI script skeleton

args → read file → decode → transform → encode → print, with an error exit
at every stage. this is the shape of most small cosmic tools.

```teal
local json = require("cosmic.json")
local fs = require("cosmic.fs")

local function die(msg: string)
  io.stderr:write("error: " .. msg .. "\n")
  os.exit(1)
end

local function main(): integer
  local path = arg[1]
  if path == nil then
    die("usage: tool.tl <input.json>")
  end
  local data, read_err = fs.read(path as string)
  if not data then
    die("cannot read '" .. tostring(path) .. "': " .. read_err)
  end
  local items, decode_err = json.decode_array(data)
  if items is {any} then
    -- transform: count the items
    local result = {count = #items}

    local encoded, encode_err = json.encode(result)
    if encode_err then
      die("encode failed: " .. encode_err)
    end
    print(encoded)
    return 0
  end
  die("invalid JSON: " .. decode_err)
  return 1
end

os.exit(main())
```

key details: `arg[1]` is `string | nil` (guard before use),
`json.decode_array` returns a typed `{any} | nil` — no cast needed, and a
top-level value that is not an array is a real error (`decode_object` is
the sibling for objects; plain `decode` returns `any` for the dynamic
case) — `is` narrows it in the positive branch, capture `encode`'s error
return instead of passing the call straight to `print`, and `main`
returns `integer` because `os.exit` rejects `number`.

## index files into sqlite (walk + hash + sqlite)

walk a tree, store path/size/digest with upsert semantics, query by
substring.

```teal
local check = require("cosmic.check")
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local sqlite = require("cosmic.sqlite")

local db = check.must(sqlite.open("index.db"))
assert(db:exec("CREATE TABLE IF NOT EXISTS files (" ..
    "path TEXT PRIMARY KEY, size INTEGER, digest TEXT)"))

check.must(fs.visit("testdata", function(e: fs.Entry, _ctx: any)
      local path = e.path
      -- e.path is the FULL path; do not join it with e.name
      local st, _serr = e:stat()
      if st and st:is_file() then
        local data = fs.read(path)
        if data then
          assert(db:exec("INSERT INTO files (path, size, digest) VALUES (?, ?, ?) " ..
              "ON CONFLICT(path) DO UPDATE SET size = excluded.size, " ..
              "digest = excluded.digest",
              {path, st:size(), hash.sha256_hex(data)}))
        end
      end
    end))

-- substring query: LIKE uses % as the wildcard, not *
for row in check.must(db:query("SELECT * FROM files WHERE path LIKE ?",
    {"%src%"})) do
  print(row.path, row.size, row.digest)
end
assert(db:close())
```

the visitor's third parameter is `fs.WalkStat`, exported on the public
`cosmic.fs` module — annotate it directly, as above. (do not require
`cosmic.fs.types`: that is an internal shard, and the lint visibility
rule refuses it from outside `cosmic/`.)

## spawn cosmic as a child (self-reinvocation)

run another script in a child process and read its output through a pipe.

```teal
local check = require("cosmic.check")
local child = require("cosmic.child")
local proc = require("cosmic.proc")

-- proc.interpreter() is arg[-1] resolved — NOT arg[0], the script path
local h = check.must(child.start({check.must(proc.interpreter()), "worker.tl"}))
local out = h:read()
print(out)
check.must(h:wait())
```

for a server child, have it print a readiness line (e.g. `READY <port>`)
and block on `h.stdout:read(64)` instead of sleeping. see
`cosmic --examples child` for the pipe-capture variant.

## TCP echo pair (net)

see `cosmic --examples net` for a runnable single-process echo exchange:
`listen_tcp("127.0.0.1", 0)` for an OS-assigned port, `dial`,
`accept`, then `send`/`recv`. `recv` returns bare nil on peer close
(end of stream); `""` only ever means a zero-byte datagram.

## HTTP server (http + fetch)

`cosmic.http` owns the socket and the loop: `listen`, then one handler
function per request. `serve` accepts and answers until the listener
closes; `serve_one` does a single connection, keep-alive included, which
is what a test or a caller with its own accept loop wants.

```teal
local check = require("cosmic.check")
local http = require("cosmic.http")

local srv = check.must(http.listen("127.0.0.1", 0))
print("READY " .. srv:port()) -- a test blocks on this line
local _ok, err = srv:serve(function(req: http.Request, res: http.Response)
    if req.path == "/health" then
      local _sent, _serr = res:json({ok = true})
    else
      local _sent, _serr = res:text("hello " .. req.path .. "\n")
    end
  end)
print("stopped: " .. err)
```

the handler gets a typed `Request` — `method`, `path`, `query`,
`version`, `headers`, `req:header(name)`, `req:body()` — and a
`Response` that computes the framing for it: `Date`, `Content-Length`
and the keep-alive decision are the server's, never the handler's. the
send verbs are `send`, `text`, `json`, `redirect`, and `html`, which
takes `cosmic.html.SafeHtml` rather than a string, so a
`cosmic.template` render reaches the wire already escaped and a raw
string does not compile. a handler that returns without sending, or one
that throws, gets a 500 and the connection carries on. a header whose
name or value carries a CR or LF — the shape of a response-splitting
payload, which is what echoing a query parameter into `redirect` or
`set_header` would hand a client — is refused rather than stripped, and
the send verb then puts nothing at all on the wire.

`listen` takes the limits: `read_timeout_ms` (default 30000),
`max_body_bytes` (413 above it, refused on the declared
`Content-Length` before a byte is read), `max_head_bytes` (431 above
it; the default 32767 is already as large as a head can be, so this one
is only worth lowering). a chunked request body is decoded, bounded by
the same `max_body_bytes` (413 if it grows past it), and a
`Content-Length` written as anything but decimal digits is a 400
rather than a framing guess.

client side, one call: `fetch.fetch("http://127.0.0.1:" .. port ..
"/status", {allow_private = true})` — `allow_private` opts out of the
SSRF guard that otherwise blocks loopback/private addresses; the
returned record carries `status`, `body`, and `headers`. to test the
pair end to end, spawn the built server binary from a test, block on
the `READY <port>` line (the readiness pattern above), then point the
real client at it — the sandbox grants loopback TCP.
