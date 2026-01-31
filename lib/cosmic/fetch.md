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
  headers: {string:string}
  body: string
  error: string
end
```

### Opts

```teal
local record Opts
  headers: {string:string}
  maxresponse: number
  max_attempts: number
  max_delay: number
  should_retry: function(Result): boolean
end
```

### fetch

```teal
local record fetch
  Fetch: function(url: string, opts?: Opts): Result
  Opts: Opts
  Result: Result
end
```

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
  local data = json.decode(result.body) as {string:{string:string}}
  print("title:", data.slideshow.title)
```

Output:
```
title:	Sample Slide Show

```
