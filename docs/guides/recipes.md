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
      local path, st = e.path, e.stat
      -- e.path is the FULL path; do not join it with e.name
      if st:is_file() then
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
`listen_tcp("127.0.0.1", 0)` for an OS-assigned port, `connect_tcp`,
`accept`, then `send`/`recv`. `recv` returns bare nil on peer close
(end of stream); `""` only ever means a zero-byte datagram.

## HTTP without a framework (net + fetch)

there is no HTTP server module, on purpose: at this scale HTTP/1.1 is a
request line, a header drain, and a `Content-Length` you compute — serve
it by hand over a `net` socket, and let `cosmic.fetch` (a full HTTP
client: retries, redirects, streaming) be the client side. this is the
sanctioned shape; `cosmic --examples fetch` runs exactly this pair.

```teal
local check = require("cosmic.check")
local net = require("cosmic.net")

-- serve one request: read the request line, drain headers, answer
-- with a computed Content-Length. loop it for a real server.
local function serve_one(srv: net.Socket): boolean, string
  local accepted, accept_err = srv:accept()
  if not accepted then
    return false, accept_err
  end
  local conn = accepted as net.Socket -- cast: record union after guard
  local request_line = conn:readline()
  local path = "/"
  if request_line is string then
    path = request_line:match("^%u+%s+(%S+)") or "/"
  end
  while true do
    local header = conn:readline()
    if not header or header == "" then break end -- blank line ends headers
  end
  local body = "hello from " .. path .. "\n"
  local ok, send_err = conn:sendall("HTTP/1.1 200 OK\r\n"
    .. "Content-Length: " .. #body .. "\r\n"
    .. "Connection: close\r\n\r\n" .. body)
  local _ok, _err = conn:close() -- the send result is the verdict, not the close
  return ok, send_err
end

local srv = check.must(net.listen_tcp("127.0.0.1", 0))
print("READY " .. check.must(srv:getsockname()).port) -- a test blocks on this line
assert(serve_one(srv))
assert(srv:close())
```

client side, one call: `fetch.fetch("http://127.0.0.1:" .. port ..
"/status", {allow_private = true})` — `allow_private` opts out of the
SSRF guard that otherwise blocks loopback/private addresses; the
returned record carries `status`, `body`, and `headers`. to test the
pair end to end, spawn the built server binary from a test, block on
the `READY <port>` line (the readiness pattern above), then point the
real client at it — the sandbox grants loopback TCP.

note `--docs http` will not find this page's shape: the matches it
returns (proxy internals, `time.format_http`) are not an HTTP server.
this recipe is the answer.
