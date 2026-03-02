-- type declarations for cosmo (cosmopolitan lua)

local record cosmo
  -- http
  Fetch: function(url: string, opts?: {string: any}): number, {string: string}, string

  -- streaming http reader
  record StreamReader
    read: function(self: StreamReader): string, string
    close: function(self: StreamReader): boolean
  end

  -- streaming http
  FetchStream: function(url: string, opts?: {string: any}): number, {string: string}, StreamReader

  -- file i/o
  Barf: function(path: string, data: string, mode?: number): boolean
  Slurp: function(path: string): string

  -- hashing
  Sha256: function(data: string): string

  -- encoding
  EncodeHex: function(data: string): string
  EncodeJson: function(value: any): string, string
  DecodeJson: function(json: string): any, string
  EncodeLua: function(value: any, opts?: {string: any}): string
  EncodeBase64: function(data: string): string
  DecodeBase64: function(str: string): string
  EncodeBase32: function(data: string): string
  DecodeBase32: function(str: string): string
  EncodeLatin1: function(str: string): string
  DecodeLatin1: function(data: string): string

  -- compression
  Compress: function(data: string): string
  Uncompress: function(data: string): string
  Deflate: function(data: string): string
  Inflate: function(data: string, max_size: integer): string

  -- url encoding
  EscapeParam: function(str: string): string
  UnescapeParam: function(str: string): string, string
  ParseParams: function(query: string): {{string, string}}

  -- html/url escaping
  EscapeHtml: function(str: string): string
  EscapeHost: function(str: string): string
  EscapePath: function(str: string): string
  EscapeSegment: function(str: string): string
  EscapeFragment: function(str: string): string
  EscapeLiteral: function(str: string): string
  EscapeUser: function(str: string): string
  EscapePass: function(str: string): string
  EscapeIp: function(str: string): string

  -- url parsing
  record ParsedUrl
    scheme: string
    user: string
    pass: string
    host: string
    port: string
    path: string
    fragment: string
    params: {{string, string}}
  end
  ParseUrl: function(url: string): ParsedUrl
  ParseHost: function(hostport: string): string

  -- http datetime
  FormatHttpDateTime: function(timestamp: number): string
  ParseHttpDateTime: function(str: string): number

  -- ip address utilities
  ParseIp: function(str: string): integer
  FormatIp: function(ip: integer): string
  CategorizeIp: function(ip: integer): string
  IsLoopbackIp: function(ip: integer): boolean
  IsPrivateIp: function(ip: integer): boolean
  IsPublicIp: function(ip: integer): boolean
  ResolveIp: function(hostname: string): integer

  -- system info
  GetHostOs: function(): string
  GetHostIsa: function(): string
  GetRandomBytes: function(count: number): string

  -- fast pseudo-random number generators (non-cryptographic)
  Rand64: function(): integer
  Lemur64: function(): integer
  Rdrand: function(): integer, string
  Rdseed: function(): integer, string

  -- uuid
  UuidV4: function(): string
  UuidV7: function(): string

  -- script detection
  is_main: function(): boolean

  -- submodules (for require path hints)
  record unix end
  record path end
  record getopt end
  record zip end
  record lsqlite3 end
end

return cosmo
