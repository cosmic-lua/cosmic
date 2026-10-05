--- [`cosmic.html`]'s `href` against the WHATWG URL test data: a URL it
--- lets through must resolve, in a browser, to a web or mail link, and
--- one with no scheme must stay on its base's scheme and, for a web
--- base, its host.
local Fs = require("cosmic.fs")
local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "vendor/wpt-url/urltestdata.json", letters = "r" } } }

--- The fewest entries the check must reach, and of them the fewest
--- with no scheme: it reaches 284 and 101.
local floor <const> = 150
local relative_floor <const> = 50

local function test_href_agrees_with_the_whatwg_url_data()
  local text = assert(Fs.read("vendor/wpt-url/urltestdata.json"))
  local entries = assert(Json.decode(text)) as {any}
  local checked, relative = 0, 0
  for _, raw in ipairs(entries) do
    -- The data's few strings are comments between its entries.
    if raw is table then
      local entry = raw as {string:any}
      local input, base = entry.input, entry.base
      if input is string and entry.failure == nil and (base == nil or base is string) and
          Html.raw_url(Html.href(input)) ~= "about:invalid" then
        checked = checked + 1
        local protocol = entry.protocol
        if input:find("^%a[%w+.-]*:") then
          assert(protocol == "http:" or protocol == "https:" or protocol == "mailto:",
            ("%q resolves to %s"):format(input, tostring(protocol)))
        else
          relative = relative + 1
          local base_text = assert(base, "a relative input has a base") as string
          assert(protocol == base_text:match("^%a[%w+.-]*:"):lower(),
            ("%q against %s resolves to %s"):format(input, base_text, tostring(protocol)))
          -- The data's web bases hold at most a user name and a lower-case
          -- host, which this reads where a URL parser would.
          local authority = base_text:match("^https?://([^/?#]*)")
          if authority ~= nil then
            assert(entry.host == authority:gsub("^.*@", ""):lower(),
              ("%q against %s resolves to host %s"):format(input, base_text, tostring(entry.host)))
          end
        end
      end
    end
  end
  assert(checked >= floor, "only " .. checked .. " entries were checked")
  assert(relative >= relative_floor, "only " .. relative .. " relative entries were checked")
end
