-- Strings made safe for HTML, as the core provides them. A safe value is
-- opaque userdata: only these functions make one, so no table, string or
-- value of the other type stands in for it.
--- @kind binding

local record html
  -- Markup that can go in element content as it is.
  record SafeHtml
    userdata
  end

  -- A value that can go inside a quoted attribute value.
  record SafeAttr
    userdata
  end

  -- A whole URL for an href or src, which `href` makes.
  record SafeUrl
    userdata
  end

  -- A URL the page loads and runs or styles itself by, which only
  -- [`trust_resource_url`] makes.
  record SafeResourceUrl
    userdata
  end

  -- One piece of a URL, which [`url_part`] and [`url_query`] make.
  record SafeUrlPart
    userdata
  end

  -- JSON text, which [`trust_json`] makes.
  record SafeJson
    userdata
  end

  -- The string, with `& < > " '` made entities.
  escape: function(s: string): SafeHtml
  -- The string with `& " ' < >` made entities and a backtick, C0 control
  -- or DEL a decimal character reference; every other byte passes. For a
  -- quoted attribute value.
  escape_attr: function(s: string): SafeAttr
  -- The string as markup, unchecked.
  trust: function(s: string): SafeHtml
  -- The string as an attribute value, unchecked.
  trust_attr: function(s: string): SafeAttr
  -- The string as a URL if its scheme is http, https or mailto or it is a
  -- relative reference, else "about:invalid"; see cosmic.html.
  href: function(s: string): SafeUrl
  -- The string as a URL, unchecked.
  trust_url: function(s: string): SafeUrl
  -- The string a SafeUrl holds. Raises on anything else.
  raw_url: function(x: SafeUrl): string
  -- The string as a URL of a resource the page loads, unchecked.
  trust_resource_url: function(s: string): SafeResourceUrl
  -- The string a SafeResourceUrl holds. Raises on anything else.
  raw_resource_url: function(x: SafeResourceUrl): string
  -- The string, or the number's text, with every byte but A-Z a-z 0-9
  -- `-` `.` `_` `~` made %XX; a value of "." or ".." is made "%252E" or
  -- "%252E%252E". Raises on any other type.
  url_part: function(s: string | number): SafeUrlPart
  -- The entries as `name=value` joined by `&`, each half escaped as by
  -- url_part but for the dot rule. nil and why for a pair that is not two
  -- strings; raises on a table that is no sequence.
  url_query: function(entries: {{string}}): SafeUrlPart?, string
  -- The string a SafeUrlPart holds. Raises on anything else.
  raw_url_part: function(x: SafeUrlPart): string
  -- The string as a URL if it is a relative reference with no scheme,
  -- else "about:invalid".
  local_href: function(s: string): SafeUrl
  -- The string, or the number's text, escaped as CSS identifier text, which
  -- holds nothing a quoted attribute value must escape.
  escape_css_attr: function(s: string | number): SafeAttr
  -- The string as JSON text, unchecked.
  trust_json: function(s: string): SafeJson
  -- The string a SafeJson holds. Raises on anything else.
  raw_json: function(x: SafeJson): string
  -- The string a SafeHtml holds. Raises on anything else.
  raw: function(x: SafeHtml): string
  -- The string a SafeAttr holds. Raises on anything else.
  raw_attr: function(x: SafeAttr): string
  -- The markup of each part in order. Raises on a table that is not a
  -- sequence, and on an element that is not a SafeHtml.
  concat: function(parts: {SafeHtml}): SafeHtml
end

return html
