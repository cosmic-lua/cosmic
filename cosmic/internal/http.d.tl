-- HTTP/HTTPS at the Lua boundary, as the core (core/http.c, over curl,
-- c-ares and mbedtls) provides it: one blocking call to open a
-- request and read its response's headers, then a handle that reads
-- the body in chunks. A fallible function returns `value, ""` on
-- success and `nil, err` on failure.

local record http
  -- Closed by `close`, by `__close` (a `<close>` variable) or by the
  -- collector; any method but `close` on a closed handle raises.
  record Handle
    userdata
    metamethod __close: function(Handle)

    -- The final response's status code.
    status: function(Handle): integer
    -- The effective URL: the one that was actually fetched, after
    -- every redirect `open`'s `follow` option let it take.
    url: function(Handle): string
    -- The final response's headers, by lowercased name; a repeated
    -- name's values joined with ", " (Set-Cookie's with "\n").
    headers: function(Handle): {string:string}
    -- One chunk of the body, at most `max` bytes (a default when
    -- omitted), and "". `nil, ""` at a clean end of body; `nil, err`
    -- on failure.
    read: function(Handle, max?: integer): string | nil, string
    -- What curl has written to a scripted transfer's connections so
    -- far; "" for one over the network. Raises if recording it ran
    -- out of memory.
    sent: function(Handle): string
    close: function(Handle)
  end

  -- An interface, so [`cosmic.http`]'s own Options, which adds what only
  -- Teal reads, is one of these.
  interface Options
    -- The HTTP method, case-sensitive; GET, or POST when there is a `body`.
    method: string
    -- Request headers, name to value.
    headers: {string:string}
    -- The request body, sent whole.
    body: string
    -- Whether to follow redirects; true by default.
    follow: boolean
    -- The most redirects followed, 10 by default.
    max_redirects: integer
    -- The schemes a redirect may lead to, "http" and "https" by default.
    redirect_protocols: {string}
    -- How long connecting may take, in milliseconds; 30000 by default.
    connect_timeout_ms: integer
    -- How long the whole request may take, in milliseconds; no limit by default.
    timeout_ms: integer
    -- The transfer rate, in bytes per second, under which a request
    -- is too slow; 1 by default and 0 turns the check off.
    low_speed_bytes: integer
    -- How many seconds it may stay under `low_speed_bytes`; 60 by default.
    low_speed_seconds: integer
    -- Whether curl logs the transfer to standard error.
    verbose: boolean
    -- Tests only: canned replies, one per connection, in place of the
    -- network. Every entry must be a string.
    script: {string}
  end

  -- Blocks until the final response's headers have arrived (after
  -- every redirect `opts.follow` allows) and returns the handle and
  -- "", or `nil, err` once the request fails outright (a bad URL, a
  -- refused connection, a TLS failure, an option curl refuses, ...).
  -- An option of the wrong shape raises, naming it: a wrong Lua type
  -- (no numeric strings for the integers), a non-integer, or an
  -- integer out of range (below 0, `max_redirects` above 32767,
  -- `low_speed_seconds` above 65535). Data that cannot be sent as
  -- given returns `nil, err`: a method that is no HTTP token, a
  -- header name or value holding CR, LF or NUL, an empty header name
  -- or one holding ':', a URL holding NUL.
  open: function(url: string, opts?: Options): Handle | nil, string

  -- True and "" when the TLS stack reads `der` as one X.509
  -- certificate, as it reads each CA root the binary carries; false
  -- and its reason when it does not. Raises when there was no memory
  -- to read it.
  check_certificate: function(der: string): boolean, string
end

return http
