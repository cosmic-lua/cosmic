--- [`cosmic.html`]'s `href` against the WHATWG URL test data: a URL it
--- lets through must resolve, in a browser, to a web or mail link, and
--- one with no scheme must stay on its base's host.
local Fs = require("cosmic.fs")
local Html = require("cosmic.html")
local Json = require("cosmic.json")
local Test = require("cosmic.test")

Test.policy{ grants = { { path = "vendor/wpt-url/urltestdata.json", letters = "r" } } }

--- The fewest entries the check must reach: it reaches about 210 of the
--- data's 900, the rest being failures or another base.
local floor <const> = 150

--- What a browser reads of `input` before it looks for a scheme: leading
--- C0 controls and spaces, and every tab and newline, dropped.
local function trimmed(input: string): string
  return (input:gsub("^[%z\1-\32]+", ""):gsub("[\t\n\r]", ""))
end

local function test_href_agrees_with_the_whatwg_url_data()
  local text = assert(Fs.read("vendor/wpt-url/urltestdata.json"))
  local entries = assert(Json.decode(text)) as {any}
  local checked, relative = 0, 0
  for _, raw in ipairs(entries) do
    -- The data's few strings are comments between its entries.
    if raw is table then
      local entry = raw as {string:any}
      local input, base = entry.input, entry.base
      local base_text = base as string
      local base_scheme = base is string and base_text:match("^(https?:)//") or nil
      if input is string and entry.failure == nil and (base == nil or base_scheme ~= nil) and
          Html.raw_url(Html.href(input)) ~= "about:invalid" then
        checked = checked + 1
        local protocol = entry.protocol
        assert(protocol == "http:" or protocol == "https:" or protocol == "mailto:",
          ("%q resolves to %s"):format(input, tostring(protocol)))
        if not trimmed(input):find("^%a[%w+.-]*:") then
          relative = relative + 1
          local authority = assert(base_text:match("^https?://([^/?#]*)"))
          local base_host = authority:gsub("^.*@", ""):lower()
          assert(entry.host == base_host and protocol == base_scheme,
            ("%q against %s resolves to %s//%s"):format(
              input, base_text, tostring(protocol), tostring(entry.host)))
        end
      end
    end
  end
  assert(checked >= floor, "only " .. checked .. " entries were checked")
  assert(relative >= 20, "only " .. relative .. " relative entries were checked")
end
