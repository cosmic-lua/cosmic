local html = require("cosmic.html")

--- What the template beside it, `profile_page.tmpl`, renders.
local record data
  record Link
    name: string
    url: html.SafeUrl
  end
  record Profile
    name: string
    site: string
    links: {Link}
  end
end

return data
