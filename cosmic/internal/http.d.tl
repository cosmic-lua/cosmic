-- HTTP/HTTPS at the Lua boundary, as the core (core/http.c, over curl,
-- c-ares and mbedtls) provides it: one blocking call to open a
-- request and read its response's headers, then a handle that reads
-- the body in chunks.

local record http
  record Handle
    userdata

    -- The response status code, once `open` has returned it.
    status: function(Handle): integer
    -- The effective URL: the one that was actually fetched, after
    -- every redirect `open`'s `follow` option let it take.
    url: function(Handle): string
    -- Response headers, lowercased names, last one wins.
    headers: function(Handle): {string:string}
    -- One chunk of the body, at most `max` bytes (a default when
    -- omitted). `nil, ""` at a clean end of body; `nil, err` on
    -- failure.
    read: function(Handle, max?: integer): string | nil, string
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
  end

  -- Blocks until the final response's headers have arrived (after
  -- every redirect `opts.follow` allows), or until the request fails
  -- outright (a bad URL, a refused connection, a TLS failure, ...).
  open: function(url: string, opts?: Options): Handle | nil, string
end

return http
