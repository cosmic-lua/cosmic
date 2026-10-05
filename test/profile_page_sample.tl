local html = require("cosmic.html")
local data = require("test.profile_page_data")

--- What a program hands the page: the links are addresses it vouches for
--- ([`Html.trust_url`]), the site is text from outside, which the page
--- checks as it writes it.
local record sample
end

function sample.profile(name: string, site: string): data.Profile
  return {
    name = name,
    site = site,
    links = { { name = "home", url = html.trust_url("/home") } },
  }
end

return sample
