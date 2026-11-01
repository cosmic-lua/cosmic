--- Helpers the tests of `cosmic_ci` share. Test support.
local record TestSupport
end

--- An HTTP/1.1 response of `status` (`"200 OK"`), the header lines `head`
--- (each ending in CRLF) and `body`, as a plain-HTTP API answers.
function TestSupport.reply(status: string, head: string, body?: string): string
  body = body or ""
  return "HTTP/1.1 " .. status .. "\r\n" .. head ..
    "Content-Length: " .. tostring(#body) .. "\r\nConnection: close\r\n\r\n" .. body
end

--- Whether `said` names the shape failure `expected` at the JSON pointer
--- `at`, as `$.a[0].b: want <expected>` or `$.a: missing`.
function TestSupport.shape_failure(said: string, at: string, expected: string): boolean
  local path = "$"
  for segment in at:gmatch("/([^/]*)") do
    path = path .. (if segment:find("^%d+$") then "[" .. segment .. "]" else "." .. segment end)
  end
  local rest = if expected:find(", got nothing$") then "missing" else "want " .. expected end
  return said:find(path .. ": " .. rest, 1, true) ~= nil
end

return TestSupport
