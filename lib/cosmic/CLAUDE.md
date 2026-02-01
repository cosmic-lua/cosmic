# CLAUDE.md - cosmic library modules

Guidelines for function signatures and error handling in `lib/cosmic/` modules.

## Error Handling Patterns

### Primary Pattern: Value + Error String

Most functions should return `value, string` where the second return is an error message on failure:

```teal
--- Good: Returns value on success, nil + error on failure
local function decode(str: string): any, string
  local result, err = cosmo.DecodeJson(str)
  return result, err as string
end

--- Good: Returns boolean success + error on failure
function db:exec(sql: string): boolean, string
  local rc = raw_db:exec(sql)
  if rc ~= sqlite3.OK then
    return false, raw_db:errmsg()
  end
  return true
end

--- Good: Prepare can fail, returns nil + error
function db:prepare(sql: string): Statement, string
  local raw_stmt, errcode, errmsg = raw_db:prepare(sql)
  if not raw_stmt then
    return nil, errmsg or ("error code " .. tostring(errcode))
  end
  return make_statement(raw_stmt, raw_db)
end
```

Callers handle errors naturally:

```teal
local data, err = json.decode(input)
if not data then
  print("parse failed: " .. err)
  return
end
```

### Result Records: For Complex Operations

Use a Result record when operations have multiple error states or rich success metadata:

```teal
--- Good: Result record for HTTP with status, headers, body
local record Result
  ok: boolean
  status: number
  headers: {string:string}
  body: string
  error: string
end

local function Fetch(url: string, opts?: Opts): Result
  local status, headers_or_err, body = cosmo.Fetch(url, opts)

  if not status then
    return {ok = false, error = tostring(headers_or_err or "unknown error")}
  end

  return {
    ok = true,
    status = status,
    headers = headers_or_err as {string:string},
    body = body,
  }
end
```

Result records are appropriate when:
- Success returns multiple related values (status + headers + body)
- Multiple distinct error conditions need different handling
- The API wraps an unreliable external service

### Patterns to Avoid

**Never throw exceptions from library code:**

```teal
--- Bad: Throws instead of returning error
function db:query(sql: string): function(): {string:any}
  local stmt, err = self:prepare(sql)
  if not stmt then
    error("query failed: " .. err)  -- Don't do this
  end
  ...
end

--- Good: Return error through the iterator or use prepare+rows pattern
local stmt, err = db:prepare(sql)
if not stmt then
  print("query failed: " .. err)
  return
end
for row in stmt:rows() do
  ...
end
```

**Never silently discard errors:**

```teal
--- Bad: Silent failure, caller can't tell what went wrong
local function walk(dir: string): Context
  local handle = io.open(dir)
  if not handle then
    return {}  -- Silently returns empty result
  end
  ...
end

--- Good: Return error as second value
local function walk(dir: string): Context, string
  local handle, err = io.open(dir)
  if not handle then
    return {}, "cannot open directory: " .. (err or dir)
  end
  ...
end
```

**Never mix patterns in the same module:**

```teal
--- Bad: prepare() returns errors, query() throws, exec() returns boolean
function db:prepare(sql: string): Statement, string     -- returns error
function db:query(sql: string): function(): Row         -- throws error
function db:exec(sql: string): boolean, string          -- returns error

--- Good: All methods use the same pattern
function db:prepare(sql: string): Statement, string
function db:exec(sql: string): boolean, string
-- For query, use prepare() + rows() so errors surface at prepare time
```

## Type Signatures

Document error returns in the type signature:

```teal
--- Good: Type shows this can fail
local record Module
  decode: function(str: string): any, string
  encode: function(value: any): string, string
end

--- Good: Method types show error possibility
local record Database
  prepare: function(self: Database, sql: string): Statement, string
  exec: function(self: Database, sql: string): boolean, string
end
```

## Doc Comments

Use `---` comments with `@param` and `@return` tags:

```teal
--- Decode a JSON string into a Lua value.
--- @param str string The JSON string to decode
--- @return any The decoded Lua value
--- @return string? Error message if decoding failed
local function decode(str: string): any, string
```

### Infallible Functions

Some functions cannot fail by design and return only a value (no error):

```teal
--- Good: Encoding always succeeds, no error needed
local function encode_hex(data: string): string
  return cosmo.EncodeHex(data)
end

--- Good: Compression always succeeds
local function compress(data: string): string
  return cosmo.Compress(data)
end
```

Infallible functions include:
- **Encoding**: `encode_hex`, `encode_base64`, `encode_base32`, `encode_lua` (input is always valid bytes)
- **Compression**: `compress`, `deflate` (any byte sequence can be compressed)
- **Escaping**: `escape_*` functions (always produce valid output)

### Lenient Parsing Functions

Some parsing functions are intentionally permissive, accepting malformed input
rather than returning errors:

```teal
--- Lenient: Returns parsed URL, treating unrecognized input as path
local function parse_url(url: string): Url
  -- "not a url" -> {path = "not a url"}
  -- Valid design choice for user input handling
end

--- Lenient: Decodes what it can, ignores invalid characters
local function decode_base64(str: string): string
  -- May produce garbage on invalid input
  -- Use with trusted input or validate externally
end
```

When wrapping lenient functions, document the behavior clearly:
- Note that invalid input may produce garbage rather than errors
- Recommend external validation for untrusted input
- Consider adding a validating alternative (e.g., `try_decode_base64`)

## Summary

| Situation | Pattern |
|-----------|---------|
| Simple operations | `value, string` (nil + error on failure) |
| Boolean success/fail | `boolean, string` (false + error on failure) |
| Complex results | Result record with `ok: boolean` and `error: string` |
| Resource creation | `Handle, string` with `__close` metamethod |
| Iteration | Return iterator from successful prepare; errors at prepare time |
| Infallible operations | Just `value` (no error return needed) |
| Lenient parsing | Just `value` (document garbage-in/garbage-out behavior) |

Consistency within a module matters more than which specific pattern you choose. Pick one and use it throughout.
