--- What the markup cosmic.web writes itself is given: the records of its
--- templates (`error_page.tmpl`, `csrf_field.tmpl`, `csrf_meta.tmpl`,
--- `htmx_head.tmpl`, `dev_tag.tmpl`), apart so that a template's import
--- of its record is no cycle.

local type Html = require("cosmic.html")

local record MarkupData
  --- An error page (cosmic/web/errors.tl).
  record ErrorPage
    --- "404 Not Found": the page's title and heading.
    title: string
    --- What went wrong, a paragraph; nil for none.
    detail?: string
    --- The fault and its stack, shown when debug is on; nil for none.
    trace?: string
  end

  --- A tag that carries a request's CSRF token (cosmic/web/csrf.tl).
  record Token
    --- The form field's name, for the hidden input.
    name: string
    --- The token.
    token: string
  end

  --- One script of htmx's.
  record Script
    --- Where the page loads it from.
    src: Html.SafeResourceUrl
    --- Its subresource integrity, `sha384-...`.
    integrity: string
  end

  --- The head tags of a page that loads htmx (cosmic/web/htmx.tl).
  record HtmxHead
    --- The configuration, as JSON text.
    config: string
    --- The scripts, htmx first.
    scripts: {Script}
    --- A CSP nonce for each script; nil for none.
    nonce?: string
  end

  --- The tag that loads the dev script (cosmic/web/dev.tl).
  record DevTag
    --- A CSP nonce; nil for none.
    nonce?: string
  end
end

return MarkupData
