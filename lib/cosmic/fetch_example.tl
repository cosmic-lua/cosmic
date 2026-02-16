--- Examples for the cosmic.fetch module.
--- Demonstrates HTTP requests and retry configuration.

-- Example_get demonstrates a simple HTTP GET request
local function Example_get()
  local fetch = require("cosmic.fetch")
  local result = fetch.Fetch("https://httpbin.org/get")
  print("status:", result.status)
  print("ok:", result.ok)
  -- Output:
  -- status:	200
  -- ok:	true
end

-- Example_get_json demonstrates fetching and parsing JSON
local function Example_get_json()
  local fetch = require("cosmic.fetch")
  local json = require("cosmic.json")
  local result = fetch.Fetch("https://httpbin.org/json")
  local data = json.decode(result.body) as {string: {string: string}}
  print("title:", data.slideshow.title)
  -- Output:
  -- title:	Sample Slide Show
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
      return r.status >= 500
    end,
  })
  print("ok:", result.ok)
  -- Output:
  -- ok:	true
end

-- Example_retry_on_status demonstrates retrying on specific HTTP status
-- codes like 429 (Too Many Requests) and 503 (Service Unavailable).
local function Example_retry_on_status()
  local fetch = require("cosmic.fetch")

  local retryable: {number: boolean} = {
    [429] = true,  -- Too Many Requests
    [503] = true,  -- Service Unavailable
    [502] = true,  -- Bad Gateway
  }

  local result = fetch.Fetch("https://httpbin.org/get", {
    max_attempts = 5,
    max_delay = 30,
    should_retry = function(r: fetch.Result): boolean
      return retryable[r.status] or false
    end,
  })
  print("ok:", result.ok)
  -- Output:
  -- ok:	true
end

return {}
