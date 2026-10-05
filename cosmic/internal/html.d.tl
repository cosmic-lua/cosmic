-- Strings made safe for HTML, as the core provides them. A safe value is
-- opaque userdata: only these functions make one, so no table, string or
-- value of the other type stands in for it.

local record html
  -- Markup that can go in element content as it is.
  record SafeHtml
    userdata
  end

  -- A value that can go inside an attribute, quoted or not.
  record SafeAttr
    userdata
  end

  -- The string, with `& < > " '` made entities.
  escape: function(s: string): SafeHtml
  -- The string with every byte but an ASCII letter or digit, and any byte
  -- of 0x80 or more, made a numeric character reference.
  escape_attr: function(s: string): SafeAttr
  -- The string as markup, unchecked.
  trust: function(s: string): SafeHtml
  -- The string as an attribute value, unchecked.
  trust_attr: function(s: string): SafeAttr
  -- The string a SafeHtml holds. Raises on anything else.
  raw: function(x: SafeHtml): string
  -- The string a SafeAttr holds. Raises on anything else.
  raw_attr: function(x: SafeAttr): string
  -- The markup of each part in order. Raises on an element that is not a
  -- SafeHtml.
  concat: function(parts: {SafeHtml}): SafeHtml
end

return html
