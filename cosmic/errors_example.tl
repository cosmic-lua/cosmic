--- Examples for the error-handling doctrine every cosmic.* module follows.
--- The doctrine itself is short — the type must admit failure — and
--- these are its shapes, runnable: a fallible VALUE returns
--- `value | nil, string`; a fallible EFFECT returns `boolean, string`;
--- a module with STRUCTURED failures returns its own error record in
--- slot 2 (D24); an infallible function returns a bare value. Library
--- code never throws (cosmic.check is the one exemption, D23).

-- Example_value_error demonstrates the primary pattern: a fallible
-- value comes back as `value | nil, string`, and the checker forces
-- the caller to narrow before using it.
local function Example_value_error()
  local json = require("cosmic.json")
  local data, err = json.decode("{ not json")
  if not data then
    print("parse failed: " .. err)
  end
  -- Output:
  -- parse failed: object key must be string
end

-- Example_boolean_error demonstrates the fallible-effect pattern: an
-- operation with nothing to return succeeds `true` or fails
-- `false, message`.
local function Example_boolean_error()
  local fs = require("cosmic.fs")
  local ok, err = fs.write("/no/such/dir/out.txt", "data")
  if not ok then
    print("write failed: " .. (err and "yes" or "no message"))
  end
  -- Output:
  -- write failed: yes
end

-- Example_structured_error demonstrates the structured shape (D24): a
-- module whose failures carry structure returns its own error record —
-- still two slots. The classification is a typed field (a typo'd kind
-- is a compile error against the module's enum), and tostring(err)
-- renders the classified message; the ftp URL fails validation, so no
-- network is touched.
local function Example_structured_error()
  local fetch = require("cosmic.fetch")
  local resp, err = fetch.fetch("ftp://example.com/file")
  if not resp then
    if err.kind == "invalid_request" then
      print("not retryable: " .. err.message)
    end
    print(tostring(err))
  end
  -- Output:
  -- not retryable: unsupported URL scheme: ftp
  -- invalid_request: unsupported URL scheme: ftp
end

-- Example_infallible demonstrates the third shape: encoding,
-- compression, and escaping cannot fail on any input, so they return a
-- bare value with no error channel to check.
local function Example_infallible()
  local codec = require("cosmic.codec")
  local uuid = require("cosmic.uuid")
  print(codec.encode_hex("hi"))
  print(#uuid.v4())
  -- Output:
  -- 6869
  -- 36
end

-- Suppress unused warnings for examples
local _ = {
  Example_value_error,
  Example_boolean_error,
  Example_structured_error,
  Example_infallible,
}
