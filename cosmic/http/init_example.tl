--- Examples for the cosmic.http module.
--- The server is real but local: it listens on an OS-assigned loopback
--- port and a forked child serves exactly one connection, so the output
--- is deterministic and no external host is contacted.

-- Example_hello demonstrates the whole surface in one exchange: listen
-- on an ephemeral port, serve one connection in a forked child, and
-- fetch from it. allow_private opts the client out of the SSRF guard
-- that otherwise blocks loopback addresses.
local function Example_hello()
  local check = require("cosmic.check")
  local fetch = require("cosmic.fetch")
  local http = require("cosmic.http")
  local proc = require("cosmic.proc")

  local srv = check.must(http.listen("127.0.0.1", 0))
  local port = srv:port()
  local pid = check.must(proc.fork())
  if pid == 0 then
    assert(srv:serve_one(function(req: http.Request, res: http.Response)
          local _ok, _err = res:text("hello " .. req.path .. "\n")
        end))
    os.exit(0)
  end
  assert(srv:close())

  local result = check.must(fetch.fetch("http://127.0.0.1:" .. port .. "/world",
      {allow_private = true}))
  assert(proc.wait(pid))
  print(result.status)
  io.write(result.body)
  -- Output:
  -- 200
  -- hello /world
end

-- Suppress unused warnings for examples
local _ = {Example_hello}
