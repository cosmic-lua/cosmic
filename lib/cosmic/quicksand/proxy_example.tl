--- Example for cosmic.quicksand.proxy.

-- Example_start_stop demonstrates the common pattern: start the
-- proxy on an ephemeral port, query the bound port, then tear it
-- down with stop() (which SIGTERMs and waitpids the listener).
local function Example_start_stop()
  local quicksand = require("cosmic.quicksand")
  if not quicksand.capabilities().linux then
    io.write("not linux\n")
    return
  end
  local proxy = require("cosmic.quicksand.proxy")
  local handle, err = proxy.start({
      bind_ip = 0x7f000001,
      bind_port = 0,
      allowed_hosts = {
        ["api.example.com:443"] = {},
        ["internal.example.com:80"] = {
          type = "bearer",
          token = "redacted",
        },
      },
      log_level = "quiet",
    })
  if not handle then
    io.write("proxy start failed: " .. tostring(err) .. "\n")
    return
  end
  io.write("listening\n")
  local h = handle as proxy.ProxyHandle
  h:stop()
end

return {}
