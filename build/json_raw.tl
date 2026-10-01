--- The core's JSON encoder with every option core/json.c takes, for the
--- tests of that C. [`cosmic.json`] hands the encoder `pretty` and
--- `max_depth` alone; the others (`sorted`, `indent`, `nan_as_null`,
--- `sparse_as_null`, `ascii`) stay in the core, and nothing but a test
--- sets them, through the raw table the store hands [`cosmic.json`]'s
--- loader.

local type _json = require("cosmic.json")
local type raw_json = require("cosmic.internal.json")

local type Searcher = function(string): any, any

local record json_raw
  --- What the core's `encode` takes after the value. Every field is
  --- optional, and the defaults are the core's.
  record Options
    --- Lay the text out over lines (default false).
    pretty: boolean
    --- One level's indentation when `pretty`: spaces and tabs only
    --- (default two spaces).
    indent: string
    --- List an object's keys in byte order (default true).
    sorted: boolean
    --- How many arrays and objects may nest, 1 to the core's limit.
    max_depth: integer
    --- Write NaN and the infinities as `null` rather than failing.
    nan_as_null: boolean
    --- Write an array's holes as `null` rather than failing.
    sparse_as_null: boolean
    --- Write every character past ASCII as a `\u` escape.
    ascii: boolean
  end
end

--- The raw table the store's searcher hands [`cosmic.json`]'s loader.
local function raw_table(): raw_json
  for _, searcher in ipairs(package.searchers as {Searcher}) do -- cast: searchers' loaders take an extra
    local loader, extra = searcher("cosmic.json")
    if type(loader) == "function" and type(extra) == "table" then
      return extra as raw_json -- cast: the table cosmic/internal/json.d.tl declares
    end
  end
  error("cosmic.json is handed no raw table")
end

local raw = raw_table()

--- `value` as the core's `encode` writes it under `opts`: the text and
--- "", or nil and why, as [`Json.encode`] answers. Raises where the core
--- does, for an `indent` that is not blank or a `max_depth` out of range.
function json_raw.encode(value: any, opts?: json_raw.Options): string | nil, string
  local o: json_raw.Options = opts or {}
  return raw.encode(value, o.pretty, o.indent, o.sorted, o.max_depth,
    o.nan_as_null, o.sparse_as_null, o.ascii)
end

return json_raw
