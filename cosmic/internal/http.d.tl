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
    __close: function(Handle)

    -- The final response's status code.
    status: function(Handle): integer
    -- The effective URL: the one that was actually fetched, after
    -- every redirect `open`'s `follow` option let it take.
    url: function(Handle): string
    -- The final response's headers, by lowercased name; a repeated
    -- name's values joined with ", " (Set-Cookie's with "\n").
    headers: function(Handle): {string:string}
    -- One chunk of the body, at most `max_bytes` bytes (a default when
    -- omitted), and "". `nil, ""` at a clean end of body; `nil, err`
    -- on failure.
    read: function(Handle, max_bytes?: integer): string?, string
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
    headers?: {string:string}
    -- The request body, sent whole.
    body?: string
    -- Whether to follow redirects; true by default.
    follow?: boolean
    -- The most redirects followed, 10 by default.
    max_redirects?: integer
    -- The schemes a redirect may lead to, "http" and "https" by default.
    redirect_protocols?: {string}
    -- How long connecting may take, in milliseconds; 30000 by default.
    connect_timeout_ms?: integer
    -- How long the whole request may take, in milliseconds; no limit by default.
    timeout_ms?: integer
    -- The transfer rate, in bytes per second, under which a request
    -- is too slow; 1 by default and 0 turns the check off.
    low_speed_bytes?: integer
    -- How many seconds it may stay under `low_speed_bytes`; 60 by default.
    low_speed_seconds?: integer
    -- Whether curl logs the transfer to standard error.
    verbose?: boolean
    -- The path of a unix domain socket to connect to in place of the
    -- network: the URL still gives the request line and the Host header.
    -- curl uses no proxy then and sends every redirect it follows
    -- through the same socket. A path longer than the system's
    -- `sun_path` (104 bytes on macOS, 108 on Linux) fails the request.
    unix_socket?: string
    -- Tests only: canned replies, one per connection, in place of the
    -- network. Every entry must be a string.
    script?: {string}
    -- PEM certificates to verify the server, and an https proxy, against
    -- in place of the trust store. curl keys connection reuse and TLS
    -- session resumption on them, so no connection verified otherwise is
    -- reused. An empty one fails the request.
    ca_blob?: string
    -- CURLOPT_PINNEDPUBLICKEY: one or more `sha256//<base64>` joined by
    -- `;`, one of which the server's public key must hash to. An empty
    -- one, or one holding NUL, fails the request.
    pin?: string
  end

  -- The trust store's certificates, as DER.
  record Roots
    -- The binary's own roots, each as the TLS stack reads it.
    carried: {string}
    -- Those $SSL_CERT_FILE added.
    extra: {string}
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
  -- or one holding ':', a URL holding NUL, a `unix_socket` that is empty
  -- or holds NUL.
  --
  -- A request curl itself failed (not one refused up front, as above)
  -- also returns a third value naming the failure: "couldnt_connect"
  -- when it could not connect, "failed" for any other.
  open: function(url: string, opts?: Options): Handle?, string, string?

  -- The trust store `open` verifies a server against when given no
  -- `ca_blob`, made the first time it is wanted, and "", or `nil, err`
  -- when it cannot be made, as `open` would fail.
  roots: function(): Roots?, string

  -- The DER of the SubjectPublicKeyInfo of `cert`, one certificate as
  -- PEM or DER, and "", or `nil, err` when the TLS stack cannot read it
  -- as exactly one. Raises when there was no memory to read it.
  public_key: function(cert: string): string?, string

  -- True and "" when the TLS stack reads `der` as one X.509
  -- certificate, as it reads each CA root the binary carries; false
  -- and its reason when it does not. Raises when there was no memory
  -- to read it.
  check_certificate: function(der: string): boolean, string
end

return http
