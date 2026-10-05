-- test/profile_page.tmpl, this and profile_page_sample.tl are the tree's
-- own template, a module the build makes. They live in test/ because
-- that is a flat directory the build reads that holds no public
-- standard library (cosmic/'s modules must document every member, which
-- a template's `render` cannot) and is not skipped as doc/ is. Three
-- small modules ship in every binary for it: they earn cosmic.html's
-- URL door (href, raw_url through the generated module, trust_url
-- through the sample) a use outside a test, which an export needs.

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
