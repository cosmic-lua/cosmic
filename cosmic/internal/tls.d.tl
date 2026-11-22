-- TLS at the Lua boundary, as the core provides it through mbedtls
-- (core/tls.c): a server's configuration of certificate and key pairs,
-- a client's of the roots it verifies a server against, and a session
-- of either over a socket.
--- @kind binding

local record tls
  -- A configuration, a server's or a client's, TLS 1.2 and 1.3. The
  -- collector frees it, once no session of it is left.
  record Config
    userdata
  end

  -- What the peer's certificate says of itself.
  record Peer
    -- The certificate, DER.
    der: string
    -- Its SubjectPublicKeyInfo, DER.
    public_key: string
    -- Its subject and issuer, as mbedtls words a name
    -- ("CN=example.com, O=Example"); "" where it cannot.
    subject: string
    issuer: string
    -- Its serial number, as colon-separated hex bytes.
    serial: string
    -- Its Subject Alternative Names: DNS names, IP addresses as text,
    -- URIs, and email addresses.
    names: {string}
    addresses: {string}
    uris: {string}
    emails: {string}
    -- When it starts and stops being valid, in seconds since the epoch.
    not_before: integer
    not_after: integer
    -- Whether its chain was verified, and passed.
    verified: boolean
  end

  -- What a session's handshake settled.
  record Info
    -- "TLSv1.2" or "TLSv1.3".
    version: string
    -- The protocol ALPN chose; nil where the client offered none the
    -- configuration has.
    alpn?: string
    -- The name the client asked for (SNI); nil where it named none, or
    -- one with a byte no host name has. On a client's session, the name
    -- it verified the server against.
    server_name?: string
    -- The peer's certificate; nil where it presented none.
    peer?: Peer
  end

  -- A session over a socket it does not own. A call that does
  -- not finish answers nil (or false), why, and what stopped it: READ
  -- or WRITE, why "", where it waits for the socket to be ready so,
  -- before the same call is made again; ENDED, why "", where the peer
  -- ended the session; FAILED and why otherwise. Every method but
  -- `free` raises once the session is freed.
  record Session
    userdata

    -- True once the handshake is done.
    handshake: function(Session): boolean, string, integer
    -- At most max bytes, and at most 16 KiB, of what the peer sent.
    -- Raises on a max below 1.
    read: function(Session, max: integer): string?, string, integer
    -- How many bytes of data from `from` were taken; called again with
    -- the same bytes after a wait. Raises on a `from` past the end.
    write: function(Session, data: string, from: integer): integer?, string, integer
    -- True once the alert that ends the session is sent.
    close_notify: function(Session): boolean, string, integer
    -- What the handshake settled; meaningful only once it is done.
    info: function(Session): Info
    -- Frees the session, once; its socket is the caller's.
    free: function(Session)
    __close: function(Session, any)
  end

  -- A pair, as `config` reads it.
  record Pair
    -- The certificate chain, PEM, the leaf first.
    cert: string
    -- The leaf's private key, PEM.
    key: string
  end

  -- What `leaf` reads of a certificate.
  record Leaf
    -- The DNS names of its Subject Alternative Names.
    names: {string}
    -- When it starts and stops being valid, in seconds since the epoch.
    not_before: integer
    not_after: integer
  end

  -- What stopped a session's call that did not finish.
  FAILED: integer
  READ: integer
  WRITE: integer
  ENDED: integer

  -- A configuration of 1 to 64 pairs: a client is offered those whose
  -- leaves name the host it asks for (SNI), or every pair where it asks
  -- for none or one no leaf names, and served the first offered that
  -- signs by an algorithm it lists. It offers the ALPN
  -- protocols of alpn, at most 8, each 1 to 255 bytes. Nil and why
  -- where a pair cannot be read or its key is not its certificate's.
  -- With clients, PEM roots, it asks each client for a certificate and
  -- verifies one against them: where required, a client that presents
  -- none, or one that does not verify, is refused; otherwise the
  -- session goes on, its peer nil or unverified. Nil and why where
  -- clients holds no certificate it reads.
  -- Raises on arguments of the wrong shape.
  config: function(pairs: {Pair}, alpn?: {string}, clients?: string, required?: boolean): Config?, string
  -- A client configuration that verifies a server's chain against the
  -- PEM certificates of roots, or verifies nothing where roots is
  -- false; offers the ALPN protocols of alpn, as `config` does; and
  -- presents identity to a server that asks for a certificate. Nil and
  -- why where roots holds no certificate it reads, or identity cannot
  -- be read or its key is not its certificate's.
  client: function(roots: string | boolean, alpn?: {string}, identity?: Pair): Config?, string
  -- A session of config over the socket fd: a client's asks for
  -- server_name and verifies the server's certificate names it, where
  -- config verifies (an IP address is matched against the certificate's
  -- IP addresses, and sent as no name). Raises on a client's verifying
  -- session with no server_name, and on one for a server's config.
  session: function(config: Config, fd: integer, server_name?: string): Session?, string
  -- What the first certificate of a PEM chain says of itself.
  leaf: function(pem: string): Leaf?, string
end

return tls
