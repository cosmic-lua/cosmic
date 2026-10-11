--- Worked examples for [`cosmic.web.cookies`], shown by `cosmic docs` under
--- the symbol each one demonstrates and run by `cosmic test` like any other
--- test.

local Cookies = require("cosmic.web.cookies")

local Example = {}

--- Reading a `Cookie` header: the first of a name wins.
function Example.parse()
  local cookies = Cookies.parse("theme=dark; sid=abc; theme=light")
  print(cookies.theme, cookies.sid)
  assert(cookies.theme == "dark" and cookies.sid == "abc")
end

--- A `Set-Cookie` line with the safe defaults, and the refusals that stop a
--- browser dropping a cookie without a word.
function Example.format()
  local line = assert(Cookies.format("theme", "dark", { max_age = 86400 }))
  print(line)
  assert(line == "theme=dark; Path=/; Max-Age=86400; HttpOnly; SameSite=Lax")
  local refused, why = Cookies.format("__Host-sid", "abc")
  print(why)
  assert(refused == nil and why:find("__Host-", 1, true))
end

--- Deleting a cookie: the attributes must be the ones it was set with.
function Example.expire()
  local line = assert(Cookies.expire("theme"))
  print(line)
  assert(line:find("Max-Age=0", 1, true))
end

return Example
