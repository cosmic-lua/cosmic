--- Examples for the error-handling doctrine every cosmic.* module follows.
--- The doctrine itself is short — the type must admit failure — and
--- these are its three shapes, runnable: a fallible VALUE returns
--- `value | nil, string`; a fallible EFFECT returns `boolean, string`;
--- an infallible function returns a bare value. Library code never
--- throws (cosmic.check is the one exemption, D23).

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
  Example_infallible,
}
