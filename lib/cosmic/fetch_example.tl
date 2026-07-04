--- Examples for the cosmic.fetch module.
--- Demonstrates HTTP requests and retry configuration.
---
--- These examples call a live HTTP endpoint (httpbin.org), so their exact
--- response depends on network conditions. They are deliberately written
--- without `-- Output:` assertions so CI does not flake when the endpoint is
--- slow, unreachable, or answers 5xx under load. The example runner still
--- compiles and executes each body, verifying the API is used correctly, and
--- every body guards against request failure so it never throws.

-- Example_get demonstrates a simple HTTP GET request.
local function Example_get()
  local fetch = require("cosmic.fetch")
  local result = fetch.Fetch("https://httpbin.org/get")
  -- result.ok reports whether the HTTP request completed; result.status holds
  -- the response code on success, and result.error the reason on failure.
  if result.ok then
    print("status:", result.status)
  else
    print("request failed:", result.error)
  end
end

-- Example_get_json demonstrates fetching and parsing a JSON response.
local function Example_get_json()
  local fetch = require("cosmic.fetch")
  local json = require("cosmic.json")
  local result = fetch.Fetch("https://httpbin.org/json")
  -- Guard on ok/body before decoding: a failed request has a nil body.
  if result.ok and result.body then
    local data = json.decode(result.body) as {string: {string: string}}
    if data and data.slideshow then
      print("title:", data.slideshow.title)
    end
  end
end

-- Example_retry demonstrates retry with a should_retry callback.
-- The retry loop in Fetch only retries when result.ok is true (the HTTP
-- request succeeded) and should_retry returns true. Connection failures
-- (result.ok == false) are returned immediately without retry.
-- Backoff is exponential: 2^attempt seconds, capped by max_delay.
local function Example_retry()
  local fetch = require("cosmic.fetch")

  -- Retry up to 3 times on 5xx server errors.
  -- Attempt 1: immediate. Attempt 2: after 4s. Attempt 3: after 8s.
  local result = fetch.Fetch("https://httpbin.org/get", {
      max_attempts = 3,
      max_delay = 10,
      should_retry = function(r: fetch.Result): boolean
        return r.ok and r.status >= 500
      end,
    })
  print("ok:", result.ok)
end

-- Example_retry_on_status demonstrates retrying on specific HTTP status
-- codes like 429 (Too Many Requests) and 503 (Service Unavailable).
local function Example_retry_on_status()
  local fetch = require("cosmic.fetch")

  local retryable: {number: boolean} = {
    [429] = true, -- Too Many Requests
    [503] = true, -- Service Unavailable
    [502] = true, -- Bad Gateway
  }

  local result = fetch.Fetch("https://httpbin.org/get", {
      max_attempts = 5,
      max_delay = 30,
      should_retry = function(r: fetch.Result): boolean
        return r.ok and (retryable[r.status] or false)
      end,
    })
  print("ok:", result.ok)
end

return {}
