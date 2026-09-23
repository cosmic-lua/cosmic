-- HTTP/HTTPS at the Lua boundary, as the core (core/http.c, over curl,
-- c-ares and mbedtls) provides it: one blocking call to open a
-- request and read its response's headers, then a handle that reads
-- the body in chunks.

local record http
  record Handle
    userdata

    -- The final response's status code.
    status: function(Handle): integer
    -- The effective URL: the one that was actually fetched, after
    -- every redirect `open`'s `follow` option let it take.
    url: function(Handle): string
    -- The final response's headers, by lowercased name; a repeated
    -- name's values joined with ", " (Set-Cookie's with "\n").
    headers: function(Handle): {string:string}
    -- One chunk of the body, at most `max` bytes (a default when
    -- omitted). `nil, ""` at a clean end of body; `nil, err` on
    -- failure.
    read: function(Handle, max?: integer): string | nil, string
    -- What curl has written to a scripted transfer's connections so
    -- far; "" for one over the network.
    sent: function(Handle): string
    close: function(Handle): boolean
  end

  record Options
    method: string
    headers: {string:string}
    body: string
    follow: boolean
    max_redirects: integer
    connect_timeout_ms: integer
    timeout_ms: integer
    low_speed_bytes: integer
    low_speed_seconds: integer
    verbose: boolean
    -- Tests only: canned replies, one per connection, in place of the
    -- network.
    script: {string}
  end

  -- Blocks until the final response's headers have arrived (after
  -- every redirect `opts.follow` allows), or until the request fails
  -- outright (a bad URL, a refused connection, a TLS failure, ...).
  -- A malformed option (a non-string method, body or header) throws.
  open: function(url: string, opts?: Options): Handle | nil, string
end

return http
