# fetch

 Structured HTTP fetch with optional retry.
 Wraps cosmo.Fetch with structured results to prevent accidentally discarding errors.

## Types

### Result

 Result from a fetch operation.

```teal
local record Result
  ok: boolean
  status: number
  headers: {string: string}
  body: string
  error: string
end
```

### Opts

```teal
local record Opts
  headers: {string: string}
  proxy: string
  maxresponse: number
  max_attempts: number
  max_delay: number
  should_retry: function(Result): boolean
end
```

### Reader

 Streaming reader for incremental body access.
 Supports Lua 5.4's to-be-closed via __close metamethod.

```teal
local record Reader
  read: function(self: Reader): string, string
  close: function(self: Reader): boolean
  closed: function(self: Reader): boolean
  lines: function(self: Reader): function(): string
end
```

### StreamResult

 Result from a streaming fetch operation.

```teal
local record StreamResult
  ok: boolean
  status: number
  headers: {string: string}
  reader: Reader
  error: string
end
```

### fetch

```teal
local record fetch
  Fetch: function(url: string, opts?: Opts): Result
  stream: function(url: string, opts?: Opts): StreamResult
  unix_proxy: function(path: string): string, string
  Opts: Opts
  Result: Result
  Reader: Reader
  StreamResult: StreamResult
end
```

## Functions

### reader:read

```teal
function reader:read(): string, string
```

 Read the next chunk from the stream.

**Returns:**

- string - chunk or nil on EOF
- string - error message on failure

### reader:close

```teal
function reader:close(): boolean
```

 Close the reader. Idempotent.

**Returns:**

- boolean - always true

### reader:closed

```teal
function reader:closed(): boolean
```

 Returns true if the reader has been closed.

**Returns:**

- boolean - closed state

## Examples

### get

 Example_get demonstrates a simple HTTP GET request

```teal
  local fetch = require("cosmic.fetch")
  local result = fetch.Fetch("https://httpbin.org/get")
  print("status:", result.status)
  print("ok:", result.ok)
```

Output:
```
status:	200
  -- ok:	true

```

### get json

 Example_get_json demonstrates fetching and parsing JSON

```teal
  local fetch = require("cosmic.fetch")
  local json = require("cosmic.json")
  local result = fetch.Fetch("https://httpbin.org/json")
  local data = json.decode(result.body) as {string: {string: string}}
  print("title:", data.slideshow.title)
```

Output:
```
title:	Sample Slide Show

```
