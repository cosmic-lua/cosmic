--- Examples for cosmic.failure: the one sink-side supertype for
--- structured errors (D24). Producing modules return their own
--- concrete record (`fetch.Error`); `Failure` is what a SINK that
--- accepts any module's error names in its signature, the way
--- `check.must` widens slot 2 to `string | Failure`.

-- Example_sink demonstrates a sink over `string | Failure`: narrow the
-- string arm with `is string` (an if/else, not an early-exit guard —
-- `is` narrowing does not survive those), and the else arm renders the
-- structured error via its __tostring. The ftp URL fails validation,
-- so no network is touched.
local function Example_sink()
  local failure = require("cosmic.failure")
  local fetch = require("cosmic.fetch")
  local function render(err: string | failure.Failure): string
    if err is string then
      return err
    else
      return tostring(err)
    end
  end
  print(render("plain message"))
  local resp, err = fetch.fetch("ftp://example.com/x")
  if not resp then
    print(render(err))
  end
  -- Output:
  -- plain message
  -- invalid_request: unsupported URL scheme: ftp
end

-- Suppress unused warnings for examples
local _ = {Example_sink}
