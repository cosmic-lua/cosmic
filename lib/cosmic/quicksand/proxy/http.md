# http

 HTTP/1.1 wire helpers for the cosmic.quicksand.proxy egress proxy:
 request-line / header / target parsing, bounded socket reads,
 short-write-safe sends, request rewriting for upstream forwarding,
 and the bidirectional CONNECT byte pump.

 Parsing functions are pure; the I/O helpers operate on raw socket
 fds via cosmo.unix and return cosmic's value,string error shape.

## Types

### ForwardSpec

 Everything needed to rewrite a client request for the upstream:
 request line pieces, parsed headers, optional body, the Host
 header value, and an optional auth header to inject.

```teal
local record ForwardSpec
  method: string
  path: string
  headers: {Header}
  body: string
  host_hdr: string
  inject_name: string
  inject_value: string
end
```

### HttpModule

```teal
local record HttpModule
  DENY: string
  BAD_REQUEST: string
  LENGTH_REQUIRED: string
  UPSTREAM_FAIL: string
  read_headers: function(fd: integer, max: integer): string | nil, string
  send_all: function(fd: integer, data: string): boolean, string
  read_body: function(fd: integer, n: integer, prefix: string): string | nil, string
  parse_request_line: function(line: string): string | nil, string, string
  parse_connect_target: function(t: string): string | nil, integer
  parse_absolute_uri: function(t: string): string | nil, string, integer, string
  parse_headers: function(block: string): {Header}
  header_get: function(headers: {Header}, lower_name: string): string | nil
  content_length: function(headers: {Header}): integer
  rebuild_request: function(spec: ForwardSpec): string
  pump: function(a: integer, b: integer)
end
```

## Functions

### read_headers

```teal
function read_headers(fd: integer, max: integer): string | nil, string
```

 Read from `fd` until "\r\n\r\n" or EOF. Returns (header_block,
 leftover_after_block). Bounds the read to `max` bytes (default
 65536) to avoid memory blowups from junk input.

### send_all

```teal
function send_all(fd: integer, data: string): boolean, string
```

 Send all of `data` on `fd`, resuming short writes via the send()
 offset parameter (no tail-substring reallocation).

### read_body

```teal
function read_body(fd: integer, n: integer, prefix: string):
```

 Read exactly `n` bytes from `fd`, given an optional already-
 buffered prefix. Returns (body, leftover_beyond_n).

### parse_request_line

```teal
function parse_request_line(line: string): string | nil, string, string
```

 Parse an HTTP request line "METHOD TARGET HTTP/x.y\r\n". Returns
 (method, target, version) or nil.

### parse_connect_target

```teal
function parse_connect_target(t: string): string | nil, integer
```

 Parse a CONNECT target "host:port". Returns (host, port) or nil.

### parse_absolute_uri

```teal
function parse_absolute_uri(t: string): string | nil, string, integer, string
```

 Parse an absolute URI "http://host[:port]/path" (proxies receive
 absolute-form per RFC 7230 5.3.2). Returns (scheme, host, port,
 path) with the scheme's default port and "/" filled in, or nil.

### parse_headers

```teal
function parse_headers(block: string): {Header}
```

 Parse a header block (everything after the request line, up to the
 blank \r\n) into a list of {orig_name, lower_name, value} triples.

### header_get

```teal
function header_get(headers: {Header}, lower_name: string): string | nil
```

 First header value for `lower_name` (case-insensitive), or nil.

### content_length

```teal
function content_length(headers: {Header}): integer
```

 Content-Length from a parsed header list; 0 if absent.

### rebuild_request

```teal
function rebuild_request(spec: ForwardSpec): string
```

 Construct the forwarded HTTP request: method + origin-form target
 + HTTP/1.1, Host rewritten to spec.host_hdr, hop-by-hop headers
 stripped, our injected auth header replacing any client-supplied
 one of the same name, and Connection: close.

### pump

```teal
function pump(a: integer, b: integer)
```

 Bidirectional byte pump between two TCP fds. Returns when both
 sides hit EOF or one side errors. Single-process: multiplexes with
 unix.poll, and issues shutdown(SHUT_WR) toward the peer on each
 half-close so it sees clean EOF.
