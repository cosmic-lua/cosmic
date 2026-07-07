# Recipes

end-to-end patterns composing several `cosmic.*` modules. each recipe is a
complete script shape — adapt names and drop pieces you don't need.

## CLI script skeleton

args → read file → decode → transform → encode → print, with an error exit
at every stage. this is the shape of most small cosmic tools.

```teal
local json = require("cosmic.json")
local cio = require("cosmic.io")

local function die(msg: string)
  io.stderr:write("error: " .. msg .. "\n")
  os.exit(1)
end

local function main(): integer
  local path = arg[1]
  if path == nil then
    die("usage: tool.tl <input.json>")
  end
  local data, read_err = cio.slurp(path as string)
  if not data then
    die("cannot read '" .. tostring(path) .. "': " .. read_err)
  end
  local decoded, decode_err = json.decode(data)
  if decode_err then
    die("invalid JSON: " .. decode_err)
  end
  local items = decoded as {any}

  -- transform: count the items
  local result = {count = #items}

  local encoded, encode_err = json.encode(result)
  if encode_err then
    die("encode failed: " .. encode_err)
  end
  print(encoded)
  return 0
end

os.exit(main())
```

key details: `arg[1]` is `string | nil` (guard before use), `json.decode`
returns `any` (cast before iterating), capture `encode`'s error return
instead of passing the call straight to `print`, and `main` returns
`integer` because `os.exit` rejects `number`.

## index files into sqlite (walk + hash + sqlite)

walk a tree, store path/size/digest with upsert semantics, query by
substring.

```teal
local fs = require("cosmic.fs")
local hash = require("cosmic.hash")
local cio = require("cosmic.io")
local sqlite = require("cosmic.sqlite")

local db = sqlite.open("index.db")
db:exec("CREATE TABLE IF NOT EXISTS files (" ..
  "path TEXT PRIMARY KEY, size INTEGER, digest TEXT)")

fs.walk("testdata", function(path: string, _name: string, st: any, _ctx: any)
    -- path is the FULL path; do not join it with the basename
    local stat = st as {mode: function(any): number, size: function(any): number}
    if stat:is_file() then
      local data = cio.slurp(path)
      if data then
        db:exec("INSERT INTO files (path, size, digest) VALUES (?, ?, ?) " ..
          "ON CONFLICT(path) DO UPDATE SET size = excluded.size, " ..
          "digest = excluded.digest", path, stat:size(), hash.sha256_hex(data))
      end
    end
  end)

-- substring query: LIKE uses % as the wildcard, not *
for row in db:query("SELECT * FROM files WHERE path LIKE ?", "%src%") do
  print(row.path, row.size, row.digest)
end
db:close()
```

for the precise `WalkStat` type, import it:
`local types = require("cosmic.fs_types")` and annotate the visitor's third
parameter as `types.WalkStat`.

## spawn cosmic as a child (self-reinvocation)

run another script in a child process and read its output through a pipe.

```teal
local child = require("cosmic.child")

local cosmic_bin = rawget(arg, -1) as string  -- NOT arg[0]; see gotchas #7
local h, err = child.spawn({cosmic_bin, "worker.tl"})
assert(h, err)
local _, out = h:read()
print(out)
h:wait()
```

for a server child, have it print a readiness line (e.g. `READY <port>`)
and block on `h.stdout:read(64)` instead of sleeping. see
`cosmic --examples child` for the pipe-capture variant.

## TCP echo pair (net)

see `cosmic --examples net` for a runnable single-process echo exchange:
`listen_tcp(0x7f000001, 0)` for an OS-assigned port, `connect_tcp`,
`accept`, then `send`/`recv`. `recv` returns `""` on peer close.
