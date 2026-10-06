-- Strings made safe for HTML, as the core provides them. A safe value is
-- opaque userdata: only these functions make one, so no table, string or
-- value of the other type stands in for it.

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

  -- The string, with `& < > " '` made entities.
  escape: function(s: string): SafeHtml
  -- The string with every ASCII byte but a letter or digit made a numeric
  -- character reference; bytes of 0x80 or more pass through. For a
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
  -- The string a SafeHtml holds. Raises on anything else.
  raw: function(x: SafeHtml): string
  -- The string a SafeAttr holds. Raises on anything else.
  raw_attr: function(x: SafeAttr): string
  -- The markup of each part in order. Raises on a table that is not a
  -- sequence, and on an element that is not a SafeHtml.
  concat: function(parts: {SafeHtml}): SafeHtml
end

return html
