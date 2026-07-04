-- type declarations for cosmo
-- GENERATED from cosmopolitan's definitions.lua by lib/types/gentype.tl.
-- Do not edit by hand. Regenerate with: bin/make regen-types

local unix = require("cosmo.unix")

--- represented as the data structure `{{"a", "b"}, {"c"}, ...}`
local record Url
  --- e.g. `"http"`
  scheme: string
  --- the username string, or nil if absent
  user: string
  --- the password string, or nil if absent
  pass: string
  --- the hostname string, or nil if `url` was a path
  host: string
  --- the port string, or nil if absent
  port: string
  --- the path string, or nil if absent
  path: string
  --- the URL paramaters e.g. `/?a=b&c` would be
  params: {{string}}
  --- the stuff after the `#` character
  fragment: string
end

local record EncoderOptions
  --- defaults to `false`. Encodes the result directly to the output buffer and returns `nil` value. This option is ignored if used outside of request handling code.
  useoutput: boolean
  --- defaults to `true`. Lua uses hash tables so the order of object keys is lost in a Lua table. So, by default, we use strcmp to impose a deterministic output order. If you don't care about ordering then setting sorted=false should yield a performance boost in serialization.
  sorted: boolean
  --- defaults to `false`. Setting this option to true will cause tables with more than one entry to be formatted across multiple lines for readability.
  pretty: boolean
  --- defaults to " ". This option controls the indentation of pretty formatting. This field is ignored if pretty isn't true.
  indent: string
  --- defaults to 64. This option controls the maximum amount of recursion the serializer is allowed to perform. The max is 32767. You might not be able to set it that high if there isn't enough C stack memory. Your serializer checks for this and will return an error rather than crashing.
  maxdepth: number
end

--- Streaming reader for an HTTP response body, returned by
--- `cosmo.FetchStream`. The reader owns the underlying connection. It is
--- closed automatically on garbage collection, but calling `close`
--- promptly is recommended.
local record StreamReader
  --- Reads the next chunk of the response body.
  --- Returns a string chunk on success. An empty string may be returned
  --- for chunked transfer encodings when framing data arrived without any
  --- payload; callers should skip empty chunks rather than treating them
  --- as EOF. Returns `nil` when the stream ends. Returns `nil` plus an
  --- error message string if the reader is closed, the connection failed,
  --- or the response was truncated.
  read: function(self: StreamReader): string | nil, string | nil
  --- Closes the reader and releases the connection, buffer, and TLS
  --- state. Idempotent: closing an already-closed reader is a no-op.
  --- Returns nothing.
  close: function(self: StreamReader)
end

local record cosmo
  type Url = Url
  type EncoderOptions = EncoderOptions
  type StreamReader = StreamReader

  --- Writes all data to file the easy way.
  --- This function writes to the local file system.
  --- For example:
  ---     assert(Barf('x.txt', 'abc123'))
  ---     assert(Barf('x.txt', 'XX', 0, 0, 3))
  ---     assert(assert(Slurp('x.txt', 1, 6)) == 'abXX23')
  Barf: function(filename: string, data: string, mode?: number, flags?: number, offset?: number): boolean, unix.Errno
  --- Formats string as binary integer literal string. If the provided value is zero,
  --- the result will be `"0"`. Otherwise the resulting value will be the
  --- "0b"-prefixed binary str. The result is currently modulo 2^64. Negative numbers
  --- are converted to unsigned.
  bin: function(int: number): string
  --- Passing `0` will raise an error. Same as the Intel x86 instruction BSF.
  Bsf: function(x: number): number
  --- Passing `0` will raise an error. Same as the Intel x86 instruction BSR.
  Bsr: function(x: number): number
  CategorizeIp: function(ip: number): string
  --- Compresses data using zlib DEFLATE with a small framing header.
  --- By default the result starts with a header that stores the
  --- uncompressed byte length (as a ULEB64 varint) followed by a `Crc32`
  --- checksum, so `Uncompress` can decode it without being told the
  --- original size. If `raw` is truthy then only the raw zlib stream is
  --- returned, in which case `Uncompress` requires the uncompressed size
  --- as its second argument.
  --- This function raises an error if the level is invalid or the system
  --- runs out of memory.
  Compress: function(uncompressed: string, level?: number, raw?: boolean): string
  --- Computes Phil Katz CRC-32 used by zip/zlib/gzip/etc.
  Crc32: function(initial: number, data: string): number
  --- Computes 32-bit Castagnoli Cyclic Redundancy Check.
  Crc32c: function(initial: number, data: string): number
  --- Computes the Curve25519 elliptic-curve scalar multiplication used
  --- for Diffie-Hellman key agreement.
  --- The second argument can be either a public key or a basepoint. Use
  --- the magic basepoint `"\9"` to derive a public key from a 32-byte
  --- secret, then multiply your secret against the other party's public
  --- key to derive a shared key, e.g.
  ---     >: secret1 = GetRandomBytes(32)
  ---     >: public1 = Curve25519(secret1, "\9")
  ---     >: secret2 = GetRandomBytes(32)
  ---     >: public2 = Curve25519(secret2, "\9")
  ---     >: Curve25519(secret1, public2) == Curve25519(secret2, public1)
  ---     true
  --- Arguments are zero-padded or truncated to 32 bytes.
  Curve25519: function(secret: string, public_or_basepoint: string): string
  --- Shrinks byte buffer in half using John Costella's magic kernel. This downscales
  --- data 2x using an eight-tap convolution, e.g.
  ---     >: Decimate('\xff\xff\x00\x00\xff\xff\x00\x00\xff\xff\x00\x00')
  ---     "\xff\x00\xff\x00\xff\x00"
  --- This is very fast if SSSE3 is available (Intel 2004+ / AMD 2011+).
  Decimate: function(data: string): string
  --- Turns ASCII into binary using the provided alphabet. The default
  --- decoding uses Crockford's base32 alphabet in a permissive way that
  --- ignores whitespace and dash (`-`) and stops at the first character
  --- outside of the alphabet. Any alphabet that has a power of 2 length
  --- (up to 128) may be supplied, which allows alternative base32
  --- encodings to be decoded. Raises an error if the alphabet length is
  --- not a power of 2 in the range 2..128.
  DecodeBase32: function(ascii: string, alphabet?: string): string
  --- Decodes binary data encoded as base64.
  --- This turns ASCII into binary, in a permissive way that ignores
  --- characters outside the base64 alphabet, such as whitespace. See
  --- `decodebase64.c`.
  DecodeBase64: function(ascii: string): string
  --- Turns ASCII base-16 hexadecimal byte string into binary string,
  --- case-insensitively. Non-hex characters may not appear in string.
  DecodeHex: function(ascii: string): string
  --- Turns JSON string into a Lua data structure.
  --- This is a generally permissive parser, in the sense that like
  --- v8, it permits scalars as top-level values. Therefore we must
  --- note that this API can be thought of as special, in the sense
  ---     val = assert(DecodeJson(str))
  --- will usually do the right thing, except in cases where `false`
  --- or `null` are the top-level value. In those cases, it's needed
  --- to check the second value too in order to discern from error
  ---     val, err = DecodeJson(str)
  ---     if not val then
  ---        if err then
  ---           print('bad json', err)
  ---        elseif val == nil then
  ---           print('val is null')
  ---        elseif val == false then
  ---           print('val is false')
  ---        end
  ---     end
  --- This parser supports 64-bit signed integers. If an overflow
  --- happens, then the integer is silently coerced to double, as
  --- consistent with v8. If a double overflows into `Infinity`, we
  --- coerce it to `null` since that's what v8 does, and the same
  --- goes for underflows which, like v8, are coerced to `0.0`.
  --- When objects are parsed, your Lua object can't preserve the
  --- original ordering of fields. As such, they'll be sorted by
  --- `EncodeJson()` and may not round-trip with original intent.
  --- This parser has perfect conformance with JSONTestSuite.
  --- This parser validates utf-8 and utf-16.
  DecodeJson: function(input: string): any, string
  --- Turns ISO-8859-1 string into UTF-8.
  DecodeLatin1: function(iso_8859_1: string): string
  --- Compresses data.
  ---     >: Deflate("hello")
  ---     "\xcbH\xcd\xc9\xc9\x07\x00"
  ---     >: Inflate("\xcbH\xcd\xc9\xc9\x07\x00", 5)
  ---     "hello"
  --- The output format is raw DEFLATE that's suitable for embedding into formats
  --- like a ZIP file. It's recommended that, like ZIP, you also store separately a
  --- `Crc32()` checksum in addition to the original uncompressed size.
  --- Lower numbers go faster (4 for instance is a sweet spot) and higher numbers go
  --- slower but have better compression.
  Deflate: function(uncompressed: string, level?: number): string, string
  --- Turns binary into ASCII using the provided alphabet (Crockford's
  --- base32 alphabet by default). Any alphabet that has a power of 2
  --- length (up to 128) may be supplied for encoding and decoding, which
  --- allows alternative base32 encodings to be produced. Raises an error
  --- if the alphabet length is not a power of 2 in the range 2..128.
  EncodeBase32: function(binary: string, alphabet?: string): string
  --- Turns binary into ASCII. This can be used to create HTML data:
  --- URIs that do things like embed a PNG file in a web page. See
  --- encodebase64.c.
  EncodeBase64: function(binary: string): string
  --- Turns binary into ASCII base-16 hexadecimal lowercase string.
  EncodeHex: function(binary: string): string
  --- Turns Lua data structure into JSON string.
  --- Since Lua uses tables are both hashmaps and arrays, we use a
  --- simple fast algorithm for telling the two apart. Tables with
  --- non-zero length (as reported by `#`) are encoded as arrays,
  --- and any non-array elements are ignored. For example:
  ---     >: EncodeJson({2})
  ---     "[2]"
  ---     >: EncodeJson({[1]=2, ["hi"]=1})
  ---     "[2]"
  --- If there are holes in your array, then the serialized array
  --- will exclude everything after the first hole. If the beginning
  --- of your array is a hole, then an error is returned.
  ---     >: EncodeJson({[1]=1, [3]=3})
  ---     "[1]"
  ---     >: EncodeJson({[2]=1, [3]=3})
  ---     "[]"
  ---     >: EncodeJson({[2]=1, [3]=3})
  ---     nil     "json objects must only use string keys"
  --- If the raw length of a table is reported as zero, then we
  --- check for the magic element `[0]=false`. If it's present, then
  --- your table will be serialized as empty array `[]`. An entry is
  --- inserted by `DecodeJson()` automatically, only when encountering
  --- empty arrays, and it's necessary in order to make empty arrays
  --- round-trip. If raw length is zero and `[0]=false` is absent,
  --- then your table will be serialized as an iterated object.
  ---     >: EncodeJson({})
  ---     "{}"
  ---     >: EncodeJson({[0]=false})
  ---     "[]"
  ---     >: EncodeJson({["hi"]=1})
  ---     "{\"hi\":1}"
  ---     >: EncodeJson({["hi"]=1, [0]=false})
  ---     "[]"
  ---     >: EncodeJson({["hi"]=1, [7]=false})
  ---     nil     "json objects must only use string keys"
  --- The following options may be used:
  --- - `useoutput`: `(bool=false)` encodes the result directly to the output buffer
  ---   and returns nil value. This option is ignored if used outside of request
  ---   handling code.
  --- - `sorted`: `(bool=true)` Lua uses hash tables so the order of object keys is
  ---   lost in a Lua table. So, by default, we use strcmp to impose a deterministic
  ---   output order. If you don't care about ordering then setting `sorted=false`
  ---   should yield a performance boost in serialization.
  --- - `pretty`: `(bool=false)` Setting this option to true will cause tables with
  ---   more than one entry to be formatted across multiple lines for readability.
  --- - `indent`: `(str=" ")` This option controls the indentation of pretty
  ---    formatting. This field is ignored if pretty isn't `true`.
  --- - `maxdepth`: `(int=64)` This option controls the maximum amount of recursion
  ---   the serializer is allowed to perform. The max is 32767. You might not be able
  ---   to set it that high if there isn't enough C stack memory. Your serializer
  ---   checks for this and will return an error rather than crashing.
  --- If the raw length of a table is reported as zero, then we
  --- check for the magic element `[0]=false`. If it's present, then
  --- your table will be serialized as empty array `[]`. An entry is
  --- inserted by `DecodeJson()` automatically, only when encountering
  --- empty arrays, and it's necessary in order to make empty arrays
  --- round-trip. If raw length is zero and `[0]=false` is absent,
  --- then your table will be serialized as an iterated object.
  --- This function will return an error if:
  --- - value is cyclic
  --- - value has depth greater than 64
  --- - value contains functions, user data, or threads
  --- - value is table that blends string / non-string keys
  --- - Your serializer runs out of C heap memory (setrlimit)
  --- We assume strings in value contain UTF-8. This serializer currently does not
  --- produce UTF-8 output. The output format is right now ASCII. Your UTF-8 data
  --- will be safely transcoded to `\uXXXX` sequences which are UTF-16. Overlong
  --- encodings in your input strings will be canonicalized rather than validated.
  --- NaNs are serialized as `null` and Infinities are `null` which is consistent
  --- with the v8 behavior.
  EncodeJson: function(value: any, options?: any): string, string
  --- Turns UTF-8 into ISO-8859-1 string.
  EncodeLatin1: function(utf8: string, flags?: number): string
  --- Turns Lua data structure into Lua code string.
  --- Since Lua uses tables as both hashmaps and arrays, tables will only be
  --- serialized as an array with determinate order, if it's an array in the
  --- strictest possible sense.
  --- 1. for all 𝑘=𝑣 in table, 𝑘 is an integer ≥1
  --- 2. no holes exist between MIN(𝑘) and MAX(𝑘)
  --- 3. if non-empty, MIN(𝑘) is 1
  --- In all other cases, your table will be serialized as an object which is
  --- iterated and displayed as a list of (possibly) sorted entries that have
  --- equal signs.
  ---     >: EncodeLua({3, 2})
  ---     "{3, 2}"
  ---     >: EncodeLua({[1]=3, [2]=3})
  ---     "{3, 2}"
  ---     >: EncodeLua({[1]=3, [3]=3})
  ---     "{[1]=3, [3]=3}"
  ---     >: EncodeLua({["hi"]=1, [1]=2})
  ---     "{[1]=2, hi=1}"
  --- The following options may be used:
  --- - `useoutput`: `(bool=false)` encodes the result directly to the output buffer
  ---   and returns nil value. This option is ignored if used outside of request
  ---   handling code.
  --- - `sorted`: `(bool=true)` Lua uses hash tables so the order of object keys is
  ---   lost in a Lua table. So, by default, we use strcmp to impose a deterministic
  ---   output order. If you don't care about ordering then setting `sorted=false`
  ---   should yield a performance boost in serialization.
  --- - `pretty`: `(bool=false)` Setting this option to true will cause tables with
  ---   more than one entry to be formatted across multiple lines for readability.
  --- - `indent`: `(str=" ")` This option controls the indentation of pretty
  ---    formatting. This field is ignored if pretty isn't `true`.
  --- - `maxdepth`: `(int=64)` This option controls the maximum amount of recursion
  ---   the serializer is allowed to perform. The max is 32767. You might not be able
  ---   to set it that high if there isn't enough C stack memory. Your serializer
  ---   checks for this and will return an error rather than crashing.
  --- If a user data object has a `__repr` or `__tostring` meta method, then that'll
  --- be used to encode the Lua code.
  --- This serializer is designed primarily to describe data. For example, it's used
  --- by the REPL where we need to be able to ignore errors when displaying data
  --- structures, since showing most things imperfectly is better than crashing.
  --- Therefore this isn't the kind of serializer you'd want to use to persist data
  --- in prod. Try using the JSON serializer for that purpose.
  --- Non-encodable value types (e.g. threads, functions) will be represented as a
  --- string literal with the type name and pointer address. The string description
  --- is of an unspecified format that could most likely change. This encoder detects
  --- cyclic tables; however instead of failing, it embeds a string of unspecified
  --- layout describing the cycle.
  --- Integer literals are encoded as decimal. However if the int64 number is ≥256
  --- and has a population count of 1 then we switch to representating the number in
  --- hexadecimal, for readability. Hex numbers have leading zeroes added in order
  --- to visualize whether the number fits in a uint16, uint32, or int64. Also some
  --- numbers can only be encoded expressionally. For example, `NaN`s are serialized
  --- as `0/0`, and `Infinity` is `math.huge`.
  ---     >: 7000
  ---     7000
  ---     >: 0x100
  ---     0x0100
  ---     >: 0x10000
  ---     0x00010000
  ---     >: 0x100000000
  ---     0x0000000100000000
  ---     >: 0/0
  ---     0/0
  ---     >: 1.5e+9999
  ---     math.huge
  ---     >: -9223372036854775807 - 1
  ---     -9223372036854775807 - 1
  --- The only failure return condition currently implemented is when C runs out of heap memory.
  EncodeLua: function(value: any, options?: any): string, string
  --- This function is the inverse of ParseUrl. The output will always be correctly
  --- formatted. The exception is if illegal characters are supplied in the scheme
  --- field, since there's no way of escaping those. Opaque parts are escaped as
  --- though they were paths, since many URI parsers won't understand things like
  --- an unescaped question mark in path.
  EncodeUrl: function(url: Url): string
  --- Escapes URL #fragment. The allowed characters are `-/?.~_@:!$&'()*+,;=0-9A-Za-z`
  --- and everything else gets `%XX` encoded. Please note that `'&` can still break
  --- HTML and that `'()` can still break CSS URLs. This function is charset agnostic
  --- and will not canonicalize overlong encodings. It is assumed that a UTF-8 string
  --- will be supplied. See `kescapefragment.S`.
  EscapeFragment: function(str: string): string
  --- Escapes URL host. See `kescapeauthority.S`.
  EscapeHost: function(str: string): string
  --- Escapes HTML entities: The set of entities is `&><"'` which become `&amp;&gt;&lt;&quot;&#39;`. This function is charset agnostic and will not canonicalize overlong encodings. It is assumed that a UTF-8 string will be supplied. See `escapehtml.c`.
  EscapeHtml: function(str: string): string
  --- Escapes URL IP-literal. This is the same as `EscapeHost` except
  --- colon is permitted, so bracketed IPv6 literals stay intact. See
  --- `escapeip.c`.
  EscapeIp: function(str: string): string
  --- Escapes JavaScript or JSON string literal content. The caller is responsible
  --- for adding the surrounding quotation marks. This implementation \uxxxx sequences
  --- for all non-ASCII sequences. HTML entities are also encoded, so the output
  --- doesn't need `EscapeHtml`. This function assumes UTF-8 input. Overlong
  --- encodings are canonicalized. Invalid input sequences are assumed to
  --- be ISO-8859-1. The output is UTF-16 since that's what JavaScript uses. For
  --- example, some individual codepoints such as emoji characters will encode as
  --- multiple `\uxxxx` sequences. Ints that are impossible to encode as UTF-16 are
  --- substituted with the `\xFFFD` replacement character.
  --- See `escapejsstringliteral.c`.
  EscapeLiteral: function(str: string): string
  --- Escapes URL parameter name or value. The allowed characters are `-.*_0-9A-Za-z`
  --- and everything else gets `%XX` encoded. This function is charset agnostic and
  --- will not canonicalize overlong encodings. It is assumed that a UTF-8 string
  --- will be supplied. See `kescapeparam.S`.
  EscapeParam: function(str: string): string
  --- Escapes URL password. See `kescapeauthority.S`.
  EscapePass: function(str: string): string
  --- Escapes URL path. This is the same as EscapeSegment except slash is allowed.
  --- The allowed characters are `-.~_@:!$&'()*+,;=0-9A-Za-z/` and everything else
  --- gets `%XX` encoded. Please note that `'&` can still break HTML, so the output
  --- may need EscapeHtml too. Also note that `'()` can still break CSS URLs. This
  --- function is charset agnostic and will not canonicalize overlong encodings.
  --- It is assumed that a UTF-8 string will be supplied. See `kescapepath.S`.
  EscapePath: function(str: string): string
  --- Escapes URL path segment. This is the same as EscapePath except slash isn't
  --- allowed. The allowed characters are `-.~_@:!$&'()*+,;=0-9A-Za-z` and everything
  --- else gets `%XX` encoded. Please note that `'&` can still break HTML, so the
  --- output may need EscapeHtml too. Also note that `'()` can still break CSS URLs.
  --- This function is charset agnostic and will not canonicalize overlong encodings.
  --- It is assumed that a UTF-8 string will be supplied. See `kescapesegment.S`.
  EscapeSegment: function(str: string): string
  --- Escapes URL username. See `kescapeauthority.S`.
  EscapeUser: function(str: string): string
  --- Sends an HTTP/HTTPS request to the specified URL. If only the URL is provided,
  --- then a GET request is sent. If both URL and body parameters are specified, then
  --- a POST request is sent. If any other method needs to be specified (for example,
  --- PUT or DELETE), then passing a table as the second value allows setting method
  --- and body values as well other options:
  --- - `method` (default: `"GET"`): sets the method to be used for the request.
  ---   The specified method is converted to uppercase.
  --- - `body` (default: `""`): sets the body value to be sent.
  --- - `followredirect` (default: `true`): forces temporary and permanent redirects
  ---    to be followed. This behavior can be disabled by passing `false`.
  --- - `maxredirects` (default: `5`): sets the number of allowed redirects to
  ---   minimize looping due to misconfigured servers. When the number is exceeded,
  ---   the result of the last redirect is returned.
  --- - `keepalive` (default = `false`): configures each request to keep the
  ---   connection open (unless closed by the server) and reuse for the
  ---   next request to the same host. This option is disabled when SSL
  ---   connection is used.
  ---   The mapping of hosts and their sockets is stored in a table
  ---   assigned to the `keepalive` field itself, so it can be passed to
  ---   the next call.
  ---   If the table includes the `close` field set to a true value,
  ---   then the connection is closed after the request is made and the
  ---   host is removed from the mapping table.
  --- - `proxy` (string): HTTP proxy URL, e.g. `"http://proxy:8080"`.
  ---   Supports Basic authentication: `"http://user:pass@proxy:8080"`.
  --- - `maxresponse` (default: `104857600`): maximum response size in bytes.
  ---   Protects against memory exhaustion from large responses.  Must be >= 0;
  ---   negative values are rejected.
  --- - `timeout` (number, seconds): per-operation socket timeout (read/write/
  ---   connect).  A value of `0` or absent keeps the 60-second default.  There
  ---   is no "infinite" option — use a large positive value if needed.  The
  ---   timeout also bounds the TLS handshake.
  --- - `resettls` (default: `true`): reset TLS state after fork.
  ---   Ensures child processes get fresh DRBG entropy.
  --- Environment variables:
  --- - `http_proxy` / `HTTP_PROXY`: default proxy URL when `proxy` option
  ---   is not specified. Supports same format as the option.
  --- - `SSL_CERT_FILE`: path to CA certificate bundle file for TLS verification.
  ---   Overrides default system CA locations.
  --- - `SSL_NO_SYSTEM_CERTS`: if set, skip loading system CA certificates.
  ---   Only embedded certificates will be used.
  --- When the redirect is being followed, the same method and body values are being
  --- sent in all cases except when 303 status is returned. In that case the method
  --- is set to GET and the body is removed before the redirect is followed. Note
  --- that if these (method/body) values are provided as table fields, they will be
  --- modified in place.
  Fetch: function(url: string, body?: string | any): number, {string: string}, string, string
  --- Sends an HTTP/HTTPS request and returns a streaming reader for the response body.
  --- Useful for Server-Sent Events (SSE), large downloads, or processing data incrementally.
  --- Accepts the same options table as `Fetch()`, including `timeout`, `maxresponse`,
  --- `headers`, `method`, `body`, `proxy`, `followredirect`, and `maxredirects`.
  --- Note: `timeout=0` (or absent) retains the 60-second default; there is no
  --- "infinite" option.  `maxresponse` limits per-read buffer growth; negative
  --- values are rejected.
  FetchStream: function(url: string, options?: any): number, {string: string}, StreamReader, string
  --- Converts UNIX timestamp to an RFC1123 string that looks like this:
  --- `Mon, 29 Mar 2021 15:37:13 GMT`. See `formathttpdatetime.c`.
  FormatHttpDateTime: function(seconds: number): string
  --- Turns integer like `0x01020304` into a string like `"1.2.3.4"`. See also
  --- `ParseIp` for the inverse operation.
  FormatIp: function(uint32: number): string
  GetCpuCore: function(): number
  GetCpuCount: function(): number
  GetCpuNode: function(): number
  GetCryptoHash: function(name: string, payload: string, key?: string): string
  --- Returns string describing host instruction set architecture.
  --- This can return:
  --- - `"X86_64"` for Intel and AMD systems
  --- - `"AARCH64"` for ARM64, M1, and Raspberry Pi systems
  --- - `"POWERPC64"` for OpenPOWER Raptor Computing Systems
  GetHostIsa: function(): string
  GetHostOs: function(): string
  GetHttpReason: function(code: number): string
  --- This is useful for fixed-width formatting. For example, CJK characters
  --- typically take up two cells. This function takes into consideration combining
  --- characters, which are discounted, as well as control codes and ANSI escape
  --- sequences.
  GetMonospaceWidth: function(str: string | number): number
  GetRandomBytes: function(length?: number): string
  GetTime: function(): number
  --- Returns `true` if the string contains forbidden control codes.
  --- `flags` selects which characters are considered forbidden and may be
  --- any combination of:
  --- - `1` (kControlWs): forbid the whitespace controls tab, carriage
  ---   return, line feed, and vertical tab
  --- - `2` (kControlC0): forbid the C0 control codes (0x00..0x1F and
  ---   0x7F), except the whitespace controls above
  --- - `4` (kControlC1): forbid the C1 control codes (0x80..0x9F), which
  ---   are decoded from UTF-8 before being checked
  --- If `flags` is zero (the default) then no characters are forbidden
  --- and this function returns `false`. Raises an error if `flags` has
  --- bits outside the values above.
  HasControlCodes: function(str: string, flags?: number): boolean
  --- Formats string as hexadecimal integer literal string. If the provided value is
  --- zero, the result will be `"0"`. Otherwise the resulting value will be the
  --- "0x"-prefixed hex string. The result is currently modulo 2^64. Negative numbers
  --- are converted to unsigned.
  hex: function(int: number): string
  --- Computes 64-bit Google HighwayHash of a string.
  --- HighwayHash is a fast keyed pseudorandom function. The four optional
  --- 64-bit key words default to zero. A zero key isn't a secret key;
  --- pass four random 64-bit integers if keyed hashing is desired.
  HighwayHash64: function(str: string, k1?: number, k2?: number, k3?: number, k4?: number): number
  --- Adds spaces to beginnings of multiline string. If the int parameter is not
  --- supplied then 1 space will be added.
  IndentLines: function(str: string, int?: number): string
  --- Decompresses data.
  --- This function performs the inverse of Deflate(). It's recommended that you
  --- perform a `Crc32()` check on the output string after this function succeeds.
  --- However, it is permissable (although not advised) to specify some large number
  --- in which case (on success) the byte length of the output string may be less
  --- than `maxoutsize`.
  Inflate: function(compressed: string, maxoutsize: number): string, string
  --- Check if the calling script is being run directly (not require'd).
  --- This function provides a Python-like `if __name__ == "__main__"` idiom
  --- for Lua scripts. It returns true when the script is executed directly
  --- from the command line, and false when the script is loaded via require().
  --- Example usage:
  ---     local M = {}
  ---     function M.main(args)
  ---       print("Hello, " .. (args[1] or "world"))
  ---     end
  ---     if is_main() then
  ---       M.main(arg)
  ---     end
  ---     return M
  is_main: function(): boolean
  --- Returns `true` if hostname seems legit.
  --- This validates the host component of a URL, permitting things like
  --- `""`, `1.2.3.4`, `localservice`, `hello.example`, and
  --- `hi-there.example`, while rejecting things like `::1`, `1.2.3`,
  --- `1.2.3.4.5`, `.hi.example`, and `hi..example`. Fully numerical names
  --- must be valid IPv4 addresses. There's currently no support for IPv6
  --- literals. See `isacceptablehost.c`.
  IsAcceptableHost: function(str: string): boolean
  IsAcceptablePath: function(str: string): boolean
  --- Returns `true` if port string seems legit, i.e. it's either empty or
  --- a string of digits that fits in the range 0..65535, e.g. `""`,
  --- `"0"`, `"65535"`. Named services like `"https"`, negative values,
  --- and numbers greater than 65535 are rejected. See
  --- `isacceptableport.c`.
  IsAcceptablePort: function(str: string): boolean
  --- Returns `true` if the given HTTP header name is a standard header
  --- that the RFCs define as storing comma-separated values and may
  --- therefore appear multiple times in a message, e.g.
  --- `Accept-Encoding`. Returns `false` for non-repeatable and
  --- unrecognized headers. See `khttprepeatable.c`.
  IsHeaderRepeatable: function(name: string): boolean
  IsLoopbackIp: function(uint32: number): boolean
  IsPrivateIp: function(uint32: number): boolean
  --- Note: we intentionally regard TEST-NET IPs as public.
  IsPublicIp: function(uint32: number): boolean
  IsReasonablePath: function(str: string): boolean
  --- Returns `true` if the string is a valid HTTP token, i.e. a nonempty
  --- ASCII string without separators or control codes, as defined by
  --- RFC7230. Tokens are used for things like HTTP methods and header
  --- names. See `isvalidhttptoken.c`.
  IsValidHttpToken: function(str: string): boolean
  --- This linear congruential generator passes practrand and bigcrush.
  Lemur64: function(): number
  --- Compresses data using LZ4.
  --- LZ4 is an extremely fast compression algorithm, trading compression ratio
  --- for speed. It's particularly well-suited for real-time compression scenarios.
  --- The compressed output is not compatible with other compression formats (use
  --- Deflate/Inflate for standard zlib compatibility).
  --- produce faster compression but with worse compression ratio. Range is 1-65537.
  Lz4Compress: function(data: string, acceleration?: number): string, string
  --- Decompresses LZ4-compressed data.
  --- You must know the maximum size of the decompressed output beforehand.
  --- This is a limitation of the LZ4 format which doesn't store the original size.
  Lz4Decompress: function(compressed: string, maxoutsize: number): string, string
  --- Computes MD5 checksum, returning 16 bytes of binary.
  Md5: function(str: string): string
  --- This gives you an idea of the density of information. Cryptographic random
  --- should be in the ballpark of `7.9` whereas plaintext will be more like `4.5`.
  MeasureEntropy: function(data: string): number
  --- Formats string as octal integer literal string. If the provided value is zero,
  --- the result will be `"0"`. Otherwise the resulting value will be the
  --- zero-prefixed octal string. The result is currently modulo 2^64. Negative
  --- numbers are converted to unsigned.
  oct: function(int: number): string
  --- Parses a `host[:port]` string, e.g. `"example.com:8080"`.
  --- Please note a longstanding quirk inherited from redbean: only the
  --- port component is currently returned. This function yields the port
  --- string (e.g. `"8080"`), or `nil` if no port is present; the host
  --- component is parsed but not returned. This function is
  --- nil-propagating: passing `nil` returns `nil`. Raises an error if the
  --- system runs out of memory.
  ParseHost: function(str: string): string | nil
  --- Converts RFC1123 string that looks like this: Mon, 29 Mar 2021 15:37:13 GMT to
  --- a UNIX timestamp. See `parsehttpdatetime.c`.
  ParseHttpDateTime: function(rfc1123: string): number
  --- Converts IPv4 address string to integer, e.g. "1.2.3.4" → 0x01020304, or
  --- returns -1 for invalid inputs. See also `FormatIp` for the inverse operation.
  ParseIp: function(ip: string): number
  --- Parses `application/x-www-form-urlencoded` key/value parameters,
  --- e.g. `"a=b&c"` becomes `{{"a", "b"}, {"c"}}`. This returns the same
  --- data structure as the `params` field of the `Url` object returned by
  --- `ParseUrl`. Keys and values are percent-decoded. This function is
  --- nil-propagating: passing `nil` returns `nil`. Raises an error if the
  --- system runs out of memory.
  ParseParams: function(paramstring: string): any
  --- Parses URL.
  --- - `scheme` is a string, e.g. `"http"`
  --- - `user` is the username string, or nil if absent
  --- - `pass` is the password string, or nil if absent
  --- - `host` is the hostname string, or nil if `url` was a path
  --- - `port` is the port string, or nil if absent
  --- - `path` is the path string, or nil if absent
  --- - `params` is the URL paramaters, e.g. `/?a=b&c` would be
  ---   represented as the data structure `{{"a", "b"}, {"c"}, ...}`
  --- - `fragment` is the stuff after the `#` character
  --- - `kUrlPlus` to turn `+` into space
  --- - `kUrlLatin1` to transcode ISO-8859-1 input into UTF-8
  --- This parser is charset agnostic. Percent encoded bytes are
  --- decoded for all fields. Returned values might contain things
  --- like NUL characters, spaces, control codes, and non-canonical
  --- encodings. Absent can be discerned from empty by checking if
  --- the pointer is set.
  --- There's no failure condition for this routine. This is a
  --- permissive parser. This doesn't normalize path segments like
  --- `.` or `..` so use IsAcceptablePath() to check for those. No
  --- restrictions are imposed beyond that which is strictly
  --- necessary for parsing. All the data that is provided will be
  --- consumed to the one of the fields. Strict conformance is
  --- enforced on some fields more than others, like scheme, since
  --- it's the most non-deterministically defined field of them all.
  --- Please note this is a URL parser, not a URI parser. Which
  --- means we support everything the URI spec says we should do
  --- except for the things we won't do, like tokenizing path
  --- segments into an array and then nesting another array beneath
  --- each of those for storing semicolon parameters. So this parser
  --- won't make SIP easy. What it can do is parse HTTP URLs and most
  --- URIs like data:opaque, better in fact than most things which
  --- claim to be URI parsers.
  ParseUrl: function(url: string, flags?: number): Url
  --- Returns number of bits set in integer.
  Popcnt: function(x: number): number
  --- This linear congruential generator passes practrand and bigcrush. This
  --- generator is safe across `fork()`, threads, and signal handlers.
  Rand64: function(): number
  --- read raw hardware RDRAND; it returns output from the OS CSPRNG (arc4random64), which is
  --- seeded from hardware entropy but is safer (no RNG fault exposure).
  Rdrand: function(): number
  --- read raw hardware RDSEED; it returns output from the OS CSPRNG (arc4random64), which is
  --- seeded from hardware entropy but is safer (no RNG fault exposure).
  Rdseed: function(): number
  --- Gets IP address associated with hostname.
  --- This function first checks if hostname is already an IP address, in which case
  --- it returns the result of `ParseIp`. Otherwise, it checks HOSTS.TXT on the local
  --- system and returns the first IPv4 address associated with hostname. If no such
  --- entry is found, a DNS lookup is performed using the system configured (e.g.
  --- `/etc/resolv.conf`) DNS resolution service. If the service returns multiple IN
  --- A records then only the first one is returned.
  --- The returned address is word-encoded in host endian order. For example,
  --- 1.2.3.4 is encoded as 0x01020304. The `FormatIp` function may be used to turn
  --- this value back into a string.
  --- If no IP address could be found, then `nil` is returned alongside a string of
  --- unspecified format describing the error. Calls to this function may be wrapped
  --- in `assert()` if an exception is desired.
  ResolveIp: function(hostname: string): number, string
  --- Computes SHA1 checksum, returning 20 bytes of binary.
  Sha1: function(str: string): string
  --- Computes SHA224 checksum, returning 28 bytes of binary.
  Sha224: function(str: string): string
  --- Computes SHA256 checksum, returning 32 bytes of binary.
  Sha256: function(str: string): string
  --- Computes SHA384 checksum, returning 48 bytes of binary.
  Sha384: function(str: string): string
  --- Computes SHA512 checksum, returning 64 bytes of binary.
  Sha512: function(str: string): string
  --- Sleeps the specified number of seconds (can be fractional).
  --- The smallest interval is a microsecond.
  Sleep: function(seconds: number)
  --- Reads all data from file the easy way.
  --- This function reads file data from local file system. Zip file assets can be
  --- accessed using the `/zip/...` prefix.
  --- `i` and `j` may be used to slice a substring in filename. These parameters are
  --- 1-indexed and behave consistently with Lua's `string.sub()` API. For example:
  ---     assert(Barf('x.txt', 'abc123'))
  ---     assert(assert(Slurp('x.txt', 2, 3)) == 'bc')
  --- This function is uninterruptible so `unix.EINTR` errors will be ignored. This
  --- should only be a concern if you've installed signal handlers. Use the UNIX API
  --- if you need to react to it.
  Slurp: function(filename: string, i?: number, j?: number): string, unix.Errno
  --- Formats a timestamp using strftime(3) format specifiers.
  --- Common format specifiers:
  --- - `%Y` four-digit year
  --- - `%m` two-digit month (01-12)
  --- - `%d` two-digit day (01-31)
  --- - `%H` two-digit hour (00-23)
  --- - `%M` two-digit minute (00-59)
  --- - `%S` two-digit second (00-59)
  --- - `%F` equivalent to `%Y-%m-%d`
  --- - `%T` equivalent to `%H:%M:%S`
  --- - `%a` abbreviated weekday name
  --- - `%b` abbreviated month name
  --- Example:
  ---     Strftime("%Y-%m-%d %H:%M:%S")           -- "2024-12-29 15:30:00"
  ---     Strftime("%F %T", os.time())            -- "2024-12-29 15:30:00"
  ---     Strftime("%a, %d %b %Y", 0)             -- "Thu, 01 Jan 1970"
  ---     Strftime("%F %T", os.time(), true)      -- local time instead of UTC
  Strftime: function(format: string, timestamp?: number, localtime?: boolean): string | nil
  --- Parses a datetime string using strptime(3) format specifiers.
  --- Returns a table with parsed components and any unparsed remainder.
  --- Uses the same format specifiers as `Strftime`.
  --- Example:
  ---     local t = Strptime("2024-12-29", "%Y-%m-%d")
  ---     -- t = {year=2024, month=12, day=29, hour=0, min=0, sec=0, ...}
  ---     local t = Strptime("2024-12-29 15:30", "%Y-%m-%d %H:%M")
  ---     -- t.rest = "" (nothing unparsed)
  ---     local t = Strptime("2024-12-29 extra", "%Y-%m-%d")
  ---     -- t.rest = " extra"
  Strptime: function(str: string, format: string): table | nil, string | nil
  --- Decompresses data produced by `Compress`.
  --- If `maxoutsize` is absent, the input is expected to begin with the
  --- header that `Compress` writes by default; the embedded length and
  --- `Crc32` checksum are verified. If `maxoutsize` is given, the input
  --- must be a raw zlib stream that decompresses to exactly `maxoutsize`
  --- bytes.
  --- This function raises an error if the input is truncated or corrupt.
  Uncompress: function(compressed: string, maxoutsize?: number): string
  --- Canonicalizes overlong encodings.
  Underlong: function(str: string): string
  --- Unescapes URL parameter name or value. Decodes `%XX` hex sequences and
  --- converts `+` to space (common in application/x-www-form-urlencoded).
  --- This is the inverse of EscapeParam.
  UnescapeParam: function(str: string): string
  --- Generate a uuid_v4
  UuidV4: function(): string
  --- Generate a uuid_v7
  UuidV7: function(): string
  --- Replaces C0 control codes and trojan source characters with descriptive
  --- UNICODE pictorial representation. This function also canonicalizes overlong
  --- encodings. C1 control codes are replaced with a JavaScript-like escape sequence.
  VisualizeControlCodes: function(str: string): string
end

return cosmo
