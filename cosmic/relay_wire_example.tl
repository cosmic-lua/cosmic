--- Worked examples for [`cosmic.relay_wire`], shown by `cosmic docs` and run by
--- `cosmic test`.

local relay_wire = require("cosmic.relay_wire")

local Example = {}

--- A SOCKS5 CONNECT request: version, command, reserved, address type, the
--- address bytes and a big-endian port.
local function socks_request(command: integer, atyp: integer, address: string, port: integer): string
  return string.pack(">BBBB", 5, command, 0, atyp) .. address .. string.pack(">I2", port)
end

--- A TLS record holding a ClientHello that names `name` and carries the
--- extensions in `extra` (each already framed) after it.
local function client_hello(name: string, extra?: string): string
  local entry = "\0" .. string.pack(">s2", name)
  local server_name = "\0\0" .. string.pack(">s2", string.pack(">s2", entry))
  local body = "\3\3" .. ("r"):rep(32) .. "\0" .. string.pack(">s2", "\0\47") .. "\1\0" ..
    string.pack(">s2", server_name .. (extra or ""))
  local message = "\1" .. string.pack(">I3", #body) .. body
  return "\22\3\1" .. string.pack(">s2", message)
end

--- A CONNECT head arrives in pieces. The reader says `more` until the empty
--- line, then the host and port, and how many bytes the head took: what
--- follows is the tunnel's. A refusal's text becomes the reason phrase of
--- the reply, which names the remedy to the program.
function Example.connect()
  local reader = relay_wire.connect_reader()
  assert(reader:feed("CONNECT API.GitHub.com:443 HTTP/1.1\r\nProxy-Auth").status == "more")
  local head = reader:feed("orization: Basic dTpw\r\n\r\n\22\3\1")
  print(head.status, head.host, head.kind, head.port, head.authorization, head.consumed)
  -- done	api.github.com	name	443	Basic dTpw	72
  assert(head.status == "done" and head.host == "api.github.com" and head.port == 443)
  assert(head.authorization == "Basic dTpw" and head.consumed == 72)
  assert(relay_wire.connect_ok() == "HTTP/1.1 200 Connection established\r\n\r\n")

  local plain = relay_wire.connect_reader():feed("GET http://example.com/ HTTP/1.1\r\n\r\n")
  assert(plain.status == "refused" and plain.http_status == 405)
  local reply = relay_wire.connect_refusal(403, "not granted: --connect api.github.com:443")
  print((reply:match("^[^\r]*"))) -- HTTP/1.1 403 not granted: --connect api.github.com:443
  assert(reply:find("^HTTP/1.1 403 not granted: %-%-connect api.github.com:443\r\n"))
end

--- SOCKS5: the greeting picks no authentication, the request names a host
--- (a domain here, never resolved by the reader), and a refused command
--- answers with its own code.
function Example.socks()
  local greeting = relay_wire.socks_greeting_reader():feed("\5\2\2\0")
  assert(greeting.status == "done" and greeting.method == 0)
  assert(relay_wire.socks_method_reply(greeting.method) == "\5\0")

  local request = relay_wire.socks_request_reader():feed(socks_request(1, 3, "\11example.com", 443))
  print(request.host, request.kind, request.port) -- example.com	name	443
  assert(request.status == "done" and request.host == "example.com" and request.port == 443)

  local bind = relay_wire.socks_request_reader():feed(socks_request(2, 1, "\1\2\3\4", 80))
  assert(bind.status == "refused" and bind.reply == "command_not_supported")
  assert(relay_wire.socks_reply(bind.reply) == "\5\7\0\1\0\0\0\0\0\0")
  assert(relay_wire.socks_reply("not_allowed") == "\5\2\0\1\0\0\0\0\0\0")

  local token = relay_wire.socks_greeting_reader(true):feed("\5\1\2")
  assert(token.status == "done" and token.method == 2)
  local login = relay_wire.socks_auth_reader():feed("\1\4user\6secret")
  assert(login.status == "done" and login.username == "user" and login.password == "secret")
  assert(relay_wire.socks_auth_reply(true) == "\1\0")
end

--- The server name in a ClientHello, whole or split across records, so the
--- relay can hold it to the CONNECT host. A hello that carries an encrypted
--- name answers with none: its server_name is only a public name.
function Example.sni()
  local records = client_hello("Api.GitHub.com")
  local reader = relay_wire.hello_reader()
  assert(reader:feed(records:sub(1, 30)).status == "more")
  local found = reader:feed(records:sub(31))
  print(found.status, found.name) -- name	api.github.com
  assert(found.status == "name" and found.name == "api.github.com" and found.consumed == #records)

  local none = relay_wire.hello_reader():feed("GET / HTTP/1.1\r\n")
  assert(none.status == "not_tls")
  local ech = relay_wire.hello_reader():feed(client_hello("public.example", "\254\13\0\1\0"))
  assert(ech.status == "encrypted_sni" and ech.name == nil)
end

return Example
