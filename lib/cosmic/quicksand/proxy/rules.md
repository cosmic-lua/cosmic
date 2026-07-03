# rules

 Allowlist rule parsing, validation, and matching for the
 cosmic.quicksand.proxy egress proxy.

 An allowlist maps host-spec strings to rule values:

   host              any port on exact host
   host:port         exact host + exact port
   host:*            any port on exact host (explicit)
   *.suffix          any host ending in ".suffix", any port
   *.suffix:port     any host ending in ".suffix", exact port

 Rule values: an empty table (or true) means "allow, no auth
 injection". A table with a `type` field of "bearer", "basic", or
 "header" injects the corresponding header on plain-HTTP requests
 (CONNECT tunnels are opaque; the rule still gates the allowlist).
 validate() rejects unknown types and missing fields loudly — a
 typo'd rule silently degrading to pass-through would strip auth
 from an otherwise-authenticated egress path.

## Types

### SuffixEntry

 One wildcard ("*.suffix") allowlist entry. `port` nil = any port.

```teal
local record SuffixEntry
  suffix: string
  port: integer
  rule: any
end
```

### Index

 Fast lookup structure built from an allowlist by index().
 exact[host][port] and exact[host]["*"] hold exact-host rules;
 suffix is walked in insertion order for "*.suffix" patterns.

```teal
local record Index
  exact: {string: {any: any}}
  suffix: {SuffixEntry}
end
```

### RulesModule

```teal
local record RulesModule
  parse_rule: function(key: string): string, integer
  validate_rule: function(key: string, rule: any): string
  validate: function(allowed_hosts: {string: any}): boolean, string
  index: function(allowed_hosts: {string: any}): Index
  match: function(idx: Index, host: string, port: integer): any
  auth_header: function(rule: any): string, string
end
```

## Functions

### parse_rule

```teal
function parse_rule(key: string): string, integer
```

 Split a host-spec into ("host", port or nil). A missing port,
 ":*", or ":" all mean "any port". Hosts compare case-insensitively.

### validate_rule

```teal
function validate_rule(key: string, rule: any): string
```

 Validate a single allowlist rule. Returns nil on success, or a
 human-readable error string. Bare pass-through values (nil, true,
 {}) are accepted as "allow, no auth injection"; a table with a
 `type` field must use a known type and carry the fields that
 auth_header() would dereference. Unknown non-type fields are
 ignored (forward compatibility).

### validate

```teal
function validate(allowed_hosts: {string: any}): boolean, string
```

 Validate every rule in an allowlist. Returns true, or false plus
 the first error found.

### index

```teal
function index(allowed_hosts: {string: any}): Index
```

 Build a lookup Index from an allowlist table. Wildcard entries
 are stored with a leading "." and matched at the tail of the
 candidate host, in insertion order.

### match

```teal
function match(idx: Index, host: string, port: integer): any
```

 Look up a (host, port) pair. Returns the rule value on a hit, or
 nil. Exact-host matches win over suffix patterns; suffix patterns
 return the first hit in insertion order.

### auth_header

```teal
function auth_header(rule: any): string, string
```

 Build the auth header a rule injects on plain-HTTP requests.
 Returns (name, value), or nil for pass-through rules.
