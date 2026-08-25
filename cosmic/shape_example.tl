--- Examples for the cosmic.shape module.
--- Demonstrates validating a decoded value into a declared record, the
--- error a mismatch produces, and a list of nested records.

-- Example_into demonstrates the whole point: after one validating
-- call the fields are ordinary typed reads, with no cast anywhere.
local function Example_into()
  local json = require("cosmic.json")
  local shape = require("cosmic.shape")
  local record Server
    host: string
    port: integer
    tls: boolean
  end
  local SERVER = shape.record({
      host = shape.string,
      port = shape.integer,
      tls = shape.optional(shape.boolean),
    })
  local decoded = json.decode('{"host":"localhost","port":8080}')
  local server, err: Server | nil, string = shape.into(decoded, SERVER)
  if server == nil then
    print("invalid: " .. err)
    return
  end
  print(server.host, server.port, server.tls)
  -- Output:
  -- localhost	8080	nil
end

-- Example_mismatch demonstrates the error: the first thing that does
-- not match, named by its path through the value.
local function Example_mismatch()
  local json = require("cosmic.json")
  local shape = require("cosmic.shape")
  local record Server
    host: string
    port: integer
  end
  local SERVER = shape.record({host = shape.string, port = shape.integer})
  local decoded = json.decode('{"host":"localhost","port":"8080"}')
  local _server, err: Server | nil, string = shape.into(decoded, SERVER)
  print(err)
  -- Output:
  -- port: expected integer, got string
end

-- Example_nested demonstrates a list inside a record: the whole tree
-- is checked, and a bad element is named by its index.
local function Example_nested()
  local json = require("cosmic.json")
  local shape = require("cosmic.shape")
  local record Release
    tag: string
    assets: {string}
  end
  local RELEASE = shape.record({
      tag = shape.string,
      assets = shape.list(shape.string),
    })
  local good = json.decode('{"tag":"v1","assets":["lua","zip"]}')
  local release, err: Release | nil, string = shape.into(good, RELEASE)
  if release ~= nil then
    print(release.tag, #release.assets, release.assets[2])
  else
    print(err)
  end
  local bad = json.decode('{"tag":"v1","assets":["lua",3]}')
  local _r, berr: Release | nil, string = shape.into(bad, RELEASE)
  print(berr)
  -- Output:
  -- v1	2	zip
  -- assets[2]: expected string, got number
end

-- Suppress unused warnings for examples
local _ = {Example_into, Example_mismatch, Example_nested}
